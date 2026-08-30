module F = Logseq_db_worker_test_support.Adapter_fixture
module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Core = Logseq_sync_pure_reducer.Core
module Protocol = Logseq_db_worker.Protocol
module Support = Managed_sync_e2e_support
module ID = Bonsai_flutter_spec.Id

exception E2e_failure of string

let fail format = Printf.ksprintf (fun message -> raise (E2e_failure message)) format
let base_url = "https://api.logseq.io"

let next_epoch =
  let value = ref 80_000L in
  fun () ->
    let epoch = ID.Runtime.Epoch.of_int64 !value in
    value := Int64.succ !value;
    epoch
;;

let random_bytes length =
  let channel = open_in_bin "/dev/urandom" in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel length |> Bytes.of_string)
;;

let fresh_uuid () =
  let bytes = random_bytes 16 in
  Bytes.set_uint8 bytes 6 (Bytes.get_uint8 bytes 6 land 0x0f lor 0x40);
  Bytes.set_uint8 bytes 8 (Bytes.get_uint8 bytes 8 land 0x3f lor 0x80);
  let hex index = Printf.sprintf "%02x" (Bytes.get_uint8 bytes index) in
  let text =
    String.concat
      "-"
      [ String.concat "" (List.init 4 hex)
      ; String.concat "" (List.init 2 (fun index -> hex (index + 4)))
      ; String.concat "" (List.init 2 (fun index -> hex (index + 6)))
      ; String.concat "" (List.init 2 (fun index -> hex (index + 8)))
      ; String.concat "" (List.init 6 (fun index -> hex (index + 10)))
      ]
  in
  match Logseq_db_types.Graph_types.Uuid.of_string text with
  | Ok uuid -> uuid
  | Error _ -> fail "random UUID generation failed"
;;

let accepted = function
  | Worker.Accepted request_id -> request_id
  | Full -> fail "worker request hit backpressure"
  | Not_ready -> fail "worker request was not ready"
  | Stopping -> fail "worker request was stopping"
;;

let sync_phase_name = function
  | Core.Offline -> "offline"
  | Connecting -> "connecting"
  | Pulling -> "pulling"
  | Submitting -> "submitting"
  | Current -> "current"
  | Paused -> "paused"
  | Failed -> "failed"
;;

let graph_phase_name = function
  | Logseq_db_worker.Graph_closed -> "closed"
  | Graph_opening -> "opening"
  | Graph_open -> "open"
  | Graph_closing -> "closing"
  | Graph_failed -> "failed"
;;

let startup_failure_stage_name = function
  | None -> "none"
  | Some Core.During_authentication -> "authentication"
  | Some During_catalog -> "catalog"
  | Some During_local_restore -> "local-restore"
  | Some During_bootstrap -> "bootstrap"
  | Some During_e2ee -> "e2ee"
;;

let contains source substring =
  let source_length = String.length source in
  let substring_length = String.length substring in
  let rec loop offset =
    offset + substring_length <= source_length
    && (String.equal (String.sub source offset substring_length) substring
        || loop (offset + 1))
  in
  substring_length = 0 || loop 0
;;

let sync_error_kind = function
  | None -> "none"
  | Some message when String.starts_with ~prefix:"sync HTTP request failed" message ->
    "http-status"
  | Some message when String.starts_with ~prefix:"sync HTTP protocol failed" message ->
    "http-protocol"
  | Some message when String.starts_with ~prefix:"sync HTTP response" message ->
    "http-response"
  | Some message
    when String.starts_with ~prefix:"authenticated sync HTTP redirect" message ->
    "http-redirect"
  | Some message when String.starts_with ~prefix:"graph catalog" message ->
    "catalog-decode"
  | Some message when String.starts_with ~prefix:"graph " message -> "catalog-entry"
  | Some message ->
    let message = String.lowercase_ascii message in
    if contains message "cryptooperationfailed" || contains message "crypto operation"
    then "crypto-operation"
    else if contains message "platform crypto"
    then "platform-crypto"
    else if contains message "certificate"
    then "tls-certificate"
    else if contains message "trust" || contains message "handshake"
    then "tls-handshake"
    else if contains message "tls"
    then "tls"
    else if contains message "timed out" || contains message "timeout"
    then "timeout"
    else if contains message "connection"
    then "connection"
    else if contains message "end_of_file" || contains message "eof"
    then "eof"
    else if contains message "closed"
    then "closed"
    else if contains message "broken pipe" || contains message "epipe"
    then "broken-pipe"
    else if contains message "reset"
    then "reset"
    else if contains message "unix_error"
    then "unix"
    else if contains message "address" || contains message "resolve"
    then "dns"
    else "other"
;;

type client_context =
  { label : string
  ; client : (Service.request, Service.response, Service.push) Worker.client
  ; credentials : Support.credentials
  ; cognito : Support.cognito_session
  ; token_requests : (string, unit) Hashtbl.t
  ; mutable selected_graph : Core.graph option
  ; mutable password_submitted : bool
  ; mutable last_state : Core.state option
  ; mutable graph_phase : Logseq_db_worker.graph_phase
  ; mutable last_event : string
  ; mutable saw_catalog : bool
  ; mutable saw_bootstrap : bool
  ; mutable saw_opening_pull : bool
  }

let send context request = Worker.send context.client request |> accepted

let send_command context command =
  ignore (send context (Service.Client_command command) : ID.Worker.Request_id.t)
;;

let fail_worker context phase reason =
  let sync, cursor, startup_failure, error_kind =
    match context.last_state with
    | None -> "unknown", "none", "none", "none"
    | Some state ->
      ( sync_phase_name state.snapshot.sync_phase
      , Option.fold ~none:"none" ~some:string_of_int state.snapshot.applied_server_t
      , startup_failure_stage_name state.snapshot.startup.failure
      , sync_error_kind state.snapshot.last_error )
  in
  fail
    "client=%s phase=%s reason=%s sync=%s startup-failure=%s error-kind=%s graph=%s \
     cursor=%s outbox=unobserved last=%s"
    context.label
    phase
    reason
    sync
    startup_failure
    error_kind
    (graph_phase_name context.graph_phase)
    cursor
    context.last_event
;;

let handle_public_state context state =
  context.last_state <- Some state;
  context.last_event <- "client-state";
  let snapshot = state.Core.snapshot in
  if snapshot.sync_phase = Failed then fail_worker context "sync" "failed";
  if snapshot.sync_phase = Pulling then context.saw_opening_pull <- true;
  if snapshot.startup.bootstrapping then context.saw_bootstrap <- true;
  (match Support.catalog_graph ~name:context.credentials.graph_name snapshot.catalog with
   | Ok None -> ()
   | Error _ ->
     fail_worker
       context
       "catalog"
       (Printf.sprintf "target-unavailable-count-%d" (List.length snapshot.catalog))
   | Ok (Some graph) ->
     context.saw_catalog <- true;
     (match context.selected_graph with
      | Some selected
        when not (Logseq_db_types.Graph_types.Uuid.equal selected.graph_id graph.graph_id)
        -> fail_worker context "catalog" "graph-changed"
      | Some _ -> ()
      | None when snapshot.startup.awaiting_selection ->
        context.selected_graph <- Some graph;
        send_command context (Select_graph graph.graph_id)
      | None -> ()));
  if snapshot.startup.awaiting_e2ee_password && not context.password_submitted
  then (
    context.password_submitted <- true;
    send_command context (Submit_e2ee_password context.credentials.e2ee_password))
;;

let handle_graph_state context state =
  context.graph_phase <- state.Logseq_db_worker.phase;
  context.last_event <- "graph-state"
;;

let handle_push context = function
  | Service.Need_id_token request ->
    context.last_event <- "need-id-token";
    let request_id = Core.token_request_id request in
    if Hashtbl.mem context.token_requests request_id
    then fail_worker context "authentication" "repeated-challenge";
    Hashtbl.add context.token_requests request_id ();
    send_command context (Provide_token { request; token = context.cognito.id_token })
  | Client_state_changed state -> handle_public_state context state
  | Bootstrap_progress _ ->
    context.saw_bootstrap <- true;
    context.last_event <- "bootstrap-progress"
  | Graph_state_changed state -> handle_graph_state context state
  | Graph_push _ -> context.last_event <- "graph-push"
;;

let handle_event context = function
  | Worker.Push { payload; _ } ->
    handle_push context payload;
    None
  | Response { outcome = Completed (Service.Client_state state); _ } ->
    handle_public_state context state;
    None
  | Response { outcome = Completed (Service.Graph_state state); _ } ->
    handle_graph_state context state;
    None
  | Response { request_id; outcome = Completed (Service.Graph_response response); _ } ->
    context.last_event <- "graph-response";
    Some (request_id, response)
  | Response { outcome = Failed _; _ } -> fail_worker context "worker-request" "failed"
  | Response { outcome = Cancelled; _ } ->
    fail_worker context "worker-request" "cancelled"
  | Response { outcome = Shutdown; _ } -> fail_worker context "worker-request" "shutdown"
  | Terminal _ -> fail_worker context "worker" "terminal"
;;

let drain context =
  Worker.For_testing.drain_events context.client ~max_events:256
  |> List.filter_map (handle_event context)
;;

let timeout_at seconds = Unix.gettimeofday () +. seconds

let await_graph_response context ~phase request_id =
  let deadline = timeout_at 45. in
  let rec loop () =
    if Unix.gettimeofday () >= deadline then fail_worker context phase "timeout";
    match
      drain context
      |> List.find_opt (fun (actual_request_id, _) -> actual_request_id = request_id)
    with
    | Some (_, response) -> response
    | None ->
      Unix.sleepf 0.01;
      loop ()
  in
  loop ()
;;

let opening_complete context =
  match context.last_state with
  | Some state ->
    state.snapshot.sync_phase = Current
    && Option.is_some state.snapshot.applied_server_t
    && context.saw_catalog
    && context.saw_bootstrap
    && context.saw_opening_pull
    && context.graph_phase = Graph_open
  | None -> false
;;

let await_opening_current context =
  let deadline = timeout_at 300. in
  let rec loop () =
    if Unix.gettimeofday () >= deadline
    then fail_worker context "cold-bootstrap" "timeout";
    ignore (drain context : (ID.Worker.Request_id.t * Protocol.response) list);
    if opening_complete context
    then (
      match context.last_state, context.selected_graph with
      | Some state, Some graph -> Option.get state.snapshot.applied_server_t, graph
      | _ -> fail_worker context "cold-bootstrap" "incomplete")
    else (
      Unix.sleepf 0.01;
      loop ())
  in
  loop ()
;;

let await_authoritative_current context ~after_server_t phase =
  let deadline = timeout_at 180. in
  let rec loop () =
    if Unix.gettimeofday () >= deadline then fail_worker context phase "timeout";
    ignore (drain context : (ID.Worker.Request_id.t * Protocol.response) list);
    match context.last_state with
    | Some state ->
      (match state.snapshot.sync_phase, state.snapshot.applied_server_t with
       | Current, Some cursor when cursor > after_server_t -> cursor
       | _ ->
         Unix.sleepf 0.01;
         loop ())
    | None ->
      Unix.sleepf 0.01;
      loop ()
  in
  loop ()
;;

let graph_request context command =
  let request = Protocol.{ api_version; request_id = fresh_uuid (); command } in
  let worker_request_id = send context (Service.Graph_request request) in
  await_graph_response context ~phase:"graph-request" worker_request_id
;;

let graph_basis context =
  match graph_request context (Read Graph_info) with
  | Succeeded { success = Graph_info_result _; basis; _ } -> basis
  | Succeeded _ -> fail_worker context "graph-read" "unexpected-response"
  | Failed _ -> fail_worker context "graph-read" "failed"
;;

let journal_parent context =
  match
    graph_request
      context
      (Read (List_pages { kind = Only_journals; limit = 50; cursor = None }))
  with
  | Succeeded { success = Pages_result { items; _ }; _ } ->
    (match
       List.find_opt
         (fun (page : Logseq_db_types.Graph_types.page_summary) -> not page.recycled)
         items
     with
     | Some page -> page.uuid
     | None -> fail_worker context "journal-read" "no-active-journal")
  | Succeeded _ -> fail_worker context "journal-read" "unexpected-response"
  | Failed _ -> fail_worker context "journal-read" "failed"
;;

let read_block context block_uuid =
  match graph_request context (Read (Get_block { block = block_uuid })) with
  | Succeeded { success = Block_result block; basis; _ } -> Ok (block, basis)
  | Succeeded _ -> fail_worker context "block-read" "unexpected-response"
  | Failed _ -> Error ()
;;

let require_block context ~block_uuid ~parent_uuid ~title =
  match read_block context block_uuid with
  | Error () -> fail_worker context "block-recovery" "missing"
  | Ok (block, basis) ->
    if not (Logseq_db_types.Graph_types.Uuid.equal block.uuid block_uuid)
    then fail_worker context "block-recovery" "uuid-mismatch";
    if not (String.equal block.title title)
    then fail_worker context "block-recovery" "title-mismatch";
    if not (Logseq_db_types.Graph_types.Uuid.equal block.parent parent_uuid)
    then fail_worker context "block-recovery" "parent-mismatch";
    block, basis
;;

let run_mutation
      ?(on_applied = fun () -> ())
      context
      ~after_server_t
      ~expected_basis
      phase
      mutation
  =
  let request =
    Protocol.
      { api_version
      ; request_id = fresh_uuid ()
      ; command = Mutate (mutation expected_basis (fresh_uuid ()))
      }
  in
  let worker_request_id = send context (Service.Graph_request request) in
  (match await_graph_response context ~phase worker_request_id with
   | Succeeded { success = Mutation_result { status = Applied; _ }; _ } -> on_applied ()
   | Succeeded _ -> fail_worker context phase "mutation-not-applied"
   | Failed failure ->
     fail_worker
       context
       phase
       (Printf.sprintf
          "mutation-failed:%s:%s"
          (Logseq_db_worker.Error.code_string (Logseq_db_worker.Error.code failure.error))
          (Logseq_db_worker.Error.message failure.error)));
  await_authoritative_current context ~after_server_t phase
;;

let insert_block context ~block_uuid ~parent_uuid ~title ~after_server_t ~on_applied =
  let expected_basis = graph_basis context in
  run_mutation
    ~on_applied
    context
    ~after_server_t
    ~expected_basis
    "insert-block"
    (fun basis mutation_id ->
       Logseq_db_types.Mutation.Structural
         (Insert_blocks
            { roots = [ { uuid = block_uuid; title; children = [] } ]
            ; position = Relative (Last_child parent_uuid)
            ; context = { mutation_id; expected_basis = basis }
            }))
;;

let delete_block context ~block_uuid ~after_server_t =
  let expected_basis = graph_basis context in
  run_mutation
    context
    ~after_server_t
    ~expected_basis
    "delete-block"
    (fun basis mutation_id ->
       Logseq_db_types.Mutation.Structural
         (Delete_blocks
            { roots = [ block_uuid ]; context = { mutation_id; expected_basis = basis } }))
;;

let config support =
  match
    Logseq_db_worker.Config.create
      ~application_support_directory:support
      ~target:(Managed_sync { base_url })
      ~compatibility_profile:Logseq_65_33_or_newer
      ~response_budget_bytes:Protocol.maximum_response_bytes
      ~default_page_size:Protocol.default_page_size
  with
  | Ok config -> config
  | Error _ -> fail "worker configuration failed"
;;

let runtime_started = ref false

let await_runtime_idle label =
  let deadline = timeout_at 30. in
  let rec loop () =
    match (Worker_runtime.For_testing.diagnostics ()).state with
    | Worker_runtime.Idle -> ()
    | Terminal | Stopped -> fail "client=%s phase=shutdown reason=terminal" label
    | Not_started | Attached | Stopping ->
      if Unix.gettimeofday () >= deadline
      then fail "client=%s phase=shutdown reason=timeout" label;
      Unix.sleepf 0.01;
      loop ()
  in
  loop ()
;;

let with_client ~label ~support ~credentials ~cognito f =
  let client =
    match
      Worker_runtime.start ~runtime_epoch:(next_epoch ()) Service.service (config support)
    with
    | Ok client ->
      runtime_started := true;
      client
    | Error _ -> fail "client=%s phase=start reason=failed" label
  in
  let context =
    { label
    ; client
    ; credentials
    ; cognito
    ; token_requests = Hashtbl.create 8
    ; selected_graph = None
    ; password_submitted = false
    ; last_state = None
    ; graph_phase = Graph_closed
    ; last_event = "started"
    ; saw_catalog = false
    ; saw_bootstrap = false
    ; saw_opening_pull = false
    }
  in
  Fun.protect
    ~finally:(fun () ->
      if not (Worker.For_testing.is_stopping client) then Worker_runtime.stop client;
      await_runtime_idle label)
    (fun () ->
       send_command context (Restore_local_account { user_id = cognito.user_id });
       send_command
         context
         (Reconcile_authenticated_user { user_id = Some cognito.user_id });
       f context)
;;

type durable_facts =
  { cursor : int
  ; checksum : string
  ; outbox_empty : bool
  }

let durable_facts support graph_id =
  let resolved =
    match
      Logseq_db_worker.Synced_mirror.resolve
        ~application_support_directory:support
        ~graph_id
    with
    | Ok resolved -> resolved
    | Error _ -> fail "durable mirror is unavailable"
  in
  let sqlite = Sqlite3.db_open resolved.database_path in
  let outbox =
    Fun.protect
      ~finally:(fun () ->
        if not (Sqlite3.db_close sqlite) then fail "durable mirror close failed")
      (fun () ->
         match Logseq_db_storage.Sync_outbox_store.read_database sqlite with
         | Ok records -> records
         | Error _ -> fail "durable outbox inspection failed")
  in
  { cursor = resolved.metadata.applied_server_t
  ; checksum = resolved.metadata.checksum
  ; outbox_empty = outbox = []
  }
;;

let require_durable_advance facts initial_cursor label =
  if facts.cursor <= initial_cursor then fail "%s durable cursor did not advance" label;
  if String.equal facts.checksum "0000000000000000"
  then fail "%s durable checksum did not advance" label;
  if not facts.outbox_empty then fail "%s durable outbox is not empty" label
;;

let cleanup_block context ~block_uuid ~parent_uuid ~title ~opening_cursor =
  match read_block context block_uuid with
  | Error () -> opening_cursor
  | Ok (block, _) ->
    if not (String.equal block.title title)
    then fail_worker context "cleanup" "title-mismatch";
    if not (Logseq_db_types.Graph_types.Uuid.equal block.parent parent_uuid)
    then fail_worker context "cleanup" "parent-mismatch";
    delete_block context ~block_uuid ~after_server_t:opening_cursor
;;

let best_effort_cleanup
      ~support
      ~credentials
      ~cognito
      ~graph_id
      ~block_uuid
      ~parent_uuid
      ~title
  =
  try
    with_client ~label:"cleanup" ~support ~credentials ~cognito (fun context ->
      let opening_cursor, graph = await_opening_current context in
      if Logseq_db_types.Graph_types.Uuid.equal graph.graph_id graph_id
      then
        ignore
          (cleanup_block context ~block_uuid ~parent_uuid ~title ~opening_cursor : int))
  with
  | _ -> ()
;;

let require_macos () =
  if not (Sys.file_exists "/System/Library/CoreServices")
  then fail "the deployed managed-sync E2E is macOS-only"
;;

let platform_crypto_provider_marker = "LOGSEQ_DB_WORKER_E2E_PLATFORM_CRYPTO_PROVIDER"
let test_file_keychain_environment = "LOGSEQ_JOURNAL_E2EE_TEST_FILE_KEYCHAIN"

let environment_with environment name value =
  let prefix = name ^ "=" in
  environment
  |> Array.to_list
  |> List.filter (fun entry -> not (String.starts_with ~prefix entry))
  |> fun entries -> Array.of_list ((prefix ^ value) :: entries)
;;

let process_exit_code = function
  | Unix.WEXITED code -> code
  | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 2
;;

let compile_platform_crypto_provider ~root ~output =
  let compiler = "/usr/bin/xcrun" in
  let source = Filename.concat root "flutter/JournalE2EECrypto.swift" in
  if not (Sys.file_exists source)
  then fail "the production platform crypto provider source is unavailable";
  let arguments =
    [| compiler
     ; "swiftc"
     ; "-D"
     ; "DEBUG"
     ; "-parse-as-library"
     ; "-emit-library"
     ; source
     ; "-o"
     ; output
    |]
  in
  let process =
    Unix.create_process compiler arguments Unix.stdin Unix.stdout Unix.stderr
  in
  let _, status = Unix.waitpid [] process in
  if process_exit_code status <> 0
  then fail "the production platform crypto provider failed to compile"
;;

let run_with_platform_crypto_provider () =
  let root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when Sys.file_exists (Filename.concat root "dune-project") -> root
    | Some _ -> fail "the Dune source root is invalid"
    | None ->
      (match Support.repository_root (Sys.getcwd ()) with
       | Ok root -> root
       | Error _ -> fail "the repository root is unavailable")
  in
  let directory = Filename.temp_file "logseq-e2e-platform-crypto-" "" in
  Sys.remove directory;
  Unix.mkdir directory 0o700;
  let provider = Filename.concat directory "libLogseqE2EEProvider.dylib" in
  let keychain = Filename.concat directory "secrets.keychain-db" in
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists directory
      then (
        Sys.readdir directory
        |> Array.iter (fun entry -> Sys.remove (Filename.concat directory entry));
        Unix.rmdir directory))
    (fun () ->
       compile_platform_crypto_provider ~root ~output:provider;
       let environment =
         environment_with (Unix.environment ()) "DYLD_INSERT_LIBRARIES" provider
         |> fun environment ->
         environment_with environment platform_crypto_provider_marker "1"
         |> fun environment ->
         environment_with environment test_file_keychain_environment keychain
       in
       let executable = Unix.realpath Sys.executable_name in
       let arguments = Array.copy Sys.argv in
       arguments.(0) <- executable;
       let process =
         Unix.create_process_env
           executable
           arguments
           environment
           Unix.stdin
           Unix.stdout
           Unix.stderr
       in
       let _, status = Unix.waitpid [] process in
       process_exit_code status)
;;

let with_execution_lock f =
  let path =
    Filename.concat (Filename.get_temp_dir_name ()) "logseq-db-worker-e2e.lock"
  in
  let descriptor = Unix.openfile path [ O_CREAT; O_RDWR ] 0o600 in
  Fun.protect
    ~finally:(fun () -> Unix.close descriptor)
    (fun () ->
       (try Unix.lockf descriptor F_TLOCK 0 with
        | Unix.Unix_error ((EACCES | EAGAIN), _, _) ->
          fail "another deployed managed-sync E2E is running");
       Fun.protect ~finally:(fun () -> Unix.lockf descriptor F_ULOCK 0) f)
;;

let run () =
  require_macos ();
  let credentials =
    match Support.credentials_from_environment Sys.getenv_opt with
    | Ok credentials -> credentials
    | Error message -> fail "%s" message
  in
  let cognito =
    match Support.authenticate credentials with
    | Ok session -> session
    | Error message -> fail "%s" message
  in
  let block_uuid = fresh_uuid () in
  let marker_title =
    "logseq-worker-e2e-" ^ Logseq_db_types.Graph_types.Uuid.to_string block_uuid
  in
  let created = ref false in
  let cleaned = ref false in
  let created_graph : Core.graph option ref = ref None in
  let created_parent : Logseq_db_types.Graph_types.page_uuid option ref = ref None in
  F.with_temp_directory "logseq-deployed-e2e-sender-" (fun sender_support ->
    F.with_temp_directory "logseq-deployed-e2e-receiver-" (fun receiver_support ->
      Fun.protect
        ~finally:(fun () ->
          match !created, !cleaned, !created_graph, !created_parent with
          | true, false, Some graph, Some parent_uuid ->
            best_effort_cleanup
              ~support:receiver_support
              ~credentials
              ~cognito
              ~graph_id:graph.graph_id
              ~block_uuid
              ~parent_uuid
              ~title:marker_title
          | _ -> ())
        (fun () ->
           let sender_opening_cursor, sender_submitted_cursor, sender_graph, parent_uuid =
             with_client
               ~label:"sender"
               ~support:sender_support
               ~credentials
               ~cognito
               (fun sender ->
                  let opening_cursor, graph = await_opening_current sender in
                  created_graph := Some graph;
                  let parent_uuid = journal_parent sender in
                  created_parent := Some parent_uuid;
                  let submitted_cursor =
                    insert_block
                      sender
                      ~block_uuid
                      ~parent_uuid
                      ~title:marker_title
                      ~after_server_t:opening_cursor
                      ~on_applied:(fun () -> created := true)
                  in
                  opening_cursor, submitted_cursor, graph, parent_uuid)
           in
           let sender_facts = durable_facts sender_support sender_graph.graph_id in
           require_durable_advance sender_facts sender_opening_cursor "sender";
           if sender_facts.cursor < sender_submitted_cursor
           then fail "sender durable cursor is behind public state";
           let receiver_opening_cursor, receiver_final_cursor, receiver_graph =
             with_client
               ~label:"receiver"
               ~support:receiver_support
               ~credentials
               ~cognito
               (fun receiver ->
                  let opening_cursor, graph = await_opening_current receiver in
                  if
                    not
                      (Logseq_db_types.Graph_types.Uuid.equal
                         graph.graph_id
                         sender_graph.graph_id)
                  then fail_worker receiver "recovery" "graph-mismatch";
                  ignore
                    (require_block receiver ~block_uuid ~parent_uuid ~title:marker_title
                     : Logseq_db_types.Graph_types.block * int64);
                  let final_cursor =
                    cleanup_block
                      receiver
                      ~block_uuid
                      ~parent_uuid
                      ~title:marker_title
                      ~opening_cursor
                  in
                  cleaned := true;
                  opening_cursor, final_cursor, graph)
           in
           if receiver_opening_cursor < sender_facts.cursor
           then fail "receiver did not recover the sender cursor";
           let receiver_facts = durable_facts receiver_support receiver_graph.graph_id in
           require_durable_advance receiver_facts receiver_opening_cursor "receiver";
           if receiver_facts.cursor < receiver_final_cursor
           then fail "receiver durable cursor is behind public state")))
;;

let () =
  let status =
    try
      if Sys.getenv_opt platform_crypto_provider_marker = Some "1"
      then (
        with_execution_lock run;
        0)
      else run_with_platform_crypto_provider ()
    with
    | E2e_failure message ->
      prerr_endline ("managed sync deployed E2E failed: " ^ message);
      2
    | _ ->
      prerr_endline "managed sync deployed E2E failed: unexpected failure";
      2
  in
  if !runtime_started then Worker_runtime.For_testing.final_shutdown ();
  exit status
;;
