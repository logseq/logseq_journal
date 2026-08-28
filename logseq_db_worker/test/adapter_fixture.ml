open Logseq_db_types.Mutation
module T = Test_support

type resolved = { graph_dir : string }

type t =
  { support : string
  ; source_graph_dir : string
  ; token : Logseq_db_types.Graph_types.Uuid.t
  ; config : Logseq_db_worker.Config.t
  ; resolved : resolved
  }

let rec remove_tree path =
  match Unix.lstat path with
  | { st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_directory prefix f =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)
;;

let create_oracle_graph root graph_name =
  let open Yojson.Safe.Util in
  let graph_dir = Filename.concat root graph_name in
  Unix.mkdir graph_dir 0o700;
  let fixture = T.read_json (T.fixture "storage/logseq-65.33-create-page.json") in
  let database_path = Filename.concat graph_dir "db.sqlite" in
  let db = Sqlite3.db_open database_path in
  Sqlite3.Rc.check (Sqlite3.exec db (fixture |> member "tableSql" |> to_string));
  let statement =
    Sqlite3.prepare db "INSERT INTO kvs(addr, content, addresses) VALUES(?, ?, ?)"
  in
  fixture
  |> member "rows"
  |> to_list
  |> List.iter (fun row ->
    Sqlite3.Rc.check (Sqlite3.reset statement);
    Sqlite3.Rc.check
      (Sqlite3.bind_int64 statement 1 (row |> member "addr" |> to_int |> Int64.of_int));
    Sqlite3.Rc.check
      (Sqlite3.bind_text statement 2 (row |> member "content" |> to_string));
    Sqlite3.Rc.check
      (Sqlite3.bind
         statement
         3
         (match row |> member "addresses" with
          | `Null -> Sqlite3.Data.NULL
          | `String value -> TEXT value
          | _ -> T.fail "oracle fixture has malformed addresses"));
    Sqlite3.Rc.check (Sqlite3.step statement));
  ignore (Sqlite3.finalize statement);
  T.require (Sqlite3.db_close db) "unable to close oracle graph fixture";
  graph_dir
;;

let install_mutation_write_failure graph_dir =
  let db = Sqlite3.db_open (Filename.concat graph_dir "db.sqlite") in
  Sqlite3.Rc.check
    (Sqlite3.exec
       db
       "CREATE TRIGGER fail_mutation_write BEFORE UPDATE ON kvs BEGIN SELECT \
        RAISE(ABORT, 'injected mutation write failure'); END");
  T.require (Sqlite3.db_close db) "unable to install mutation write failure"
;;

let config support token =
  match
    Logseq_db_worker.Config.create
      ~application_support_directory:support
      ~target:(Snapshot { token })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
      ~default_page_size:Logseq_db_worker.Protocol.default_page_size
  with
  | Ok config -> config
  | Error message -> T.fail "invalid adapter fixture config: %s" message
;;

let resolved_snapshot support token =
  { graph_dir =
      Filename.concat
        (Filename.concat support "logseq-db-worker/snapshots")
        (Logseq_db_types.Graph_types.Uuid.to_string token)
  }
;;

let with_snapshot ?(fail_mutation_writes = false) f =
  with_temp_directory "logseq-db-worker-adapter-" (fun support ->
    let sources = Filename.concat support "sources" in
    Unix.mkdir sources 0o700;
    let source_graph_dir = create_oracle_graph sources "oracle-graph" in
    if fail_mutation_writes then install_mutation_write_failure source_graph_dir;
    let token =
      match
        Cli_command.create_snapshot
          ~application_support_directory:support
          ~source_graph_dir
      with
      | Ok token -> token
      | Error message -> T.fail "unable to create adapter snapshot: %s" message
    in
    let resolved = resolved_snapshot support token in
    f { support; source_graph_dir; token; config = config support token; resolved })
;;

let clone_with_mutation_write_failure fixture =
  install_mutation_write_failure fixture.resolved.graph_dir;
  let token =
    match
      Cli_command.create_snapshot
        ~application_support_directory:fixture.support
        ~source_graph_dir:fixture.resolved.graph_dir
    with
    | Ok token -> token
    | Error message -> T.fail "unable to clone mutation-failure snapshot: %s" message
  in
  let resolved = resolved_snapshot fixture.support token in
  { fixture with token; config = config fixture.support token; resolved }
;;

let uuid value =
  match Logseq_db_types.Graph_types.Uuid.of_string value with
  | Ok uuid -> uuid
  | Error message -> T.fail "%s" message
;;

let missing_config support = config support (uuid "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee")

let dependencies =
  Logseq_db_worker.Engine.
    { clocks =
        { epoch_ms = (fun () -> 1_704_067_200_000L)
        ; monotonic_ns = (fun () -> 1_000_000L)
        }
    ; cursor_authentication_key = Bytes.make 32 'a'
    }
;;

let graph_info_request ?(request_id = "10000000-0000-4000-8000-000000000001") () =
  Logseq_db_worker.Protocol.
    { api_version; request_id = uuid request_id; command = Read Graph_info }
;;

let create_page_request ~basis ~request_id ~mutation_id ~page_uuid ~title =
  Logseq_db_worker.Protocol.
    { api_version
    ; request_id = uuid request_id
    ; command =
        Mutate
          (Page
             (Create_page
                { title
                ; kind = Create_ordinary_page { uuid = uuid page_uuid }
                ; context = { mutation_id = uuid mutation_id; expected_basis = basis }
                }))
    }
;;
