module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Core = Service
module Protocol = Logseq_db_worker.Protocol
module Support = Managed_sync_e2e_support
module Probe = Managed_sync_protocol_probe
module Sync_protocol = Logseq_sync_pure_reducer.Sync_protocol
module ID = Bonsai_flutter_spec.Id

exception E2e_failure of string

let fail format = Printf.ksprintf (fun message -> raise (E2e_failure message)) format
let base_url = "https://api.logseq.io"
let report_phase phase = prerr_endline ("managed sync deployed E2E phase: " ^ phase)

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
  ; mutable recovery_started : bool
  ; mutable last_state : Core.state option
  ; mutable graph_phase : Logseq_db_worker.graph_phase
  ; mutable last_event : string
  ; mutable saw_catalog : bool
  ; mutable saw_bootstrap : bool
  ; mutable saw_opening_pull : bool
  ; mutable state_history : string list
  }

let send context request = Worker.send context.client request |> accepted

let send_command context command =
  ignore (send context (Service.Client_command command) : ID.Worker.Request_id.t)
;;

let fail_worker context phase reason =
  let sync, cursor, startup_failure, error_kind, error_detail =
    match context.last_state with
    | None -> "unknown", "none", "none", "none", "none"
    | Some state ->
      ( sync_phase_name state.snapshot.sync_phase
      , Option.fold ~none:"none" ~some:string_of_int state.snapshot.applied_server_t
      , startup_failure_stage_name state.snapshot.startup.failure
      , sync_error_kind state.snapshot.last_error
      , Option.fold ~none:"none" ~some:String.escaped state.snapshot.last_error )
  in
  fail
    "client=%s phase=%s reason=%s sync=%s startup-failure=%s error-kind=%s graph=%s \
     cursor=%s outbox=unobserved last=%s history=%s error=%s"
    context.label
    phase
    reason
    sync
    startup_failure
    error_kind
    (graph_phase_name context.graph_phase)
    cursor
    context.last_event
    (String.concat "," (List.rev context.state_history))
    error_detail
;;

let handle_public_state context state =
  context.last_state <- Some state;
  context.last_event <- "client-state";
  let snapshot = state.Core.snapshot in
  let marker =
    Printf.sprintf
      "%s:%s:%s"
      (sync_phase_name snapshot.sync_phase)
      (Option.fold ~none:"none" ~some:string_of_int snapshot.applied_server_t)
      (sync_error_kind snapshot.last_error)
  in
  if not (List.mem marker context.state_history)
  then (
    let rec take count reversed = function
      | _ when count = 0 -> List.rev reversed
      | [] -> List.rev reversed
      | value :: rest -> take (count - 1) (value :: reversed) rest
    in
    context.state_history <- take 24 [] (marker :: context.state_history));
  (match snapshot.sync_phase, snapshot.startup.failure with
   | Failed, Some During_local_restore when not context.recovery_started ->
     context.recovery_started <- true;
     send_command context Begin_online_recovery
   | Failed, _ -> fail_worker context "sync" "failed"
   | _ -> ());
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
    let request_id = Service.token_request_id request in
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
  | Response { outcome = Completed Service.Client_command_completed; _ } -> None
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

let await_opening_current ?(timeout_seconds = 300.) context =
  let deadline = timeout_at timeout_seconds in
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

let journal_parent context =
  match
    graph_request
      context
      (V2_list_journals
         { from_day = 0
         ; through_day = 99_999_999
         ; limit = 50
         ; cursor = None
         ; revision = None
         })
  with
  | V2_response { outcome = V2_journals_outcome { items; _ }; _ } ->
    (match
       List.find_opt
         (fun (item : Protocol.v2_journal_item) -> not item.page.recycled)
         items
     with
     | Some item -> item.page.uuid
     | None -> fail_worker context "journal-read" "no-active-journal")
  | V2_response _ -> fail_worker context "journal-read" "unexpected-response"
;;

let read_block context block_uuid =
  match graph_request context (V2_get_block { block = block_uuid; revision = None }) with
  | V2_response { outcome = V2_block_outcome (V2_present_block { value; revision }); _ }
    -> Ok (value, revision)
  | V2_response { outcome = V2_block_outcome (V2_missing_block _); _ } -> Error ()
  | V2_response _ -> fail_worker context "block-read" "unexpected-response"
;;

let precondition_scope = function
  | Protocol.V2_children_revision parent -> Protocol.V2_children_scope parent
  | V2_page_tree_revision { page; maximum_depth } ->
    V2_page_tree_scope { page; maximum_depth }
;;

let require_block context ~block_uuid ~parent_uuid ~title =
  match read_block context block_uuid with
  | Error () -> fail_worker context "block-recovery" "missing"
  | Ok (block, basis) ->
    if not (Logseq_db_types.Graph_types.Uuid.equal block.block.uuid block_uuid)
    then fail_worker context "block-recovery" "uuid-mismatch";
    if not (String.equal block.block.title title)
    then fail_worker context "block-recovery" "title-mismatch";
    if not (Logseq_db_types.Graph_types.Uuid.equal block.block.parent parent_uuid)
    then fail_worker context "block-recovery" "parent-mismatch";
    block, basis
;;

let run_mutation ?(on_applied = fun () -> ()) context ~after_server_t phase command =
  report_phase (phase ^ "-request");
  let request = Protocol.{ api_version; request_id = fresh_uuid (); command } in
  let worker_request_id = send context (Service.Graph_request request) in
  (match await_graph_response context ~phase worker_request_id with
   | V2_response { outcome = V2_mutation_committed { status = V2_applied; _ }; _ } ->
     report_phase (phase ^ "-local-commit");
     on_applied ()
   | V2_response { outcome = V2_failed { code; message }; _ } ->
     fail_worker context phase (Printf.sprintf "mutation-failed:%s:%s" code message)
   | V2_response _ -> fail_worker context phase "mutation-not-applied");
  let cursor = await_authoritative_current context ~after_server_t phase in
  report_phase (phase ^ "-authoritative");
  cursor
;;

let insert_preconditions context parent =
  let page_revision =
    match graph_request context (V2_get_page { page = parent; revision = None }) with
    | V2_response { outcome = V2_page_outcome (V2_present_page { revision; _ }); _ } ->
      revision
    | V2_response _ -> fail_worker context "insert-precondition" "parent-page-missing"
  in
  let scope_revision =
    match
      graph_request
        context
        (V2_get_children { parent; limit = 200; cursor = None; revision = None })
    with
    | V2_response { outcome = V2_children_outcome { scope_revision; _ }; _ } ->
      scope_revision
    | V2_response _ -> fail_worker context "insert-precondition" "children-missing"
  in
  Protocol.
    { blocks = []
    ; pages = [ parent, page_revision ]
    ; scopes = [ V2_children_scope parent, scope_revision ]
    }
;;

let insert_block context ~block_uuid ~parent_uuid ~title ~after_server_t ~on_applied =
  run_mutation
    ~on_applied
    context
    ~after_server_t
    "insert-block"
    (V2_insert_blocks
       { mutation_id = fresh_uuid ()
       ; parent = parent_uuid
       ; roots = [ { uuid = block_uuid; title; children = [] } ]
       ; preconditions = insert_preconditions context parent_uuid
       })
;;

let delete_block context ~block_uuid ~after_server_t =
  report_phase "delete-precondition-start";
  let block, revision =
    match read_block context block_uuid with
    | Ok value -> value
    | Error () -> fail_worker context "delete-precondition" "block-missing"
  in
  let revision_scope, scope_revision =
    match
      graph_request
        context
        (V2_get_page_tree
           { page = block.block.page
           ; maximum_depth = 256
           ; limit = 200
           ; cursor = None
           ; revision = None
           })
    with
    | V2_response
        { outcome = V2_page_tree_outcome { revision_scope; scope_revision; _ }; _ } ->
      revision_scope, scope_revision
    | V2_response _ -> fail_worker context "delete-precondition" "page-tree-missing"
  in
  report_phase "delete-precondition-complete";
  run_mutation
    context
    ~after_server_t
    "delete-block"
    (V2_delete_blocks
       { mutation_id = fresh_uuid ()
       ; root = block_uuid
       ; preconditions =
           { blocks = [ block_uuid, revision ]
           ; pages = []
           ; scopes = [ precondition_scope revision_scope, scope_revision ]
           }
       })
;;

let raw_transaction ~mutation_id ~operation operations =
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let tx = Codec.to_string ~mode:Codec.Verbose (Transit.Array operations) in
  Sync_protocol.Client.{ tx; tx_id = Some mutation_id; outliner_op = Some operation }
;;

let raw_marker_create ~mutation_id ~block_uuid ~parent_uuid ~protected_title =
  let module Transit = Transit_core.Json in
  let lookup uuid =
    Transit.Array
      [ Transit.Keyword "block/uuid"
      ; Transit.Uuid (Logseq_db_types.Graph_types.Uuid.to_string uuid)
      ]
  in
  let entity =
    Transit.String
      ("managed-sync-e2e:" ^ Logseq_db_types.Graph_types.Uuid.to_string (fresh_uuid ()))
  in
  let compact_id =
    Logseq_db_types.Graph_types.Uuid.to_string mutation_id
    |> String.split_on_char '-'
    |> String.concat ""
  in
  let order = "a0" ^ String.sub compact_id 0 8 ^ "1" in
  raw_transaction
    ~mutation_id
    ~operation:"insert-blocks"
    [ Transit.Array
        [ Transit.Keyword "db/add"
        ; entity
        ; Transit.Keyword "block/uuid"
        ; Transit.Uuid (Logseq_db_types.Graph_types.Uuid.to_string block_uuid)
        ]
    ; Transit.Array
        [ Transit.Keyword "db/add"
        ; entity
        ; Transit.Keyword "block/title"
        ; Transit.String protected_title
        ]
    ; Transit.Array
        [ Transit.Keyword "db/add"
        ; entity
        ; Transit.Keyword "block/parent"
        ; lookup parent_uuid
        ]
    ; Transit.Array
        [ Transit.Keyword "db/add"
        ; entity
        ; Transit.Keyword "block/page"
        ; lookup parent_uuid
        ]
    ; Transit.Array
        [ Transit.Keyword "db/add"
        ; entity
        ; Transit.Keyword "block/order"
        ; Transit.String order
        ]
    ; Transit.Array
        [ Transit.Keyword "db/add"
        ; entity
        ; Transit.Keyword "block/created-at"
        ; Transit.Int 1_704_067_200_000
        ]
    ; Transit.Array
        [ Transit.Keyword "db/add"
        ; entity
        ; Transit.Keyword "block/updated-at"
        ; Transit.Int 1_704_067_200_000
        ]
    ]
;;

let raw_marker_touch ~mutation_id ~block_uuid ~updated_at =
  let module Transit = Transit_core.Json in
  raw_transaction
    ~mutation_id
    ~operation:"save-block"
    [ Transit.Array
        [ Transit.Keyword "db/add"
        ; Transit.Array
            [ Transit.Keyword "block/uuid"
            ; Transit.Uuid (Logseq_db_types.Graph_types.Uuid.to_string block_uuid)
            ]
        ; Transit.Keyword "block/updated-at"
        ; Transit.Int updated_at
        ]
    ]
;;

let raw_marker_delete ~mutation_id block_uuid =
  let module Transit = Transit_core.Json in
  raw_transaction
    ~mutation_id
    ~operation:"delete-blocks"
    [ Transit.Array
        [ Transit.Keyword "db/retractEntity"
        ; Transit.Array
            [ Transit.Keyword "block/uuid"
            ; Transit.Uuid (Logseq_db_types.Graph_types.Uuid.to_string block_uuid)
            ]
        ]
    ]
;;

let raw_batch ~t_before transactions =
  Sync_protocol.Client.Tx_batch
    { client_revision = Some (Logseq_db_types.Graph_types.Uuid.to_string (fresh_uuid ()))
    ; t_before
    ; txs = transactions
    }
;;

let probe_require_ok phase = function
  | Ok value -> value
  | Error message -> fail "deployed protocol phase=%s reason=%s" phase message
;;

let probe_hello clock connection =
  Probe.await
    ~clock
    ~timeout_seconds:30.
    (function
      | Sync_protocol.Server.Hello { t; _ } -> Some t
      | Error { message } -> fail "deployed protocol hello failed: %s" message
      | _ -> None)
    connection
  |> probe_require_ok "hello"
;;

let probe_send connection message phase =
  Probe.send connection message |> probe_require_ok phase
;;

let probe_batch_result clock connection =
  Probe.await
    ~clock
    ~timeout_seconds:30.
    (function
      | Sync_protocol.Server.Tx_batch_ok { t; checksum } -> Some (`Accepted (t, checksum))
      | Tx_reject rejection -> Some (`Rejected rejection)
      | Error { message } -> fail "deployed protocol batch failed: %s" message
      | _ -> None)
    connection
  |> probe_require_ok "batch-result"
;;

let rejection_reason_name = function
  | Sync_protocol.Stale -> "stale"
  | Db_transact_failed -> "db-transact-failed"
  | Empty_tx_data -> "empty-tx-data"
  | Invalid_tx -> "invalid-tx"
  | Invalid_t_before -> "invalid-t-before"
  | Snapshot_upload_in_progress -> "snapshot-upload-in-progress"
;;

let probe_expect_accepted clock connection phase =
  match probe_batch_result clock connection with
  | `Accepted value -> value
  | `Rejected rejection ->
    fail
      "deployed protocol phase=%s unexpectedly rejected reason=%s missing-blocks=%d \
       detail=%s"
      phase
      (rejection_reason_name rejection.Sync_protocol.reason)
      (List.length rejection.missing_block_uuids)
      (Option.fold ~none:"none" ~some:String.escaped rejection.Sync_protocol.error_detail)
;;

let probe_pull clock connection ~since =
  probe_send connection (Sync_protocol.Client.Pull { since = Some since }) "pull";
  Probe.await
    ~clock
    ~timeout_seconds:30.
    (function
      | Sync_protocol.Server.Pull_ok { t; checksum; txs } -> Some (t, checksum, txs)
      | Error { message } -> fail "deployed protocol pull failed: %s" message
      | _ -> None)
    connection
  |> probe_require_ok "pull-result"
;;

let protected_title_from_history ~block_uuid transactions =
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let expected_uuid = Logseq_db_types.Graph_types.Uuid.to_string block_uuid in
  let is_expected_entity = function
    | Transit.String uuid -> String.equal uuid expected_uuid
    | Transit.Array [ Transit.Keyword "block/uuid"; Transit.Uuid uuid ] ->
      String.equal uuid expected_uuid
    | _ -> false
  in
  let title_from_operation = function
    | Transit.Array
        [ Transit.Keyword "db/add"
        ; entity
        ; Transit.Keyword "block/title"
        ; Transit.String title
        ; _
        ]
      when is_expected_entity entity -> Some title
    | _ -> None
  in
  List.find_map
    (fun (transaction : Sync_protocol.Server.pull_transaction) ->
       match Codec.of_string transaction.tx with
       | Transit.Array operations -> List.find_map title_from_operation operations
       | _ -> None)
    transactions
;;

let transaction_adds_block_uuid ~block_uuid transaction =
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let expected_uuid = Logseq_db_types.Graph_types.Uuid.to_string block_uuid in
  let is_expected_entity = function
    | Transit.String uuid -> String.equal uuid expected_uuid
    | Transit.Array [ Transit.Keyword "block/uuid"; Transit.Uuid uuid ] ->
      String.equal uuid expected_uuid
    | _ -> false
  in
  match Codec.of_string transaction.Sync_protocol.Server.tx with
  | Transit.Array operations ->
    List.exists
      (function
        | Transit.Array
            [ Transit.Keyword "db/add"
            ; entity
            ; Transit.Keyword "block/uuid"
            ; Transit.Uuid value
            ; _
            ] -> is_expected_entity entity && String.equal value expected_uuid
        | _ -> false)
      operations
  | _ -> false
;;

let run_deployed_protocol_contract
      ~token
      ~graph_id
      ~parent_uuid
      ~source_block_uuid
      ~source_cursor
  =
  report_phase "protocol-contract-start";
  Eio_main.run (fun environment ->
    Eio.Switch.run (fun sw ->
      let network = Eio.Stdenv.net environment in
      let clock = Eio.Stdenv.clock environment in
      let first =
        Probe.connect ~sw ~network ~clock ~base_url ~graph_id ~token
        |> probe_require_ok "connect-first"
      in
      let second =
        Probe.connect ~sw ~network ~clock ~base_url ~graph_id ~token
        |> probe_require_ok "connect-second"
      in
      Fun.protect
        ~finally:(fun () ->
          Probe.close first;
          Probe.close second)
        (fun () ->
           probe_send
             first
             (Sync_protocol.Client.Hello { client = "logseq-journal-e2e-first" })
             "hello-first";
           probe_send
             second
             (Sync_protocol.Client.Hello { client = "logseq-journal-e2e-second" })
             "hello-second";
           let first_t = probe_hello clock first in
           let second_t = probe_hello clock second in
           let baseline = Int.max first_t second_t in
           let _, _, source_history = probe_pull clock first ~since:source_cursor in
           let protected_title =
             match
               protected_title_from_history ~block_uuid:source_block_uuid source_history
             with
             | Some title -> title
             | None -> fail "deployed Pull omitted the source protected title"
           in
           let _, _, _ = probe_pull clock first ~since:baseline in
           let _, _, _ = probe_pull clock second ~since:baseline in
           let accepted_block = fresh_uuid () in
           let second_accepted_block = fresh_uuid () in
           let first_id = fresh_uuid () in
           let second_id = fresh_uuid () in
           let first_transaction =
             raw_marker_create
               ~mutation_id:first_id
               ~block_uuid:accepted_block
               ~parent_uuid
               ~protected_title
           in
           let second_transaction =
             raw_marker_create
               ~mutation_id:second_id
               ~block_uuid:second_accepted_block
               ~parent_uuid
               ~protected_title
           in
           let group =
             raw_batch ~t_before:baseline [ first_transaction; second_transaction ]
           in
           probe_send first group "group-submit";
           let group_t, _ = probe_expect_accepted clock first "group-submit" in
           if group_t <> baseline + 2
           then fail "deployed group cursors are not contiguous in member order";
           let pulled_t, _, pulled = probe_pull clock second ~since:baseline in
           if pulled_t < group_t
           then fail "deployed pull did not reach the accepted group";
           let group_members =
             pulled
             |> List.filter (fun transaction ->
               transaction.Sync_protocol.Server.t > baseline && transaction.t <= group_t)
           in
           if
             List.map (fun tx -> tx.Sync_protocol.Server.t) group_members
             <> [ baseline + 1; baseline + 2 ]
           then fail "deployed group interval was interleaved or reordered";
           List.iter2
             (fun (expected_uuid, expected) transaction ->
                if not (transaction_adds_block_uuid ~block_uuid:expected_uuid transaction)
                then fail "deployed Pull omitted a normalized group member";
                if
                  transaction.Sync_protocol.Server.outliner_op
                  <> expected.Sync_protocol.Client.outliner_op
                then fail "deployed Pull changed the separate outliner operation")
             [ accepted_block, first_transaction
             ; second_accepted_block, second_transaction
             ]
             group_members;
           probe_send first group "stale-retry";
           (match probe_batch_result clock first with
            | `Rejected { reason = Sync_protocol.Stale; t = Some retry_t; _ }
              when retry_t = group_t -> ()
            | `Rejected _ -> fail "deployed retry did not return the current stale cursor"
            | `Accepted _ -> fail "deployed retry unexpectedly executed twice");
           let accepted_delete_id = fresh_uuid () in
           let accepted_delete =
             raw_batch
               ~t_before:group_t
               [ raw_marker_delete ~mutation_id:accepted_delete_id accepted_block ]
           in
           probe_send first accepted_delete "accepted-before-remote-delete";
           let delete_t, _ =
             probe_expect_accepted clock first "accepted-before-remote-delete"
           in
           let later_remote_id = fresh_uuid () in
           probe_send
             second
             (raw_batch
                ~t_before:delete_t
                [ raw_marker_touch
                    ~mutation_id:later_remote_id
                    ~block_uuid:second_accepted_block
                    ~updated_at:1_704_067_200_001
                ])
             "remote-after-delete";
           let later_remote_t, _ =
             probe_expect_accepted clock second "remote-after-delete"
           in
           if delete_t >= later_remote_t
           then fail "deployed accepted delete did not precede the remote transaction";
           let stale_block = fresh_uuid () in
           let create_stale_id = fresh_uuid () in
           probe_send
             first
             (raw_batch
                ~t_before:later_remote_t
                [ raw_marker_create
                    ~mutation_id:create_stale_id
                    ~block_uuid:stale_block
                    ~parent_uuid
                    ~protected_title
                ])
             "stale-marker-create";
           let stale_baseline, _ =
             probe_expect_accepted clock first "stale-marker-create"
           in
           let intervening_id = fresh_uuid () in
           probe_send
             second
             (raw_batch
                ~t_before:stale_baseline
                [ raw_marker_touch
                    ~mutation_id:intervening_id
                    ~block_uuid:second_accepted_block
                    ~updated_at:1_704_067_200_002
                ])
             "intervening-remote";
           let intervening_t, _ =
             probe_expect_accepted clock second "intervening-remote"
           in
           let stale_delete_id = fresh_uuid () in
           probe_send
             first
             (raw_batch
                ~t_before:stale_baseline
                [ raw_marker_delete ~mutation_id:stale_delete_id stale_block ])
             "stale-delete";
           (match probe_batch_result clock first with
            | `Rejected
                { reason = Sync_protocol.Stale
                ; t = Some rejection_t
                ; success_tx_ids = []
                ; failed_tx_id = None
                ; _
                }
              when rejection_t >= intervening_t -> ()
            | `Rejected _ ->
              fail "deployed stale delete lacked batch-level non-execution evidence"
            | `Accepted _ -> fail "deployed stale t_before delete executed");
           probe_send
             first
             (raw_batch
                ~t_before:intervening_t
                [ raw_marker_delete ~mutation_id:(fresh_uuid ()) stale_block ])
             "stale-marker-cleanup";
           let stale_cleanup_t, _ =
             probe_expect_accepted clock first "stale-marker-cleanup"
           in
           probe_send
             first
             (raw_batch
                ~t_before:stale_cleanup_t
                [ raw_marker_delete ~mutation_id:(fresh_uuid ()) second_accepted_block ])
             "second-group-marker-cleanup";
           ignore
             (probe_expect_accepted clock first "second-group-marker-cleanup"
              : int * string option))));
  report_phase "protocol-contract-complete"
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
    ; recovery_started = false
    ; last_state = None
    ; graph_phase = Graph_closed
    ; last_event = "started"
    ; saw_catalog = false
    ; saw_bootstrap = false
    ; saw_opening_pull = false
    ; state_history = []
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
       let result = f context in
       let token_request_count = Hashtbl.length context.token_requests in
       report_phase (Printf.sprintf "%s-token-request-count-%d" label token_request_count);
       if token_request_count <> 1
       then fail_worker context "authentication" "unexpected-token-request-count";
       result)
;;

type durable_facts =
  { cursor : int
  ; checksum : string
  ; outbox_empty : bool
  }

let durable_facts support graph_id =
  let database_path =
    Filename.concat
      support
      (Filename.concat
         "logseq-db-worker/synced-graphs"
         (Filename.concat
            (Logseq_db_types.Graph_types.Uuid.to_string graph_id)
            "db.sqlite"))
  in
  let metadata =
    match Logseq_db_storage.Sync_checkpoint_store.read_path database_path with
    | Ok metadata -> metadata
    | Error _ -> fail "durable mirror is unavailable"
  in
  let sqlite = Sqlite3.db_open database_path in
  let outbox =
    Fun.protect
      ~finally:(fun () ->
        if not (Sqlite3.db_close sqlite) then fail "durable mirror close failed")
      (fun () ->
         match Logseq_db_storage.Sync_outbox_store.read_database sqlite with
         | Ok records -> records
         | Error _ -> fail "durable outbox inspection failed")
  in
  { cursor = metadata.applied_server_t
  ; checksum = metadata.checksum
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
  report_phase "cleanup-read-start";
  match read_block context block_uuid with
  | Error () -> opening_cursor
  | Ok (block, _) ->
    report_phase "cleanup-read-complete";
    if not (String.equal block.block.title title)
    then fail_worker context "cleanup" "title-mismatch";
    if not (Logseq_db_types.Graph_types.Uuid.equal block.block.parent parent_uuid)
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
    report_phase "best-effort-cleanup-start";
    with_client ~label:"cleanup" ~support ~credentials ~cognito (fun context ->
      let opening_cursor, graph = await_opening_current ~timeout_seconds:30. context in
      if Logseq_db_types.Graph_types.Uuid.equal graph.graph_id graph_id
      then
        ignore
          (cleanup_block context ~block_uuid ~parent_uuid ~title ~opening_cursor : int));
    report_phase "best-effort-cleanup-complete"
  with
  | _ -> report_phase "best-effort-cleanup-failed"
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
  with_temp_directory "logseq-deployed-e2e-sender-" (fun sender_support ->
    with_temp_directory "logseq-deployed-e2e-receiver-" (fun receiver_support ->
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
             report_phase "sender-start";
             with_client
               ~label:"sender"
               ~support:sender_support
               ~credentials
               ~cognito
               (fun sender ->
                  let opening_cursor, graph = await_opening_current sender in
                  report_phase "sender-open";
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
                  report_phase "sender-insert-complete";
                  opening_cursor, submitted_cursor, graph, parent_uuid)
           in
           report_phase "sender-closed";
           let sender_facts = durable_facts sender_support sender_graph.graph_id in
           require_durable_advance sender_facts sender_opening_cursor "sender";
           if sender_facts.cursor < sender_submitted_cursor
           then fail "sender durable cursor is behind public state";
           let receiver_opening_cursor, receiver_final_cursor, receiver_graph =
             report_phase "receiver-start";
             with_client
               ~label:"receiver"
               ~support:receiver_support
               ~credentials
               ~cognito
               (fun receiver ->
                  let opening_cursor, graph = await_opening_current receiver in
                  report_phase "receiver-open";
                  if
                    not
                      (Logseq_db_types.Graph_types.Uuid.equal
                         graph.graph_id
                         sender_graph.graph_id)
                  then fail_worker receiver "recovery" "graph-mismatch";
                  ignore
                    (require_block receiver ~block_uuid ~parent_uuid ~title:marker_title
                     : Protocol.v2_block_record * string);
                  let final_cursor =
                    cleanup_block
                      receiver
                      ~block_uuid
                      ~parent_uuid
                      ~title:marker_title
                      ~opening_cursor
                  in
                  report_phase "receiver-delete-complete";
                  cleaned := true;
                  opening_cursor, final_cursor, graph)
           in
           report_phase "receiver-closed";
           if receiver_opening_cursor < sender_facts.cursor
           then fail "receiver did not recover the sender cursor";
           let receiver_facts = durable_facts receiver_support receiver_graph.graph_id in
           require_durable_advance receiver_facts receiver_opening_cursor "receiver";
           if receiver_facts.cursor < receiver_final_cursor
           then fail "receiver durable cursor is behind public state";
           run_deployed_protocol_contract
             ~token:cognito.id_token
             ~graph_id:receiver_graph.graph_id
             ~parent_uuid
             ~source_block_uuid:block_uuid
             ~source_cursor:sender_opening_cursor)))
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
