type progress =
  { received_bytes : int
  ; total_bytes : int option
  ; datom_count : int option
  }

let artifact_row_count headers =
  let value =
    List.find_map
      (fun (name, value) ->
         if String.equal (String.lowercase_ascii name) "x-snapshot-row-count"
         then Some value
         else None)
      headers
  in
  match Option.bind value int_of_string_opt with
  | Some value when value > 0 -> Ok value
  | _ -> Error "snapshot row-count header is invalid"
;;

let remove_if_exists path =
  try Sys.remove path with
  | Sys_error _ -> ()
;;

let cleanup = List.iter remove_if_exists

let gzip_signature path =
  try
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr channel)
      (fun () ->
         try
           let first = input_char channel in
           let second = input_char channel in
           Ok (first = '\x1f' && second = '\x8b')
         with
         | End_of_file -> Ok false)
  with
  | Sys_error message -> Error message
;;

let copy_file ~maximum_bytes source destination =
  try
    let input_channel = open_in_bin source in
    Fun.protect
      ~finally:(fun () -> close_in_noerr input_channel)
      (fun () ->
         let output_channel =
           open_out_gen
             [ Open_wronly; Open_creat; Open_excl; Open_binary ]
             0o600
             destination
         in
         Fun.protect
           ~finally:(fun () -> close_out_noerr output_channel)
           (fun () ->
              let buffer = Bytes.create 16_384 in
              let copied = ref 0 in
              let rec loop () =
                let count = input input_channel buffer 0 (Bytes.length buffer) in
                if count > 0
                then (
                  if !copied + count > maximum_bytes
                  then failwith "snapshot artifact exceeds its decompressed bound";
                  output output_channel buffer 0 count;
                  copied := !copied + count;
                  loop ())
              in
              loop ()));
    Ok ()
  with
  | Sys_error message ->
    remove_if_exists destination;
    Error message
  | exception_ ->
    remove_if_exists destination;
    Error (Printexc.to_string exception_)
;;

let nonempty path =
  try (Unix.stat path).st_size > 0 with
  | Unix.Unix_error _ -> false
;;

let decompress ~decompress_gzip ~maximum_bytes source destination =
  remove_if_exists destination;
  match decompress_gzip source destination maximum_bytes with
  | 0 when nonempty destination -> Ok ()
  | 0 ->
    remove_if_exists destination;
    Error "snapshot gzip layer is empty"
  | _ ->
    remove_if_exists destination;
    Error "snapshot gzip layer is invalid"
;;

let peel_gzip_layers ~decompress_gzip ~maximum_bytes ~source ~destination ~temporary_paths
  =
  if maximum_bytes <= 0
  then Error "snapshot decompressed bound must be positive"
  else (
    match temporary_paths with
    | first :: second :: _ ->
      cleanup [ destination; first; second ];
      let fail message =
        cleanup [ destination; first; second ];
        Error message
      in
      (match gzip_signature source with
       | Error message -> fail message
       | Ok false -> copy_file ~maximum_bytes source destination
       | Ok true ->
         (match decompress ~decompress_gzip ~maximum_bytes source first with
          | Error message -> fail message
          | Ok () ->
            (match gzip_signature first with
             | Error message -> fail message
             | Ok false ->
               (try
                  Sys.rename first destination;
                  cleanup [ second ];
                  Ok ()
                with
                | Sys_error message -> fail message)
             | Ok true ->
               (match decompress ~decompress_gzip ~maximum_bytes first second with
                | Error message -> fail message
                | Ok () ->
                  (match gzip_signature second with
                   | Error message -> fail message
                   | Ok true -> fail "snapshot exceeds the supported gzip layer count"
                   | Ok false ->
                     (try
                        Sys.rename second destination;
                        cleanup [ first ];
                        Ok ()
                      with
                      | Sys_error message -> fail message))))))
    | [] | [ _ ] -> Error "two private gzip staging paths are required")
;;

(* Cache IO is private to the runner interpreter. *)
module Asset_cache = struct
  module Core = Logseq_sync_pure_reducer.Core
  module Asset = Logseq_db_types.Asset_descriptor
  module Uuid = Logseq_db_types.Graph_types.Uuid

  type handle = string

  type error =
    | Invalid of string
    | Io of string
    | Full
    | Stale
    | Checksum_mismatch

  type manifest =
    { asset : Uuid.t
    ; file_type : string
    ; checksum : string
    ; size : int64
    }
  [@@deriving yojson]

  type record =
    { name : string
    ; file_type : string
    ; checksum : string
    ; size : int64
    ; mutable touched : float
    ; mutable pins : int
    }

  type staged_record =
    { staged_name : string
    ; staged_location : string
    ; mutable staged_pins : int
    ; mutable retired : bool
    }

  type t =
    { directory : string
    ; budget : int64
    ; maximum_file_bytes : int
    ; records : (string, record) Hashtbl.t
    ; handles : (handle, record) Hashtbl.t
    ; staged_records : (string, staged_record) Hashtbl.t
    ; staged_handles : (handle, staged_record) Hashtbl.t
    ; mutable closed : bool
    }

  let next_handle = Atomic.make 0
  let ( let* ) = Result.bind

  let protect f =
    try f () with
    | Sys_error message | Failure message -> Error (Io message)
    | Yojson.Json_error message -> Error (Invalid message)
    | Yojson.Safe.Util.Type_error (message, _) -> Error (Invalid message)
    | Unix.Unix_error (error, operation, _) ->
      Error (Io (operation ^ ": " ^ Unix.error_message error))
  ;;

  let rec mkdir path =
    if not (Sys.file_exists path)
    then (
      mkdir (Filename.dirname path);
      Unix.mkdir path 0o700;
      let parent = Unix.openfile (Filename.dirname path) [ Unix.O_RDONLY ] 0 in
      Fun.protect ~finally:(fun () -> Unix.close parent) (fun () -> Unix.fsync parent))
  ;;

  let unlink path =
    try Unix.unlink path with
    | Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  ;;

  (* Data files carry the validated attachment type so native presentation
     (for example Quick Look) classifies them correctly. *)
  let data_path t record =
    Filename.concat t.directory (record.name ^ "." ^ record.file_type)
  ;;

  let manifest_path t name = Filename.concat t.directory (name ^ ".json")

  let name asset (version : Asset.version) =
    Asset_codec.checksum
      (Uuid.to_string asset ^ ":" ^ version.file_type ^ ":" ^ version.checksum)
  ;;

  let sync_directory t =
    let fd = Unix.openfile t.directory [ Unix.O_RDONLY ] 0 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
  ;;

  let write path bytes =
    let fd = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_TRUNC ] 0o600 in
    Fun.protect
      ~finally:(fun () -> Unix.close fd)
      (fun () ->
         let rec loop offset =
           if offset < String.length bytes
           then (
             let count =
               Unix.write_substring fd bytes offset (String.length bytes - offset)
             in
             if count = 0
             then raise (Sys_error "Asset file write made no progress")
             else loop (offset + count))
         in
         loop 0;
         Unix.fsync fd)
  ;;

  let checksum_file path =
    let channel = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in channel)
      (fun () ->
         let buffer = Bytes.create 65536 in
         let rec read context =
           match input channel buffer 0 (Bytes.length buffer) with
           | 0 -> Digestif.SHA256.(to_hex (get context))
           | length -> read (Digestif.SHA256.feed_bytes context ~off:0 ~len:length buffer)
         in
         read Digestif.SHA256.empty)
  ;;

  let remove_record t record =
    unlink (manifest_path t record.name);
    unlink (data_path t record);
    Hashtbl.remove t.records record.name
  ;;

  let pin t record =
    record.pins <- record.pins + 1;
    record.touched <- Unix.gettimeofday ();
    Unix.utimes (manifest_path t record.name) record.touched record.touched;
    let handle = Printf.sprintf "asset:%d" (Atomic.fetch_and_add next_handle 1) in
    Hashtbl.add t.handles handle record;
    handle
  ;;

  let read_manifest directory file =
    let path = Filename.concat directory file in
    let invalid () = Error (Invalid "Unsupported or invalid asset cache manifest") in
    try
      if (Unix.stat path).st_size > 1024
      then invalid ()
      else (
        match
          Logseq_db_types.Json_codec.decode
            manifest_of_yojson
            (Yojson.Safe.from_file path)
        with
        | Error _ -> invalid ()
        | Ok manifest ->
          (match
             Asset.version ~checksum:manifest.checksum ~file_type:manifest.file_type
           with
           | Ok version
             when manifest.size >= 0L && name manifest.asset version ^ ".json" = file ->
             Ok
               { name = name manifest.asset version
               ; file_type = version.file_type
               ; checksum = version.checksum
               ; size = manifest.size
               ; touched = (Unix.stat path).st_mtime
               ; pins = 0
               }
           | Ok _ | Error _ -> invalid ()))
    with
    | Yojson.Json_error _ | Failure _ | Invalid_argument _ -> invalid ()
  ;;

  type account_identity = string * string [@@deriving to_yojson]

  let account_directory ~root (account : Core.account_scope) =
    let name =
      Asset_codec.checksum
        (account_identity_to_yojson
           (Uri.to_string account.managed_sync_origin, account.user_id)
         |> Yojson.Safe.to_string)
    in
    Filename.concat root name
  ;;


  let lookup t ~asset ~version =
    protect (fun () ->
      if t.closed
      then Error Stale
      else (
        match Hashtbl.find_opt t.records (name asset version) with
        | None -> Ok None
        | Some record ->
          let path = data_path t record in
          let valid =
            try
              let stat = Unix.stat path in
              stat.st_kind = Unix.S_REG
              && Int64.of_int stat.st_size = record.size
              && stat.st_size <= t.maximum_file_bytes
              && checksum_file path = record.checksum
            with
            | Sys_error _ | Unix.Unix_error _ -> false
          in
          if valid
          then Ok (Some (pin t record))
          else (
            if record.pins = 0 then remove_record t record;
            Ok None)))
  ;;

  let reserve t needed =
    let usage =
      Hashtbl.fold (fun _ record total -> Int64.add total record.size) t.records 0L
    in
    let candidates =
      Hashtbl.fold
        (fun _ record acc -> if record.pins = 0 then record :: acc else acc)
        t.records
        []
      |> List.sort (fun a b -> Float.compare a.touched b.touched)
    in
    let rec evict usage = function
      | _ when needed <= t.budget && usage <= Int64.sub t.budget needed -> Ok ()
      | [] -> Error Full
      | record :: rest ->
        remove_record t record;
        evict (Int64.sub usage record.size) rest
    in
    if needed > t.budget then Error Full else evict usage candidates
  ;;

  let publish t ~asset ~(version : Asset.version) ~current ~plaintext =
    protect (fun () ->
      if t.closed || not (current ())
      then Error Stale
      else if String.length plaintext > t.maximum_file_bytes
      then Error (Invalid "Asset exceeds cache file limit")
      else if Asset_codec.checksum plaintext <> version.checksum
      then Error Checksum_mismatch
      else
        let* existing = lookup t ~asset ~version in
        match existing with
        | Some handle -> Ok handle
        | None ->
          let size = Int64.of_int (String.length plaintext) in
          let* () = reserve t size in
          let name = name asset version in
          (* A corrupt pinned record cannot be replaced beneath a renderer. *)
          if Hashtbl.mem t.records name
          then Error Full
          else (
            let record =
              { name
              ; file_type = version.file_type
              ; checksum = version.checksum
              ; size
              ; touched = Unix.gettimeofday ()
              ; pins = 0
              }
            in
            let data = data_path t record
            and manifest = manifest_path t name in
            let temporary = data ^ ".part"
            and temporary_manifest = manifest ^ ".part" in
            Fun.protect
              ~finally:(fun () ->
                unlink temporary;
                unlink temporary_manifest)
              (fun () ->
                 write temporary plaintext;
                 write
                   temporary_manifest
                   (manifest_to_yojson
                      { asset
                      ; file_type = version.file_type
                      ; checksum = version.checksum
                      ; size
                      }
                    |> Yojson.Safe.to_string);
                 if t.closed || not (current ())
                 then Error Stale
                 else (
                   Unix.rename temporary data;
                   Unix.rename temporary_manifest manifest;
                   sync_directory t;
                   Hashtbl.replace t.records name record;
                   Ok (pin t record)))))
  ;;

  let pin_staged t record =
    record.staged_pins <- record.staged_pins + 1;
    let handle = Printf.sprintf "staged:%d" (Atomic.fetch_and_add next_handle 1) in
    Hashtbl.add t.staged_handles handle record;
    handle
  ;;

  let clean_retired_staging t record =
    if record.retired && record.staged_pins = 0
    then
      protect (fun () ->
        unlink record.staged_location;
        let directory = Filename.dirname record.staged_location in
        if Sys.file_exists directory
        then (
          let fd = Unix.openfile directory [ Unix.O_RDONLY ] 0 in
          Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd));
        Hashtbl.remove t.staged_records record.staged_name;
        Ok ())
    else Ok ()
  ;;

  let path t handle =
    if t.closed
    then None
    else (
      match Hashtbl.find_opt t.handles handle with
      | Some record -> Some (data_path t record)
      | None ->
        Option.map
          (fun record -> record.staged_location)
          (Hashtbl.find_opt t.staged_handles handle))
  ;;

  let retain t handle =
    if t.closed
    then None
    else (
      match Hashtbl.find_opt t.handles handle with
      | Some record -> Some (pin t record)
      | None -> Option.map (pin_staged t) (Hashtbl.find_opt t.staged_handles handle))
  ;;

  let release t handle =
    match Hashtbl.find_opt t.handles handle with
    | Some record ->
      record.pins <- record.pins - 1;
      Hashtbl.remove t.handles handle
    | None ->
      (match Hashtbl.find_opt t.staged_handles handle with
       | None -> ()
       | Some record ->
         record.staged_pins <- record.staged_pins - 1;
         Hashtbl.remove t.staged_handles handle;
         if record.retired
         then ignore (clean_retired_staging t record)
         else if record.staged_pins = 0
         then Hashtbl.remove t.staged_records record.staged_name)
  ;;

  let close t =
    t.closed <- true;
    Hashtbl.clear t.handles;
    Hashtbl.iter (fun _ record -> record.pins <- 0) t.records;
    Hashtbl.clear t.staged_handles;
    Hashtbl.fold (fun _ record records -> record :: records) t.staged_records []
    |> List.iter (fun record ->
      record.staged_pins <- 0;
      ignore (clean_retired_staging t record));
    Hashtbl.clear t.staged_records
  ;;

  let remove_tree path =
    let rec remove path =
      match Unix.lstat path with
      | { Unix.st_kind = Unix.S_DIR; _ } ->
        Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
        Unix.rmdir path
      | _ -> Unix.unlink path
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
    in
    protect (fun () ->
      remove path;
      Ok ())
  ;;

  external rename_exclusive : string -> string -> int = "logseq_journal_rename_exclusive"

  let graph_deletion_paths ~root (scope : Core.graph_scope) retirement =
    let account = account_directory ~root scope.account in
    let graph = Uuid.to_string scope.graph_id in
    let directory = Filename.concat
      (Filename.concat (Filename.concat root ".asset-retirements") (Filename.basename account)) graph in
    Filename.concat account graph, directory,
    Filename.concat (Filename.concat directory "states") (Core.retirement_id_to_string retirement ^ ".json"),
    Filename.concat (Filename.concat directory "pending") (Core.retirement_id_to_string retirement ^ ".data")
  ;;

  let sync_path directory =
    let fd = Unix.openfile directory [Unix.O_RDONLY] 0 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
  ;;

  let write_retirement path json =
    let temporary = path ^ ".part" in
    write temporary (Yojson.Safe.to_string json);
    Unix.rename temporary path;
    sync_path (Filename.dirname path)
  ;;

  let identity path =
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; st_dev; st_ino; _ } -> Printf.sprintf "%d:%d" st_dev st_ino
    | _ -> failwith "asset namespace is not a directory"
  ;;

  let retirement_state manifest_path =
    let open Yojson.Safe.Util in
    let json = Yojson.Safe.from_file manifest_path in
    if json |> member "version" |> to_int <> 1 then failwith "unsupported asset retirement";
    json |> member "identity" |> to_string, json |> member "state" |> to_string
  ;;

  let retirement_json captured state =
    `Assoc ["version", `Int 1; "identity", `String captured; "state", `String state]
  ;;

  let graph_deletion_terminal ~root ~scope ~retirement =
    protect (fun () ->
      let _, _, manifest, _ = graph_deletion_paths ~root scope retirement in
      if not (Sys.file_exists manifest) then Ok None else
        let _, state = retirement_state manifest in
        Ok (match state with
          | "complete" | "committed" ->
            let fd = Unix.openfile manifest [Unix.O_RDONLY] 0 in
            Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd);
            sync_path (Filename.dirname manifest);
            Some `Committed
          | "aborted" | "account-deleted" -> Some `Aborted
          | _ -> None))
  ;;

  let prepare_graph_deletion ~root ~(scope : Core.graph_scope) ~retirement =
    protect (fun () ->
      let canonical, directory, manifest, data = graph_deletion_paths ~root scope retirement in
      mkdir directory;
      mkdir (Filename.dirname manifest); mkdir (Filename.dirname data);
      let captured, state =
        if Sys.file_exists manifest then retirement_state manifest
        else (
          let captured = if Sys.file_exists canonical then identity canonical else "absent" in
          write_retirement manifest (retirement_json captured "preparing"); captured, "preparing") in
      if state <> "preparing" && state <> "prepared" then Error Stale
      else (
        if Sys.file_exists data then (
          if identity data <> captured then failwith "retired asset identity changed")
        else if captured <> "absent" then (
          if not (Sys.file_exists canonical) || identity canonical <> captured
          then failwith "canonical asset identity changed";
          let error = rename_exclusive canonical data in
          if error <> 0 then failwith ("asset retirement rename failed: " ^ string_of_int error);
          sync_path (Filename.dirname canonical); sync_path (Filename.dirname data));
        write_retirement manifest (retirement_json captured "prepared");
        Ok ()))
  ;;

  let finish_graph_deletion ~root ~deletion ~commit =
    protect (fun () ->
      let scope = Core.asset_deletion_scope deletion in
      let canonical, _directory, manifest, data = graph_deletion_paths ~root scope
          (Core.asset_deletion_retirement deletion) in
      if not (Sys.file_exists manifest) then (
        if Sys.file_exists data then Error Stale
        else if commit then Error Stale
        else (
          mkdir (Filename.dirname manifest);
          write_retirement manifest (retirement_json "absent" "aborted"); Ok ()))
      else
        let captured, state = retirement_state manifest in
        if state = "account-deleted" then (
          ignore (remove_tree data); Ok ())
        else if state = "aborted" || state = "complete" then Ok ()
        else if commit then (
          if Sys.file_exists data && identity data <> captured then failwith "retired asset identity changed";
          write_retirement manifest (retirement_json captured "committed");
          (* The producer owns deferred collection. A purge failure must not
             block a replacement cache or undo the durable commit decision. *)
          (match remove_tree data with
           | Error _ -> ()
           | Ok () ->
             (try sync_path (Filename.dirname data);
                  write_retirement manifest (retirement_json captured "complete") with _ -> ()));
          Ok ())
        else if state = "committed" then Ok ()
        else (
          if Sys.file_exists data then (
            if identity data <> captured then failwith "retired asset identity changed";
            mkdir (Filename.dirname canonical);
            let error = rename_exclusive data canonical in
            if error <> 0 then failwith ("asset restore conflict; retirement retained: " ^ string_of_int error);
            sync_path (Filename.dirname canonical); sync_path (Filename.dirname data))
          else if captured <> "absent" &&
            (not (Sys.file_exists canonical) || identity canonical <> captured)
          then failwith "asset restore is incomplete; retirement retained";
          if Sys.file_exists (Filename.dirname canonical) then sync_path (Filename.dirname canonical);
          if Sys.file_exists (Filename.dirname data) then sync_path (Filename.dirname data);
          write_retirement manifest (retirement_json captured "aborted");
          Ok ()))
  ;;

  let collect_retired_assets ~root ~(scope : Core.graph_scope) =
    let _, directory, _, _ = graph_deletion_paths ~root scope
      (Core.retirement_id_of_string "00000000-0000-4000-8000-000000000000" |> Result.get_ok) in
    let pending = Filename.concat directory "pending" in
    if Sys.file_exists pending then
      Array.iter (fun name ->
        if Filename.check_suffix name ".data" then
          try
            let retirement = Filename.chop_suffix name ".data" |> Core.retirement_id_of_string |> Result.get_ok in
            let _, _, manifest, _ = graph_deletion_paths ~root scope retirement in
            let _, state = retirement_state manifest in
            if state = "committed" || state = "complete" || state = "account-deleted" then
              ignore (finish_graph_deletion ~root
                ~deletion:(Core.asset_deletion_reference ~scope ~retirement) ~commit:true)
          with _ -> ()) (Sys.readdir pending)
  ;;

  let delete_account ~root ~account =
    protect (fun () ->
      let directory = account_directory ~root account in
      let retired = Filename.concat (Filename.concat root ".asset-retirements") (Filename.basename directory) in
      if Sys.file_exists retired then
        Array.iter (fun graph ->
          match Uuid.of_string graph with
          | Error _ -> ()
          | Ok _ ->
            let folder = Filename.concat retired graph in
            let states = Filename.concat folder "states" in
            if Sys.file_exists states then Array.iter (fun file ->
              if Filename.check_suffix file ".json" then (
                let manifest = Filename.concat states file in
                let captured, _ = retirement_state manifest in
                write_retirement manifest (retirement_json captured "account-deleted"))) (Sys.readdir states);
            match remove_tree (Filename.concat folder "pending") with
            | Ok () -> () | Error _ -> failwith "retired account assets remain") (Sys.readdir retired);
      remove_tree directory)
  ;;

  let create ~root ~(scope : Core.graph_scope) ~budget_bytes ~maximum_file_bytes =
    (try collect_retired_assets ~root ~scope with _ -> ());
    protect (fun () ->
      if
        budget_bytes < 0L
        || maximum_file_bytes < 0
        || maximum_file_bytes > 100 * 1024 * 1024
      then Error (Invalid "Invalid cache size limits")
      else (
        let directory =
          Filename.concat
            (account_directory ~root scope.account)
            (Uuid.to_string scope.graph_id)
        in
        mkdir directory;
        (* Validate all persisted JSON before cleaning anything. Unsupported
           internal formats require an explicit caller-visible failure. *)
        let rec load_manifests records = function
          | [] -> Ok (List.rev records)
          | file :: rest when Filename.check_suffix file ".json" ->
            let* record = read_manifest directory file in
            load_manifests ((file, record) :: records) rest
          | _ :: rest -> load_manifests records rest
        in
        let* manifests = load_manifests [] (Array.to_list (Sys.readdir directory)) in
        let pending = Filename.concat directory "pending" in
        if Sys.file_exists pending
        then
          Array.iter
            (fun file ->
               if Filename.check_suffix file ".part"
               then unlink (Filename.concat pending file))
            (Sys.readdir pending);
        let t =
          { directory
          ; budget = budget_bytes
          ; maximum_file_bytes
          ; records = Hashtbl.create 64
          ; handles = Hashtbl.create 64
          ; staged_records = Hashtbl.create 8
          ; staged_handles = Hashtbl.create 8
          ; closed = false
          }
        in
        List.iter
          (fun (file, (record : record)) ->
             if
               record.size <= Int64.of_int maximum_file_bytes
               && Sys.file_exists (data_path t record)
             then Hashtbl.replace t.records record.name record
             else unlink (Filename.concat directory file))
          manifests;
        Array.iter
          (fun file ->
             if Filename.check_suffix file ".part"
             then unlink (Filename.concat directory file))
          (Sys.readdir directory);
        let kept = Hashtbl.create (2 * Hashtbl.length t.records) in
        Hashtbl.iter
          (fun _ record ->
             Hashtbl.replace kept (record.name ^ ".json") ();
             Hashtbl.replace kept (record.name ^ "." ^ record.file_type) ())
          t.records;
        Array.iter
          (fun file ->
             let path = Filename.concat directory file in
             if (not (Hashtbl.mem kept file)) && not (Sys.is_directory path)
             then unlink path)
          (Sys.readdir directory);
        Ok t))
  ;;

  type staged =
    { file : string
    ; checksum : string
    ; size : int64
    }

  let pending_directory t = Filename.concat t.directory "pending"

  let valid_staged_type file_type =
    Result.is_ok (Asset.version ~checksum:(String.make 64 '0') ~file_type)
  ;;

  let valid_staged_nonce nonce =
    String.length nonce = 64
    && String.for_all
         (function
           | '0' .. '9' | 'a' .. 'f' -> true
           | _ -> false)
         nonce
  ;;

  let valid_staged_file file =
    Filename.basename file = file
    &&
    match String.split_on_char '.' file with
    | [ operation; file_type ] ->
      Result.is_ok (Uuid.of_string operation) && valid_staged_type file_type
    | [ operation; nonce; file_type ] ->
      Result.is_ok (Uuid.of_string operation)
      && valid_staged_nonce nonce
      && valid_staged_type file_type
    | _ -> false
  ;;

  let staged_path t ~file =
    if t.closed || not (valid_staged_file file)
    then None
    else (
      let path = Filename.concat (pending_directory t) file in
      match Unix.lstat path with
      | { Unix.st_kind = Unix.S_REG; _ } -> Some path
      | _ -> None
      | exception Unix.Unix_error _ -> None)
  ;;

  let retain_staged t ~file =
    Option.bind (staged_path t ~file) (fun location ->
      match Hashtbl.find_opt t.staged_records file with
      | Some record when record.retired -> None
      | Some record -> Some (pin_staged t record)
      | None ->
        let record =
          { staged_name = file
          ; staged_location = location
          ; staged_pins = 0
          ; retired = false
          }
        in
        Hashtbl.add t.staged_records file record;
        Some (pin_staged t record))
  ;;

  let release_staged t ~file =
    if t.closed
    then Error Stale
    else if not (valid_staged_file file)
    then Error (Invalid "Invalid staged file")
    else (
      let record =
        match Hashtbl.find_opt t.staged_records file with
        | Some record -> record
        | None ->
          { staged_name = file
          ; staged_location = Filename.concat (pending_directory t) file
          ; staged_pins = 0
          ; retired = true
          }
      in
      record.retired <- true;
      clean_retired_staging t record)
  ;;

  let stage t ~operation ~file_type ~source_file ~pending_budget_bytes =
    if t.closed
    then Error Stale
    else if not (valid_staged_type file_type)
    then Error (Invalid "Invalid staged file type")
    else if pending_budget_bytes < 0L
    then Error (Invalid "Invalid staging budget")
    else
      protect (fun () ->
        let directory = pending_directory t in
        mkdir directory;
        (* A delayed completion must name this physical instance, even if its
           business operation is staged again after pruning or recovery. *)
        let nonce = Asset_codec.checksum (Mirage_crypto_rng_unix.getrandom 16) in
        let file = Uuid.to_string operation ^ "." ^ nonce ^ "." ^ file_type in
        let target = Filename.concat directory file in
        let partial = target ^ ".part" in
        if Sys.file_exists target
        then Error (Invalid "Staged import already exists")
        else (
          let source =
            Unix.openfile source_file [ Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC ] 0
          in
          Fun.protect
            ~finally:(fun () -> Unix.close source)
            (fun () ->
               let metadata = Unix.fstat source in
               if metadata.st_kind <> Unix.S_REG
               then Error (Invalid "Import source must be a regular file")
               else if metadata.st_size > t.maximum_file_bytes
               then Error (Invalid "Import exceeds file size limit")
               else (
                 let files = Sys.readdir directory in
                 let used =
                   Array.fold_left
                     (fun total name ->
                        let size =
                          (Unix.lstat (Filename.concat directory name)).st_size
                        in
                        Int64.add total (Int64.of_int (max 1 size)))
                     0L
                     files
                 in
                 let allocation = Int64.of_int (max 1 metadata.st_size) in
                 if
                   Array.length files >= 4096
                   || used > Int64.sub pending_budget_bytes allocation
                 then Error Full
                 else (
                   let output =
                     Unix.openfile
                       partial
                       [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
                       0o600
                   in
                   Fun.protect
                     ~finally:(fun () ->
                       Unix.close output;
                       unlink partial)
                     (fun () ->
                        let buffer = Bytes.create 65536 in
                        let rec copy count digest =
                          match Unix.read source buffer 0 (Bytes.length buffer) with
                          | 0 -> Ok (count, digest)
                          | length ->
                            if count + length > metadata.st_size
                            then Error (Invalid "Import source changed during staging")
                            else (
                              let rec write offset =
                                if offset < length
                                then (
                                  let written =
                                    Unix.write output buffer offset (length - offset)
                                  in
                                  if written = 0
                                  then raise (Sys_error "Staging write made no progress")
                                  else write (offset + written))
                              in
                              write 0;
                              copy
                                (count + length)
                                (Digestif.SHA256.feed_bytes
                                   digest
                                   ~off:0
                                   ~len:length
                                   buffer))
                        in
                        let* size, digest = copy 0 Digestif.SHA256.empty in
                        let after = Unix.fstat source in
                        if
                          size <> metadata.st_size
                          || after.st_mtime <> metadata.st_mtime
                          || after.st_size <> metadata.st_size
                        then Error (Invalid "Import source changed during staging")
                        else (
                          Unix.fsync output;
                          (* Publish without replacing another physical instance. *)
                          Unix.link partial target;
                          unlink partial;
                          let fd = Unix.openfile directory [ Unix.O_RDONLY ] 0 in
                          Fun.protect
                            ~finally:(fun () -> Unix.close fd)
                            (fun () -> Unix.fsync fd);
                          Ok
                            { file
                            ; checksum =
                                Digestif.SHA256.to_hex (Digestif.SHA256.get digest)
                            ; size = Int64.of_int size
                            })))))))
  ;;

  let prune_staged t ~keep =
    if t.closed
    then Error Stale
    else
      protect (fun () ->
        let directory = pending_directory t in
        if not (Sys.file_exists directory)
        then Ok 0
        else (
          let stream = Unix.opendir directory in
          let rec inspect count orphaned =
            match Unix.readdir stream with
            | "." | ".." -> inspect count orphaned
            | _ when count >= 4096 -> Error Full
            | file ->
              let path = Filename.concat directory file in
              if
                (not (valid_staged_file file))
                ||
                match Hashtbl.find_opt t.staged_records file with
                | Some record -> record.staged_pins > 0
                | None -> false
              then inspect (count + 1) orphaned
              else (
                match Unix.lstat path with
                | { Unix.st_kind = Unix.S_REG; _ } ->
                  (match keep file with
                   | Error message -> Error (Io message)
                   | Ok true -> inspect (count + 1) orphaned
                   | Ok false -> inspect (count + 1) (file :: orphaned))
                | _ -> inspect (count + 1) orphaned
                | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
                  inspect (count + 1) orphaned)
            | exception End_of_file -> Ok orphaned
          in
          match
            Fun.protect ~finally:(fun () -> Unix.closedir stream) (fun () -> inspect 0 [])
          with
          | Error _ as error -> error
          | Ok orphaned ->
            List.iter (fun file -> unlink (Filename.concat directory file)) orphaned;
            if orphaned <> []
            then (
              let fd = Unix.openfile directory [ Unix.O_RDONLY ] 0 in
              Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd));
            Ok (List.length orphaned)))
  ;;
end
