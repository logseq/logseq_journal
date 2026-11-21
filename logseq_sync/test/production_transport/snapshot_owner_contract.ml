module D = Sync_dsl.Core
module S = Logseq_sync_transport.Snapshot
module C = Logseq_sync_transport.Http_client
module H = Logseq_sync_native_transport.Http
module N = Logseq_sync_native_transport.Http_eio

let get = function
  | Ok value -> value
  | Error error -> Alcotest.fail (D.error_message error)
;;

let identity =
  get
    (D.identity
       ~origin:"https://example.com"
       ~account:"synthetic"
       ~graph:"60000000-0000-4000-8000-000000000001"
       ~account_generation:0L
       ~graph_generation:0L)
;;

let cursor = Result.get_ok (Logseq_overlay_db.Types.Server_cursor.of_int64 3L)

let limits_with_items maximum_items =
  get
    (D.limits
       ~maximum_items
       ~maximum_bytes:1048576
       ~maximum_pending:8
       ~maximum_resources:8
       ~steps_per_turn:8
       ~maximum_tasks:8
       ~maximum_messages:4
       ~maximum_message_bytes:1048576
       ~maximum_demands:8
       ~maximum_active_assets:2
       ~foreground_reserve:1
       ~foreground_demand_reserve:1
       ~foreground_descriptor_reserve_bytes:128
       ~asset_cache_budget_bytes:4096L
       ~asset_maximum_file_bytes:1024
       ~asset_pending_budget_bytes:4096L
       ~snapshot_maximum_artifact_bytes:8388608L
       ~snapshot_staging_budget_bytes:33554432L
       ~snapshot_scratch_budget_bytes:33554432L)
;;

let limits = limits_with_items 1024

let scope : C.scope =
  { check_current = (fun () -> Ok ()); admit_network = (fun () -> Ok ()) }
;;

let response ?(status = 200) ?(headers = []) body : N.response = { status; headers; body }

let rec remove path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_directory callback =
  let path = Filename.temp_file ~temp_dir:(Sys.getcwd ()) "snapshot-owner-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove path) (fun () -> callback path)
;;

let fixture () =
  let open Yojson.Safe.Util in
  let rec root path =
    if Sys.file_exists (Filename.concat path "dune-project")
    then path
    else root (Filename.dirname path)
  in
  let rows =
    Yojson.Safe.from_file
      (Filename.concat
         (root (Sys.getcwd ()))
         "logseq_sync/test/production_transport/snapshot_rows.json")
    |> member "rows"
    |> to_list
  in
  let module V = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let rows =
    List.map
      (fun row ->
         V.Array
           [ V.Int (row |> member "addr" |> to_int)
           ; V.String (row |> member "content" |> to_string)
           ; (match row |> member "addresses" with
              | `Null -> V.Null
              | value -> V.String (to_string value))
           ])
      rows
  in
  let payload = Codec.to_string ~mode:Codec.Verbose (V.Array rows) in
  let prefix = Bytes.create 4 in
  for index = 0 to 3 do
    Bytes.set
      prefix
      index
      (Char.chr ((String.length payload lsr ((3 - index) * 8)) land 255))
  done;
  Bytes.to_string prefix ^ payload, List.length rows
;;

let write path wire =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel wire)
;;

let expect predicate = function
  | Error error when predicate error -> ()
  | Error error -> Alcotest.fail (D.error_message error)
  | Ok _ -> Alcotest.fail "Expected failure"
;;

let protocol = function
  | D.Protocol_failure _ -> true
  | _ -> false
;;

let with_owner
      ?(encrypted = false)
      ?(metadata = "{\"ok\":true,\"url\":\"https://cdn.example.com/snapshot\",\"t\":3}")
      ?wire
      ?rows
      callback
  =
  Eio_main.run (fun _ ->
    with_directory (fun root ->
      let original, count = fixture () in
      let wire = Option.value wire ~default:original
      and rows = Option.value rows ~default:count in
      let requests = ref []
      and downloads = ref 0
      and tokens = ref [] in
      let backend : C.backend =
        { perform =
            (fun request ->
              requests := request :: !requests;
              Ok (response metadata))
        ; download =
            (fun ~request ~destination ~maximum_bytes ->
              incr downloads;
              requests := request :: !requests;
              Alcotest.(check bool) "bounded stream" true (maximum_bytes > 0);
              write destination wire;
              Ok (response ~headers:[ "x-snapshot-row-count", string_of_int rows ] ""))
        }
      in
      let http =
        C.create ~backend ~token:(fun ~epoch ~refresh ->
          tokens := (epoch, refresh) :: !tokens;
          Ok "synthetic-bearer")
      in
      let owner =
        get
          (S.create
             ~verify:Logseq_overlay_db.Database.inspect_snapshot_storage
             ~root
             ~identity
             ~limits
             ~encrypted
             ~http)
      in
      Fun.protect
        ~finally:(fun () -> get (S.close owner))
        (fun () -> callback root owner requests downloads tokens)))
;;

let encryption_failure () =
  with_owner ~encrypted:true (fun root owner _ _ _ ->
    expect
      protocol
      (S.acquire
         owner
         ~scope
         ~epoch:7L
         ~handoff:(fun _ -> Alcotest.fail "Invalid encryption must not hand off")
         cursor);
    Alcotest.(check int)
      "encryption failure cleans staging"
      0
      (Array.length (Sys.readdir root)))
;;

let acquire owner handoff = S.acquire owner ~scope ~epoch:7L ~handoff cursor

let success () =
  with_owner (fun root owner requests downloads tokens ->
    let handed = ref [] in
    let snapshot =
      get
        (acquire owner (fun refs ->
           handed := Rrbvec.to_list refs;
           Ok ()))
    in
    let source = get (S.source owner snapshot) in
    Alcotest.(check bool) "retained actual file" true (Sys.file_exists source.path);
    Alcotest.(check int) "single download" 1 !downloads;
    Alcotest.(check int) "no preliminary pull" 2 (List.length !requests);
    Alcotest.(check int) "only metadata authenticates" 1 (List.length !tokens);
    let artifact = List.hd !requests in
    Alcotest.(check bool)
      "no CDN bearer"
      false
      (List.mem_assoc "authorization" artifact.H.headers);
    Alcotest.(check int) "original handoff" 1 (List.length !handed);
    Alcotest.(check int)
      "canonical checksum length"
      28
      (String.length snapshot.D.checksum);
    let forged_resource =
      get (D.resource ~owner:identity ~token:snapshot.resource.token)
    in
    let forged =
      get
        (D.snapshot
           ~resource:forged_resource
           ~through:cursor
           ~checksum:snapshot.checksum
           ~encrypted:false)
    in
    expect
      (function
        | D.Stale_context -> true
        | _ -> false)
      (S.source owner forged);
    get (S.release owner ~identity snapshot);
    get (S.release owner ~identity snapshot);
    Alcotest.(check bool) "physical release" false (Sys.file_exists source.path);
    Alcotest.(check int) "all owned staging gone" 0 (Array.length (Sys.readdir root)))
;;

let metadata_failure () =
  List.iter
    (fun metadata ->
       with_owner ~metadata (fun root owner _ downloads _ ->
         expect
           protocol
           (acquire owner (fun _ -> Alcotest.fail "invalid metadata handed off"));
         Alcotest.(check int) "no download" 0 !downloads;
         Alcotest.(check int) "no artifacts" 0 (Array.length (Sys.readdir root))))
    [ "{\"ok\":true,\"url\":\"https://cdn.example.com/x\"}"
    ; "{\"ok\":true,\"url\":\"https://cdn.example.com/x\",\"t\":-1}"
    ; "{\"ok\":true,\"url\":\"https://cdn.example.com/x\",\"t\":4}"
    ; "{\"ok\":true,\"url\":\"http://cdn.example.com/x\",\"t\":3}"
    ]
;;

let framing_failure () =
  with_owner ~wire:"\000\000\000\010broken" ~rows:2 (fun root owner _ _ _ ->
    expect
      protocol
      (acquire owner (fun _ -> Alcotest.fail "malformed artifact handed off"));
    Alcotest.(check int) "failed framing cleaned" 0 (Array.length (Sys.readdir root)))
;;

let row_failure () =
  with_owner ~rows:1 (fun root owner _ _ _ ->
    expect protocol (acquire owner (fun _ -> Alcotest.fail "wrong count handed off"));
    Alcotest.(check int) "failed rows cleaned" 0 (Array.length (Sys.readdir root)))
;;

let handoff_failure () =
  with_owner (fun root owner _ _ _ ->
    expect
      (function
        | D.Stale_context -> true
        | _ -> false)
      (acquire owner (fun _ -> Error D.Stale_context));
    Alcotest.(check int) "failed handoff cleaned" 0 (Array.length (Sys.readdir root)))
;;

let auth () =
  Eio_main.run (fun _ ->
    let calls = ref 0
    and tokens = ref [] in
    let backend : C.backend =
      { perform =
          (fun _ ->
            incr calls;
            Ok (response ~status:(if !calls = 1 then 401 else 200) "ok"))
      ; download = (fun ~request:_ ~destination:_ ~maximum_bytes:_ -> assert false)
      }
    in
    let client =
      C.create ~backend ~token:(fun ~epoch:_ ~refresh ->
        tokens := refresh :: !tokens;
        Ok "synthetic")
    in
    ignore
      (get
         (C.perform client ~scope ~epoch:7L ~authenticated:true (fun token ->
            H.catalog ~base_url:(Uri.of_string identity.origin) ~token:(Option.get token))));
    Alcotest.(check (list bool)) "one checked refresh" [ true; false ] !tokens;
    Alcotest.(check int) "two attempts" 2 !calls)
;;

let http_status_policy () =
  List.iter
    (fun (status, network) ->
       let calls = ref 0 in
       let backend : C.backend =
         { perform =
             (fun _ ->
               incr calls;
               Ok (response ~status ""))
         ; download = (fun ~request:_ ~destination:_ ~maximum_bytes:_ -> assert false)
         }
       in
       let client =
         C.create ~backend ~token:(fun ~epoch:_ ~refresh:_ -> Ok "synthetic")
       in
       let result =
         C.perform client ~scope ~epoch:1L ~authenticated:true (fun _ ->
           H.artifact
             ~base_url:(Uri.of_string identity.origin)
             ~uri:(Uri.of_string identity.origin)
             ~token:None)
       in
       expect
         (function
           | D.Network_failure _ -> network
           | D.Protocol_failure _ -> not network
           | _ -> false)
         result;
       Alcotest.(check int) "no hidden refresh or retry" 1 !calls)
    [ 400, false; 422, false; 429, false; 500, false; 503, false ]
;;

let native_client
      ~environment
      ~sw
      ?(http_response_seconds = 1.)
      ?(download_seconds = 3.)
      ()
  =
  let deadlines : Execute.Core.network_deadlines =
    { setup_seconds = 1.
    ; tls_handshake_seconds = 1.
    ; http_response_seconds
    ; download_seconds
    }
  in
  C.create
    ~backend:
      (C.native_backend
         ~sw
         ~clock:(Eio.Stdenv.mono_clock environment)
         ~network:(Eio.Stdenv.net environment)
         ~authenticator:(fun ?ip:_ ~host:_ _ -> Ok None)
         ~deadlines)
    ~token:(fun ~epoch:_ ~refresh:_ -> Ok "synthetic-bearer")
;;

let wire_response headers body = "HTTP/1.1 200 OK\r\n" ^ headers ^ "\r\n" ^ body

let check_retired report =
  let open Yojson.Basic.Util in
  report
  |> to_list
  |> List.iter (fun row ->
    Alcotest.(check bool) "physical peer close" true (row |> member "closed" |> to_bool))
;;

let native_snapshot layers () =
  let wire, rows = fixture () in
  let metadata = "{\"ok\":true,\"url\":\"{{ORIGIN}}/snapshot\",\"t\":3}" in
  let metadata =
    wire_response
      "Content-Type: application/json\r\nContent-Length: {{LENGTH}}\r\n"
      metadata
  in
  let artifact =
    wire_response
      (Printf.sprintf "Content-Length: {{LENGTH}}\r\nX-Snapshot-Row-Count: %d\r\n" rows)
      wire
  in
  let artifact =
    match Tls_peer.case artifact with
    | `Assoc fields -> `Assoc (("gzip_layers", `Int layers) :: fields)
    | _ -> assert false
  in
  let report =
    Tls_peer.with_peer
      [ Tls_peer.case metadata; artifact ]
      (fun ~environment ~sw ~support ~origin ->
         let http = native_client ~environment ~sw () in
         let identity =
           get
             (D.identity
                ~origin:(Uri.to_string origin)
                ~account:"synthetic"
                ~graph:identity.graph
                ~account_generation:0L
                ~graph_generation:0L)
         in
         let staging = Filename.concat support "staging" in
         Unix.mkdir staging 0o700;
         let owner =
           get
             (S.create
                ~verify:Logseq_overlay_db.Database.inspect_snapshot_storage
                ~root:staging
                ~identity
                ~limits
                ~encrypted:false
                ~http)
         in
         Fun.protect
           ~finally:(fun () -> get (S.close owner))
           (fun () ->
              let result = acquire owner (fun _ -> Ok ()) in
              if layers > 2
              then expect protocol result
              else (
                let snapshot = get result in
                let source = get (S.source owner snapshot) in
                Alcotest.(check string)
                  "actual native artifact"
                  wire
                  (Tls_peer.read_file source.path);
                get (S.release owner ~identity snapshot));
              Alcotest.(check int)
                "native staging cleaned"
                0
                (Array.length (Sys.readdir staging))))
  in
  check_retired report
;;

let remote_graph_fixture ?(protected_titles = []) () =
  with_directory (fun root ->
    let module Storage = Logseq_db_storage.Logseq_sqlite_storage in
    let attribute : Datascript.schema_attr =
      { cardinality = One
      ; unique = None
      ; indexed = true
      ; is_component = false
      ; no_history = false
      ; doc = None
      ; value_type = None
      ; tuple_attrs = None
      ; tuple_types = None
      }
    in
    let schema =
      List.map
        (fun name ->
           let attribute =
             match name with
             | "db/ident" | "block/uuid" -> { attribute with unique = Some Identity }
             | "block/parent" | "block/page" ->
               { attribute with value_type = Some RefType }
             | "block/tags" ->
               { attribute with cardinality = Many; value_type = Some RefType }
             | _ -> attribute
           in
           name, attribute)
        [ "db/ident"
        ; "block/uuid"
        ; "block/title"
        ; "block/name"
        ; "block/journal-day"
        ; "block/link"
        ; "block/refs"
        ; "block/tags"
        ; "block/parent"
        ; "block/page"
        ; "block/order"
        ; "kv/value"
        ]
    in
    let fact e a v : Datascript.datom = { e; a; v; tx = 536870913; added = true } in
    let kv e name value = [ fact e "db/ident" (Keyword name); fact e "kv/value" value ] in
    let database =
      Datascript.init_db
        ~schema
        (List.concat
           [ kv 1 "logseq.kv/graph-remote?" (Bool true)
           ; kv 2 "logseq.kv/graph-uuid" (Uuid identity.graph)
           ; kv 3 "logseq.kv/db-type" (String "db")
           ; kv
               4
               "logseq.kv/schema-version"
               (Map [ Keyword "major", Int64 65L; Keyword "minor", Int64 33L ])
           ; (if protected_titles = []
              then []
              else kv 5 "logseq.kv/graph-rtc-e2ee?" (Bool true))
           ; [ fact 6 "db/ident" (Keyword "logseq.class/Journal") ]
           ; List.concat
               (List.mapi
                  (fun index title ->
                     let entity = 100 + index in
                     [ fact
                         entity
                         "block/uuid"
                         (Uuid (Printf.sprintf "70000000-0000-4000-8000-%012d" index))
                     ; fact entity "block/title" (String title)
                     ])
                  protected_titles)
           ])
    in
    let path = Filename.concat root "db.sqlite" in
    let sqlite = Sqlite3.db_open path in
    Sqlite3.Rc.check
      (Sqlite3.exec
         sqlite
         "CREATE TABLE kvs (addr INTEGER PRIMARY KEY, content TEXT, addresses JSON)");
    ignore (Sqlite3.db_close sqlite);
    let connection = Result.get_ok (Storage.open_database path) in
    let callbacks = Storage.connection_callbacks connection in
    Fun.protect
      ~finally:(fun () -> ignore (Storage.close callbacks))
      (fun () ->
         Result.get_ok (callbacks.begin_staging ());
         ignore (Datascript.store ~storage:callbacks.storage database);
         let batch = Result.get_ok (callbacks.finish_staging None []) in
         Result.get_ok (Storage.commit_batch callbacks batch));
    let checksum =
      Result.get_ok
        (Logseq_overlay_db.Database.inspect_snapshot_storage
           ~check_current:(fun () -> ())
           ~scratch_bytes:33554432L
           ~encrypted:(protected_titles <> [])
           ~path)
    in
    let sqlite = Sqlite3.db_open path in
    let rows = ref [] in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
      (fun () ->
         Sqlite3.Rc.check
           (Sqlite3.exec
              sqlite
              ~cb:(fun values _ ->
                let open Transit_core.Json in
                rows
                := Array
                     [ Int (int_of_string (Option.get values.(0)))
                     ; String (Option.get values.(1))
                     ; (match values.(2) with
                        | None -> Null
                        | Some value -> String value)
                     ]
                   :: !rows)
              "SELECT addr, content, addresses FROM kvs ORDER BY addr"));
    let module Codec = Transit_native.Transit.Json in
    let payload =
      Codec.to_string ~mode:Codec.Verbose (Transit_core.Json.Array (List.rev !rows))
    in
    let prefix =
      Bytes.init 4 (fun index ->
        Char.chr ((String.length payload lsr ((3 - index) * 8)) land 255))
    in
    Bytes.to_string prefix ^ payload, List.length !rows, checksum)
;;

let protected_append_echo database ~path ~protect ~unprotect ~duplicate =
  let module Database = Logseq_overlay_db.Database in
  let module Types = Logseq_overlay_db.Types in
  let module Graph = Logseq_db_types.Graph_types in
  let module J = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let ok result =
    match result with
    | Ok value -> value
    | Error _ -> Alcotest.fail "Synthetic protected append operation failed"
  in
  let uuid ordinal =
    ok (Graph.Uuid.of_string (Printf.sprintf "90000000-0000-4000-8000-%012d" ordinal))
  in
  let page = uuid 7790
  and root = uuid 7791
  and child = uuid 7792 in
  let expected = ok (Database.write_precondition ~blocks:[] ~pages:[] ~scopes:[]) in
  let intent =
    ok
      (Database.persist_local_intent
         database
         ~namespace:(String.make 64 'a')
         ~payload:"Synthetic AES append"
         ~expected
         (Types.Append_journal
            { mutation_id = uuid 7793
            ; page
            ; title = "2026-11-02"
            ; journal_day = 20261102
            ; root =
                { uuid = root
                ; title = "Synthetic AES root"
                ; task_status = None
                ; children =
                    Rrbvec.singleton
                      { Types.uuid = child
                      ; title = "Synthetic AES child"
                      ; task_status = None
                      ; children = Rrbvec.empty
                      }
                }
            }))
  in
  let local = ok (Database.commit_local_intent database intent) in
  let local = Database.intent_commit_outcome local in
  let view () = ok (Database.inspect_sync database) in
  let transition change =
    ok
      (Database.begin_outbox_transition
         database
         ~expected:(Types.sync_view_token (view ()))
         change)
  in
  let prepared, request = transition (Types.Submit_group [ local.mutation_id ]) in
  let request = Option.get request in
  let protected = request, get (protect request) in
  let submitted =
    ok (Database.apply_outbox_transition database prepared ~encrypted:(Some protected))
    |> fun commit -> Option.get commit.Types.submission_batch
  in
  let wires = Types.submission_batch_wires submitted in
  Alcotest.(check int) "one atomic AES transaction" 1 (List.length wires);
  let operations =
    Types.submission_wire_protected_transaction (List.hd wires)
    |> Codec.of_string
    |> function
    | J.Array operations -> List.rev operations
    | _ -> Alcotest.fail "Synthetic append wire is not an array"
  in
  let through = ok (Types.Server_cursor.of_int64 4L) in
  let barrier =
    { Types.through
    ; checksum = ok (Types.Checksum.of_string "checksum:v1:0000000000000000")
    }
  in
  let prepared, crypto =
    transition
      (Types.Accept_group { batch_id = Types.submission_batch_id submitted; barrier })
  in
  Alcotest.(check bool) "acceptance needs no crypto" true (crypto = None);
  ignore (ok (Database.apply_outbox_transition database prepared ~encrypted:None));
  let state () =
    let sync = view () in
    let snapshot = ok (Database.current_snapshot database) in
    Fun.protect
      ~finally:(fun () -> Database.release_snapshot snapshot)
      (fun () ->
         ( Types.sync_view_checkpoint sync
         , Types.sync_view_submissions sync
         , Database.snapshot_version snapshot
         , ok (Database.get_outline_blocks snapshot [ root; child ]) ))
  in
  let apply operations =
    let wire = Codec.to_string ~mode:Codec.Verbose (J.Array operations) in
    let batch =
      ok
        (Types.authoritative_batch
           ~maximum_count:16
           ~maximum_bytes:1048576
           ~transactions:
             [ Types.authoritative_transaction
                 ~cursor:through
                 ~transaction:
                   (ok (Types.encoded_transaction_of_string ~maximum_bytes:1048576 wire))
             ]
           ~through
           ~checksum:None)
    in
    let prepared, request =
      ok
        (Database.begin_authoritative
           database
           ~expected:(Types.sync_view_token (view ()))
           batch)
    in
    let request = Option.get request in
    let decrypted = request, get (unprotect request) in
    let result =
      Database.apply_authoritative database prepared ~decrypted:(Some decrypted)
    in
    (match result with
     | Error (Types.Authoritative_decode_failed message) ->
       Alcotest.failf "Synthetic echo decode: %s" message
     | _ -> ());
    result
  in
  let durable_state () =
    let sqlite = Sqlite3.db_open ~mode:`READONLY path in
    Fun.protect
      ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
      (fun () ->
         let tables = ref [] in
         Sqlite3.Rc.check
           (Sqlite3.exec
              sqlite
              ~cb:(fun row _ -> tables := Option.get row.(0) :: !tables)
              "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
         List.map
           (fun table ->
              let rows = ref [] in
              Sqlite3.Rc.check
                (Sqlite3.exec
                   sqlite
                   ~cb:(fun row _ -> rows := Array.to_list row :: !rows)
                   ("SELECT * FROM \""
                    ^ String.concat "\"\"" (String.split_on_char '"' table)
                    ^ "\""));
              table, List.sort compare !rows)
           !tables)
  in
  let before = state ()
  and durable_before = durable_state () in
  let reject label operations =
    (match apply operations with
     | Error (Types.Authoritative_integrity_failure _) -> ()
     | _ -> Alcotest.fail ("AES echo must reject " ^ label));
    Alcotest.(check bool)
      (label ^ " leaves logical view unchanged")
      true
      (state () = before);
    Alcotest.(check bool)
      (label ^ " leaves every durable table unchanged")
      true
      (durable_state () = durable_before)
  in
  if not duplicate
  then (
    reject
      "changed UUID"
      (List.map
         (function
           | J.Array [ op; entity; J.Keyword "block/uuid"; J.Uuid value ]
             when value = Graph.Uuid.to_string child ->
             J.Array
               [ op
               ; entity
               ; J.Keyword "block/uuid"
               ; J.Uuid (Graph.Uuid.to_string (uuid 7794))
               ]
           | operation -> operation)
         operations);
    reject
      "changed reference"
      (List.map
         (function
           | J.Array [ op; entity; J.Keyword "block/parent"; _ ] ->
             J.Array
               [ op
               ; entity
               ; J.Keyword "block/parent"
               ; J.Array [ J.Keyword "block/uuid"; J.Uuid (Graph.Uuid.to_string child) ]
               ]
           | operation -> operation)
         operations);
    reject
      "changed ident reference"
      (List.map
         (function
           | J.Array [ op; entity; J.Keyword "block/tags"; _ ] ->
             J.Array
               [ op
               ; entity
               ; J.Keyword "block/tags"
               ; J.Array [ J.Keyword "db/ident"; J.Keyword "logseq.kv/graph-remote?" ]
               ]
           | operation -> operation)
         operations);
    let title =
      List.find
        (function
          | J.Array [ _; _; J.Keyword "block/title"; _ ] -> true
          | _ -> false)
        operations
    in
    reject "missing fact" (List.filter (fun operation -> operation <> title) operations);
    let entity =
      match title with
      | J.Array [ _; entity; _; _ ] -> entity
      | _ -> assert false
    in
    reject
      "extra fact"
      (operations
       @ [ J.Array [ J.Keyword "db/add"; entity; J.Keyword "block/updated-at"; J.Int 123 ]
         ]);
    let repeated =
      match title with
      | J.Array [ op; _; attr; value ] ->
        J.Array [ op; J.String "synthetic-extra-owner"; attr; value ]
      | _ -> assert false
    in
    reject "changed multiplicity" (operations @ [ repeated ]));
  let operations = if duplicate then operations @ operations else operations in
  (match ok (apply operations) with
   | Database.Authoritative_applied _ -> ()
   | _ -> Alcotest.fail "AES reordered append was deferred");
  Alcotest.(check int64)
    "AES echo advances checkpoint"
    4L
    (Types.Server_cursor.to_int64 (Types.sync_view_checkpoint (view ())));
  Alcotest.(check int)
    "AES echo retires accepted owner"
    0
    (List.length (Types.sync_view_submissions (view ())));
  let actual =
    ok
      (Database.inspect_snapshot_storage
         ~check_current:(fun () -> ())
         ~scratch_bytes:33554432L
         ~encrypted:true
         ~path)
  in
  Alcotest.(check (option bool))
    "AES echo actual durable checksum"
    (Some true)
    (ok (Database.check_checkpoint_checksum database ~through ~expected:actual));
  let wrong = ok (Types.Checksum.of_string "checksum:v1:ffffffffffffffff") in
  Alcotest.(check (option bool))
    "AES echo wrong checksum rejected"
    (Some false)
    (ok (Database.check_checkpoint_checksum database ~through ~expected:wrong));
  let snapshot = ok (Database.current_snapshot database) in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () ->
       match ok (Database.get_outline_blocks snapshot [ root; child ]) with
       | [ Types.Present_block { value = first; _ }
         ; Types.Present_block { value = second; _ }
         ] ->
         Alcotest.(check bool)
           "AES echo stable parent/page references"
           true
           (first.block.parent = page
            && second.block.parent = root
            && first.block.page = page
            && second.block.page = page);
         Alcotest.(check string)
           "AES root authenticated title"
           "Synthetic AES root"
           first.block.title;
         Alcotest.(check string)
           "AES child authenticated title"
           "Synthetic AES child"
           second.block.title
       | _ -> Alcotest.fail "AES echo lost the complete tree")
;;

let synthetic_crypto_backend () =
  let module Crypto = Logseq_sync_crypto.Core in
  let module Aes = Mirage_crypto.AES.GCM in
  let backend : Crypto.backend =
    { unlock = (fun ~identity:_ ~wrapped_graph_key:_ -> Ok (String.make 32 'k'))
    ; crypto =
        { encrypt_aes_gcm =
            (fun ~key ~plaintext ->
              let iv = String.make 12 'i' in
              Ok
                (iv, Aes.authenticate_encrypt ~key:(Aes.of_secret key) ~nonce:iv plaintext))
        ; decrypt_aes_gcm =
            (fun ~key ~iv ~ciphertext ->
              match
                Aes.authenticate_decrypt ~key:(Aes.of_secret key) ~nonce:iv ciphertext
              with
              | Some plaintext -> Ok plaintext
              | None -> Error "Synthetic authentication failure")
        }
    }
  in
  backend
;;

let encrypted_snapshot_activation ?echo () =
  let module Crypto = Logseq_sync_crypto.Core in
  let module Owner = Logseq_sync_execute_owners.Database_owner in
  let module Database = Logseq_overlay_db.Database in
  let module Types = Logseq_overlay_db.Types in
  let backend = synthetic_crypto_backend () in
  let crypto_limits = limits_with_items 2 in
  let crypto = Crypto.create ~identity ~limits:crypto_limits ~encrypted:true ~backend in
  let run operation =
    Crypto.run crypto ~identity ~check_current:(fun () -> Ok ()) operation
  in
  Fun.protect
    ~finally:(fun () -> Crypto.retire crypto)
    (fun () ->
       ignore (get (run (D.Unlock (get (D.unlock_input ~wrapped_graph_key:"synthetic")))));
       let titles =
         List.init 5 (fun index -> Printf.sprintf "Synthetic title %d" index)
       in
       let protected_titles =
         List.map
           (fun title ->
              let plaintext =
                Transit_native.Transit.Json.to_string (Transit_core.Json.String title)
              in
              let iv, ciphertext =
                List.hd
                  (Rrbvec.to_list
                     (get (run (D.Encrypt_values (Rrbvec.singleton plaintext)))))
              in
              Transit_native.Transit.Json.to_string
                (Transit_core.Json.Array [ Binary iv; Binary ciphertext ]))
           titles
       in
       let wire, rows, _ = remote_graph_fixture ~protected_titles () in
       with_owner ~encrypted:true ~wire ~rows (fun root owner _ _ _ ->
         Eio.Switch.run (fun sw ->
           let snapshot = get (acquire owner (fun _ -> Ok ())) in
           let source = get (S.source owner snapshot) in
           let dependencies =
             Result.get_ok
               (Database.dependencies
                  ~epoch_ms:(fun () -> 0L)
                  ~monotonic_ns:Mtime_clock.elapsed_ns
                  ~limits:
                    { Types.response_budget_bytes = 1048576
                    ; outbox_max_records = 32
                    ; outbox_max_bytes = 4194304
                    ; change_max_items = 1024
                    ; change_max_bytes = 1048576
                    ; dispatcher_capacity = 32
                    ; wire_batch_max_bytes = 1048576
                    })
           in
           let inspection =
             Result.get_ok
               (Database.inspect_mirror
                  ~application_support_directory:root
                  ~graph_id:
                    (Result.get_ok
                       (Logseq_db_types.Graph_types.Uuid.of_string identity.graph)))
           in
           let binding =
             Owner.activation_owner
               ~sw
               ~dependencies
               ~inspection
               ~graph_name:"Encrypted synthetic"
           in
           let batches = ref [] in
           let unprotect request =
             batches
             := List.length (Database.unprotection_ciphertexts request) :: !batches;
             run (D.Unprotect request)
           in
           (match
              Owner.activate_snapshot
                binding
                ~check_current:(fun () -> Ok ())
                { snapshot
                ; path = source.path
                ; expected_rows = source.expected_rows
                ; maximum_crypto_items = 1024
                ; maximum_crypto_bytes = crypto_limits.maximum_bytes
                ; unprotect
                }
            with
            | Error (D.Capacity_exceeded "Crypto items") -> ()
            | _ ->
              Alcotest.fail
                "unbounded snapshot must reproduce the crypto capacity rejection");
           Alcotest.(check bool)
             "rejected activation stays absent"
             true
             (get (Owner.database_if_open binding) = None);
           let corrupt =
             get
               (D.snapshot
                  ~resource:snapshot.resource
                  ~through:snapshot.through
                  ~checksum:"checksum:v1:ffffffffffffffff"
                  ~encrypted:true)
           in
           batches := [];
           ignore
             (get
                (Owner.activate_snapshot
                   binding
                   ~check_current:(fun () -> Ok ())
                   { snapshot = corrupt
                   ; path = source.path
                   ; expected_rows = source.expected_rows
                   ; maximum_crypto_items = crypto_limits.maximum_items
                   ; maximum_crypto_bytes = crypto_limits.maximum_bytes
                   ; unprotect =
                       (fun request ->
                         batches
                         := List.length (Database.unprotection_ciphertexts request)
                            :: !batches;
                         run (D.Unprotect request))
                   }));
           let database = get (Owner.database binding) in
           Fun.protect
             ~finally:(fun () -> ignore (Database.close database))
             (fun () ->
                Alcotest.(check (list int)) "bounded crypto batches" [ 1; 2; 2 ] !batches;
                let expected =
                  Result.get_ok (Types.Checksum.of_string snapshot.checksum)
                in
                Alcotest.(check (option bool))
                  "actual authoritative checksum"
                  (Some true)
                  (Result.get_ok
                     (Database.check_checkpoint_checksum
                        database
                        ~through:cursor
                        ~expected));
                let wrong =
                  Result.get_ok (Types.Checksum.of_string "checksum:v1:ffffffffffffffff")
                in
                Alcotest.(check (option bool))
                  "same cursor rejects wrong checksum"
                  (Some false)
                  (Result.get_ok
                     (Database.check_checkpoint_checksum
                        database
                        ~through:cursor
                        ~expected:wrong));
                Alcotest.(check (option bool))
                  "different cursor has no checksum comparison"
                  None
                  (Result.get_ok
                     (Database.check_checkpoint_checksum
                        database
                        ~through:(Result.get_ok (Types.Server_cursor.of_int64 4L))
                        ~expected:wrong));
                let view = Result.get_ok (Database.inspect_sync database) in
                Alcotest.(check int64)
                  "activated checkpoint"
                  3L
                  (Types.Server_cursor.to_int64 (Types.sync_view_checkpoint view));
                Option.iter
                  (fun duplicate ->
                     let echo_crypto =
                       Crypto.create ~identity ~limits ~encrypted:true ~backend
                     in
                     let run operation =
                       Crypto.run
                         echo_crypto
                         ~identity
                         ~check_current:(fun () -> Ok ())
                         operation
                     in
                     Fun.protect
                       ~finally:(fun () -> Crypto.retire echo_crypto)
                       (fun () ->
                          ignore
                            (get
                               (run
                                  (D.Unlock
                                     (get (D.unlock_input ~wrapped_graph_key:"synthetic")))));
                          protected_append_echo
                            database
                            ~path:
                              (Filename.concat
                                 root
                                 ("logseq-db-worker/synced-graphs/"
                                  ^ identity.graph
                                  ^ "/db.sqlite"))
                            ~protect:(fun request -> run (D.Protect request))
                            ~unprotect:(fun request -> run (D.Unprotect request))
                            ~duplicate))
                  echo))))
;;

let start_encrypted_native_fixture
      ~environment
      ~sw
      ~root
      ~dependencies
      ~config
      ~sqlite
      ~on_change
  =
  let module X = Execute.Core in
  let module T = Logseq_sync_transport.Core in
  let module Crypto = Logseq_sync_crypto.Core in
  let module Worker = Logseq_sync_worker_owner.Core in
  let module Assets = Worker.Assets in
  let module Service = Logseq_sync_sync_service.Core in
  let module Database = Logseq_overlay_db.Database in
  let module Types = Logseq_overlay_db.Types in
  let identity = config.Service.identity in
  let clock = Eio.Stdenv.mono_clock environment in
  let deadlines : X.network_deadlines =
    { setup_seconds = 2.
    ; tls_handshake_seconds = 2.
    ; http_response_seconds = 2.
    ; download_seconds = 2.
    }
  in
  let staging_directory = Filename.concat root "staging" in
  Unix.mkdir staging_directory 0o700;
  let transport =
    get
      (T.create_native
         ~verify_snapshot:Database.inspect_snapshot_storage
         ~sw
         ~clock
         ~network:(Eio.Stdenv.net environment)
         ~authenticator:(fun ?ip:_ ~host:_ _ -> Ok None)
         ~identity
         ~limits
         ~deadlines
         ~cleanup_seconds:2.
         ~liveness:X.Peer_close_only
         ~staging_directory
         ~encrypted:true
         ~token:(fun ~epoch:_ ~refresh:_ -> Ok "synthetic-fixture-token"))
  in
  let inspection =
    Result.get_ok
      (Database.inspect_mirror
         ~application_support_directory:root
         ~graph_id:
           (Result.get_ok (Logseq_db_types.Graph_types.Uuid.of_string identity.graph)))
  in
  let owner =
    get
      (X.activation_owner
         ~sw
         ~dependencies
         ~inspection
         ~graph_name:"Anonymous encrypted bootstrap"
         ~snapshot_source:(T.snapshot_source transport))
  in
  let crypto =
    Crypto.create ~identity ~limits ~encrypted:true ~backend:(synthetic_crypto_backend ())
  in
  ignore
    (get
       (Crypto.run
          crypto
          ~identity
          ~check_current:(fun () -> Ok ())
          (D.Unlock (get (D.unlock_input ~wrapped_graph_key:"synthetic")))));
  let assets =
    get
      (Assets.create
         ~root:(Filename.concat root "assets")
         ~identity
         ~limits
         ~crypto
         ~key:(Assets.native_key ~identity ~crypto)
         ~network:
           { get =
               (fun ~identity:_ ~asset:_ ~version:_ ~maximum_wire_bytes:_ ->
                 Alcotest.fail "bootstrap must not fetch assets")
           ; put =
               (fun ~identity:_ ~asset:_ ~version:_ ~wire:_ ->
                 Alcotest.fail "bootstrap must not upload assets")
           })
  in
  let bound = ref None in
  let worker =
    Worker.create
      ~clock
      ~namespace:(String.make 64 'a')
      ~assets
      ~store:(Worker.store sqlite)
      ~notify_outbox_changed:(fun ~owner ~identity ->
        (Option.get !bound).Service.outbox_committed ~owner ~identity)
  in
  let gate = ref D.Closed in
  let checkpoint () =
    Option.map
      (fun database ->
         Types.sync_view_checkpoint (Result.get_ok (Database.inspect_sync database)))
      (get (X.database_if_open owner))
  in
  let caps : X.capabilities =
    { validate_identity =
        (fun actual -> if actual = identity then Ok () else Error D.Stale_context)
    ; validate_limits =
        (fun actual ->
          if actual = limits then Ok () else Error (D.Invalid_input "fixture limits"))
    ; websocket_liveness = X.Peer_close_only
    ; network_deadlines = deadlines
    ; cleanup_seconds = 2.
    ; acquire = (fun _ -> Ok ())
    ; fence_network =
        (fun identity ->
          gate := D.Closed;
          T.fence transport ~identity)
    ; close_network = (fun identity -> T.close_network transport ~identity)
    ; authorize_network =
        (fun identity ~epoch ->
          get (T.authorize transport ~identity ~epoch);
          gate := D.Open { authorization_epoch = epoch };
          Ok ())
    ; validate_resource = T.validate_resource transport
    ; restore =
        (fun ~scope _ ->
          get (X.check_current scope);
          Ok
            { D.keys = Crypto.status crypto
            ; checkpoint = checkpoint ()
            ; recovery_pending = false
            })
    ; worker_owner = Worker.worker_owner worker
    ; dispatch =
        { database =
            (fun ~owner:_ ~scope:_ ~identity:_ _ ->
              Alcotest.fail "Execute owns database dispatch")
        ; transport =
            (fun ~scope ~identity operation ->
              T.dispatch transport ~scope ~identity operation)
        ; crypto =
            (fun ~scope ~identity operation ->
              Worker.crypto_dispatch worker ~scope ~identity operation)
        ; assets = (fun ~scope:_ ~identity:_ _ -> Alcotest.fail "unexpected assets")
        }
    ; observe =
        (fun identity ->
          Ok
            { D.identity
            ; keys = Crypto.status crypto
            ; network = !gate
            ; checkpoint = checkpoint ()
            ; pending_submissions = 0
            ; pending_assets = 0
            ; cleanup_pending = 0
            ; last_failure = None
            })
    ; fence =
        (fun identity ->
          Assets.fence assets;
          Worker.fence worker ~identity)
    ; retire =
        (fun identity ->
          get (Worker.await_quiescent worker ~identity);
          get (Assets.close assets);
          Crypto.retire crypto;
          Ok ())
    ; release_file = (fun identity file -> Assets.release_file assets ~identity file)
    ; release_lease = (fun identity lease -> Assets.release_lease assets ~identity lease)
    ; release_snapshot =
        (fun identity snapshot -> T.release_snapshot transport ~identity snapshot)
    }
  in
  let service =
    get
      (Service.start
         ~sw
         ~config
         ~dependencies:
           { clock
           ; database_owner = owner
           ; capabilities = caps
           ; bind_ingress = (fun ingress -> bound := Some ingress)
           }
         ~on_change)
  in
  ( owner
  , (fun reconnect ->
      if reconnect
      then (
        get (Service.set_network service D.Closed);
        get (Service.set_network service (D.Open { authorization_epoch = 2L })))
      else get ((Option.get !bound).Service.outbox_committed ~owner ~identity))
  , fun () ->
      Service.close service;
      Option.iter
        (fun database -> ignore (Database.close database))
        (get (X.database_if_open owner)) )
;;

let native_service_bootstrap ?(checksum_mode = `Valid) ?(new_head = false) () =
  let module App = Journal_sync_lifecycle.Core in
  let module X = Execute.Core in
  let module Database = Logseq_overlay_db.Database in
  let module Types = Logseq_overlay_db.Types in
  let protected_titles =
    if checksum_mode <> `Invalid
    then []
    else (
      let plaintext =
        Transit_native.Transit.Json.to_string
          (Transit_core.Json.String "Anonymous encrypted title")
      in
      let iv, ciphertext =
        Result.get_ok
          ((synthetic_crypto_backend ()).crypto.encrypt_aes_gcm
             ~key:(String.make 32 'k')
             ~plaintext)
      in
      [ Transit_native.Transit.Json.to_string
          (Transit_core.Json.Array [ Binary iv; Binary ciphertext ])
      ])
  in
  let wire, rows, checksum = remote_graph_fixture ~protected_titles () in
  let metadata =
    wire_response
      "Content-Type: application/json\r\nContent-Length: {{LENGTH}}\r\n"
      "{\"ok\":true,\"url\":\"{{ORIGIN}}/snapshot\",\"t\":3}"
  in
  let artifact =
    wire_response
      (Printf.sprintf "Content-Length: {{LENGTH}}\r\nX-Snapshot-Row-Count: %d\r\n" rows)
      wire
  in
  let module Protocol = Logseq_sync_protocol.Sync_protocol in
  let wire_checksum = Types.Checksum.to_string checksum in
  let wire_checksum = String.sub wire_checksum (String.length "checksum:v1:") 16 in
  let hello =
    Result.get_ok
      (Protocol.encode_server_message
         (Protocol.Server.Hello
            { t = cursor
            ; checksum =
                (match checksum_mode with
                 | `Valid -> Some wire_checksum
                 | `Invalid ->
                   Some
                     (if wire_checksum = "ffffffffffffffff"
                      then "0000000000000000"
                      else "ffffffffffffffff")
                 | `Missing -> None)
            }))
  in
  let frame =
    String.make 1 (Char.chr 0x81) ^ String.make 1 (Char.chr (String.length hello)) ^ hello
  in
  let socket ?(parallel = true) frame =
    match Tls_peer.case ~ws:true "" with
    | `Assoc fields ->
      `Assoc
        (("parallel", `Bool parallel)
         :: ("lifetime", `Int 10)
         :: ("reply_text", `String (Tls_peer.hex frame))
         :: fields)
    | _ -> assert false
  in
  let later_hello =
    Result.get_ok
      (Protocol.encode_server_message
         (Protocol.Server.Hello { t = cursor; checksum = Some "1234567890abcdef" }))
  in
  let later_frame =
    String.make 1 (Char.chr 0x81)
    ^ String.make 1 (Char.chr (String.length later_hello))
    ^ later_hello
  in
  let report =
    Tls_peer.with_peer
      ([ socket frame
       ; Tls_peer.case ~eof:true metadata
       ; Tls_peer.case ~eof:true artifact
       ]
       @ if new_head then [ socket ~parallel:false later_frame ] else [])
      (fun ~environment ~sw ~support ~origin ->
         let identity =
           get
             (D.identity
                ~origin:(Uri.to_string origin)
                ~account:"synthetic"
                ~graph:identity.graph
                ~account_generation:0L
                ~graph_generation:0L)
         in
         let root = Filename.concat support "application" in
         Unix.mkdir root 0o700;
         let dependencies =
           Result.get_ok
             (Database.dependencies
                ~epoch_ms:(fun () -> 0L)
                ~monotonic_ns:Mtime_clock.elapsed_ns
                ~limits:
                  { Types.response_budget_bytes = 1048576
                  ; outbox_max_records = 32
                  ; outbox_max_bytes = 4194304
                  ; change_max_items = 1024
                  ; change_max_bytes = 1048576
                  ; dispatcher_capacity = 32
                  ; wire_batch_max_bytes = 1048576
                  })
         in
         let sqlite = Sqlite3.db_open ":memory:" in
         Fun.protect
           ~finally:(fun () ->
             Alcotest.(check bool)
               "App upload store released"
               true
               (Sqlite3.db_close sqlite))
           (fun () ->
              Result.get_ok
                (Logseq_db_storage.Asset_upload_store.initialize_database sqlite);
              let retry =
                get
                  (D.retry_policy
                     ~initial_seconds:0.01
                     ~maximum_seconds:0.01
                     ~multiplier:1.
                     ~maximum_attempts:0)
              in
              let config : Logseq_sync_sync_service.Core.config =
                { identity
                ; limits
                ; network = D.Open { authorization_epoch = 1L }
                ; policy =
                    get
                      (D.policy_config
                         ~sync_retry:retry
                         ~asset_retry:retry
                         ~no_progress_seconds:0.01)
                }
              in
              let errors = ref [] in
              let observed_checkpoint = ref None in
              let online = ref false in
              let returned = ref false in
              let on_change (status : Logseq_sync_sync_service.Core.status) =
                Alcotest.(check bool) "startup callback follows return" true !returned;
                let observation = status.observation in
                observed_checkpoint := observation.state.checkpoint;
                online := observation.status = D.Service_online;
                match observation.status with
                | D.Service_blocked error -> errors := error :: !errors
                | _ -> ()
              in
              let owner, resample, close =
                if checksum_mode = `Invalid
                then
                  start_encrypted_native_fixture
                    ~environment
                    ~sw
                    ~root
                    ~dependencies
                    ~config
                    ~sqlite
                    ~on_change
                else (
                  let service =
                    get
                      (App.start_owned_native
                         ~sw
                         ~clock:(Eio.Stdenv.mono_clock environment)
                         ~network:(Eio.Stdenv.net environment)
                         ~authenticator:(fun ?ip:_ ~host:_ _ -> Ok None)
                         ~config
                         ~deadlines:
                           { X.setup_seconds = 2.
                           ; tls_handshake_seconds = 2.
                           ; http_response_seconds = 2.
                           ; download_seconds = 2.
                           }
                         ~liveness:X.Peer_close_only
                         ~cleanup_seconds:2.
                         ~root
                         ~dependencies
                         ~graph_name:"Synthetic native bootstrap"
                         ~upload_store:(Logseq_sync_worker_owner.Core.store sqlite)
                         ~namespace:(String.make 64 'a')
                         ~encrypted:false
                         ~token:(fun ~epoch:_ ~refresh:_ -> Ok "synthetic-fixture-token")
                         ~on_change
                         ~on_error:(fun error -> errors := error :: !errors))
                  in
                  ( App.database_owner service
                  , (fun _ -> get (App.projection_changed service))
                  , fun () -> App.close service ))
              in
              returned := true;
              Fun.protect ~finally:close (fun () ->
                Tls_peer.wait (Eio.Stdenv.clock environment) (fun () ->
                  (match !errors with
                   | D.Activation_failure (Types.Snapshot_parse_error message) :: _ ->
                     Alcotest.fail ("Activation parse: " ^ message)
                   | D.Activation_failure Types.Snapshot_limit_exceeded :: _ ->
                     Alcotest.fail "Activation limit exceeded"
                   | D.Activation_failure
                       (Types.Snapshot_commit_persistence_failed message)
                     :: _ -> Alcotest.fail ("Activation persistence: " ^ message)
                   | error :: _ -> Alcotest.fail (D.error_message error)
                   | [] -> ());
                  Option.is_some !observed_checkpoint && !online);
                let database = get (X.database owner) in
                Alcotest.(check (option bool))
                  "actual snapshot digest is committed"
                  (Some true)
                  (Result.get_ok
                     (Database.check_checkpoint_checksum
                        database
                        ~through:cursor
                        ~expected:checksum));
                let inspection =
                  Result.get_ok
                    (Database.inspect_mirror
                       ~application_support_directory:root
                       ~graph_id:
                         (Result.get_ok
                            (Logseq_db_types.Graph_types.Uuid.of_string identity.graph)))
                in
                Alcotest.(check bool)
                  "activated mirror is locally available"
                  true
                  (match Database.mirror_presence inspection with
                   | Types.Available _ -> true
                   | Types.Absent _ -> false);
                let durable_digest =
                  Result.get_ok
                    (Database.inspect_snapshot_storage
                       ~check_current:(fun () -> ())
                       ~scratch_bytes:33554432L
                       ~encrypted:(checksum_mode = `Invalid)
                       ~path:
                         (Filename.concat
                            root
                            ("logseq-db-worker/synced-graphs/"
                             ^ identity.graph
                             ^ "/db.sqlite")))
                in
                Alcotest.(check string)
                  "SQLite stores actual snapshot digest"
                  (Types.Checksum.to_string checksum)
                  (Types.Checksum.to_string durable_digest);
                if checksum_mode = `Invalid
                then (
                  let expected =
                    Result.get_ok
                      (Types.Checksum.of_string
                         ("checksum:v1:"
                          ^
                          if wire_checksum = "ffffffffffffffff"
                          then "0000000000000000"
                          else "ffffffffffffffff"))
                  in
                  Alcotest.(check (option bool))
                    "Hello digest never forges the durable digest"
                    (Some false)
                    (Result.get_ok
                       (Database.check_checkpoint_checksum
                          database
                          ~through:cursor
                          ~expected));
                  online := false;
                  resample false;
                  Tls_peer.wait (Eio.Stdenv.clock environment) (fun () ->
                    match !errors with
                    | error :: _ -> Alcotest.fail (D.error_message error)
                    | [] -> !online));
                let view = Result.get_ok (Database.inspect_sync database) in
                Alcotest.(check int64)
                  "native service activates exact server checkpoint"
                  3L
                  (Types.sync_view_checkpoint view |> Types.Server_cursor.to_int64);
                Alcotest.(check int)
                  "bootstrap subscription errors"
                  0
                  (List.length !errors);
                if new_head
                then (
                  resample true;
                  online := false;
                  Tls_peer.wait (Eio.Stdenv.clock environment) (fun () ->
                    match !errors with
                    | error :: _ -> Alcotest.fail (D.error_message error)
                    | [] -> !online);
                  Alcotest.(check int)
                    "new head remains online without errors"
                    0
                    (List.length !errors);
                  Alcotest.(check (option bool))
                    "diagnostic head preserves actual digest"
                    (Some true)
                    (Result.get_ok
                       (Database.check_checkpoint_checksum
                          database
                          ~through:cursor
                          ~expected:checksum))))))
  in
  check_retired report
;;

let native_http ~download ~success ~eof wire () =
  let report =
    Tls_peer.with_peer
      [ Tls_peer.case ~eof wire ]
      (fun ~environment ~sw ~support ~origin ->
         let http = native_client ~environment ~sw () in
         let destination = Filename.concat support "artifact" in
         let request token =
           H.
             { operation = Get
             ; uri = origin
             ; headers = H.authorization (Option.get token)
             ; maximum_response_bytes = 16
             ; expected_content_type = Asset_binary
             }
         in
         let result =
           if download
           then
             C.download
               http
               ~scope
               ~epoch:1L
               ~authenticated:true
               ~destination
               ~maximum_bytes:16
               request
           else C.perform http ~scope ~epoch:1L ~authenticated:true request
         in
         Alcotest.(check bool) "HTTP outcome" success (Result.is_ok result);
         if not success
         then
           expect
             (function
               | D.Protocol_failure _ -> true
               | _ -> false)
             result;
         if download
         then (
           Alcotest.(check bool)
             "publish only complete body"
             success
             (Sys.file_exists destination);
           Alcotest.(check bool)
             "no partial files"
             false
             (Array.exists
                (fun name -> Filename.check_suffix name ".partial")
                (Sys.readdir support))))
  in
  check_retired report
;;

let native_assets () =
  let report =
    Tls_peer.with_peer
      [ Tls_peer.case (wire_response "Content-Length: 4\r\n" "wire")
      ; Tls_peer.case (wire_response "Content-Length: 0\r\n" "")
      ]
      (fun ~environment ~sw ~support:_ ~origin ->
         let http = native_client ~environment ~sw () in
         let identity =
           get
             (D.identity
                ~origin:(Uri.to_string origin)
                ~account:"synthetic"
                ~graph:identity.graph
                ~account_generation:0L
                ~graph_generation:0L)
         in
         let asset =
           Result.get_ok
             (Logseq_db_types.Graph_types.Uuid.of_string
                "11111111-1111-4111-8111-111111111111")
         in
         let version =
           Result.get_ok
             (Logseq_db_types.Asset_descriptor.version
                ~checksum:(String.make 64 'a')
                ~file_type:"png")
         in
         Alcotest.(check (option string))
           "GET preserves protected wire"
           (Some "wire")
           (get
              (C.get_asset
                 http
                 ~scope
                 ~epoch:1L
                 ~identity
                 ~asset
                 ~version
                 ~maximum_wire_bytes:16));
         get
           (C.put_asset
              http
              ~scope
              ~epoch:1L
              ~identity
              ~asset
              ~version
              ~wire:"protected-wire"))
  in
  check_retired report;
  let open Yojson.Basic.Util in
  let requests =
    report |> to_list |> List.map (fun row -> row |> member "request" |> to_string)
  in
  let decode hex =
    String.init
      (String.length hex / 2)
      (fun index -> Char.chr (int_of_string ("0x" ^ String.sub hex (index * 2) 2)))
  in
  let put = decode (List.nth requests 1) in
  Alcotest.(check bool)
    "production PUT method"
    true
    (String.starts_with ~prefix:"PUT /assets/" put);
  Alcotest.(check bool)
    "PUT exact frozen wire"
    true
    (String.ends_with ~suffix:"protected-wire" put)
;;

let native_cancel () =
  let case =
    match Tls_peer.case (wire_response "Content-Length: 1\r\n" "x") with
    | `Assoc fields -> `Assoc (("body_delay", `Float 0.2) :: fields)
    | _ -> assert false
  in
  let report =
    Tls_peer.with_peer [ case ] (fun ~environment ~sw ~support ~origin ->
      let http = native_client ~environment ~sw ~download_seconds:0.05 () in
      let destination = Filename.concat support "artifact" in
      expect
        (function
          | D.Network_failure _ -> true
          | _ -> false)
        (C.download
           http
           ~scope
           ~epoch:1L
           ~authenticated:false
           ~destination
           ~maximum_bytes:16
           (fun _ -> H.artifact ~base_url:origin ~uri:origin ~token:None));
      Alcotest.(check bool)
        "deadline leaves no artifact"
        false
        (Sys.file_exists destination))
  in
  check_retired report
;;

let native_response_deadline () =
  let case =
    match Tls_peer.case (wire_response "Content-Length: 1\r\n" "x") with
    | `Assoc fields -> `Assoc (("response_delay", `Float 0.2) :: fields)
    | _ -> assert false
  in
  let report =
    Tls_peer.with_peer [ case ] (fun ~environment ~sw ~support:_ ~origin ->
      let http = native_client ~environment ~sw ~http_response_seconds:0.05 () in
      expect
        (function
          | D.Network_failure _ -> true
          | _ -> false)
        (C.perform http ~scope ~epoch:1L ~authenticated:false (fun _ ->
           H.artifact ~base_url:origin ~uri:origin ~token:None)))
  in
  check_retired report
;;

let scaled_mono clock scale =
  let started = Eio.Time.Mono.now clock |> Mtime.to_uint64_ns in
  let module Clock = struct
    type t = unit
    type time = Mtime.t

    let now () =
      let elapsed = Int64.sub (Mtime.to_uint64_ns (Eio.Time.Mono.now clock)) started in
      Mtime.of_uint64_ns (Int64.of_float (Int64.to_float elapsed *. scale))
    ;;

    let sleep_until () deadline =
      let elapsed = Int64.to_float (Mtime.to_uint64_ns deadline) /. scale in
      Eio.Time.Mono.sleep_until
        clock
        (Mtime.of_uint64_ns (Int64.add started (Int64.of_float elapsed)))
    ;;
  end
  in
  Eio.Resource.T ((), Eio.Time.Pi.clock (module Clock))
;;

let native_phase_budget phase ~expires () =
  let delay = if phase = "body_delay" then 1.6 else 0.4 in
  let fields =
    match Tls_peer.case (wire_response "Content-Length: 1\r\n" "x") with
    | `Assoc fields -> fields
    | _ -> assert false
  in
  let cases =
    if expires && phase = "tls_delay"
    then (
      let case = `Assoc (("stall_tls", `Bool true) :: fields) in
      [ case; case ])
    else [ `Assoc ((phase, `Float delay) :: fields) ]
  in
  let report =
    Tls_peer.with_peer cases (fun ~environment ~sw ~support ~origin ->
      let deadlines : Execute.Core.network_deadlines =
        { setup_seconds = 60.
        ; tls_handshake_seconds = 60.
        ; http_response_seconds = 60.
        ; download_seconds = 600.
        }
      in
      let deadlines =
        if not expires
        then deadlines
        else (
          match phase with
          | "tls_delay" -> { deadlines with tls_handshake_seconds = 3. }
          | "response_delay" -> { deadlines with http_response_seconds = 3. }
          | _ -> { deadlines with download_seconds = 3. })
      in
      let http =
        C.create
          ~backend:
            (C.native_backend
               ~sw
               ~clock:(scaled_mono (Eio.Stdenv.mono_clock environment) 100.)
               ~network:(Eio.Stdenv.net environment)
               ~authenticator:(fun ?ip:_ ~host:_ _ -> Ok None)
               ~deadlines)
          ~token:(fun ~epoch:_ ~refresh:_ -> Ok "synthetic")
      in
      let request _ = H.artifact ~base_url:origin ~uri:origin ~token:None in
      let result =
        if phase = "body_delay"
        then
          C.download
            http
            ~scope
            ~epoch:1L
            ~authenticated:false
            ~destination:(Filename.concat support "artifact")
            ~maximum_bytes:16
            request
        else C.perform http ~scope ~epoch:1L ~authenticated:false request
      in
      if expires
      then
        expect
          (function
            | D.Network_failure _ -> true
            | _ -> false)
          result
      else ignore (get result))
  in
  check_retired report
;;

let native_download_budget_starts_at_body () =
  let case =
    match Tls_peer.case (wire_response "Content-Length: 1\r\n" "x") with
    | `Assoc fields -> `Assoc (("response_delay", `Float 0.2) :: fields)
    | _ -> assert false
  in
  let report =
    Tls_peer.with_peer [ case ] (fun ~environment ~sw ~support ~origin ->
      let http =
        native_client ~environment ~sw ~http_response_seconds:1. ~download_seconds:0.1 ()
      in
      let destination = Filename.concat support "artifact" in
      ignore
        (get
           (C.download
              http
              ~scope
              ~epoch:1L
              ~authenticated:false
              ~destination
              ~maximum_bytes:16
              (fun _ -> H.artifact ~base_url:origin ~uri:origin ~token:None)));
      Alcotest.(check bool)
        "body gets its own budget after headers"
        true
        (Sys.file_exists destination))
  in
  check_retired report
;;

let native_download_body_budget () =
  let case =
    match Tls_peer.case (wire_response "Content-Length: 1\r\n" "x") with
    | `Assoc fields -> `Assoc (("body_delay", `Float 0.2) :: fields)
    | _ -> assert false
  in
  let report =
    Tls_peer.with_peer [ case ] (fun ~environment ~sw ~support ~origin ->
      let destination = Filename.concat support "artifact" in
      let result =
        N.download_with_deadlines
          ~setup_seconds:1.
          ~tls_handshake_seconds:1.
          ~http_response_seconds:1.
          ~download_seconds:0.03
          ~sw
          ~clock:
            (Logseq_sync_native_transport.Transport_time.monotonic
               (Eio.Stdenv.mono_clock environment))
          ~network:(Eio.Stdenv.net environment)
          ~authenticator:(fun ?ip:_ ~host:_ _ -> Ok None)
          ~request:(H.artifact ~base_url:origin ~uri:origin ~token:None)
          ~destination
          ~maximum_bytes:16
          ~on_progress:(fun _ -> ())
      in
      Alcotest.(check bool)
        "native body timer expires without outer timeout"
        true
        (match result with
         | Error (N.Network _) -> true
         | _ -> false);
      Alcotest.(check bool)
        "body timeout prevents publication"
        false
        (Sys.file_exists destination))
  in
  check_retired report
;;

let native_setup_configured_budget () =
  let report =
    Tls_peer.with_peer
      [ Tls_peer.case (wire_response "Content-Length: 1\r\n" "x") ]
      (fun ~environment ~sw ~support:_ ~origin ->
         let underlying = Eio.Stdenv.net environment in
         let attempts = ref 0 in
         let module Network = struct
           type t = unit

           type tag =
             [ `Generic
             | `Unix
             ]

           let connect () ~sw address =
             incr attempts;
             Eio.Time.sleep (Eio.Stdenv.clock environment) 0.2;
             if !attempts = 1 then raise (Unix.Unix_error (Unix.ECONNREFUSED, "", ""));
             Eio.Net.connect ~sw underlying address
           ;;

           let listen () ~reuse_addr:_ ~reuse_port:_ ~backlog:_ ~sw:_ _ = assert false
           let datagram_socket () ~reuse_addr:_ ~reuse_port:_ ~sw:_ _ = assert false
           let getaddrinfo () ~service:_ _ = assert false
           let getnameinfo () _ = assert false
         end
         in
         let network = Eio.Resource.T ((), Eio.Net.Pi.network (module Network)) in
         let deadlines : Execute.Core.network_deadlines =
           { setup_seconds = 60.
           ; tls_handshake_seconds = 60.
           ; http_response_seconds = 60.
           ; download_seconds = 600.
           }
         in
         let http =
           C.create
             ~backend:
               (C.native_backend
                  ~sw
                  ~clock:(scaled_mono (Eio.Stdenv.mono_clock environment) 100.)
                  ~network
                  ~authenticator:(fun ?ip:_ ~host:_ _ -> Ok None)
                  ~deadlines)
             ~token:(fun ~epoch:_ ~refresh:_ -> Ok "synthetic")
         in
         ignore
           (get
              (C.perform http ~scope ~epoch:1L ~authenticated:false (fun _ ->
                 H.artifact ~base_url:origin ~uri:origin ~token:None))))
  in
  check_retired report
;;

let native_setup_budget () =
  Eio_main.run (fun environment ->
    Eio.Switch.run (fun sw ->
      let module Network = struct
        type t = unit
        type tag = [ `Generic ]

        let connect () ~sw:_ _ =
          Eio.Time.sleep (Eio.Stdenv.clock environment) 0.2;
          assert false
        ;;

        let listen () ~reuse_addr:_ ~reuse_port:_ ~backlog:_ ~sw:_ _ = assert false
        let datagram_socket () ~reuse_addr:_ ~reuse_port:_ ~sw:_ _ = assert false
        let getaddrinfo () ~service:_ _ = assert false
        let getnameinfo () _ = assert false
      end
      in
      let network = Eio.Resource.T ((), Eio.Net.Pi.network (module Network)) in
      let deadlines : Execute.Core.network_deadlines =
        { setup_seconds = 0.03
        ; tls_handshake_seconds = 1.
        ; http_response_seconds = 1.
        ; download_seconds = 3.
        }
      in
      let http =
        C.create
          ~backend:
            (C.native_backend
               ~sw
               ~clock:(Eio.Stdenv.mono_clock environment)
               ~network
               ~authenticator:(fun ?ip:_ ~host:_ _ -> Ok None)
               ~deadlines)
          ~token:(fun ~epoch:_ ~refresh:_ -> Ok "synthetic")
      in
      Eio.Time.with_timeout_exn (Eio.Stdenv.clock environment) 0.1 (fun () ->
        expect
          (function
            | D.Network_failure _ -> true
            | _ -> false)
          (C.perform http ~scope ~epoch:1L ~authenticated:false (fun _ ->
             H.artifact
               ~base_url:(Uri.of_string "https://localhost:1")
               ~uri:(Uri.of_string "https://localhost:1")
               ~token:None)))))
;;

let native_reject_auth () =
  let report =
    Tls_peer.with_peer
      [ Tls_peer.case "" ]
      (fun ~environment ~sw ~support:_ ~origin ->
         let deadlines : Execute.Core.network_deadlines =
           { setup_seconds = 1.
           ; tls_handshake_seconds = 1.
           ; http_response_seconds = 1.
           ; download_seconds = 3.
           }
         in
         let tokens = ref [] in
         let http =
           C.create
             ~backend:
               (C.native_backend
                  ~sw
                  ~clock:(Eio.Stdenv.mono_clock environment)
                  ~network:(Eio.Stdenv.net environment)
                  ~authenticator:(fun ?ip:_ ~host:_ _ ->
                    Error (`Msg "synthetic credential must not appear"))
                  ~deadlines)
             ~token:(fun ~epoch:_ ~refresh ->
               tokens := refresh :: !tokens;
               Ok "synthetic")
         in
         let result =
           C.perform http ~scope ~epoch:1L ~authenticated:true (fun _ ->
             H.artifact ~base_url:origin ~uri:origin ~token:None)
         in
         expect
           (function
             | D.Authentication_failure message -> message = "TLS authentication failed"
             | _ -> false)
           result;
         Alcotest.(check (list bool))
           "TLS authentication does not refresh"
           [ false ]
           !tokens)
  in
  check_retired report
;;

let native_error_cause kind () =
  let wire =
    match kind with
    | "content-type" ->
      wire_response "Content-Type: credential-secret\r\nContent-Length: 1\r\n" "x"
    | "crypto" -> wire_response "Content-Length: 2\r\n" "x"
    | _ -> wire_response "Content-Length: 1\r\n" "x"
  in
  let case =
    match Tls_peer.case wire with
    | `Assoc fields when kind = "crypto" -> `Assoc (("corrupt_tls", `Bool true) :: fields)
    | case -> case
  in
  let report =
    Tls_peer.with_peer [ case ] (fun ~environment ~sw ~support ~origin ->
      let http = native_client ~environment ~sw () in
      let result =
        C.download
          http
          ~scope
          ~epoch:1L
          ~authenticated:false
          ~destination:
            (Filename.concat
               support
               (if kind = "storage" then "missing/artifact" else "artifact"))
          ~maximum_bytes:16
          (fun _ -> H.artifact ~base_url:origin ~uri:origin ~token:None)
      in
      expect
        (function
          | D.Protocol_failure message when kind = "content-type" ->
            message = "Invalid HTTP response Content-Type"
          | D.Storage_failure _ when kind = "storage" -> true
          | D.Crypto_failure _ when kind = "crypto" -> true
          | _ -> false)
        result;
      Alcotest.(check bool)
        "no failed artifact publication"
        false
        (Sys.file_exists (Filename.concat support "artifact")))
  in
  check_retired report
;;

let () =
  let tests =
    [ ( "encrypted native snapshot activation respects crypto bounds"
      , fun () -> encrypted_snapshot_activation () )
    ; ( "AES protected append reordered echo and six exact-payload rejections"
      , fun () -> encrypted_snapshot_activation ~echo:false () )
    ; ( "AES protected append duplicate operations retain exact datoms"
      , fun () -> encrypted_snapshot_activation ~echo:true () )
    ; ("App owned native absent mirror bootstrap", fun () -> native_service_bootstrap ())
    ; ( "encrypted native bootstrap admits mismatched Hello and retains actual digest"
      , fun () -> native_service_bootstrap ~checksum_mode:`Invalid () )
    ; ( "encrypted native bootstrap warns and continues on a later mismatched head"
      , fun () -> native_service_bootstrap ~checksum_mode:`Invalid ~new_head:true () )
    ; ( "native bootstrap accepts missing Hello checksum"
      , fun () -> native_service_bootstrap ~checksum_mode:`Missing () )
    ; "encryption metadata rejects and cleans", encryption_failure
    ; "actual framed artifact and original ledger", success
    ; "metadata rejects before download", metadata_failure
    ; "framing rejects and cleans", framing_failure
    ; "row count rejects and cleans", row_failure
    ; "handoff failure cleans", handoff_failure
    ; "HTTP refresh once", auth
    ; "HTTP status classification", http_status_policy
    ; "native response phase deadline", native_response_deadline
    ; "native setup phase deadline", native_setup_budget
    ; "native setup configured budget", native_setup_configured_budget
    ; "native TLS authentication cause", native_reject_auth
    ; "native content type cause and redaction", native_error_cause "content-type"
    ; "native storage cause", native_error_cause "storage"
    ; "native crypto cause", native_error_cause "crypto"
    ; "native TLS configured budget", native_phase_budget "tls_delay" ~expires:false
    ; "native TLS phase expires", native_phase_budget "tls_delay" ~expires:true
    ; ( "native response configured budget"
      , native_phase_budget "response_delay" ~expires:false )
    ; "native response phase expires", native_phase_budget "response_delay" ~expires:true
    ; "native download configured budget", native_phase_budget "body_delay" ~expires:false
    ; "native download phase expires", native_phase_budget "body_delay" ~expires:true
    ; "native download budget starts at body", native_download_budget_starts_at_body
    ; "native body phase without outer timer", native_download_body_budget
    ; "native asset GET and PUT", native_assets
    ; "native deadline physically joins", native_cancel
    ]
  in
  let tests =
    tests
    @ List.init 4 (fun layers ->
      "native snapshot gzip layers " ^ string_of_int layers, native_snapshot layers)
  in
  let cases =
    [ "fixed", true, false, wire_response "Content-Length: 1\r\n" "x"
    ; ( "chunked"
      , true
      , false
      , wire_response "Transfer-Encoding: chunked\r\n" "1\r\nx\r\n0\r\n\r\n" )
    ; "close delimited", true, true, wire_response "" "x"
    ; "malformed status", false, true, "not HTTP\r\n\r\n"
    ; "HTTP 400", false, false, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
    ; ( "HTTP 422"
      , false
      , false
      , "HTTP/1.1 422 Unprocessable Content\r\nContent-Length: 0\r\n\r\n" )
    ; "truncated", false, true, wire_response "Content-Length: 2\r\n" "x"
    ; ( "body bound"
      , false
      , false
      , wire_response "Content-Length: 17\r\n" (String.make 17 'x') )
    ; ( "bad chunk"
      , false
      , true
      , wire_response "Transfer-Encoding: chunked\r\n" "Z\r\nx\r\n" )
    ]
  in
  let tests =
    tests
    @ List.concat_map
        (fun (name, success, eof, wire) ->
           List.map
             (fun download ->
                ( (if download then "download " else "GET ") ^ name
                , native_http ~download ~success ~eof wire ))
             [ false; true ])
        cases
  in
  Alcotest.run
    "snapshot producer"
    [ ( "acquisition"
      , List.map (fun (name, test) -> Alcotest.test_case name `Quick test) tests )
    ]
;;
