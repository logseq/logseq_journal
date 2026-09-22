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
  | Sys_error message -> Error (Io message)
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
  try
    let path = Filename.concat directory file in
    if (Unix.stat path).st_size > 1024
    then None
    else (
      match Yojson.Safe.from_file path with
      | `Assoc fields ->
        (match
           ( List.assoc_opt "asset" fields
           , List.assoc_opt "type" fields
           , List.assoc_opt "checksum" fields
           , List.assoc_opt "size" fields )
         with
         | ( Some (`String asset)
           , Some (`String file_type)
           , Some (`String checksum)
           , Some (`String size) ) ->
           (match
              ( Uuid.of_string asset
              , Asset.version ~checksum ~file_type
              , Int64.of_string_opt size )
            with
            | Ok asset, Ok version, Some size
              when size >= 0L && name asset version ^ ".json" = file ->
              let name = name asset version in
              Some
                { name
                ; file_type = version.file_type
                ; checksum
                ; size
                ; touched = (Unix.stat path).st_mtime
                ; pins = 0
                }
            | _ -> None)
         | _ -> None)
      | _ -> None)
  with
  | Sys_error _ | Unix.Unix_error _ | Yojson.Json_error _ -> None
;;

let account_directory ~root (account : Core.account_scope) =
  let name =
    Asset_codec.checksum
      (Yojson.Safe.to_string
         (`List
             [ `String (Uri.to_string account.managed_sync_origin)
             ; `String account.user_id
             ]))
  in
  Filename.concat root name
;;

let create ~root ~(scope : Core.graph_scope) ~budget_bytes ~maximum_file_bytes =
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
      Array.iter
        (fun file ->
           if Filename.check_suffix file ".json"
           then (
             match read_manifest directory file with
             | Some record
               when record.size <= Int64.of_int maximum_file_bytes
                    && Sys.file_exists (data_path t record) ->
               Hashtbl.replace t.records record.name record
             | _ -> unlink (Filename.concat directory file))
           else if Filename.check_suffix file ".part"
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
                 (Yojson.Safe.to_string
                    (`Assoc
                        [ "asset", `String (Uuid.to_string asset)
                        ; "type", `String version.file_type
                        ; "checksum", `String version.checksum
                        ; "size", `String (Int64.to_string size)
                        ]));
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

let delete t =
  close t;
  Result.map (fun () -> Hashtbl.clear t.records) (remove_tree t.directory)
;;

let delete_account ~root ~account = remove_tree (account_directory ~root account)

let delete_graph ~root ~account ~graph_id =
  remove_tree
    (Filename.concat (account_directory ~root account) (Uuid.to_string graph_id))
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

let valid_staged_file file =
  Filename.basename file = file
  &&
  match String.rindex_opt file '.' with
  | None -> false
  | Some separator ->
    Result.is_ok (Uuid.of_string (String.sub file 0 separator))
    && valid_staged_type
         (String.sub file (separator + 1) (String.length file - separator - 1))
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
      let file = Uuid.to_string operation ^ "." ^ file_type in
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
                      let size = (Unix.lstat (Filename.concat directory name)).st_size in
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
                        Unix.rename partial target;
                        let fd = Unix.openfile directory [ Unix.O_RDONLY ] 0 in
                        Fun.protect
                          ~finally:(fun () -> Unix.close fd)
                          (fun () -> Unix.fsync fd);
                        Ok
                          { file
                          ; checksum = Digestif.SHA256.to_hex (Digestif.SHA256.get digest)
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
                let operation =
                  Uuid.of_string (Filename.chop_extension file) |> Result.get_ok
                in
                (match keep operation with
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
