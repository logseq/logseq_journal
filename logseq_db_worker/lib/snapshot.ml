type catalog =
  { root : string
  ; snapshots : string
  ; inbox : string
  ; authentication_key : bytes
  }

type resolved =
  { graph_dir : string
  ; graph_name : string
  }

type write_session =
  { token : Graph_types.Uuid.t
  ; recovery_token : Graph_types.Uuid.t
  ; mutation_id : Graph_types.Uuid.t
  ; snapshot_dir : string
  ; database_identity : string
  ; before_sha256 : string
  }

type error =
  | Invalid_catalog_root
  | Invalid_inbox_entry
  | Source_missing
  | Manifest_mismatch
  | Token_unknown
  | Path_escape
  | Symlink_rejected
  | Hard_link_rejected
  | Publish_failed of string

let is_directory path =
  try (Unix.stat path).st_kind = Unix.S_DIR with
  | Unix.Unix_error _ -> false
;;

let ensure_directory path =
  if Sys.file_exists path
  then is_directory path
  else (
    try
      Unix.mkdir path 0o700;
      true
    with
    | Unix.Unix_error _ -> false)
;;

let read_exactly fd length =
  let bytes = Bytes.create length in
  let rec loop offset =
    if offset < length
    then (
      match Unix.read fd bytes offset (length - offset) with
      | 0 -> raise End_of_file
      | count -> loop (offset + count))
  in
  loop 0;
  bytes
;;

let random_bytes length =
  let fd = Unix.openfile "/dev/urandom" [ Unix.O_RDONLY ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> read_exactly fd length)
;;

let write_all fd bytes =
  let rec loop offset =
    if offset < Bytes.length bytes
    then loop (offset + Unix.write fd bytes offset (Bytes.length bytes - offset))
  in
  loop 0;
  Unix.fsync fd
;;

let catalog_key root =
  let path = Filename.concat root "catalog.key" in
  let read () =
    let fd = Unix.openfile path [ Unix.O_RDONLY ] 0 in
    Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> read_exactly fd 32)
  in
  try read () with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    let key = random_bytes 32 in
    (try
       let fd = Unix.openfile path [ Unix.O_CREAT; O_EXCL; O_WRONLY ] 0o600 in
       Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> write_all fd key);
       key
     with
     | Unix.Unix_error (Unix.EEXIST, _, _) -> read ())
;;

let create_catalog ~application_support_directory =
  if
    Filename.is_relative application_support_directory
    || not (is_directory application_support_directory)
  then Error Invalid_catalog_root
  else (
    try
      let support = Unix.realpath application_support_directory in
      let root = Filename.concat support "logseq-db-worker" in
      let snapshots = Filename.concat root "snapshots" in
      let inbox = Filename.concat root "inbox" in
      if ensure_directory root && ensure_directory snapshots && ensure_directory inbox
      then (
        let root = Unix.realpath root in
        Ok
          { root
          ; snapshots = Unix.realpath snapshots
          ; inbox = Unix.realpath inbox
          ; authentication_key = catalog_key root
          })
      else Error Invalid_catalog_root
    with
    | Unix.Unix_error _ -> Error Invalid_catalog_root)
;;

let random_uuid () =
  let bytes = random_bytes 16 in
  Bytes.set bytes 6 (Char.chr (Char.code (Bytes.get bytes 6) land 0x0f lor 0x40));
  Bytes.set bytes 8 (Char.chr (Char.code (Bytes.get bytes 8) land 0x3f lor 0x80));
  let buffer = Buffer.create 36 in
  Bytes.iteri
    (fun index byte ->
       if List.mem index [ 4; 6; 8; 10 ] then Buffer.add_char buffer '-';
       Buffer.add_string buffer (Printf.sprintf "%02x" (Char.code byte)))
    bytes;
  match Graph_types.Uuid.of_string (Buffer.contents buffer) with
  | Ok uuid -> uuid
  | Error message -> failwith message
;;

let hash_file path =
  let channel = open_in_bin path in
  let buffer = Bytes.create 65_536 in
  let rec loop context =
    match input channel buffer 0 (Bytes.length buffer) with
    | 0 -> context
    | count -> loop (Digestif.SHA256.feed_bytes context ~off:0 ~len:count buffer)
  in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> Digestif.SHA256.(to_hex (get (loop empty))))
;;

let physical_digest path =
  let db = Sqlite3.db_open ~mode:`READONLY path in
  let context = ref Digestif.SHA256.empty in
  let feed value =
    match value with
    | None -> context := Digestif.SHA256.feed_string !context "N;"
    | Some value ->
      context := Digestif.SHA256.feed_string !context "S";
      context
      := Digestif.SHA256.feed_string !context (string_of_int (String.length value));
      context := Digestif.SHA256.feed_string !context ":";
      context := Digestif.SHA256.feed_string !context value;
      context := Digestif.SHA256.feed_string !context ";"
  in
  let feed_row row =
    context := Digestif.SHA256.feed_string !context "R";
    Array.iter feed row
  in
  let quote_identifier value =
    let escaped = String.split_on_char '"' value |> String.concat "\"\"" in
    "\"" ^ escaped ^ "\""
  in
  let system_table value = String.length value >= 7 && String.sub value 0 7 = "sqlite_" in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () ->
       let tables = ref [] in
       Sqlite3.Rc.check
         (Sqlite3.exec
            db
            "SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name"
            ~cb:(fun row _ ->
              feed_row row;
              if Array.length row >= 2 && row.(0) = Some "table"
              then (
                match row.(1) with
                | Some name when not (system_table name) -> tables := name :: !tables
                | Some _ | None -> ())));
       List.rev !tables
       |> List.iter (fun table ->
         let sql = "SELECT * FROM " ^ quote_identifier table ^ " ORDER BY rowid" in
         match Sqlite3.exec db sql ~cb:(fun row _ -> feed_row row) with
         | rc when Sqlite3.Rc.is_success rc -> ()
         | _ ->
           Sqlite3.Rc.check
             (Sqlite3.exec
                db
                ("SELECT * FROM " ^ quote_identifier table)
                ~cb:(fun row _ -> feed_row row)));
       Digestif.SHA256.(to_hex (get !context)))
;;

let sqlite_uri_path path =
  let encoded = Buffer.create (String.length path) in
  let unreserved = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '.' | '_' | '~' | '/' -> true
    | _ -> false
  in
  String.iter
    (fun character ->
       if unreserved character
       then Buffer.add_char encoded character
       else Buffer.add_string encoded (Printf.sprintf "%%%02X" (Char.code character)))
    path;
  Buffer.contents encoded
;;

let open_backup_source source =
  let wal_exists = Sys.file_exists (source ^ "-wal") in
  let shm_exists = Sys.file_exists (source ^ "-shm") in
  match wal_exists, shm_exists with
  | false, false ->
    Sqlite3.db_open
      ~mode:`READONLY
      ~uri:true
      ("file:" ^ sqlite_uri_path source ^ "?mode=ro&immutable=1")
  | true, true -> Sqlite3.db_open ~mode:`READONLY source
  | _ -> failwith "source database has an incomplete SQLite WAL sidecar set"
;;

let backup_sqlite ~source ~destination =
  let source_db = open_backup_source source in
  let destination_db = Sqlite3.db_open destination in
  Fun.protect
    ~finally:(fun () ->
      ignore (Sqlite3.db_close destination_db);
      ignore (Sqlite3.db_close source_db))
    (fun () ->
       let backup =
         Sqlite3.Backup.init
           ~dst:destination_db
           ~dst_name:"main"
           ~src:source_db
           ~src_name:"main"
       in
       let rec copy () =
         match Sqlite3.Backup.step backup 256 with
         | Sqlite3.Rc.DONE -> ()
         | OK -> copy ()
         | BUSY | LOCKED -> copy ()
         | rc -> Sqlite3.Rc.check rc
       in
       Fun.protect
         ~finally:(fun () -> Sqlite3.Rc.check (Sqlite3.Backup.finish backup))
         copy)
;;

let prepare_published_database path =
  let db = Sqlite3.db_open ~mode:`NO_CREATE path in
  Fun.protect
    ~finally:(fun () ->
      if not (Sqlite3.db_close db) then failwith "unable to close published snapshot")
    (fun () ->
       Sqlite3.Rc.check (Sqlite3.exec db "PRAGMA journal_mode=WAL");
       Sqlite3.Rc.check (Sqlite3.exec db "PRAGMA synchronous=FULL");
       Sqlite3.Rc.check (Sqlite3.exec db "PRAGMA wal_checkpoint(TRUNCATE)"))
;;

let manifest_path snapshot_dir = Filename.concat snapshot_dir "manifest.json"
let database_path snapshot_dir = Filename.concat snapshot_dir "db.sqlite"
let write_session_path snapshot_dir = Filename.concat snapshot_dir "write-session.json"

let valid_entry entry =
  String.length entry > 0
  && (not (String.equal entry "."))
  && (not (String.equal entry ".."))
  && (not (String.contains entry '/'))
  && (not (String.contains entry '\\'))
  && not (String.contains entry '\000')
;;

let database_identity path =
  let stat = Unix.lstat path in
  if stat.st_kind = Unix.S_LNK
  then Error Symlink_rejected
  else if stat.st_kind <> Unix.S_REG
  then Error Manifest_mismatch
  else if stat.st_nlink <> 1
  then Error Hard_link_rejected
  else Ok (Printf.sprintf "%d:%d" stat.st_dev stat.st_ino)
;;

let atomic_write_json path value =
  let temporary = path ^ ".tmp-" ^ Graph_types.Uuid.to_string (random_uuid ()) in
  let fd = Unix.openfile temporary [ Unix.O_CREAT; O_EXCL; O_WRONLY ] 0o600 in
  Fun.protect
    ~finally:(fun () ->
      (try Unix.close fd with
       | Unix.Unix_error _ -> ());
      try Unix.unlink temporary with
      | Unix.Unix_error _ -> ())
    (fun () ->
       write_all fd (Bytes.of_string (Yojson.Safe.to_string value ^ "\n"));
       Unix.close fd;
       Unix.rename temporary path)
;;

let manifest_payload
      ~token
      ~graph_name
      ~source_identity
      ~database_identity
      ~sha256
      ~owner_generation
  =
  `Assoc
    [ "formatVersion", `Int 3
    ; "token", `String (Graph_types.Uuid.to_string token)
    ; "graphName", `String graph_name
    ; "sourceIdentity", `String source_identity
    ; "databaseIdentity", `String database_identity
    ; "sha256", `String sha256
    ; ( "ownerGeneration"
      , match owner_generation with
        | None -> `Null
        | Some generation -> `String generation )
    ]
;;

let authenticate key payload =
  Digestif.SHA256.(
    to_hex (hmac_string ~key:(Bytes.to_string key) (Yojson.Safe.to_string payload)))
;;

let authenticated_document authentication_key payload =
  `Assoc
    [ "payload", payload
    ; "authentication", `String (authenticate authentication_key payload)
    ]
;;

let write_manifest
      path
      ~authentication_key
      ~token
      ~graph_name
      ~source_identity
      ~database_identity
      ~sha256
      ~owner_generation
  =
  let payload =
    manifest_payload
      ~token
      ~graph_name
      ~source_identity
      ~database_identity
      ~sha256
      ~owner_generation
  in
  atomic_write_json path (authenticated_document authentication_key payload)
;;

type manifest =
  { graph_name : string
  ; source_identity : string
  ; database_identity : string
  ; sha256 : string
  ; owner_generation : string option
  }

let authenticated_payload authentication_key path =
  match Yojson.Safe.from_file path with
  | `Assoc fields when List.length fields = 2 ->
    (match List.assoc_opt "payload" fields, List.assoc_opt "authentication" fields with
     | Some payload, Some (`String authentication)
       when String.equal authentication (authenticate authentication_key payload) ->
       Ok payload
     | _ -> Error Manifest_mismatch)
  | _ -> Error Manifest_mismatch
;;

let read_manifest catalog token snapshot_dir =
  let token_text = Graph_types.Uuid.to_string token in
  let ( let* ) result f = Result.bind result f in
  let* actual_database_identity = database_identity (database_path snapshot_dir) in
  let* payload =
    authenticated_payload catalog.authentication_key (manifest_path snapshot_dir)
  in
  match payload with
  | `Assoc fields ->
    (match
       ( List.assoc_opt "formatVersion" fields
       , List.assoc_opt "token" fields
       , List.assoc_opt "graphName" fields
       , List.assoc_opt "sourceIdentity" fields
       , List.assoc_opt "databaseIdentity" fields
       , List.assoc_opt "sha256" fields
       , List.assoc_opt "ownerGeneration" fields )
     with
     | ( Some (`Int 3)
       , Some (`String manifest_token)
       , Some (`String graph_name)
       , Some (`String source_identity)
       , Some (`String expected_database_identity)
       , Some (`String sha256)
       , Some owner_generation )
       when List.length fields = 7
            && valid_entry graph_name
            && String.equal manifest_token token_text
            && String.equal expected_database_identity actual_database_identity ->
       (match owner_generation with
        | `Null ->
          Ok
            { graph_name
            ; source_identity
            ; database_identity = actual_database_identity
            ; sha256
            ; owner_generation = None
            }
        | `String generation ->
          (match Graph_types.Uuid.of_string generation with
           | Ok _ ->
             Ok
               { graph_name
               ; source_identity
               ; database_identity = actual_database_identity
               ; sha256
               ; owner_generation = Some generation
               }
           | Error _ -> Error Manifest_mismatch)
        | _ -> Error Manifest_mismatch)
     | _ -> Error Manifest_mismatch)
  | _ -> Error Manifest_mismatch
;;

type pending_write =
  { pending_recovery_token : Graph_types.Uuid.t
  ; pending_mutation_id : Graph_types.Uuid.t
  ; pending_database_identity : string
  ; pending_before_sha256 : string
  ; pending_committed_digest : string option
  }

let pending_payload
      ~token
      ~recovery_token
      ~mutation_id
      ~database_identity
      ~before_sha256
      ~committed_digest
  =
  `Assoc
    [ "formatVersion", `Int 1
    ; "token", `String (Graph_types.Uuid.to_string token)
    ; "recoveryToken", `String (Graph_types.Uuid.to_string recovery_token)
    ; "mutationId", `String (Graph_types.Uuid.to_string mutation_id)
    ; "databaseIdentity", `String database_identity
    ; "beforeSha256", `String before_sha256
    ; ( "committedDigest"
      , match committed_digest with
        | None -> `Null
        | Some digest -> `String digest )
    ]
;;

let read_pending catalog token snapshot_dir =
  let path = write_session_path snapshot_dir in
  if not (Sys.file_exists path)
  then Ok None
  else (
    let ( let* ) result f = Result.bind result f in
    let* payload = authenticated_payload catalog.authentication_key path in
    match payload with
    | `Assoc fields ->
      (match
         ( List.assoc_opt "formatVersion" fields
         , List.assoc_opt "token" fields
         , List.assoc_opt "recoveryToken" fields
         , List.assoc_opt "mutationId" fields
         , List.assoc_opt "databaseIdentity" fields
         , List.assoc_opt "beforeSha256" fields
         , List.assoc_opt "committedDigest" fields )
       with
       | ( Some (`Int 1)
         , Some (`String pending_token)
         , Some (`String recovery_token)
         , Some (`String mutation_id)
         , Some (`String pending_database_identity)
         , Some (`String pending_before_sha256)
         , Some (`String pending_committed_digest) )
         when List.length fields = 7
              && String.equal pending_token (Graph_types.Uuid.to_string token) ->
         (match
            ( Graph_types.Uuid.of_string recovery_token
            , Graph_types.Uuid.of_string mutation_id )
          with
          | Ok pending_recovery_token, Ok pending_mutation_id ->
            Ok
              (Some
                 { pending_recovery_token
                 ; pending_mutation_id
                 ; pending_database_identity
                 ; pending_before_sha256
                 ; pending_committed_digest = Some pending_committed_digest
                 })
          | Error _, _ | _, Error _ -> Error Manifest_mismatch)
       | ( Some (`Int 1)
         , Some (`String pending_token)
         , Some (`String recovery_token)
         , Some (`String mutation_id)
         , Some (`String pending_database_identity)
         , Some (`String pending_before_sha256)
         , Some `Null )
         when List.length fields = 7
              && String.equal pending_token (Graph_types.Uuid.to_string token) ->
         (match
            ( Graph_types.Uuid.of_string recovery_token
            , Graph_types.Uuid.of_string mutation_id )
          with
          | Ok pending_recovery_token, Ok pending_mutation_id ->
            Ok
              (Some
                 { pending_recovery_token
                 ; pending_mutation_id
                 ; pending_database_identity
                 ; pending_before_sha256
                 ; pending_committed_digest = None
                 })
          | Error _, _ | _, Error _ -> Error Manifest_mismatch)
       | _ -> Error Manifest_mismatch)
    | _ -> Error Manifest_mismatch)
;;

let canonical_snapshot_dir catalog token =
  let token_text = Graph_types.Uuid.to_string token in
  let snapshot_dir = Filename.concat catalog.snapshots token_text in
  if not (is_directory snapshot_dir)
  then Error Token_unknown
  else (
    let canonical = Unix.realpath snapshot_dir in
    if String.equal (Filename.dirname canonical) catalog.snapshots
    then Ok canonical
    else Error Path_escape)
;;

let inspect catalog token =
  let ( let* ) result f = Result.bind result f in
  let* snapshot_dir = canonical_snapshot_dir catalog token in
  let* manifest = read_manifest catalog token snapshot_dir in
  let* pending = read_pending catalog token snapshot_dir in
  Ok (snapshot_dir, manifest, pending)
;;

let publish catalog ~source_graph_dir ~graph_name ~owner_generation =
  let source_database = Filename.concat source_graph_dir "db.sqlite" in
  let source_stat =
    try Some (Unix.stat source_database) with
    | Unix.Unix_error _ -> None
  in
  match source_stat with
  | None -> Error Source_missing
  | Some source_stat when source_stat.st_kind <> Unix.S_REG -> Error Source_missing
  | Some source_stat ->
    let token = random_uuid () in
    let token_text = Graph_types.Uuid.to_string token in
    let temporary = Filename.concat catalog.snapshots (".tmp-" ^ token_text) in
    let published = Filename.concat catalog.snapshots token_text in
    (try
       Unix.mkdir temporary 0o700;
       let destination_database = database_path temporary in
       backup_sqlite ~source:source_database ~destination:destination_database;
       prepare_published_database destination_database;
       let destination_stat = Unix.stat destination_database in
       if destination_stat.st_nlink <> 1
       then raise (Failure "snapshot database is hard linked");
       let source_identity =
         Printf.sprintf "%d:%d" source_stat.st_dev source_stat.st_ino
       in
       write_manifest
         (manifest_path temporary)
         ~authentication_key:catalog.authentication_key
         ~token
         ~graph_name
         ~source_identity
         ~database_identity:
           (match database_identity destination_database with
            | Ok identity -> identity
            | Error _ -> raise (Failure "snapshot database identity is invalid"))
         ~sha256:(hash_file destination_database)
         ~owner_generation;
       Unix.rename temporary published;
       Ok token
     with
     | exn -> Error (Publish_failed (Printexc.to_string exn)))
;;

let create catalog ~source_graph_dir =
  if Filename.is_relative source_graph_dir || not (is_directory source_graph_dir)
  then Error Source_missing
  else (
    let source_graph_dir = Unix.realpath source_graph_dir in
    publish
      catalog
      ~source_graph_dir
      ~graph_name:(Filename.basename source_graph_dir)
      ~owner_generation:None)
;;

let import catalog ~inbox_entry =
  if not (valid_entry inbox_entry)
  then Error Invalid_inbox_entry
  else (
    let source = Filename.concat catalog.inbox inbox_entry in
    match
      try Some (Unix.lstat source) with
      | Unix.Unix_error _ -> None
    with
    | None -> Error Source_missing
    | Some stat when stat.st_kind = Unix.S_LNK -> Error Symlink_rejected
    | Some stat when stat.st_kind <> Unix.S_DIR -> Error Source_missing
    | Some _ ->
      (match
         publish
           catalog
           ~source_graph_dir:source
           ~graph_name:inbox_entry
           ~owner_generation:None
       with
       | Error _ as error -> error
       | Ok token ->
         let consumed =
           Filename.concat catalog.root (".consumed-" ^ Graph_types.Uuid.to_string token)
         in
         (try
            Unix.rename source consumed;
            Ok token
          with
          | Unix.Unix_error (_, _, _) ->
            Error (Publish_failed "unable to consume inbox entry"))))
;;

let import_native catalog ~inbox_entry ~destination_graph_dir =
  if not (valid_entry inbox_entry)
  then Error Invalid_inbox_entry
  else (
    let support = Filename.dirname catalog.root in
    let graphs = Filename.dirname destination_graph_dir in
    let destination_support = Filename.dirname graphs in
    let canonical_graphs = Filename.concat support "graphs" in
    if
      not
        (String.equal (Filename.basename destination_graph_dir) inbox_entry
         && String.equal (Filename.basename graphs) "graphs"
         &&
         try String.equal (Unix.realpath destination_support) support with
         | Unix.Unix_error _ -> false)
    then Error Path_escape
    else (
      let source = Filename.concat catalog.inbox inbox_entry in
      let source_database = database_path source in
      let source_stat =
        try Some (Unix.lstat source) with
        | Unix.Unix_error _ -> None
      in
      match source_stat with
      | None -> Error Source_missing
      | Some stat when stat.st_kind = Unix.S_LNK -> Error Symlink_rejected
      | Some stat when stat.st_kind <> Unix.S_DIR -> Error Source_missing
      | Some _ ->
        (match database_identity source_database with
         | Error _ as error -> error
         | Ok _ ->
           let token = Graph_types.Uuid.to_string (random_uuid ()) in
           let temporary = Filename.concat graphs (".tmp-native-" ^ token) in
           let replaced = Filename.concat catalog.root (".replaced-native-" ^ token) in
           let failed = Filename.concat catalog.root (".failed-native-" ^ token) in
           let preserve_partial () =
             if Sys.file_exists temporary
             then (
               try Unix.rename temporary failed with
               | Unix.Unix_error _ -> ())
           in
           let restore_replaced () =
             if Sys.file_exists replaced && not (Sys.file_exists destination_graph_dir)
             then (
               try Unix.rename replaced destination_graph_dir with
               | Unix.Unix_error _ -> ())
           in
           (try
              if not (ensure_directory graphs)
              then raise (Failure "unable to create native graph root");
              if not (String.equal (Unix.realpath graphs) canonical_graphs)
              then raise (Failure "native graph root escaped application support");
              Unix.mkdir temporary 0o700;
              let destination_database = database_path temporary in
              backup_sqlite ~source:source_database ~destination:destination_database;
              prepare_published_database destination_database;
              (match database_identity destination_database with
               | Ok _ -> ()
               | Error _ -> raise (Failure "native database identity is invalid"));
              if Sys.file_exists destination_graph_dir
              then (
                let destination_stat = Unix.lstat destination_graph_dir in
                if
                  destination_stat.st_kind <> Unix.S_DIR
                  || not
                       (String.equal
                          (Filename.dirname (Unix.realpath destination_graph_dir))
                          canonical_graphs)
                then raise (Failure "native graph destination is invalid");
                Unix.rename destination_graph_dir replaced);
              (try Unix.rename temporary destination_graph_dir with
               | exn ->
                 restore_replaced ();
                 raise exn);
              let consumed = Filename.concat catalog.root (".consumed-native-" ^ token) in
              (try Unix.rename source consumed with
               | Unix.Unix_error _ -> ());
              Ok ()
            with
            | exn ->
              preserve_partial ();
              restore_replaced ();
              Error (Publish_failed (Printexc.to_string exn))))))
;;

let resolve catalog token =
  try
    let ( let* ) result f = Result.bind result f in
    let* snapshot_dir, manifest, pending = inspect catalog token in
    let* () =
      match pending with
      | None -> Ok ()
      | Some _ -> Error Manifest_mismatch
    in
    if String.equal manifest.sha256 (hash_file (database_path snapshot_dir))
    then Ok { graph_dir = snapshot_dir; graph_name = manifest.graph_name }
    else Error Manifest_mismatch
  with
  | Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _ -> Error Manifest_mismatch
;;

let create_recovery_copy catalog token =
  match resolve catalog token with
  | Error _ as error -> error
  | Ok resolved ->
    publish
      catalog
      ~source_graph_dir:resolved.graph_dir
      ~graph_name:resolved.graph_name
      ~owner_generation:None
;;

let create_native_recovery_copy catalog ~source_graph_dir ~owner_generation =
  match Graph_types.Uuid.of_string owner_generation with
  | Error _ -> Error Manifest_mismatch
  | Ok _ ->
    if Filename.is_relative source_graph_dir || not (is_directory source_graph_dir)
    then Error Source_missing
    else (
      let source_graph_dir = Unix.realpath source_graph_dir in
      publish
        catalog
        ~source_graph_dir
        ~graph_name:(Filename.basename source_graph_dir)
        ~owner_generation:(Some owner_generation))
;;

let manifest_owner_generation catalog token =
  try
    let ( let* ) result f = Result.bind result f in
    let* snapshot_dir = canonical_snapshot_dir catalog token in
    let* manifest = read_manifest catalog token snapshot_dir in
    Ok manifest.owner_generation
  with
  | Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _ -> Error Manifest_mismatch
;;

let begin_write_session catalog token ~recovery_token ~mutation_id =
  if Graph_types.Uuid.equal token recovery_token
  then Error Manifest_mismatch
  else (
    match resolve catalog token, resolve catalog recovery_token with
    | Error error, _ | _, Error error -> Error error
    | Ok resolved, Ok _ ->
      (try
         let ( let* ) result f = Result.bind result f in
         let* manifest = read_manifest catalog token resolved.graph_dir in
         let payload =
           pending_payload
             ~token
             ~recovery_token
             ~mutation_id
             ~database_identity:manifest.database_identity
             ~before_sha256:manifest.sha256
             ~committed_digest:None
         in
         let path = write_session_path resolved.graph_dir in
         if Sys.file_exists path
         then Error Manifest_mismatch
         else (
           atomic_write_json
             path
             (authenticated_document catalog.authentication_key payload);
           Ok
             { token
             ; recovery_token
             ; mutation_id
             ; snapshot_dir = resolved.graph_dir
             ; database_identity = manifest.database_identity
             ; before_sha256 = manifest.sha256
             })
       with
       | Unix.Unix_error _ | Sys_error _ ->
         Error (Publish_failed "unable to begin snapshot write session")))
;;

let matching_pending write_session pending =
  Graph_types.Uuid.equal pending.pending_recovery_token write_session.recovery_token
  && Graph_types.Uuid.equal pending.pending_mutation_id write_session.mutation_id
  && String.equal pending.pending_database_identity write_session.database_identity
  && String.equal pending.pending_before_sha256 write_session.before_sha256
;;

let record_committed_write catalog write_session =
  try
    let ( let* ) result f = Result.bind result f in
    let* snapshot_dir = canonical_snapshot_dir catalog write_session.token in
    if not (String.equal snapshot_dir write_session.snapshot_dir)
    then Error Manifest_mismatch
    else
      let* pending = read_pending catalog write_session.token snapshot_dir in
      match pending with
      | Some pending when matching_pending write_session pending ->
        let payload =
          pending_payload
            ~token:write_session.token
            ~recovery_token:write_session.recovery_token
            ~mutation_id:write_session.mutation_id
            ~database_identity:write_session.database_identity
            ~before_sha256:write_session.before_sha256
            ~committed_digest:(Some (physical_digest (database_path snapshot_dir)))
        in
        atomic_write_json
          (write_session_path snapshot_dir)
          (authenticated_document catalog.authentication_key payload);
        Ok ()
      | None | Some _ -> Error Manifest_mismatch
  with
  | Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _ ->
    Error (Publish_failed "unable to authenticate committed snapshot write")
;;

let finish_write_session catalog write_session =
  try
    let ( let* ) result f = Result.bind result f in
    let* snapshot_dir = canonical_snapshot_dir catalog write_session.token in
    if not (String.equal snapshot_dir write_session.snapshot_dir)
    then Error Manifest_mismatch
    else
      let* manifest = read_manifest catalog write_session.token snapshot_dir in
      let* pending = read_pending catalog write_session.token snapshot_dir in
      match pending with
      | Some pending
        when matching_pending write_session pending
             && Option.equal
                  String.equal
                  pending.pending_committed_digest
                  (Some (physical_digest (database_path snapshot_dir)))
             && String.equal manifest.sha256 write_session.before_sha256
             && String.equal manifest.database_identity write_session.database_identity ->
        write_manifest
          (manifest_path snapshot_dir)
          ~authentication_key:catalog.authentication_key
          ~token:write_session.token
          ~graph_name:manifest.graph_name
          ~source_identity:manifest.source_identity
          ~database_identity:manifest.database_identity
          ~sha256:(hash_file (database_path snapshot_dir))
          ~owner_generation:manifest.owner_generation;
        Unix.unlink (write_session_path snapshot_dir);
        Ok ()
      | None | Some _ -> Error Manifest_mismatch
  with
  | Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _ ->
    Error (Publish_failed "unable to finish snapshot write session")
;;

let recover catalog token =
  try
    let ( let* ) result f = Result.bind result f in
    let* snapshot_dir, manifest, pending = inspect catalog token in
    match pending with
    | None ->
      if String.equal (hash_file (database_path snapshot_dir)) manifest.sha256
      then
        publish
          catalog
          ~source_graph_dir:snapshot_dir
          ~graph_name:manifest.graph_name
          ~owner_generation:manifest.owner_generation
      else Error Manifest_mismatch
    | Some pending
      when String.equal pending.pending_database_identity manifest.database_identity
           && String.equal pending.pending_before_sha256 manifest.sha256 ->
      (match resolve catalog pending.pending_recovery_token with
       | Error _ -> Error Manifest_mismatch
       | Ok recovery ->
         (match pending.pending_committed_digest with
          | Some digest
            when String.equal digest (physical_digest (database_path snapshot_dir)) ->
            publish
              catalog
              ~source_graph_dir:snapshot_dir
              ~graph_name:manifest.graph_name
              ~owner_generation:manifest.owner_generation
          | Some _ | None ->
            publish
              catalog
              ~source_graph_dir:recovery.graph_dir
              ~graph_name:manifest.graph_name
              ~owner_generation:manifest.owner_generation))
    | Some _ -> Error Manifest_mismatch
  with
  | Unix.Unix_error _ | Sys_error _ | Yojson.Json_error _ -> Error Manifest_mismatch
;;
