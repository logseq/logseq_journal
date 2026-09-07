module D = Logseq_overlay_db.Database
module T = Logseq_overlay_db.Types
module G = Logseq_db_types.Graph_types
module A = Logseq_db_storage.Audit_datascript
module Storage = Logseq_db_storage.Logseq_sqlite_storage

let ok label = function
  | Ok value -> value
  | Error _ -> failwith label
;;

let require value label = if not value then failwith label
let uuid text = G.Uuid.of_string text |> ok "UUID"

let dependencies () =
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
  D.dependencies
    ~epoch_ms:(fun () -> 1_788_220_800_000L)
    ~monotonic_ns:(fun () -> 0L)
    ~limits
  |> ok "dependencies"
;;

let rewrite_root path transform =
  let connection = Storage.open_database path |> ok "edge open" in
  let original = Storage.restore_database connection |> ok "edge restore" in
  let database = transform original in
  let callbacks = Storage.connection_callbacks connection in
  callbacks.begin_staging () |> ok "edge begin staging";
  Datascript.store ~storage:callbacks.storage database;
  let batch =
    callbacks.finish_staging
      None
      [ Datascript.Storage.tail_address, Datascript.Storage_tail [] ]
    |> ok "edge finish staging"
  in
  Storage.commit_batch callbacks batch |> ok "edge commit";
  Storage.close callbacks |> ok "edge close"
;;

let write_snapshot_from_database ~database_path ~snapshot_path =
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let sqlite = Sqlite3.db_open ~mode:`NO_CREATE database_path in
  let statement =
    Sqlite3.prepare sqlite "SELECT addr, content, addresses FROM kvs ORDER BY addr"
  in
  let rec rows reversed =
    match Sqlite3.step statement with
    | Sqlite3.Rc.ROW ->
      let addr = Sqlite3.column_int statement 0 in
      let content = Sqlite3.column_text statement 1 in
      let addresses =
        match Sqlite3.column statement 2 with
        | Sqlite3.Data.NULL -> Transit.Null
        | TEXT value -> Transit.String value
        | _ -> failwith "snapshot fixture addresses column is not text or null"
      in
      rows
        (Transit.Array [ Transit.Int addr; Transit.String content; addresses ] :: reversed)
    | DONE -> List.rev reversed
    | rc -> failwith ("snapshot query: " ^ Sqlite3.Rc.to_string rc)
  in
  let rows =
    Fun.protect
      ~finally:(fun () ->
        ignore (Sqlite3.finalize statement);
        require (Sqlite3.db_close sqlite) "unable to close snapshot source")
      (fun () -> rows [])
  in
  let payload = Codec.to_string ~mode:Codec.Verbose (Transit.Array rows) in
  let length = String.length payload in
  let prefix = Bytes.create 4 in
  Bytes.set prefix 0 (Char.chr ((length lsr 24) land 0xff));
  Bytes.set prefix 1 (Char.chr ((length lsr 16) land 0xff));
  Bytes.set prefix 2 (Char.chr ((length lsr 8) land 0xff));
  Bytes.set prefix 3 (Char.chr (length land 0xff));
  let channel = open_out_bin snapshot_path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () ->
       output_bytes channel prefix;
       output_string channel payload;
       flush channel);
  List.length rows
;;

let seed support ~entities ~unrelated ~duplicates =
  let graph_id, path =
    Fixture_generator.seed_mirror ~application_support_directory:support ~block_count:0
  in
  rewrite_root path (fun original ->
    let base = Datascript.datoms original Datascript.Eavt () |> List.of_seq in
    let d e a v : Datascript.datom = { e; a; v; tx = 536870913; added = true } in
    let facts =
      List.init entities (fun n ->
        [ d
            (100000 + n)
            "block/uuid"
            (Uuid (Printf.sprintf "92000000-0000-4000-8000-%012d" n))
        ; d (100000 + n) "block/name" (String "name")
        ; d (100000 + n) "block/title" (String "日誌😀")
        ])
      |> List.concat
    in
    let noise =
      List.init unrelated (fun n -> d (200000 + n) "audit/noise" (String "unrelated"))
    in
    let repeated =
      if duplicates
      then List.map (fun (d : Datascript.datom) -> { d with tx = d.tx + 1 }) facts
      else []
    in
    Datascript.init_db
      ~schema:(Datascript.schema original)
      (base @ facts @ noise @ repeated));
  graph_id, path
;;

let measure phase f =
  A.phase := phase;
  A.measure phase f
;;

let finish_crypto prepared =
  let rec loop () =
    match D.next_snapshot_unprotection_batch prepared |> ok "next crypto" with
    | None -> ()
    | Some request ->
      D.supply_snapshot_unprotection_batch
        prepared
        ~request
        ~plaintexts:(D.unprotection_ciphertexts request)
      |> ok "crypto";
      loop ()
  in
  loop ()
;;

let checksum inspection =
  match D.mirror_presence inspection with
  | T.Available { checksum = Some value; _ } -> value
  | _ -> failwith "published checksum missing"
;;

let sample ~verify ~root ~name ~graph_id ~path ~expected_rows ~expected ~retry iteration =
  let support =
    Filename.concat
      root
      (Printf.sprintf "%s-%b-%b-%d" name (Option.is_some expected) retry iteration)
  in
  Unix.mkdir support 0o700;
  let inspection =
    D.inspect_mirror ~application_support_directory:support ~graph_id |> ok "inspect"
  in
  A.reset ();
  let prepared =
    measure "preparation" (fun () ->
      D.prepare_snapshot_activation
        (dependencies ())
        inspection
        ~path
        ~applied_server_cursor:
          (T.Server_cursor.of_string "server-cursor:v1:0" |> ok "cursor")
        ~expected_checksum:expected
        ~expected_rows
      |> ok "prepare")
  in
  Fun.protect
    ~finally:(fun () -> D.cancel_snapshot_activation prepared)
    (fun () ->
       measure "decryption" (fun () -> finish_crypto prepared);
       if retry
       then (
         let parent = Filename.concat support "logseq-db-worker/synced-graphs" in
         Unix.chmod parent 0o500;
         let result =
           Fun.protect
             ~finally:(fun () -> Unix.chmod parent 0o700)
             (fun () ->
                measure "commit" (fun () -> D.commit_snapshot_activation prepared))
         in
         match result with
         | Error (T.Snapshot_commit_persistence_failed _) -> ()
         | _ -> failwith "expected publication failure");
       let inspection =
         measure
           (if retry then "retry" else "commit")
           (fun () -> D.commit_snapshot_activation prepared |> ok "commit")
       in
       let digest = checksum inspection in
       let events = A.json () in
       let count phase =
         List.fold_left
           (fun count json ->
              let open Yojson.Safe.Util in
              if
                json |> member "operation" |> to_string = "checksum"
                && json |> member "phase" |> to_string = phase
              then count + 1
              else count)
           0
           !A.events
       in
       if verify
       then (
         require
           (count "preparation" = if Option.is_some expected then 1 else 0)
           "preparation checksum count";
         require (count "commit" = 1) "final checksum count";
         require (count "retry" = 0) "persisted preparation was recomputed");
       Option.iter
         (fun expected -> require (T.Checksum.equal digest expected) "digest parity")
         expected;
       let json =
         `Assoc
           [ "fixture", `String name
           ; "sample", `Int iteration
           ; "expected_checksum", `Bool (Option.is_some expected)
           ; "retry", `Bool retry
           ; "digest", `String (T.Checksum.to_string digest)
           ; "events", events
           ]
       in
       print_endline (Yojson.Safe.to_string json);
       digest)
;;

let audit ~verify ~root ~name ~graph_id ~database_path =
  let path = Filename.concat root (name ^ ".transit") in
  let expected_rows = write_snapshot_from_database ~database_path ~snapshot_path:path in
  let first =
    sample
      ~verify
      ~root
      ~name
      ~graph_id
      ~path
      ~expected_rows
      ~expected:None
      ~retry:false
      0
  in
  for iteration = 1 to 2 do
    let digest =
      sample
        ~verify
        ~root
        ~name
        ~graph_id
        ~path
        ~expected_rows
        ~expected:None
        ~retry:false
        iteration
    in
    require (T.Checksum.equal digest first) "repeat parity"
  done;
  for iteration = 0 to 2 do
    ignore
      (sample
         ~verify
         ~root
         ~name
         ~graph_id
         ~path
         ~expected_rows
         ~expected:(Some first)
         ~retry:false
         iteration)
  done;
  ignore
    (sample
       ~verify
       ~root
       ~name
       ~graph_id
       ~path
       ~expected_rows
       ~expected:None
       ~retry:true
       0)
;;

let () =
  let verify = Sys.argv.(1) = "verify"
  and root = Sys.argv.(2) in
  if Array.length Sys.argv = 5
  then
    audit
      ~verify
      ~root
      ~name:"mirror"
      ~graph_id:(uuid Sys.argv.(4))
      ~database_path:Sys.argv.(3)
  else
    List.iter
      (fun (entities, unrelated, duplicates) ->
         let name = Printf.sprintf "u%d-n%d-duplicates%b" entities unrelated duplicates in
         let support = Filename.concat root (name ^ "-source") in
         let graph_id, database_path = seed support ~entities ~unrelated ~duplicates in
         audit ~verify ~root ~name ~graph_id ~database_path)
      [ 1000, 0, false
      ; 1000, 64000, false
      ; 4000, 0, false
      ; 16000, 0, false
      ; 1000, 0, true
      ; 1000, 64000, true
      ]
;;
