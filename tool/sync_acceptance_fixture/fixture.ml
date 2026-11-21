module Storage = Logseq_db_storage.Logseq_sqlite_storage
module D = Logseq_overlay_db.Database
module T = Logseq_overlay_db.Types
module G = Logseq_db_types.Graph_types

let require condition message = if not condition then failwith message

let ok label = function
  | Ok value -> value
  | Error message -> failwith (label ^ ": " ^ message)
;;

let snapshot_error = function
  | T.Snapshot_parse_error message -> "parse: " ^ message
  | Snapshot_crypto_error message -> "crypto: " ^ message
  | Snapshot_commit_persistence_failed message -> "persistence: " ^ message
  | Invalid_snapshot_path -> "invalid snapshot path"
  | Invalid_expected_rows -> "invalid expected rows"
  | Snapshot_input_too_large -> "snapshot input too large"
  | Mirror_exists -> "mirror exists"
  | Stale_snapshot_inspection -> "stale snapshot inspection"
  | Snapshot_limit_exceeded -> "snapshot limit exceeded"
  | Snapshot_preparation_canceled -> "snapshot preparation canceled"
  | Snapshot_commit_stale -> "snapshot commit stale"
  | Snapshot_commit_consumed -> "snapshot commit consumed"
  | Snapshot_state_error reason ->
    (match reason with
     | Snapshot_root_unavailable -> "snapshot root unavailable"
     | Snapshot_next_after_persist_or_commit -> "next after persist/commit"
     | Snapshot_crypto_batch_pending -> "crypto batch pending"
     | Snapshot_supply_after_persist_or_commit -> "supply after persist/commit"
     | Snapshot_persist_awaiting_crypto -> "persist awaiting crypto"
     | Snapshot_checkpoint_invalid reason ->
       "invalid checkpoint: "
       ^
         (match reason with
         | `Schema_negative -> "negative schema"
         | `Checksum_invalid -> "invalid checksum"
         | `Unknown -> "unknown"))
  | Snapshot_crypto_result_error reason ->
    (match reason with
     | Crypto_result_missing_item _ -> "crypto result missing item"
     | Crypto_result_extra_item _ -> "crypto result extra item"
     | Crypto_result_duplicate_item _ -> "crypto result duplicate item"
     | Crypto_result_reordered -> "crypto result reordered"
     | Crypto_result_stale -> "crypto result stale"
     | Crypto_result_limit_exceeded -> "crypto result limit exceeded")
;;

let snapshot_ok label result = Result.map_error snapshot_error result |> ok label

let mirror_error = function
  | T.Invalid_application_support_directory -> "invalid support directory"
  | Mirror_location_unavailable message -> "mirror location: " ^ message
  | Mirror_inspection_failed message -> "mirror inspection: " ^ message
;;

let open_error = function
  | T.Mirror_absent -> "mirror absent"
  | Invalid_graph_name -> "invalid graph name"
  | Ownership_conflict -> "ownership conflict"
  | Attachment_stale -> "attachment stale"
  | Restore_failed message -> "restore: " ^ message
  | Corrupt_authoritative_store message -> "authoritative store: " ^ message
  | Corrupt_outbox message -> "outbox: " ^ message
  | Corrupt_mutation_receipt message -> "mutation receipt: " ^ message
  | Open_resource_failed message -> "resource: " ^ message
;;

let read_error = function
  | T.Database_closed -> "database closed"
  | Snapshot_released -> "snapshot released"
  | Snapshot_generation_invalidated -> "snapshot generation invalidated"
  | Read_limit_exceeded -> "read limit exceeded"
  | Stale_read_cursor -> "stale read cursor"
  | Invalid_read_request message -> "invalid request: " ^ message
  | Fatal_read_state message -> "fatal read: " ^ message
;;

let storage label = function
  | Ok value -> value
  | Error error -> failwith (Storage.diagnostic_error ~operation:label error)
;;

let canonical_path path =
  require
    (not (Filename.is_relative path)
     && not (List.exists (fun part -> part = ".." || part = ".") (String.split_on_char '/' path)))
    "explicit path must be absolute without traversal";
  let rec no_symlink current =
    require ((Unix.lstat current).Unix.st_kind <> Unix.S_LNK) "symlink in explicit path";
    let parent = Filename.dirname current in
    if parent <> current then no_symlink parent
  in
  no_symlink path;
  require (Unix.realpath path = path) "explicit path must be canonical"
;;

let work_root path =
  canonical_path path;
  require
    (Filename.dirname path = "/Users/rcmerci/Library/Application Support/Journal isolated evidence")
    "work root is outside isolated evidence";
  let stat = Unix.lstat path in
  require
    (stat.Unix.st_kind = Unix.S_DIR && stat.Unix.st_uid = Unix.getuid ()
     && stat.Unix.st_perm land 0o7777 = 0o700)
    "work root must be private and owned";
  path
;;

let owned_path ?root path =
  let parent = Unix.realpath (Filename.dirname path) in
  (match root with
   | None ->
     let prefix = Unix.realpath "_build" ^ "/plain-fixture-" in
     require (String.starts_with ~prefix parent) "not a task-owned fixture directory"
   | Some root ->
     canonical_path (Filename.dirname path);
     require (path = Filename.concat parent (Filename.basename path)) "noncanonical fixture path";
     require (Filename.basename path <> "." && Filename.basename path <> "..") "invalid fixture filename";
     let name = Filename.basename parent in
     require
       (Filename.dirname parent = root
        && String.length name = 28
        && String.sub name 0 14 = "plain-fixture-"
        && String.for_all
             (fun character -> (character >= '0' && character <= '9') || (character >= 'a' && character <= 'f'))
             (String.sub name 14 12)
        && name.[26] = '-' && (name.[27] = 'A' || name.[27] = 'B'))
       "not a task-owned fixture directory");
  let stat = Unix.stat parent in
  require
    (stat.Unix.st_perm land (if Option.is_some root then 0o7777 else 0o777) = 0o700
     && stat.Unix.st_uid = Unix.getuid ())
    "fixture directory is not private and owned";
  let resolved = Filename.concat parent (Filename.basename path) in
  (match Unix.lstat resolved with
   | stat ->
     require
       (stat.Unix.st_kind = Unix.S_REG && stat.Unix.st_uid = Unix.getuid ())
       "fixture path is not an owned regular file"
   | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  resolved
;;

let rewrite source destination graph_id =
  require (not (Sys.file_exists destination)) "destination already exists";
  let input = open_in_bin source in
  let output =
    open_out_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o600 destination
  in
  Fun.protect
    ~finally:(fun () ->
      close_in_noerr input;
      close_out_noerr output)
    (fun () ->
       let buffer = Bytes.create 65536 in
       let rec copy () =
         let count = Stdlib.input input buffer 0 (Bytes.length buffer) in
         if count > 0
         then (
           Stdlib.output output buffer 0 count;
           copy ())
       in
       copy ());
  let source_connection = Storage.open_database destination |> storage "source open" in
  let source_callbacks = Storage.connection_callbacks source_connection in
  Fun.protect
    ~finally:(fun () -> Storage.close source_callbacks |> storage "source close")
    (fun () ->
       let database =
         Storage.restore_database source_connection |> storage "source restore"
       in
       let kv ident value =
         Datascript.Entity
           { db_id = Some (Datascript.Temp_id ident)
           ; attrs =
               [ "db/ident", Datascript.One_value (Keyword ident)
               ; "kv/value", Datascript.One_value value
               ]
           }
       in
       let database =
         Datascript.db_with
           [ kv "logseq.kv/graph-uuid" (Uuid graph_id)
           ; kv "logseq.kv/graph-rtc-e2ee?" (Bool false)
           ; kv "logseq.kv/graph-remote?" (Bool true)
           ]
           database
       in
       let facts = Datascript.datoms database Datascript.Eavt () |> List.of_seq in
       let kv_value ident =
         let entity =
           match
             List.find_opt
               (fun (fact : Datascript.datom) ->
                  fact.a = "db/ident" && fact.v = Datascript.Keyword ident)
               facts
           with
           | Some entity -> entity
           | None -> failwith ("missing KV ident: " ^ ident)
         in
         (List.find
            (fun (fact : Datascript.datom) -> fact.e = entity.e && fact.a = "kv/value")
            facts)
           .v
       in
       require (kv_value "logseq.kv/graph-uuid" = Uuid graph_id) "graph identity mismatch";
       require
         (kv_value "logseq.kv/graph-rtc-e2ee?" = Bool false)
         "encryption flag mismatch";
       require (kv_value "logseq.kv/graph-remote?" = Bool true) "remote flag mismatch";
       let schema =
         match kv_value "logseq.kv/schema-version" with
         | Map entries ->
           let number key =
             match List.assoc (Datascript.Keyword key) entries with
             | Datascript.Int64 value -> Int64.to_int value
             | _ -> failwith "schema component is not an integer"
           in
           let major = number "major"
           and minor = number "minor" in
           require (major = 65 && minor >= 33) "schema is below supported minimum";
           Printf.sprintf "%d.%d" major minor
         | _ -> failwith "schema is not a version map"
       in
       let callbacks = source_callbacks in
       callbacks.begin_staging () |> ok "begin staging";
       ignore (Datascript.store ~storage:callbacks.storage database);
       let batch =
         callbacks.finish_staging
           None
           [ Datascript.Storage.tail_address, Datascript.Storage_tail [] ]
         |> ok "finish staging"
       in
       Storage.commit_batch callbacks batch |> storage "commit destination";
       schema)
;;

let frame database_path snapshot_path =
  let module Json = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let connection = Sqlite3.db_open ~mode:`READONLY database_path in
  let statement =
    Sqlite3.prepare connection "SELECT addr, content, addresses FROM kvs ORDER BY addr"
  in
  let rec collect reversed =
    match Sqlite3.step statement with
    | ROW ->
      let address = Sqlite3.column_int statement 0 in
      let content =
        match Sqlite3.column statement 1 with
        | TEXT value -> value
        | _ -> failwith "native destination content is not text"
      in
      let addresses =
        match Sqlite3.column statement 2 with
        | NULL -> Json.Null
        | TEXT value -> Json.String value
        | _ -> failwith "native destination addresses are not text/null"
      in
      collect (Json.Array [ Json.Int address; Json.String content; addresses ] :: reversed)
    | DONE -> List.rev reversed
    | status -> failwith ("snapshot read: " ^ Sqlite3.Rc.to_string status)
  in
  let rows =
    Fun.protect
      ~finally:(fun () ->
        ignore (Sqlite3.finalize statement);
        require (Sqlite3.db_close connection) "close SQLite")
      (fun () -> collect [])
  in
  let payload = Codec.to_string ~mode:Codec.Verbose (Json.Array rows) in
  let length = String.length payload in
  require (length + 4 <= 1_000_000) "snapshot exceeds single request limit";
  let prefix =
    Bytes.init 4 (fun index -> Char.chr ((length lsr ((3 - index) * 8)) land 255))
  in
  let channel =
    open_out_gen [ Open_wronly; Open_creat; Open_excl; Open_binary ] 0o600 snapshot_path
  in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () ->
       output_bytes channel prefix;
       output_string channel payload);
  List.length rows, length + 4
;;

let activate root graph_id path expected_rows expected =
  Unix.mkdir root 0o700;
  let limits : T.capability_limits =
    { response_budget_bytes = 8 * 1024 * 1024
    ; outbox_max_records = 4096
    ; outbox_max_bytes = 8 * 1024 * 1024
    ; change_max_items = 4096
    ; change_max_bytes = 8 * 1024 * 1024
    ; dispatcher_capacity = 128
    ; wire_batch_max_bytes = 8 * 1024 * 1024
    }
  in
  let dependencies =
    D.dependencies ~epoch_ms:(fun () -> 0L) ~monotonic_ns:(fun () -> 0L) ~limits
    |> Result.map_error (function
      | T.Non_positive_limit name -> "non-positive limit: " ^ name
      | Inconsistent_limits name -> "inconsistent limits: " ^ name)
    |> ok "dependencies"
  in
  let graph_id = G.Uuid.of_string graph_id |> ok "UUID" in
  let inspection =
    D.inspect_mirror ~application_support_directory:root ~graph_id
    |> Result.map_error mirror_error
    |> ok "inspect"
  in
  let prepared =
    D.prepare_snapshot_activation
      dependencies
      inspection
      ~path
      ~applied_server_cursor:
        (T.Server_cursor.of_int64 0L
         |> Result.map_error (fun `Negative_cursor -> "negative cursor")
         |> ok "cursor")
      ~expected_checksum:expected
      ~expected_rows
    |> snapshot_ok "snapshot preparation"
  in
  Fun.protect
    ~finally:(fun () -> D.cancel_snapshot_activation prepared)
    (fun () ->
       let rec plaintext () =
         match
           D.next_snapshot_unprotection_batch prepared |> snapshot_ok "plaintext batch"
         with
         | None -> ()
         | Some request ->
           D.supply_snapshot_unprotection_batch
             prepared
             ~request
             ~plaintexts:(D.unprotection_ciphertexts request)
           |> snapshot_ok "plaintext supply";
           plaintext ()
       in
       plaintext ();
       let inspection =
         D.commit_snapshot_activation prepared |> snapshot_ok "snapshot activation"
       in
       match D.mirror_presence inspection with
       | T.Available { checksum = Some checksum; _ } ->
         Eio.Switch.run (fun sw ->
           let database =
             D.open_ ~sw dependencies inspection ~graph_name:"Owned acceptance fixture"
             |> Result.map_error open_error
             |> ok "open activated graph"
           in
           Fun.protect
             ~finally:(fun () ->
               D.close database
               |> Result.map_error (function
                 | T.Close_failed message -> "close: " ^ message
                 | Fatal_close message -> "fatal close: " ^ message)
               |> ok "close activated graph")
             (fun () ->
                let snapshot =
                  D.current_snapshot database
                  |> Result.map_error read_error
                  |> ok "current snapshot"
                in
                Fun.protect
                  ~finally:(fun () -> D.release_snapshot snapshot)
                  (fun () ->
                     let info =
                       D.graph_info snapshot
                       |> Result.map_error read_error
                       |> ok "graph info"
                     in
                     require
                       (G.Uuid.to_string info.graph_uuid = G.Uuid.to_string graph_id)
                       "activated identity mismatch";
                     require
                       (info.schema.major = 65 && info.schema.minor >= 33)
                       "activated schema mismatch")));
         checksum
       | _ -> failwith "activated checksum unavailable")
;;

let () =
  try
    Eio_main.run (fun _ ->
      let root, arguments =
        if Array.length Sys.argv >= 3 && Sys.argv.(1) = "--work-root"
        then Some (work_root Sys.argv.(2)), Array.sub Sys.argv 2 (Array.length Sys.argv - 2)
        else None, Sys.argv
      in
      let owned_path = owned_path ?root in
      require
        (Array.length arguments = 5)
        "usage: fixture [--work-root ROOT] SOURCE DESTINATION UUID SNAPSHOT | --verify-frame PATH UUID ROWS";
      if arguments.(1) = "--verify-frame"
      then (
        let path = owned_path arguments.(2) in
        let graph_id = arguments.(3) in
        let rows = int_of_string arguments.(4) in
        let checksum = activate (path ^ ".fresh-read") graph_id path rows None in
        let repeated =
          activate (path ^ ".fresh-verify") graph_id path rows (Some checksum)
        in
        require (T.Checksum.equal checksum repeated) "remote snapshot checksum mismatch";
        print_endline
          (Yojson.Safe.to_string
             (`Assoc
                 [ "graph_id", `String graph_id
                 ; "checksum", `String (T.Checksum.to_string checksum)
                 ; "fresh_read_open_current", `Bool true
                 ])))
      else (
        let source = owned_path arguments.(1) in
        let destination = owned_path arguments.(2) in
        let graph_id = arguments.(3) in
        ignore (G.Uuid.of_string graph_id |> ok "UUID");
        let snapshot = owned_path arguments.(4) in
        let schema = rewrite source destination graph_id in
        let rows, bytes = frame destination snapshot in
        let checksum = activate (snapshot ^ ".activation") graph_id snapshot rows None in
        let repeated =
          activate (snapshot ^ ".verification") graph_id snapshot rows (Some checksum)
        in
        require (T.Checksum.equal checksum repeated) "checksum parity";
        let inspected =
          D.inspect_snapshot_storage
            ~check_current:(fun () -> ())
            ~scratch_bytes:16_777_216L
            ~encrypted:false
            ~path:destination
          |> ok "storage inspector"
        in
        require
          (T.Checksum.equal checksum inspected)
          "storage inspector checksum mismatch";
        print_endline
          (Yojson.Safe.to_string
             (`Assoc
                 [ "graph_id", `String graph_id
                 ; "schema", `String schema
                 ; "rows", `Int rows
                 ; "bytes", `Int bytes
                 ; "checksum", `String (T.Checksum.to_string checksum)
                 ; "encrypted", `Bool false
                 ; "cursor", `Int 0
                 ; "public_activation_verified", `Bool true
                 ]))))
  with
  | exception_value ->
    prerr_endline (Printexc.to_string exception_value);
    exit 1
;;
