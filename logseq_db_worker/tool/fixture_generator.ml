type mode =
  | Runtime_flow
  | Runtime_flow_with_pagination
  | Runtime_flow_with_persistence_failure

type generated =
  { support_root : string
  ; snapshot_token : Logseq_db_worker.Graph_types.Uuid.t
  ; graph_dir : string
  }

type managed_generated =
  { support_root : string
  ; graph_id : Logseq_db_worker.Graph_types.Uuid.t
  ; graph_dir : string
  ; user_id : string
  ; base_url : string
  ; expected_timeline_text : string
  }

module Snapshot = Logseq_db_worker__Snapshot
module Adapter_fixture = Logseq_db_worker_test_support.Adapter_fixture

let uuid value =
  match Logseq_db_worker.Graph_types.Uuid.of_string value with
  | Ok uuid -> uuid
  | Error message -> failwith message
;;

let seed_pagination_graph ~support_root ~graph_dir =
  let open Logseq_db_worker in
  let open Protocol in
  let config =
    Config.create
      ~application_support_directory:support_root
      ~target:(Native_local_graph { graph_name = Filename.basename graph_dir; graph_dir })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Protocol.maximum_response_bytes
      ~default_page_size:Protocol.default_page_size
    |> Result.get_ok
  in
  let engine =
    Engine.open_ ~dependencies:Adapter_fixture.dependencies config |> Result.get_ok
  in
  let sequence = ref 1 in
  let execute mutation =
    let number = !sequence in
    incr sequence;
    let request_id = uuid (Printf.sprintf "92000000-0000-4000-8000-%012x" number) in
    let response =
      Engine.execute engine { api_version; request_id; command = Mutate mutation }
    in
    match response with
    | Succeeded { success = Mutation_result { status = Applied; _ }; _ } -> ()
    | Succeeded
        { success = Mutation_result { status = No_change | Already_applied; _ }; _ }
    | Succeeded _ -> failwith "pagination fixture mutation was not applied"
    | Failed failure -> failwith (Error.message failure.error)
  in
  let context () =
    let number = !sequence in
    let expected_basis = Option.get (Engine.basis engine) in
    { mutation_id = uuid (Printf.sprintf "93000000-0000-4000-8000-%012x" number)
    ; expected_basis
    }
  in
  let seed_day index day title row_count row_prefix =
    let page =
      uuid
        (Printf.sprintf
           "00000001-%04d-%04d-0000-000000000000"
           (day / 10_000)
           (day mod 10_000))
    in
    execute
      (Page
         (Create_page
            { title
            ; kind = Create_journal_page { journal_day = day; supplied_uuid = Some page }
            ; context = context ()
            }));
    let roots =
      List.init row_count (fun offset ->
        let row = offset + 1 in
        { uuid =
            uuid (Printf.sprintf "94000000-0000-4000-8000-%012x" ((index * 1_000) + row))
        ; title = Printf.sprintf "%s row %02d" row_prefix row
        ; children = []
        })
      @
      if index = 1
      then
        [ { uuid = uuid "95000000-0000-4000-8000-000000000001"
          ; title = "Pagination expandable parent"
          ; children =
              [ { uuid = uuid "95000000-0000-4000-8000-000000000002"
                ; title = "Pagination persisted child"
                ; children = []
                }
              ]
          }
        ]
      else []
    in
    execute
      (Structural
         (Insert_blocks
            { roots; position = Relative (Last_child page); context = context () }))
  in
  Fun.protect
    ~finally:(fun () -> ignore (Engine.close engine))
    (fun () ->
       seed_day 1 20260807 "Aug 7th, 2026" 1 "Pagination today";
       seed_day 2 20260806 "Aug 6th, 2026" 1 "Pagination day six";
       seed_day 3 20260805 "Aug 5th, 2026" 70 "Pagination day five";
       seed_day 4 20260804 "Aug 4th, 2026" 70 "Pagination day four")
;;

let create ~support_root ~mode =
  try
    if Filename.is_relative support_root
    then Error "support root must be absolute"
    else if not (Sys.file_exists support_root && Sys.is_directory support_root)
    then Error "support root must be an existing directory"
    else (
      let support_root = Unix.realpath support_root in
      let sources = Filename.concat support_root "sources" in
      let source_graph_dir = Filename.concat sources "runtime-flow-source" in
      if Sys.file_exists source_graph_dir
      then Error "runtime flow source already exists"
      else (
        if Sys.file_exists sources
        then (
          if not (Sys.is_directory sources)
          then failwith "fixture sources path is not a directory")
        else Unix.mkdir sources 0o700;
        let source_graph_dir =
          Adapter_fixture.create_oracle_graph sources "runtime-flow-source"
        in
        (match mode with
         | Runtime_flow -> ()
         | Runtime_flow_with_pagination ->
           seed_pagination_graph ~support_root ~graph_dir:source_graph_dir
         | Runtime_flow_with_persistence_failure ->
           Adapter_fixture.install_mutation_write_failure source_graph_dir);
        let catalog =
          match Snapshot.create_catalog ~application_support_directory:support_root with
          | Ok catalog -> catalog
          | Error _ -> failwith "unable to create snapshot catalog"
        in
        let snapshot_token =
          match Snapshot.create catalog ~source_graph_dir with
          | Ok token -> token
          | Error _ -> failwith "unable to publish runtime fixture snapshot"
        in
        let graph_dir =
          match Snapshot.resolve catalog snapshot_token with
          | Ok resolved -> resolved.graph_dir
          | Error _ -> failwith "unable to resolve published runtime fixture"
        in
        Ok { support_root; snapshot_token; graph_dir }))
  with
  | Unix.Unix_error (error, operation, path) ->
    Error
      (Printf.sprintf
         "fixture filesystem operation failed: %s(%s): %s"
         operation
         path
         (Unix.error_message error))
  | Failure message -> Error message
;;

let create_encrypted_warm_start ~support_root =
  try
    if Filename.is_relative support_root
    then Error "support root must be absolute"
    else if not (Sys.file_exists support_root && Sys.is_directory support_root)
    then Error "support root must be an existing directory"
    else (
      let support_root = Unix.realpath support_root in
      let graph_id_text = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" in
      let graph_id = uuid graph_id_text in
      let graph_dir =
        Logseq_db_worker.Sync_mirror.graph_directory
          ~application_support_directory:support_root
          ~graph_id
      in
      if Sys.file_exists graph_dir
      then Error "encrypted warm-start mirror already exists"
      else (
        let root = Filename.dirname graph_dir in
        Adapter_fixture.make_directory root;
        let created = Adapter_fixture.create_oracle_graph root graph_id_text in
        if not (String.equal created graph_dir)
        then failwith "encrypted warm-start mirror path changed";
        seed_pagination_graph ~support_root ~graph_dir;
        Adapter_fixture.add_remote_identity graph_dir graph_id_text;
        let database_path = Filename.concat graph_dir "db.sqlite" in
        let module Storage = Logseq_db_worker__Logseq_sqlite_storage in
        let connection =
          match Storage.open_database database_path with
          | Ok value -> value
          | Error _ -> failwith "unable to reopen encrypted warm-start fixture"
        in
        let db =
          match Storage.restore_database connection with
          | Ok value -> value
          | Error _ -> failwith "unable to restore encrypted warm-start fixture"
        in
        let checksum = Logseq_db_worker.Sync_checksum.recompute ~e2ee:false db in
        (match Storage.close (Storage.connection_callbacks connection) with
         | Ok () -> ()
         | Error _ -> failwith "unable to close encrypted warm-start fixture");
        let metadata =
          match
            Logseq_db_worker__Sync_meta.create
              ~graph_id
              ~schema:Logseq_db_worker.Graph_types.{ major = 65; minor = 33 }
              ~applied_server_t:40
              ~checksum
          with
          | Ok value -> value
          | Error message -> failwith message
        in
        let sqlite = Sqlite3.db_open database_path in
        (match Logseq_db_worker__Sync_meta.initialize_database sqlite metadata with
         | Ok () -> ()
         | Error message ->
           failwith ("unable to initialize encrypted warm-start fixture: " ^ message));
        if not (Sqlite3.db_close sqlite)
        then failwith "unable to close encrypted warm-start metadata";
        let base_url = "https://api.logseq.io" in
        let user_id = "macos-integration-" ^ Digest.to_hex (Digest.string support_root) in
        let graph =
          Logseq_db_worker.Sync_catalog.
            { graph_id
            ; name = "Encrypted Offline Notes"
            ; schema = { major = 65; minor = 33; exact = true }
            ; encrypted = true
            }
        in
        let cache =
          Logseq_db_worker.Sync_catalog.create_cache
            ~user_id
            ~base_url
            ~graphs:[ graph ]
            ~selected_graph:(Some graph_id)
          |> fun cache ->
          Logseq_db_worker.Sync_catalog.set_mirror_status
            cache
            graph_id
            Logseq_db_worker.Sync_catalog.Ready
        in
        (match
           Logseq_db_worker.Sync_catalog_store.save
             ~application_support_directory:support_root
             cache
         with
         | Ok () -> ()
         | Error message -> failwith ("unable to save encrypted fixture catalog: " ^ message));
        Ok
          { support_root
          ; graph_id
          ; graph_dir
          ; user_id
          ; base_url
          ; expected_timeline_text = "Pagination today row 01"
          }))
  with
  | Unix.Unix_error (error, operation, path) ->
    Error
      (Printf.sprintf
         "fixture filesystem operation failed: %s(%s): %s"
         operation
         path
         (Unix.error_message error))
  | Failure message -> Error message
;;

let to_yojson (generated : generated) =
  `Assoc
    [ "formatVersion", `Int 1
    ; "supportRoot", `String generated.support_root
    ; ( "snapshotToken"
      , `String (Logseq_db_worker.Graph_types.Uuid.to_string generated.snapshot_token) )
    ; "graphDir", `String generated.graph_dir
    ]
;;

let managed_to_yojson (generated : managed_generated) =
  `Assoc
    [ "formatVersion", `Int 1
    ; "supportRoot", `String generated.support_root
    ; "baseUrl", `String generated.base_url
    ; "userId", `String generated.user_id
    ; ( "graphId"
      , `String (Logseq_db_worker.Graph_types.Uuid.to_string generated.graph_id) )
    ; "graphDir", `String generated.graph_dir
    ; "expectedTimelineText", `String generated.expected_timeline_text
    ]
;;
