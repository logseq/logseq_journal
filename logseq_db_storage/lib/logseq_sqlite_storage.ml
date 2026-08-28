type write =
  { address : string
  ; payload : string
  ; addresses : string list
  }

type batch =
  { writes : write list
  ; sync_metadata : Sync_checkpoint.t option
  ; sync_outbox : string list option
  }

type garbage_stats =
  { total_address_count : int
  ; reachable_address_count : int
  ; unreachable_address_count : int
  ; database_size_bytes : int64
  }

type error =
  | Pragma_mismatch of string
  | Corrupt_storage of string
  | Begin_failed of string
  | Write_failed of
      { address : string
      ; message : string
      }
  | Commit_failed of string
  | Checkpoint_failed of string
  | Close_failed of string

type callbacks =
  { storage : Datascript.storage
  ; initial_root_metadata : Logseq_sqlite_codec.root_index_metadata option
  ; begin_staging : unit -> (unit, string) result
  ; finish_staging :
      Logseq_sqlite_codec.root_index_metadata option
      -> (string * Datascript.storage_payload) list
      -> (batch, string) result
  ; abort_staging : unit -> unit
  ; begin_immediate : unit -> (unit, string) result
  ; upsert : write -> (unit, string) result
  ; upsert_sync_metadata : Sync_checkpoint.t -> (unit, string) result
  ; load_sync_outbox : unit -> (string list, string) result
  ; replace_sync_outbox : string list -> (unit, string) result
  ; commit : unit -> (unit, string) result
  ; rollback : unit -> unit
  ; unreachable_address_count : unit -> int
  ; database_size_bytes : unit -> int64
  ; checkpoint : unit -> (unit, string) result
  ; close : unit -> (unit, string) result
  }

type connection =
  { sqlite : Sqlite3.db
  ; storage : Datascript.storage
  ; callbacks : callbacks
  }

type startup_metadata =
  { schema : Datascript.schema
  ; basis : int64
  }

let pragma_value db name =
  let value = ref None in
  let rc =
    Sqlite3.exec db ("PRAGMA " ^ name) ~cb:(fun row _headers ->
      if Array.length row > 0 then value := row.(0))
  in
  if Sqlite3.Rc.is_success rc then !value else None
;;

let verify_writable_pragmas db =
  let require name predicate expected =
    match pragma_value db name with
    | Some value when predicate value -> Ok ()
    | Some value ->
      Error
        (Pragma_mismatch
           (Printf.sprintf "PRAGMA %s is %S; expected %s" name value expected))
    | None -> Error (Pragma_mismatch ("unable to read PRAGMA " ^ name))
  in
  let ( let* ) result f = Result.bind result f in
  let* () =
    require
      "journal_mode"
      (fun value -> String.equal (String.lowercase_ascii value) "wal")
      "WAL"
  in
  let* () = require "synchronous" (fun value -> String.equal value "2") "FULL (2)" in
  let* () =
    require
      "busy_timeout"
      (fun value ->
         match int_of_string_opt value with
         | Some milliseconds -> milliseconds > 0
         | None -> false)
      "a positive timeout"
  in
  require
    "locking_mode"
    (fun value -> String.equal (String.lowercase_ascii value) "normal")
    "NORMAL"
;;

let commit_batch callbacks batch =
  match callbacks.begin_immediate () with
  | Error message -> Error (Begin_failed message)
  | Ok () ->
    let rollback error =
      callbacks.rollback ();
      Error error
    in
    let rec write_all = function
      | [] -> Ok ()
      | write :: rest ->
        (match callbacks.upsert write with
         | Ok () -> write_all rest
         | Error message -> rollback (Write_failed { address = write.address; message }))
    in
    (match write_all batch.writes with
     | Error _ as error -> error
     | Ok () ->
       let metadata =
         match batch.sync_metadata with
         | None -> Ok ()
         | Some metadata -> callbacks.upsert_sync_metadata metadata
       in
       (match metadata with
        | Error message -> rollback (Commit_failed message)
        | Ok () ->
          let outbox =
            match batch.sync_outbox with
            | None -> Ok ()
            | Some records -> callbacks.replace_sync_outbox records
          in
          (match outbox with
           | Error message -> rollback (Commit_failed message)
           | Ok () ->
             (match callbacks.commit () with
              | Ok () -> Ok ()
              | Error message -> rollback (Commit_failed message)))))
;;

let commit_sync_metadata callbacks metadata =
  commit_batch
    callbacks
    { writes = []; sync_metadata = Some metadata; sync_outbox = None }
;;

let unreachable_addresses (callbacks : callbacks) =
  let storage = callbacks.storage in
  let reachable = Hashtbl.create 256 in
  let rec visit address =
    if Hashtbl.mem reachable address
    then Ok ()
    else (
      Hashtbl.add reachable address ();
      match storage.storage_restore address with
      | None ->
        Error (Corrupt_storage ("reachable storage address is missing: " ^ address))
      | Some (Datascript.Storage_root root) ->
        visit_all [ root.storage_eavt; root.storage_aevt; root.storage_avet ]
      | Some (Storage_node (Persistent_sorted_set.Branch (_, children))) ->
        visit_all children
      | Some (Storage_node (Leaf _) | Storage_tail _) -> Ok ())
  and visit_all = function
    | [] -> Ok ()
    | address :: rest ->
      (match visit address with
       | Error _ as error -> error
       | Ok () -> visit_all rest)
  in
  match
    visit_all [ Datascript.Storage.root_address; Datascript.Storage.tail_address ]
  with
  | Error _ as error -> error
  | Ok () ->
    let addresses = storage.storage_list_addresses () in
    let unreachable =
      List.filter (fun address -> not (Hashtbl.mem reachable address)) addresses
    in
    Ok (Hashtbl.length reachable, addresses, unreachable)
;;

let garbage_stats callbacks =
  match unreachable_addresses callbacks with
  | Error _ as error -> error
  | Ok (reachable_address_count, addresses, unreachable) ->
    Ok
      { total_address_count = List.length addresses
      ; reachable_address_count
      ; unreachable_address_count = List.length unreachable
      ; database_size_bytes = callbacks.database_size_bytes ()
      }
;;

let collect_garbage (callbacks : callbacks) =
  match unreachable_addresses callbacks with
  | Error _ as error -> error
  | Ok (_reachable_address_count, _addresses, unreachable) ->
    if unreachable = []
    then Ok ()
    else (
      match callbacks.begin_immediate () with
      | Error message -> Error (Begin_failed message)
      | Ok () ->
        let rollback error =
          callbacks.rollback ();
          Error error
        in
        (match
           try
             callbacks.storage.storage_delete unreachable;
             Ok ()
           with
           | exn -> Error (Printexc.to_string exn)
         with
         | Error message ->
           rollback (Write_failed { address = "reachability-gc"; message })
         | Ok () ->
           (match callbacks.commit () with
            | Ok () -> Ok ()
            | Error message -> rollback (Commit_failed message))))
;;

let checkpoint callbacks =
  match callbacks.checkpoint () with
  | Ok () -> Ok ()
  | Error message -> Error (Checkpoint_failed message)
;;

let close callbacks =
  match callbacks.close () with
  | Ok () -> Ok ()
  | Error message -> Error (Close_failed message)
;;

let rc_result db rc =
  if Sqlite3.Rc.is_success rc then Ok () else Error (Sqlite3.errmsg db)
;;

let prepared db sql bind read =
  let statement = Sqlite3.prepare db sql in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize statement))
    (fun () ->
       bind statement;
       read statement)
;;

let addresses_json addresses =
  match addresses with
  | [] -> Sqlite3.Data.NULL
  | addresses ->
    let values =
      List.map
        (fun address ->
           match int_of_string_opt address with
           | Some address -> `Int address
           | None -> invalid_arg "storage address is not an integer")
        addresses
    in
    Sqlite3.Data.TEXT (Yojson.Safe.to_string (`List values))
;;

let open_database path =
  try
    let sqlite = Sqlite3.db_open ~mode:`NO_CREATE path in
    Sqlite3.busy_timeout sqlite 5_000;
    let exec sql () = rc_result sqlite (Sqlite3.exec sqlite sql) in
    Sqlite3.Rc.check (Sqlite3.exec sqlite "PRAGMA journal_mode=WAL");
    Sqlite3.Rc.check (Sqlite3.exec sqlite "PRAGMA synchronous=FULL");
    Sqlite3.Rc.check (Sqlite3.exec sqlite "PRAGMA locking_mode=NORMAL");
    (match verify_writable_pragmas sqlite with
     | Error error ->
       ignore (Sqlite3.db_close sqlite);
       raise
         (Failure
            (match error with
             | Pragma_mismatch message -> message
             | _ -> assert false))
     | Ok () -> ());
    let table_columns = ref [] in
    Sqlite3.Rc.check
      (Sqlite3.exec sqlite "PRAGMA table_info(kvs)" ~cb:(fun row _ ->
         if Array.length row >= 6
         then table_columns := (row.(1), row.(2), row.(5)) :: !table_columns));
    let normalized_columns = List.rev !table_columns in
    let expected =
      [ Some "addr", Some "INTEGER", Some "1"
      ; Some "content", Some "TEXT", Some "0"
      ; Some "addresses", Some "JSON", Some "0"
      ]
    in
    if normalized_columns <> expected
    then (
      ignore (Sqlite3.db_close sqlite);
      Error (Pragma_mismatch "unexpected kvs table contract"))
    else (
      let invalid_address = ref None in
      Sqlite3.Rc.check
        (Sqlite3.exec
           sqlite
           "SELECT CAST(addr AS TEXT) FROM kvs WHERE typeof(addr) <> 'integer' OR addr < \
            0 LIMIT 1"
           ~cb:(fun row _ -> invalid_address := row.(0)));
      match !invalid_address with
      | Some address ->
        ignore (Sqlite3.db_close sqlite);
        Error (Pragma_mismatch ("invalid kvs integer address: " ^ address))
      | None ->
        let capture : (string, Datascript.storage_payload) Hashtbl.t option ref =
          ref None
        in
        let restore_sqlite address =
          prepared
            sqlite
            "SELECT content, addresses FROM kvs WHERE addr = ?"
            (fun statement -> Sqlite3.Rc.check (Sqlite3.bind_text statement 1 address))
            (fun statement ->
               match Sqlite3.step statement with
               | Sqlite3.Rc.ROW ->
                 let content = Sqlite3.column_text statement 0 in
                 let addresses =
                   if Sqlite3.column_is_null statement 1
                   then []
                   else (
                     match Yojson.Safe.from_string (Sqlite3.column_text statement 1) with
                     | `List values ->
                       List.map
                         (function
                           | `Int value -> string_of_int value
                           | `Intlit value -> value
                           | _ -> invalid_arg "invalid addresses JSON")
                         values
                     | _ -> invalid_arg "invalid addresses JSON")
                 in
                 (match
                    Logseq_sqlite_codec.decode_physical_payload ~content ~addresses
                  with
                  | Ok payload -> Some payload
                  | Error _ -> invalid_arg ("invalid storage payload at " ^ address))
               | DONE -> None
               | rc ->
                 Sqlite3.Rc.check rc;
                 None)
        in
        let list_addresses () =
          let addresses = ref [] in
          Sqlite3.Rc.check
            (Sqlite3.exec sqlite "SELECT addr FROM kvs ORDER BY addr" ~cb:(fun row _ ->
               match row.(0) with
               | Some address -> addresses := address :: !addresses
               | None -> ()));
          List.rev !addresses
        in
        let delete addresses =
          List.iter
            (fun address ->
               prepared
                 sqlite
                 "DELETE FROM kvs WHERE addr = ?"
                 (fun statement ->
                    Sqlite3.Rc.check (Sqlite3.bind_text statement 1 address))
                 (fun statement -> Sqlite3.Rc.check (Sqlite3.step statement)))
            addresses
        in
        let upsert write =
          try
            prepared
              sqlite
              "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?) ON \
               CONFLICT(addr) DO UPDATE SET content=excluded.content, \
               addresses=excluded.addresses"
              (fun statement ->
                 Sqlite3.Rc.check (Sqlite3.bind_text statement 1 write.address);
                 Sqlite3.Rc.check (Sqlite3.bind_text statement 2 write.payload);
                 Sqlite3.Rc.check
                   (Sqlite3.bind statement 3 (addresses_json write.addresses)))
              (fun statement -> rc_result sqlite (Sqlite3.step statement))
          with
          | exn -> Error (Printexc.to_string exn)
        in
        let storage_store entries =
          match !capture with
          | None -> invalid_arg "direct storage writes are forbidden"
          | Some captured ->
            List.iter
              (fun (address, payload) -> Hashtbl.replace captured address payload)
              entries
        in
        let restore address =
          match !capture with
          | Some captured ->
            (match Hashtbl.find_opt captured address with
             | Some payload -> Some payload
             | None -> restore_sqlite address)
          | None -> restore_sqlite address
        in
        let storage =
          { Datascript.storage_store
          ; storage_restore = restore
          ; storage_list_addresses = list_addresses
          ; storage_delete = delete
          }
        in
        let begin_staging () =
          if Option.is_some !capture
          then Error "nested storage staging is forbidden"
          else (
            capture := Some (Hashtbl.create 64);
            Ok ())
        in
        let abort_staging () = capture := None in
        let finish_staging metadata extras =
          match !capture with
          | None -> Error "storage staging has not begun"
          | Some captured ->
            List.iter
              (fun (address, payload) -> Hashtbl.replace captured address payload)
              extras;
            capture := None;
            let entries =
              Hashtbl.to_seq captured
              |> List.of_seq
              |> List.sort (fun (left, _) (right, _) ->
                match int_of_string_opt left, int_of_string_opt right with
                | Some left, Some right -> Int.compare left right
                | _ -> String.compare left right)
            in
            let encoded =
              if
                List.exists
                  (fun (_, payload) ->
                     match payload with
                     | Datascript.Storage_root _ -> true
                     | Storage_node _ | Storage_tail _ -> false)
                  entries
              then Logseq_sqlite_codec.encode_physical_batch ~restore ?metadata entries
              else (
                let rec encode acc = function
                  | [] -> Ok (List.rev acc)
                  | (address, payload) :: rest ->
                    (match Logseq_sqlite_codec.encode_physical_payload payload with
                     | Error error -> Error error
                     | Ok (content, addresses) ->
                       encode
                         (Logseq_sqlite_codec.{ address; content; addresses } :: acc)
                         rest)
                in
                encode [] entries)
            in
            (match encoded with
             | Error error ->
               Error
                 (match error with
                  | Unsupported_tag tag ->
                    "unable to encode staged physical storage batch: unsupported tag "
                    ^ tag
                  | Malformed_transit message
                  | Out_of_range_number message
                  | Malformed_storage_payload message ->
                    "unable to encode staged physical storage batch: " ^ message)
             | Ok encoded ->
               Ok
                 { writes =
                     List.map
                       (fun entry ->
                          { address = entry.Logseq_sqlite_codec.address
                          ; payload = entry.content
                          ; addresses = entry.addresses
                          })
                       encoded
                 ; sync_metadata = None
                 ; sync_outbox = None
                 })
        in
        let initial_root_metadata =
          prepared
            sqlite
            "SELECT content FROM kvs WHERE addr = 0"
            (fun _ -> ())
            (fun statement ->
               match Sqlite3.step statement with
               | Sqlite3.Rc.ROW ->
                 (match
                    Logseq_sqlite_codec.decode_root_index_metadata
                      (Sqlite3.column_text statement 0)
                  with
                  | Ok metadata -> Some metadata
                  | Error _ -> None)
               | DONE -> None
               | rc ->
                 Sqlite3.Rc.check rc;
                 None)
        in
        let initial_root_addresses =
          match restore_sqlite Datascript.Storage.root_address with
          | Some (Datascript.Storage_root root) ->
            Some [ root.storage_eavt; root.storage_aevt; root.storage_avet ]
          | Some (Storage_node _ | Storage_tail _) | None -> None
        in
        let unreachable_address_count_sql =
          Option.map
            (fun root_addresses ->
               let seeds =
                 [ Datascript.Storage.root_address; Datascript.Storage.tail_address ]
                 @ root_addresses
                 |> List.map (fun address ->
                   Printf.sprintf "(%d)" (int_of_string address))
                 |> String.concat ", "
               in
               Printf.sprintf
                 "WITH RECURSIVE reachable(addr) AS (VALUES %s UNION SELECT \
                  CAST(child.value AS INTEGER) FROM reachable JOIN kvs ON kvs.addr = \
                  reachable.addr JOIN json_each(COALESCE(kvs.addresses, '[]')) AS child) \
                  SELECT (SELECT count(*) FROM kvs) - count(*) FROM reachable"
                 seeds)
            initial_root_addresses
        in
        let callbacks =
          { storage
          ; initial_root_metadata
          ; begin_staging
          ; finish_staging
          ; abort_staging
          ; begin_immediate = exec "BEGIN IMMEDIATE"
          ; upsert
          ; upsert_sync_metadata = Sync_checkpoint_store.update_database sqlite
          ; load_sync_outbox = (fun () -> Sync_outbox_store.read_database sqlite)
          ; replace_sync_outbox = Sync_outbox_store.replace_database sqlite
          ; commit = exec "COMMIT"
          ; rollback = (fun () -> ignore (Sqlite3.exec sqlite "ROLLBACK"))
          ; unreachable_address_count =
              (fun () ->
                match unreachable_address_count_sql with
                | None -> 0
                | Some sql ->
                  (match
                     prepared
                       sqlite
                       sql
                       (fun _ -> ())
                       (fun statement ->
                          match Sqlite3.step statement with
                          | ROW -> Some (Sqlite3.column_int statement 0)
                          | rc ->
                            Sqlite3.Rc.check rc;
                            None)
                   with
                   | Some count -> count
                   | None -> failwith "unable to count unreachable storage addresses"))
          ; database_size_bytes =
              (fun () ->
                match
                  pragma_value sqlite "page_count", pragma_value sqlite "page_size"
                with
                | Some page_count, Some page_size ->
                  Int64.mul (Int64.of_string page_count) (Int64.of_string page_size)
                | None, _ | _, None -> failwith "unable to read SQLite database size")
          ; checkpoint = exec "PRAGMA wal_checkpoint(TRUNCATE)"
          ; close =
              (fun () ->
                if Sqlite3.db_close sqlite then Ok () else Error (Sqlite3.errmsg sqlite))
          }
        in
        Ok { sqlite; storage; callbacks })
  with
  | exn -> Error (Begin_failed (Printexc.to_string exn))
;;

let datascript_storage connection = connection.storage
let connection_callbacks connection = connection.callbacks
let verify_connection_pragmas connection = verify_writable_pragmas connection.sqlite

let startup_metadata connection =
  let corrupt message = Error (Corrupt_storage message) in
  match
    ( connection.storage.storage_restore Datascript.Storage.root_address
    , connection.storage.storage_restore Datascript.Storage.tail_address )
  with
  | Some (Datascript.Storage_root root), Some (Datascript.Storage_tail tail) ->
    let basis_tx =
      List.fold_left
        (fun maximum group ->
           match group with
           | [] -> maximum
           | first :: _ -> first.Datascript.tx)
        root.storage_max_tx
        tail
    in
    Ok { schema = root.storage_schema; basis = Int64.of_int basis_tx }
  | Some (Storage_root _), Some _ ->
    corrupt "storage tail address 1 has the wrong payload"
  | Some (Storage_root _), None -> corrupt "storage tail address 1 is missing"
  | Some _, _ -> corrupt "storage root address 0 has the wrong payload"
  | None, _ -> corrupt "storage root address 0 is missing"
;;

let sync_metadata connection = Sync_checkpoint_store.read_database connection.sqlite

let initialize_sync_outbox connection =
  Sync_outbox_store.initialize_database connection.sqlite
;;

let sync_outbox connection = Sync_outbox_store.read_database connection.sqlite

let validate_storage_header connection =
  let corrupt message = Error (Corrupt_storage message) in
  try
    let root_content = ref None in
    Sqlite3.Rc.check
      (Sqlite3.exec
         connection.sqlite
         "SELECT content FROM kvs WHERE addr = 0"
         ~cb:(fun row _ -> root_content := row.(0)));
    match !root_content with
    | None -> corrupt "storage root address 0 is missing"
    | Some content ->
      (match
         ( Logseq_sqlite_codec.decode_physical_payload ~content ~addresses:[]
         , Logseq_sqlite_codec.decode_root_index_metadata content )
       with
       | Ok (Datascript.Storage_root root), Ok _metadata ->
         let require_index label address =
           match connection.storage.storage_restore address with
           | Some (Datascript.Storage_node _) -> Ok ()
           | Some _ -> corrupt (label ^ " root address is not an index node")
           | None -> corrupt (label ^ " root address is missing")
         in
         let ( let* ) result f = Result.bind result f in
         let* () = require_index "EAVT" root.storage_eavt in
         let* () = require_index "AEVT" root.storage_aevt in
         let* () = require_index "AVET" root.storage_avet in
         (match connection.storage.storage_restore Datascript.Storage.tail_address with
          | Some (Datascript.Storage_tail _) -> Ok ()
          | Some _ -> corrupt "storage tail address 1 has the wrong payload"
          | None -> corrupt "storage tail address 1 is missing")
       | Ok (Datascript.Storage_root _), Error _ ->
         corrupt "storage root index metadata is malformed"
       | Ok _, _ -> corrupt "storage root address 0 has the wrong payload"
       | Error _, _ -> corrupt "storage root metadata is malformed")
  with
  | Invalid_argument message -> corrupt message
  | exn -> corrupt (Printexc.to_string exn)
;;

let restore_database connection =
  let corrupt message = Error (Corrupt_storage message) in
  match validate_storage_header connection with
  | Error _ as error -> error
  | Ok () ->
    (try
       match Datascript.restore connection.storage with
       | Some db -> Ok db
       | None -> corrupt "DataScript restore returned no database"
     with
     | Invalid_argument message -> corrupt message
     | exn -> corrupt (Printexc.to_string exn))
;;
