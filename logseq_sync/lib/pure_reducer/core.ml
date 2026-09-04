module Overlay = Logseq_overlay_db.Types

type graph_id = Logseq_db_types.Graph_types.Uuid.t
type graph = Logseq_db_types.Managed_graph.t
type account_generation = int
type graph_generation = int
type connection_generation = int
type presentation_generation = int
type lifecycle_generation = int64

type sync_phase =
  | Offline
  | Connecting
  | Pulling
  | Submitting
  | Current
  | Paused
  | Failed

type startup_failure_stage =
  | During_authentication
  | During_catalog
  | During_local_restore
  | During_bootstrap
  | During_e2ee

type startup_facts =
  { authenticated : bool
  ; catalog_loading : bool
  ; awaiting_selection : bool
  ; restoring_local : bool
  ; bootstrapping : bool
  ; awaiting_e2ee_password : bool
  ; failure : startup_failure_stage option
  ; account_generation : account_generation
  ; graph_generation : graph_generation
  ; presentation_generation : presentation_generation
  }

type snapshot =
  { sync_phase : sync_phase
  ; catalog : graph list
  ; selected_graph : graph_id option
  ; applied_server_t : int option
  ; timeline_presentation_pending : bool
  ; startup : startup_facts
  ; last_error : string option
  }

type diagnostic_group =
  { title : string
  ; entries : (string * string) list
  }

type diagnostics =
  { groups : diagnostic_group list
  ; history : string list
  }

type state =
  { snapshot : snapshot
  ; diagnostics : diagnostics
  }

type limits =
  { maximum_response_bytes : int
  ; maximum_artifact_bytes : int
  ; submission_batch_size : int
  }
[@@warning "-69"]

type config =
  { managed_sync_origin : Uri.t
  ; limits : limits
  }

type config_error = Invalid_config of string

let limits ~maximum_response_bytes ~maximum_artifact_bytes ~submission_batch_size =
  if
    maximum_response_bytes <= 0
    || maximum_response_bytes > Logseq_db_types.Limits.maximum_response_bytes
  then Error (Invalid_config "maximum response bytes are outside the supported bound")
  else if maximum_artifact_bytes <= 0
  then Error (Invalid_config "maximum artifact bytes must be positive")
  else if submission_batch_size <= 0 || submission_batch_size > 4096
  then Error (Invalid_config "submission batch size is outside the supported bound")
  else Ok { maximum_response_bytes; maximum_artifact_bytes; submission_batch_size }
;;

let config ~managed_sync_origin ~limits =
  match Uri.scheme managed_sync_origin, Uri.host managed_sync_origin with
  | Some "https", Some host when String.length host > 0 ->
    Ok { managed_sync_origin; limits }
  | _ -> Error (Invalid_config "managed sync origin must be an absolute HTTPS URI")
;;

type token_purpose =
  | Catalog_discovery
  | Snapshot_bootstrap
  | E2ee_key_access
  | Websocket_connect

type token_request =
  { request_id : string
  ; purpose : token_purpose
  ; account_generation : account_generation
  ; graph_generation : graph_generation option
  ; connection_generation : connection_generation option
  }
[@@warning "-69"]

let token_request_id request = request.request_id
let token_request_purpose request = request.purpose

type bootstrap_progress =
  { graph_id : graph_id
  ; received_bytes : int64
  ; total_bytes : int64 option
  }

type invalidation =
  { basis : int64
  ; changed_uuids : graph_id list
  ; changed_uuids_truncated : bool
  }

type account_scope =
  { managed_sync_origin : Uri.t
  ; user_id : string
  ; account_generation : account_generation
  ; presentation_generation : presentation_generation
  ; lifecycle_generation : lifecycle_generation
  }

type authenticated_account_scope =
  { account : account_scope
  ; token : string
  }

type graph_scope =
  { account : account_scope
  ; graph_id : graph_id
  ; graph_generation : graph_generation
  }

type authorized_graph_scope =
  { graph : graph_scope
  ; token : string
  }

type connection_scope =
  { graph : graph_scope
  ; connection_generation : connection_generation
  }

type effect_scope =
  { account_generation : account_generation option
  ; graph_generation : graph_generation option
  ; connection_generation : connection_generation option
  ; presentation_generation : presentation_generation option
  ; lifecycle_generation : lifecycle_generation option
  }

type effect_id = int

type crypto_failure_kind =
  | Invalid_key_material
  | Crypto_provider_unavailable

type effect_error =
  | Effect_failed of string
  | Crypto_failed of crypto_failure_kind * string

type graph_key_handle =
  { handle_id : string
  ; handle_scope : graph_scope
  }

type staged_artifact =
  { artifact_id : string
  ; artifact_scope : graph_scope
  ; artifact_path : string
  ; artifact_expected_rows : int
  }
[@@warning "-69"]

type catalog_cache =
  { cache_user_id : string
  ; cache_graphs : graph list
  ; cache_selected_graph : graph_id option
  }

let graph_key_handle ~id ~scope = { handle_id = id; handle_scope = scope }
let graph_key_handle_id handle = handle.handle_id
let graph_key_handle_scope handle = handle.handle_scope

let staged_artifact ~id ~scope ~path ~expected_rows =
  { artifact_id = id
  ; artifact_scope = scope
  ; artifact_path = path
  ; artifact_expected_rows = expected_rows
  }
;;

let staged_artifact_path artifact = artifact.artifact_path
let staged_artifact_expected_rows artifact = artifact.artifact_expected_rows

let effect_scope_of_account (account : account_scope) =
  { account_generation = Some account.account_generation
  ; graph_generation = None
  ; connection_generation = None
  ; presentation_generation = Some account.presentation_generation
  ; lifecycle_generation = Some account.lifecycle_generation
  }
;;

let effect_scope_of_graph (graph : graph_scope) =
  { (effect_scope_of_account graph.account) with
    graph_generation = Some graph.graph_generation
  }
;;

let effect_scope_of_connection (connection : connection_scope) =
  { (effect_scope_of_graph connection.graph) with
    connection_generation = Some connection.connection_generation
  }
;;

let catalog_cache ~user_id ~graphs ~selected_graph =
  { cache_user_id = user_id
  ; cache_graphs = graphs
  ; cache_selected_graph = selected_graph
  }
;;

let catalog_cache_user_id cache = cache.cache_user_id
let catalog_cache_graphs cache = cache.cache_graphs
let catalog_cache_selected_graph cache = cache.cache_selected_graph

let graph_to_json (graph : graph) =
  `Assoc
    [ "graphId", `String (Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id)
    ; "name", `String graph.name
    ; ( "schema"
      , `Assoc
          [ "major", `Int graph.schema.major
          ; "minor", `Int graph.schema.minor
          ; "exact", `Bool graph.schema.exact
          ] )
    ; "encrypted", `Bool graph.encrypted
    ]
;;

let encode_catalog_cache cache =
  `Assoc
    [ "userId", `String cache.cache_user_id
    ; "graphs", `List (List.map graph_to_json cache.cache_graphs)
    ; ( "selectedGraph"
      , Option.fold
          ~none:`Null
          ~some:(fun id -> `String (Logseq_db_types.Graph_types.Uuid.to_string id))
          cache.cache_selected_graph )
    ]
  |> Yojson.Safe.to_string
;;

let decode_catalog_cache source =
  let open Yojson.Safe.Util in
  try
    let json = Yojson.Safe.from_string source in
    let graph_of_json value =
      let schema = value |> member "schema" in
      Logseq_db_types.Managed_graph.
        { graph_id =
            value
            |> member "graphId"
            |> to_string
            |> Logseq_db_types.Graph_types.Uuid.of_string
            |> Result.get_ok
        ; name = value |> member "name" |> to_string
        ; schema =
            { major = schema |> member "major" |> to_int
            ; minor = schema |> member "minor" |> to_int
            ; exact = schema |> member "exact" |> to_bool
            }
        ; encrypted = value |> member "encrypted" |> to_bool
        }
    in
    let selected_graph =
      match json |> member "selectedGraph" with
      | `String value ->
        Logseq_db_types.Graph_types.Uuid.of_string value |> Result.to_option
      | `Null | _ -> None
    in
    Ok
      { cache_user_id = json |> member "userId" |> to_string
      ; cache_graphs = json |> member "graphs" |> to_list |> List.map graph_of_json
      ; cache_selected_graph = selected_graph
      }
  with
  | Yojson.Json_error message | Type_error (message, _) | Invalid_argument message ->
    Error message
;;

type encryption_batch =
  { scope : graph_scope
  ; key : graph_key_handle
  ; plaintexts : string list
  }

type encrypted_values = (string * string) list

type decryption_batch =
  { scope : graph_scope
  ; key : graph_key_handle
  ; protected_values : (string * string) list
  }

type decrypted_values = string list
type snapshot_baseline = string
type snapshot_metadata = string

type snapshot_download =
  { scope : authorized_graph_scope
  ; uri : Uri.t
  ; expected_bytes : int64 option
  ; maximum_bytes : int
  }

type graph_key_request =
  { scope : authorized_graph_scope
  ; encrypted_graph_key : string
  }

type private_key_unlock =
  { scope : authenticated_account_scope
  ; password : string
  ; private_key_package : string
  }

type _ runner_request =
  | Load_catalog : account_scope -> catalog_cache option runner_request
  | Save_catalog :
      { account : account_scope
      ; cache : catalog_cache
      }
      -> unit runner_request
  | Fetch_catalog : authenticated_account_scope -> graph list runner_request
  | Fetch_snapshot_baseline : authorized_graph_scope -> snapshot_baseline runner_request
  | Fetch_snapshot_metadata : authorized_graph_scope -> snapshot_metadata runner_request
  | Download_snapshot : snapshot_download -> staged_artifact runner_request
  | Fetch_e2ee_graph_key : authorized_graph_scope -> string runner_request
  | Fetch_e2ee_user_keys : authenticated_account_scope -> string runner_request
  | Load_and_unlock_graph_key : graph_scope -> graph_key_handle runner_request
  | Fetch_and_unlock_graph_key : graph_key_request -> graph_key_handle runner_request
  | Unlock_private_key : private_key_unlock -> unit runner_request
  | Delete_wrapped_graph_key :
      { account : account_scope
      ; graph_id : graph_id
      }
      -> unit runner_request
  | Delete_account_secrets : account_scope -> unit runner_request
  | Encrypt_protected_values : encryption_batch -> encrypted_values runner_request
  | Decrypt_protected_values : decryption_batch -> decrypted_values runner_request

type _ request_kind =
  | Load_catalog_kind : catalog_cache option request_kind
  | Save_catalog_kind : unit request_kind
  | Fetch_catalog_kind : graph list request_kind
  | Fetch_snapshot_baseline_kind : snapshot_baseline request_kind
  | Fetch_snapshot_metadata_kind : snapshot_metadata request_kind
  | Download_snapshot_kind : staged_artifact request_kind
  | Fetch_e2ee_graph_key_kind : string request_kind
  | Fetch_e2ee_user_keys_kind : string request_kind
  | Load_and_unlock_graph_key_kind : graph_key_handle request_kind
  | Fetch_and_unlock_graph_key_kind : graph_key_handle request_kind
  | Unlock_private_key_kind : unit request_kind
  | Delete_wrapped_graph_key_kind : unit request_kind
  | Delete_account_secrets_kind : unit request_kind
  | Encrypt_protected_values_kind : encrypted_values request_kind
  | Decrypt_protected_values_kind : decrypted_values request_kind

type 'a effect_ticket =
  { id : effect_id
  ; scope : effect_scope
  ; kind : 'a request_kind
  }

let effect_ticket_id ticket = ticket.id
let effect_ticket_scope ticket = ticket.scope
let effect_id_to_string = string_of_int

type websocket_request =
  { scope : connection_scope
  ; uri : Uri.t
  ; token : string
  }

type websocket_send =
  { scope : connection_scope
  ; message : Sync_protocol.Client.message
  }

type timer_id = int

type timer_request =
  { id : timer_id
  ; scope : effect_scope
  ; delay_seconds : float
  }

type runner_effect =
  | Request : 'a effect_ticket * 'a runner_request -> runner_effect
  | Start_websocket of websocket_request
  | Send_websocket of websocket_send
  | Close_websocket of connection_scope
  | Schedule_timer of timer_request
  | Cancel_effects of effect_scope

type runner_completion =
  | Completion : 'a effect_ticket * ('a, effect_error) result -> runner_completion

let scope_of_request : type a. a runner_request -> effect_scope = function
  | Load_catalog account | Save_catalog { account; _ } -> effect_scope_of_account account
  | Fetch_catalog value -> effect_scope_of_account value.account
  | Fetch_snapshot_baseline value | Fetch_snapshot_metadata value ->
    effect_scope_of_graph value.graph
  | Download_snapshot value -> effect_scope_of_graph value.scope.graph
  | Fetch_e2ee_graph_key value -> effect_scope_of_graph value.graph
  | Fetch_e2ee_user_keys value -> effect_scope_of_account value.account
  | Load_and_unlock_graph_key value -> effect_scope_of_graph value
  | Fetch_and_unlock_graph_key value -> effect_scope_of_graph value.scope.graph
  | Unlock_private_key value -> effect_scope_of_account value.scope.account
  | Delete_wrapped_graph_key value -> effect_scope_of_account value.account
  | Delete_account_secrets value -> effect_scope_of_account value
  | Encrypt_protected_values value -> effect_scope_of_graph value.scope
  | Decrypt_protected_values value -> effect_scope_of_graph value.scope
;;

let runner_effect_scope = function
  | Request (ticket, _) -> ticket.scope
  | Start_websocket value -> effect_scope_of_connection value.scope
  | Send_websocket value -> effect_scope_of_connection value.scope
  | Close_websocket value -> effect_scope_of_connection value
  | Schedule_timer value -> value.scope
  | Cancel_effects value -> value
;;

let runner_effect_diagnostic = function
  | Request (ticket, _) -> Printf.sprintf "request:%d" ticket.id
  | Start_websocket _ -> "start-websocket"
  | Send_websocket _ -> "send-websocket"
  | Close_websocket _ -> "close-websocket"
  | Schedule_timer value -> Printf.sprintf "timer:%d" value.id
  | Cancel_effects _ -> "cancel-effects"
;;

let equal_runner_effect left right = left = right

type mirror_request =
  { graph : graph
  ; scope : graph_scope
  }

type snapshot_activation_request =
  { artifact : staged_artifact
  ; scope : graph_scope
  ; applied_server_t : int
  ; key : graph_key_handle option
  }

type mirror_deletion =
  { graph_id : graph_id
  ; scope : effect_scope
  }

type mirror_inspection =
  | Mirror_available of mirror_request
  | Mirror_absent of graph_scope

type outbox_transition_request =
  { expected : Overlay.sync_token
  ; key : graph_key_handle option
  ; scope : graph_scope
  ; transition : Overlay.outbox_transition
  }

type authoritative_batch =
  { input : Overlay.authoritative_batch
  ; key : graph_key_handle option
  ; scope : connection_scope
  ; presentation_generation : presentation_generation
  ; lifecycle_generation : lifecycle_generation
  }

type worker_effect =
  | Inspect_mirror of mirror_request
  | Activate_snapshot of snapshot_activation_request
  | Delete_mirror of mirror_deletion
  | Attach_graph of mirror_request
  | Detach_graph of graph_scope
  | Reset_managed_account of account_scope
  | Inspect_sync of graph_scope
  | Apply_outbox_transition of outbox_transition_request
  | Apply_authoritative_batch of authoritative_batch

type output =
  | State_changed of state
  | Token_requested of token_request
  | Bootstrap_progressed of bootstrap_progress

type instruction =
  | Run of runner_effect
  | Delegate of worker_effect
  | Publish of output

let equal_instruction left right = left = right
let equal_instructions left right = left = right

type scoped_error =
  { scope : effect_scope
  ; message : string
  }

type graph_attachment =
  { scope : graph_scope
  ; sync : Overlay.sync_view
  }

type sync_inspection =
  { scope : graph_scope
  ; sync : Overlay.sync_view
  }

type authoritative_commit_result =
  { scope : graph_scope
  ; commit : Overlay.authoritative_commit
  ; sync : Overlay.sync_view
  }

type authoritative_deferred_result =
  { scope : graph_scope
  ; defer : Overlay.authoritative_defer
  }

type outbox_transition_result =
  { scope : graph_scope
  ; commit : Overlay.outbox_commit
  ; sync : Overlay.sync_view
  }

type snapshot_activation = { scope : graph_scope }

type event =
  | Restore_local_account of { user_id : string }
  | Account_authenticated of { user_id : string option }
  | Local_feed_acknowledged
  | Local_outbox_changed
  | Timeline_presented
  | Token_provided of token_request * string
  | Token_rejected of token_request
  | Graph_selected of graph_id
  | Graph_picker_requested
  | Catalog_refresh_requested
  | Online_recovery_requested
  | E2ee_password_submitted of string
  | Local_cache_deletion_requested of graph_id
  | Foreground_changed of
      { foreground : bool
      ; lifecycle_generation : lifecycle_generation
      }
  | Mirror_inspected of mirror_inspection
  | Graph_attached of graph_attachment
  | Graph_attachment_failed of scoped_error
  | Sync_inspected of sync_inspection
  | Outbox_transition_applied of outbox_transition_result
  | Authoritative_batch_applied of authoritative_commit_result
  | Authoritative_batch_deferred of authoritative_deferred_result
  | Authoritative_batch_failed of scoped_error
  | Snapshot_activated of snapshot_activation
  | Snapshot_activation_failed of scoped_error
  | Runner_completed of runner_completion
  | Snapshot_download_progress of bootstrap_progress
  | Websocket_opened of connection_scope
  | Websocket_message of connection_scope * Sync_protocol.Server.message
  | Websocket_protocol_error of connection_scope * Sync_protocol.codec_error
  | Websocket_closed of connection_scope * string option
  | Timer_elapsed of timer_id
  | Shutdown

type pending_effect = Pending_effect : 'a effect_ticket -> pending_effect

type submission_owner =
  { batch_id : Overlay.submission_batch_id
  ; mutation_ids : graph_id list
  ; connection : connection_scope
  ; accepted_through : int option
  }

type t =
  { config : config
  ; public_state : state
  ; user_id : string option
  ; lifecycle_generation : lifecycle_generation
  ; next_effect_id : int
  ; pending_token : token_request option
  ; pending_effects : pending_effect list
  ; selected_graph_value : graph option
  ; current_graph_scope : graph_scope option
  ; connection_generation : connection_generation
  ; graph_key : graph_key_handle option
  ; pending_graph_open : mirror_request option
  ; pending_mirror_inspection : mirror_request option
  ; pending_attachment : mirror_request option
  ; pending_encrypted_graph_key : string option
  ; pending_private_key_package : string option
  ; snapshot_authorization : authorized_graph_scope option
  ; snapshot_server_t : int option
  ; active_snapshot_download : graph_scope option
  ; sync_view : Overlay.sync_view option
  ; pending_sync_inspection : graph_scope option
  ; pending_outbox_transition : outbox_transition_request option
  ; submission_owner : submission_owner option
  ; active_authoritative_batch : authoritative_batch option
  ; queued_authoritative_batch : authoritative_batch option
  ; deferred_authoritative_owner : Overlay.submission_batch_id option
  ; websocket_live : bool
  ; closed : bool
  }

type create_error = Invalid_create of string

let initial_startup =
  { authenticated = false
  ; catalog_loading = false
  ; awaiting_selection = false
  ; restoring_local = false
  ; bootstrapping = false
  ; awaiting_e2ee_password = false
  ; failure = None
  ; account_generation = 0
  ; graph_generation = 0
  ; presentation_generation = 0
  }
;;

let initial config =
  let snapshot =
    { sync_phase = Offline
    ; catalog = []
    ; selected_graph = None
    ; applied_server_t = None
    ; timeline_presentation_pending = false
    ; startup = initial_startup
    ; last_error = None
    }
  in
  Ok
    { config
    ; public_state = { snapshot; diagnostics = { groups = []; history = [] } }
    ; user_id = None
    ; lifecycle_generation = 0L
    ; next_effect_id = 1
    ; pending_token = None
    ; pending_effects = []
    ; selected_graph_value = None
    ; current_graph_scope = None
    ; connection_generation = 0
    ; graph_key = None
    ; pending_graph_open = None
    ; pending_mirror_inspection = None
    ; pending_attachment = None
    ; pending_encrypted_graph_key = None
    ; pending_private_key_package = None
    ; snapshot_authorization = None
    ; snapshot_server_t = None
    ; active_snapshot_download = None
    ; sync_view = None
    ; pending_sync_inspection = None
    ; pending_outbox_transition = None
    ; submission_owner = None
    ; active_authoritative_batch = None
    ; queued_authoritative_batch = None
    ; deferred_authoritative_owner = None
    ; websocket_live = false
    ; closed = false
    }
;;

let state core = core.public_state
let admitted_graph_scope core = core.current_graph_scope

type transition =
  { next : t
  ; effects : instruction list
  }

let unchanged next = { next; effects = [] }
let publish core = Publish (State_changed core.public_state)

let set_snapshot core snapshot =
  { core with public_state = { core.public_state with snapshot } }
;;

let rejection_reason_diagnostic = function
  | Sync_protocol.Stale -> "stale"
  | Db_transact_failed -> "db-transact-failed"
  | Empty_tx_data -> "empty-tx-data"
  | Invalid_tx -> "invalid-tx"
  | Invalid_t_before -> "invalid-t-before"
  | Snapshot_upload_in_progress -> "snapshot-upload-in-progress"
;;

let append_diagnostic_history core entry =
  let rec take count reversed = function
    | _ when count = 0 -> List.rev reversed
    | [] -> List.rev reversed
    | value :: rest -> take (count - 1) (value :: reversed) rest
  in
  let diagnostics = core.public_state.diagnostics in
  let diagnostics =
    { diagnostics with history = take 32 [] (entry :: diagnostics.history) }
  in
  { core with public_state = { core.public_state with diagnostics } }
;;

let safe_rejection_detail_keywords = function
  | None -> []
  | Some detail ->
    let normalized =
      detail
      |> String.lowercase_ascii
      |> String.map (function
        | ('a' .. 'z' | '-') as character -> character
        | _ -> ' ')
    in
    let allowed =
      [ "add"
      ; "a"
      ; "as"
      ; "be"
      ; "block"
      ; "already"
      ; "assert"
      ; "attribute"
      ; "cannot"
      ; "cardinality"
      ; "cas"
      ; "component"
      ; "conflict"
      ; "constraint"
      ; "datom"
      ; "data"
      ; "decrypt"
      ; "encrypted"
      ; "entity"
      ; "exists"
      ; "expected"
      ; "failed"
      ; "found"
      ; "fractional"
      ; "got"
      ; "instant"
      ; "integer"
      ; "index"
      ; "invalid"
      ; "is"
      ; "key"
      ; "keyword"
      ; "lookup"
      ; "map"
      ; "missing"
      ; "must"
      ; "nil"
      ; "normal-block"
      ; "order"
      ; "page"
      ; "parent"
      ; "ref"
      ; "reference"
      ; "required"
      ; "retract"
      ; "schema"
      ; "should"
      ; "string"
      ; "store"
      ; "tempid"
      ; "transact"
      ; "transaction"
      ; "to"
      ; "tx"
      ; "type"
      ; "unique"
      ; "unknown"
      ; "unsupported"
      ; "uuid"
      ; "value"
      ; "valid"
      ; "vector"
      ; "write"
      ]
    in
    let rec take count reversed = function
      | _ when count = 0 -> List.rev reversed
      | [] -> List.rev reversed
      | word :: rest -> take (count - 1) (word :: reversed) rest
    in
    normalized
    |> String.split_on_char ' '
    |> List.filter (fun word -> List.mem word allowed)
    |> List.rev
    |> take 64 []
    |> List.rev
;;

let fail core stage message =
  let startup = { core.public_state.snapshot.startup with failure = Some stage } in
  let snapshot =
    { core.public_state.snapshot with
      sync_phase = Failed
    ; startup
    ; last_error = Some message
    }
  in
  let core =
    { core with
      pending_token = None
    ; pending_effects = []
    ; pending_mirror_inspection = None
    ; pending_attachment = None
    ; pending_encrypted_graph_key = None
    ; pending_private_key_package = None
    ; snapshot_authorization = None
    ; snapshot_server_t = None
    ; active_snapshot_download = None
    ; pending_sync_inspection = None
    ; pending_outbox_transition = None
    ; active_authoritative_batch = None
    ; queued_authoritative_batch = None
    ; deferred_authoritative_owner = None
    }
  in
  let next = set_snapshot core snapshot in
  { next; effects = [ publish next ] }
;;

let cleanup_failed core message =
  let core = append_diagnostic_history core message in
  let next =
    set_snapshot core { core.public_state.snapshot with last_error = Some message }
  in
  { next; effects = [ publish next ] }
;;

let account_scope core user_id =
  { managed_sync_origin = core.config.managed_sync_origin
  ; user_id
  ; account_generation = core.public_state.snapshot.startup.account_generation
  ; presentation_generation = core.public_state.snapshot.startup.presentation_generation
  ; lifecycle_generation = core.lifecycle_generation
  }
;;

let graph_scope_is_current core scope = core.current_graph_scope = Some scope

let connection_is_current core (scope : connection_scope) =
  graph_scope_is_current core scope.graph
  && scope.connection_generation = core.connection_generation
;;

let request_kind : type a. a runner_request -> a request_kind = function
  | Load_catalog _ -> Load_catalog_kind
  | Save_catalog _ -> Save_catalog_kind
  | Fetch_catalog _ -> Fetch_catalog_kind
  | Fetch_snapshot_baseline _ -> Fetch_snapshot_baseline_kind
  | Fetch_snapshot_metadata _ -> Fetch_snapshot_metadata_kind
  | Download_snapshot _ -> Download_snapshot_kind
  | Fetch_e2ee_graph_key _ -> Fetch_e2ee_graph_key_kind
  | Fetch_e2ee_user_keys _ -> Fetch_e2ee_user_keys_kind
  | Load_and_unlock_graph_key _ -> Load_and_unlock_graph_key_kind
  | Fetch_and_unlock_graph_key _ -> Fetch_and_unlock_graph_key_kind
  | Unlock_private_key _ -> Unlock_private_key_kind
  | Delete_wrapped_graph_key _ -> Delete_wrapped_graph_key_kind
  | Delete_account_secrets _ -> Delete_account_secrets_kind
  | Encrypt_protected_values _ -> Encrypt_protected_values_kind
  | Decrypt_protected_values _ -> Decrypt_protected_values_kind
;;

let issue_request : type a. t -> a runner_request -> t * runner_effect =
  fun core request ->
  let ticket =
    { id = core.next_effect_id
    ; scope = scope_of_request request
    ; kind = request_kind request
    }
  in
  ( { core with
      next_effect_id = core.next_effect_id + 1
    ; pending_effects = Pending_effect ticket :: core.pending_effects
    }
  , Request (ticket, request) )
;;

let issue_token core purpose =
  let core =
    match purpose with
    | Websocket_connect ->
      { core with
        connection_generation = core.connection_generation + 1
      ; websocket_live = false
      ; pending_sync_inspection = None
      ; pending_outbox_transition = None
      ; submission_owner = None
      ; active_authoritative_batch = None
      ; queued_authoritative_batch = None
      ; deferred_authoritative_owner = None
      }
    | Catalog_discovery | Snapshot_bootstrap | E2ee_key_access -> core
  in
  let request =
    { request_id = Printf.sprintf "token-%d" core.next_effect_id
    ; purpose
    ; account_generation = core.public_state.snapshot.startup.account_generation
    ; graph_generation =
        Option.map
          (fun (scope : graph_scope) -> scope.graph_generation)
          core.current_graph_scope
    ; connection_generation =
        (match purpose with
         | Websocket_connect -> Some core.connection_generation
         | _ -> None)
    }
  in
  ( { core with pending_token = Some request; next_effect_id = core.next_effect_id + 1 }
  , Publish (Token_requested request) )
;;

let server_cursor value =
  Overlay.Server_cursor.of_string (Printf.sprintf "server-cursor:v1:%d" value)
;;

let checksum value = Overlay.Checksum.of_string ("checksum:v1:" ^ value)

let server_cursor_number cursor =
  Overlay.Server_cursor.to_string cursor
  |> String.split_on_char ':'
  |> List.rev
  |> List.hd
  |> int_of_string
;;

let decode_snapshot_baseline source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc fields ->
      (match List.assoc_opt "type" fields, List.assoc_opt "t" fields with
       | Some (`String "pull/ok"), Some (`Int server_t) when server_t >= 0 -> Ok server_t
       | _ -> Error "snapshot baseline pull is invalid")
    | _ -> Error "snapshot baseline pull must be an object"
  with
  | Yojson.Json_error _ -> Error "snapshot baseline pull is not valid JSON"
;;

let decode_snapshot_uri source =
  try
    match Yojson.Safe.from_string source with
    | `Assoc fields ->
      (match List.assoc_opt "ok" fields, List.assoc_opt "url" fields with
       | Some (`Bool true), Some (`String value) ->
         let uri = Uri.of_string value in
         (match Uri.scheme uri, Uri.host uri, Uri.userinfo uri, Uri.fragment uri with
          | Some "https", Some host, None, None when String.length host > 0 -> Ok uri
          | _ -> Error "snapshot download URL is invalid")
       | _ -> Error "snapshot metadata is invalid")
    | _ -> Error "snapshot metadata must be an object"
  with
  | Yojson.Json_error _ -> Error "snapshot metadata is not valid JSON"
;;

let save_cache core =
  match core.user_id with
  | None -> core, []
  | Some user_id ->
    let cache =
      catalog_cache
        ~user_id
        ~graphs:core.public_state.snapshot.catalog
        ~selected_graph:core.public_state.snapshot.selected_graph
    in
    let next, request =
      issue_request core (Save_catalog { account = account_scope core user_id; cache })
    in
    next, [ Run request ]
;;

let authenticate core user_id =
  let startup =
    { initial_startup with
      authenticated = true
    ; catalog_loading = true
    ; account_generation = core.public_state.snapshot.startup.account_generation + 1
    ; presentation_generation =
        core.public_state.snapshot.startup.presentation_generation + 1
    }
  in
  let snapshot =
    { core.public_state.snapshot with
      catalog = []
    ; selected_graph = None
    ; applied_server_t = None
    ; startup
    ; last_error = None
    }
  in
  let core =
    set_snapshot
      { core with
        user_id = Some user_id
      ; pending_token = None
      ; pending_effects = []
      ; current_graph_scope = None
      ; graph_key = None
      ; pending_graph_open = None
      ; pending_mirror_inspection = None
      ; pending_attachment = None
      ; pending_encrypted_graph_key = None
      ; pending_private_key_package = None
      ; snapshot_authorization = None
      ; snapshot_server_t = None
      ; active_snapshot_download = None
      ; sync_view = None
      ; pending_sync_inspection = None
      ; pending_outbox_transition = None
      ; submission_owner = None
      ; active_authoritative_batch = None
      ; queued_authoritative_batch = None
      ; deferred_authoritative_owner = None
      ; websocket_live = false
      }
      snapshot
  in
  let next, token = issue_token core Catalog_discovery in
  { next; effects = [ publish next; token ] }
;;

let restore_local core user_id =
  let startup =
    { initial_startup with
      restoring_local = true
    ; account_generation = core.public_state.snapshot.startup.account_generation + 1
    }
  in
  let core =
    set_snapshot
      { core with
        user_id = Some user_id
      ; pending_token = None
      ; pending_effects = []
      ; selected_graph_value = None
      ; current_graph_scope = None
      ; graph_key = None
      ; pending_graph_open = None
      ; pending_mirror_inspection = None
      ; pending_attachment = None
      ; pending_encrypted_graph_key = None
      ; pending_private_key_package = None
      ; snapshot_authorization = None
      ; snapshot_server_t = None
      ; active_snapshot_download = None
      ; sync_view = None
      ; pending_sync_inspection = None
      ; pending_outbox_transition = None
      ; submission_owner = None
      ; active_authoritative_batch = None
      ; queued_authoritative_batch = None
      ; deferred_authoritative_owner = None
      ; websocket_live = false
      }
      { core.public_state.snapshot with startup }
  in
  let next, request = issue_request core (Load_catalog (account_scope core user_id)) in
  { next; effects = [ publish next; Run request ] }
;;

let sign_out core =
  let old_account = Option.map (account_scope core) core.user_id in
  let generation_increment = if Option.is_some old_account then 1 else 0 in
  let current_startup = core.public_state.snapshot.startup in
  let snapshot =
    { core.public_state.snapshot with
      sync_phase = Offline
    ; catalog = []
    ; selected_graph = None
    ; applied_server_t = None
    ; startup =
        { initial_startup with
          account_generation = current_startup.account_generation + generation_increment
        ; graph_generation = current_startup.graph_generation
        ; presentation_generation =
            current_startup.presentation_generation + generation_increment
        }
    }
  in
  let next =
    set_snapshot
      { core with
        user_id = None
      ; pending_token = None
      ; pending_effects = []
      ; current_graph_scope = None
      ; graph_key = None
      ; pending_graph_open = None
      ; pending_mirror_inspection = None
      ; pending_attachment = None
      ; pending_encrypted_graph_key = None
      ; pending_private_key_package = None
      ; snapshot_authorization = None
      ; snapshot_server_t = None
      ; active_snapshot_download = None
      ; sync_view = None
      ; pending_sync_inspection = None
      ; pending_outbox_transition = None
      ; submission_owner = None
      ; active_authoritative_batch = None
      ; queued_authoritative_batch = None
      ; deferred_authoritative_owner = None
      ; websocket_live = false
      }
      snapshot
  in
  match old_account with
  | None -> { next; effects = [ publish next ] }
  | Some account ->
    let next, deletion = issue_request next (Delete_account_secrets account) in
    { next
    ; effects =
        [ Run (Cancel_effects (effect_scope_of_account account))
        ; Delegate (Reset_managed_account account)
        ; Run deletion
        ; publish next
        ]
    }
;;

let provide_token core request token =
  if core.pending_token <> Some request || String.length token = 0
  then unchanged core
  else (
    let core = { core with pending_token = None } in
    match request.purpose, core.user_id, core.current_graph_scope with
    | Catalog_discovery, Some user_id, _ ->
      let next, request_effect =
        issue_request core (Fetch_catalog { account = account_scope core user_id; token })
      in
      { next; effects = [ Run request_effect ] }
    | Snapshot_bootstrap, _, Some graph ->
      let authorization = { graph; token } in
      let core =
        { core with
          snapshot_authorization = Some authorization
        ; snapshot_server_t = None
        }
      in
      let next, request_effect =
        issue_request core (Fetch_snapshot_baseline authorization)
      in
      { next; effects = [ Run request_effect ] }
    | E2ee_key_access, _, Some graph ->
      let authorization = { graph; token } in
      let core =
        { core with
          snapshot_authorization = Some authorization
        ; snapshot_server_t = None
        ; pending_encrypted_graph_key = None
        ; pending_private_key_package = None
        }
      in
      let next, request_effect =
        issue_request core (Fetch_e2ee_graph_key authorization)
      in
      { next; effects = [ Run request_effect ] }
    | Websocket_connect, _, Some graph ->
      let scope = { graph; connection_generation = core.connection_generation } in
      let uri =
        Uri.with_scheme core.config.managed_sync_origin (Some "wss")
        |> fun uri ->
        Uri.with_path
          uri
          ("/sync/" ^ Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id)
      in
      let next =
        set_snapshot core { core.public_state.snapshot with sync_phase = Connecting }
      in
      { next; effects = [ publish next; Run (Start_websocket { scope; uri; token }) ] }
    | _, _, _ -> unchanged core)
;;

let select_graph core graph_id =
  match
    ( core.user_id
    , List.find_opt
        (fun (graph : graph) ->
           Logseq_db_types.Graph_types.Uuid.equal graph.graph_id graph_id)
        core.public_state.snapshot.catalog )
  with
  | Some user_id, Some graph ->
    let graph_generation = core.public_state.snapshot.startup.graph_generation + 1 in
    let startup =
      { core.public_state.snapshot.startup with
        awaiting_selection = false
      ; restoring_local = true
      ; graph_generation
      }
    in
    let snapshot =
      { core.public_state.snapshot with
        selected_graph = Some graph_id
      ; applied_server_t = None
      ; startup
      }
    in
    let scope = { account = account_scope core user_id; graph_id; graph_generation } in
    let mirror_request = { graph; scope } in
    let core =
      set_snapshot
        { core with
          selected_graph_value = Some graph
        ; current_graph_scope = Some scope
        ; graph_key = None
        ; pending_graph_open = None
        ; pending_mirror_inspection = Some mirror_request
        ; pending_attachment = None
        ; pending_encrypted_graph_key = None
        ; pending_private_key_package = None
        ; snapshot_authorization = None
        ; snapshot_server_t = None
        ; active_snapshot_download = None
        ; sync_view = None
        ; pending_sync_inspection = None
        ; pending_outbox_transition = None
        ; submission_owner = None
        ; active_authoritative_batch = None
        ; queued_authoritative_batch = None
        ; deferred_authoritative_owner = None
        }
        snapshot
    in
    let next, cache = save_cache core in
    { next; effects = Delegate (Inspect_mirror mirror_request) :: publish next :: cache }
  | _ -> unchanged core
;;

let mirror_inspected core = function
  | Mirror_available request
    when graph_scope_is_current core request.scope
         && core.pending_mirror_inspection = Some request ->
    let core = { core with pending_mirror_inspection = None } in
    (match core.selected_graph_value, core.graph_key with
     | Some graph, Some key
       when graph.encrypted && graph_key_handle_scope key = request.scope ->
       { next = { core with pending_attachment = Some request }
       ; effects = [ Delegate (Attach_graph request) ]
       }
     | Some graph, _ when graph.encrypted ->
       let next, key_request =
         issue_request core (Load_and_unlock_graph_key request.scope)
       in
       { next = { next with pending_graph_open = Some request }
       ; effects = [ Run key_request ]
       }
     | Some _, _ | None, _ ->
       { next = { core with pending_attachment = Some request }
       ; effects = [ Delegate (Attach_graph request) ]
       })
  | Mirror_absent scope
    when graph_scope_is_current core scope
         && Option.fold
              ~none:false
              ~some:(fun (request : mirror_request) -> request.scope = scope)
              core.pending_mirror_inspection ->
    let core = { core with pending_mirror_inspection = None } in
    let startup =
      { core.public_state.snapshot.startup with
        restoring_local = false
      ; bootstrapping = true
      }
    in
    let core = set_snapshot core { core.public_state.snapshot with startup } in
    (match core.selected_graph_value with
     | Some graph when graph.encrypted ->
       let next, request = issue_request core (Load_and_unlock_graph_key scope) in
       { next; effects = [ publish next; Run request ] }
     | Some _ | None ->
       let next, token = issue_token core Snapshot_bootstrap in
       { next; effects = [ publish next; token ] })
  | _ -> unchanged core
;;

let graph_attached core (attachment : graph_attachment) =
  if
    (not (graph_scope_is_current core attachment.scope))
    || not
         (Option.fold
            ~none:false
            ~some:(fun (request : mirror_request) -> request.scope = attachment.scope)
            core.pending_attachment)
  then unchanged core
  else (
    let core = { core with pending_attachment = None } in
    let startup =
      { core.public_state.snapshot.startup with
        restoring_local = false
      ; bootstrapping = false
      ; failure = None
      }
    in
    let snapshot =
      { core.public_state.snapshot with
        sync_phase = Current
      ; applied_server_t =
          Some (server_cursor_number (Overlay.sync_view_checkpoint attachment.sync))
      ; timeline_presentation_pending = true
      ; startup
      ; last_error = None
      }
    in
    let core = set_snapshot { core with sync_view = Some attachment.sync } snapshot in
    let next, token = issue_token core Websocket_connect in
    { next; effects = [ publish next; token ] })
;;

let operation_name = function
  | Overlay.Save_block_operation -> "save-block"
  | Insert_blocks_operation -> "insert-blocks"
  | Delete_blocks_operation -> "delete-blocks"
  | Create_journal_page_operation -> "create-journal-page"
  | Set_task_status_operation -> "set-task-status"
  | Clear_task_status_operation -> "clear-task-status"
;;

let submission_message batch =
  let txs =
    Overlay.submission_batch_wires batch
    |> List.map (fun wire ->
      Sync_protocol.Client.
        { tx = Overlay.submission_wire_protected_transaction wire
        ; tx_id = Some (Overlay.submission_wire_mutation_id wire)
        ; outliner_op = Some (operation_name (Overlay.submission_wire_operation wire))
        })
  in
  Sync_protocol.Client.Tx_batch
    { client_revision =
        Some (Overlay.Submission_batch_id.to_string (Overlay.submission_batch_id batch))
    ; t_before = server_cursor_number (Overlay.submission_batch_t_before batch)
    ; txs
    }
;;

let plan_submission core =
  match
    ( core.sync_view
    , core.current_graph_scope
    , core.submission_owner
    , core.pending_outbox_transition
    , core.websocket_live )
  with
  | Some sync, Some scope, None, None, true ->
    let rec take n acc = function
      | [] -> List.rev acc
      | _ when n = 0 -> List.rev acc
      | x :: xs -> take (n - 1) (x :: acc) xs
    in
    let ids =
      Overlay.sync_view_submissions sync
      |> List.filter (fun (item : Overlay.submission_descriptor) ->
        item.state = Overlay.Queued && item.dependency_eligible)
      |> List.map (fun (item : Overlay.submission_descriptor) -> item.mutation_id)
      |> take core.config.limits.submission_batch_size []
    in
    if ids = []
    then unchanged core
    else (
      let request =
        { expected = Overlay.sync_view_token sync
        ; key = core.graph_key
        ; scope
        ; transition = Overlay.Submit_group ids
        }
      in
      let next =
        set_snapshot
          { core with pending_outbox_transition = Some request }
          { core.public_state.snapshot with sync_phase = Submitting }
      in
      { next; effects = [ publish next; Delegate (Apply_outbox_transition request) ] })
  | _ -> unchanged core
;;

let outbox_transition_applied core (result : outbox_transition_result) =
  if
    (not (graph_scope_is_current core result.scope))
    || not
         (Option.fold
            ~none:false
            ~some:(fun (request : outbox_transition_request) ->
              request.scope = result.scope
              && request.transition = result.commit.transition)
            core.pending_outbox_transition)
  then unchanged core
  else (
    let transition_batch_id =
      match result.commit.transition with
      | Overlay.Retry_group batch_id -> Some batch_id
      | Accept_group { batch_id; _ } | Reject_group { batch_id; _ } -> Some batch_id
      | Submit_group _ -> None
    in
    let resumes_deferred =
      match core.deferred_authoritative_owner, transition_batch_id with
      | Some awaited, Some observed -> Overlay.Submission_batch_id.equal awaited observed
      | None, _ | Some _, None -> false
    in
    let submission_owner =
      match result.commit.transition, core.submission_owner with
      | Overlay.Reject_group { batch_id; _ }, Some owner
        when Overlay.Submission_batch_id.equal batch_id owner.batch_id -> None
      | (Submit_group _ | Retry_group _ | Accept_group _ | Reject_group _), owner -> owner
    in
    let core =
      { core with
        pending_outbox_transition = None
      ; sync_view = Some result.sync
      ; submission_owner
      ; deferred_authoritative_owner =
          (if resumes_deferred then None else core.deferred_authoritative_owner)
      }
    in
    let resume_effects =
      match resumes_deferred, core.active_authoritative_batch with
      | true, Some batch -> [ Delegate (Apply_authoritative_batch batch) ]
      | false, _ | true, None -> []
    in
    match result.commit.submission_batch, core.current_graph_scope with
    | Some batch, Some graph ->
      let connection = { graph; connection_generation = core.connection_generation } in
      let mutation_ids =
        Overlay.submission_batch_wires batch
        |> List.map Overlay.submission_wire_mutation_id
      in
      let next =
        { core with
          submission_owner =
            Some
              { batch_id = Overlay.submission_batch_id batch
              ; mutation_ids
              ; connection
              ; accepted_through = None
              }
        }
      in
      { next
      ; effects =
          resume_effects
          @ [ Run
                (Send_websocket { scope = connection; message = submission_message batch })
            ]
      }
    | _ ->
      let next =
        set_snapshot core { core.public_state.snapshot with sync_phase = Current }
      in
      if resume_effects <> []
      then { next; effects = resume_effects }
      else (
        match result.commit.transition with
        | Overlay.Accept_group _ ->
          let next =
            set_snapshot next { next.public_state.snapshot with sync_phase = Pulling }
          in
          let pull =
            match
              ( next.current_graph_scope
              , next.public_state.snapshot.applied_server_t
              , next.websocket_live )
            with
            | Some graph, Some since, true ->
              [ Run
                  (Send_websocket
                     { scope =
                         { graph; connection_generation = next.connection_generation }
                     ; message = Sync_protocol.Client.Pull { since = Some since }
                     })
              ]
            | None, _, _ | _, None, _ | _, _, false -> []
          in
          { next; effects = publish next :: pull }
        | Submit_group _ | Retry_group _ | Reject_group _ ->
          let planned = plan_submission next in
          { next = planned.next; effects = publish next :: planned.effects }))
;;

let pull_effect core =
  match core.current_graph_scope, core.public_state.snapshot.applied_server_t with
  | Some graph, Some cursor when core.websocket_live ->
    Some
      (Run
         (Send_websocket
            { scope = { graph; connection_generation = core.connection_generation }
            ; message = Sync_protocol.Client.Pull { since = Some cursor }
            }))
  | _ -> None
;;

let websocket_opened core connection =
  if (not (connection_is_current core connection)) || core.websocket_live
  then unchanged core
  else (
    let next =
      set_snapshot
        { core with websocket_live = true }
        { core.public_state.snapshot with sync_phase = Pulling }
    in
    { next; effects = publish next :: Option.to_list (pull_effect next) })
;;

let authoritative_input core t checksum_value txs =
  let current = Option.value core.public_state.snapshot.applied_server_t ~default:(-1) in
  let txs = List.filter (fun tx -> tx.Sync_protocol.Server.t > current) txs in
  if t = current && txs = []
  then Ok None
  else (
    let rec encode acc = function
      | [] -> Ok (List.rev acc)
      | tx :: rest ->
        (match server_cursor tx.Sync_protocol.Server.t with
         | Error message -> Error message
         | Ok cursor ->
           (match
              Overlay.encoded_transaction_of_string
                ~maximum_bytes:core.config.limits.maximum_response_bytes
                tx.tx
            with
            | Error _ -> Error "invalid encoded transaction"
            | Ok transaction ->
              encode (Overlay.authoritative_transaction ~cursor ~transaction :: acc) rest))
    in
    Result.bind (encode [] txs) (fun transactions ->
      Result.bind (server_cursor t) (fun through ->
        let checksum =
          match checksum_value with
          | None -> Ok None
          | Some value -> Result.map Option.some (checksum value)
        in
        Result.bind checksum (fun checksum ->
          Overlay.authoritative_batch
            ~maximum_count:4096
            ~maximum_bytes:core.config.limits.maximum_response_bytes
            ~transactions
            ~through
            ~checksum
          |> Result.map Option.some
          |> Result.map_error (fun _ -> "invalid authoritative batch")))))
;;

let enqueue_authoritative core batch =
  match core.active_authoritative_batch with
  | None ->
    { next = { core with active_authoritative_batch = Some batch }
    ; effects = [ Delegate (Apply_authoritative_batch batch) ]
    }
  | Some _ ->
    { next = { core with queued_authoritative_batch = Some batch }; effects = [] }
;;

let apply_accept core owner t checksum_value =
  match core.sync_view, checksum_value, server_cursor t with
  | Some sync, Some checksum_value, Ok through ->
    (match checksum checksum_value with
     | Error _ -> fail core During_catalog "invalid acceptance checksum"
     | Ok checksum ->
       let request =
         { expected = Overlay.sync_view_token sync
         ; key = core.graph_key
         ; scope = owner.connection.graph
         ; transition =
             Overlay.Accept_group
               { batch_id = owner.batch_id; barrier = Overlay.{ through; checksum } }
         }
       in
       { next =
           { core with
             pending_outbox_transition = Some request
           ; submission_owner = Some { owner with accepted_through = Some t }
           }
       ; effects = [ Delegate (Apply_outbox_transition request) ]
       })
  | _ -> fail core During_catalog "invalid acceptance barrier"
;;

let apply_rejection core owner rejection =
  match core.sync_view with
  | None -> unchanged core
  | Some sync ->
    let uuid_equal = Logseq_db_types.Graph_types.Uuid.equal in
    let rec consume_prefix members prefix =
      match members, prefix with
      | rest, [] -> Ok rest
      | member :: members, item :: prefix when uuid_equal member item ->
        consume_prefix members prefix
      | [], _ :: _ | _ :: _, _ :: _ ->
        Error "rejection accepted IDs are not a batch prefix"
    in
    let partition () =
      Result.bind
        (consume_prefix owner.mutation_ids rejection.Sync_protocol.success_tx_ids)
        (fun remaining ->
           match rejection.failed_tx_id, remaining with
           | Some failed, expected :: suffix when uuid_equal failed expected ->
             Ok (Some failed, suffix)
           | None, expected :: suffix when rejection.success_tx_ids = [] ->
             Ok (Some expected, suffix)
           | Some _, _ -> Error "rejection failed ID is not the next submitted member"
           | None, _ -> Error "rejection omitted the failed submitted member")
    in
    let acceptance_barrier () =
      match rejection.success_tx_ids with
      | [] -> Ok None
      | _ :: _ ->
        (match rejection.t, rejection.checksum with
         | Some through, Some checksum_value ->
           Result.bind (server_cursor through) (fun through ->
             Result.map
               (fun checksum -> Some Overlay.{ through; checksum })
               (checksum checksum_value))
         | _ -> Error "partial rejection omitted its acceptance barrier")
    in
    let reason =
      match rejection.Sync_protocol.reason with
      | Sync_protocol.Empty_tx_data | Invalid_tx | Invalid_t_before ->
        Overlay.Invalid_request
      | Db_transact_failed when rejection.missing_block_uuids <> [] ->
        Overlay.Missing_dependencies
      | Db_transact_failed | Snapshot_upload_in_progress -> Overlay.Operational_failure
      | Stale -> Overlay.Operational_failure
    in
    let disposition =
      match rejection.Sync_protocol.reason, reason with
      | Stale, _ -> "stale"
      | _, Overlay.Invalid_request -> "invalid-request"
      | _, Missing_dependencies -> "missing-dependencies"
      | _, Operational_failure -> "operational-failure"
      | _, Permission_denied -> "permission-denied"
    in
    let core =
      let detail = safe_rejection_detail_keywords rejection.error_detail in
      let detail =
        match detail with
        | [] -> ""
        | keywords -> ":detail-" ^ String.concat "-" keywords
      in
      append_diagnostic_history
        core
        ("tx-reject:"
         ^ rejection_reason_diagnostic rejection.Sync_protocol.reason
         ^ ":"
         ^ disposition
         ^ detail)
    in
    let resolution =
      match rejection.Sync_protocol.reason, rejection.t with
      | Sync_protocol.Stale, Some through ->
        Result.map (fun through -> Overlay.Stale { through }) (server_cursor through)
      | Stale, None -> Error "stale rejection omitted cursor"
      | _, _ ->
        Result.bind (partition ()) (fun (failed_member, unexecuted_suffix) ->
          Result.map
            (fun acceptance_barrier ->
               Overlay.Definitive
                 { reason
                 ; partition =
                     { accepted_prefix = rejection.success_tx_ids
                     ; failed_member
                     ; unexecuted_suffix
                     ; acceptance_barrier
                     ; missing_uuids = rejection.missing_block_uuids
                     ; diagnostics = Option.to_list rejection.error_detail
                     }
                 })
            (acceptance_barrier ()))
    in
    (match resolution with
     | Error message -> fail core During_catalog message
     | Ok resolution ->
       let request =
         { expected = Overlay.sync_view_token sync
         ; key = core.graph_key
         ; scope = owner.connection.graph
         ; transition = Overlay.Reject_group { batch_id = owner.batch_id; resolution }
         }
       in
       { next = { core with pending_outbox_transition = Some request }
       ; effects = [ Delegate (Apply_outbox_transition request) ]
       })
;;

let websocket_message core connection message =
  if (not (connection_is_current core connection)) || not core.websocket_live
  then unchanged core
  else (
    match message with
    | Sync_protocol.Server.Pull_ok { t; checksum; txs } ->
      (match authoritative_input core t checksum txs with
       | Error message -> fail core During_catalog message
       | Ok None ->
         let next =
           set_snapshot core { core.public_state.snapshot with sync_phase = Current }
         in
         let planned = plan_submission next in
         { next = planned.next; effects = publish next :: planned.effects }
       | Ok (Some input) ->
         enqueue_authoritative
           core
           { input
           ; key = core.graph_key
           ; scope = connection
           ; presentation_generation =
               core.public_state.snapshot.startup.presentation_generation
           ; lifecycle_generation = core.lifecycle_generation
           })
    | Tx_batch_ok { t; checksum } ->
      (match core.submission_owner with
       | Some owner when owner.connection = connection ->
         apply_accept core owner t checksum
       | _ -> unchanged core)
    | Tx_reject rejection ->
      (match core.submission_owner with
       | Some owner when owner.connection = connection ->
         apply_rejection core owner rejection
       | _ -> unchanged core)
    | Hello _ | Changed _ ->
      (match pull_effect core with
       | None -> unchanged core
       | Some pull -> { next = core; effects = [ pull ] })
    | Error { message } -> fail core During_catalog ("sync server error: " ^ message)
    | Online_users _ | Presence _ | Pong -> unchanged core)
;;

let authoritative_applied core (result : authoritative_commit_result) =
  if
    (not (graph_scope_is_current core result.scope))
    || Option.is_none core.active_authoritative_batch
  then unchanged core
  else (
    let applied_server_t = server_cursor_number result.commit.checkpoint in
    let receipt_mutation_id (receipt : Overlay.mutation_receipt) =
      match receipt with
      | Applied_receipt { mutation_id; _ }
      | No_change_receipt { mutation_id; _ }
      | Discarded_receipt { mutation_id; _ } -> mutation_id
      | Remote_won_receipt receipt -> receipt.mutation_id
    in
    let owner =
      match core.submission_owner with
      | Some owner ->
        let retains =
          List.exists
            (fun (receipt : Overlay.terminal_receipt) ->
               match receipt.transport_disposition with
               | Overlay.Retain_terminal_owner_until_response batch_id ->
                 Overlay.Submission_batch_id.equal batch_id owner.batch_id
               | No_transport_owner | Clear_transport_owner -> false)
            result.commit.terminal_receipts
        in
        let clears =
          List.exists
            (fun (receipt : Overlay.terminal_receipt) ->
               receipt.transport_disposition = Overlay.Clear_transport_owner
               && List.exists
                    (Logseq_db_types.Graph_types.Uuid.equal
                       (receipt_mutation_id receipt.receipt))
                    owner.mutation_ids)
            result.commit.terminal_receipts
        in
        if retains
        then Some { owner with accepted_through = None }
        else if clears
        then None
        else (
          match owner.accepted_through with
          | Some through when applied_server_t >= through -> None
          | _ -> Some owner)
      | None -> None
    in
    let queued = core.queued_authoritative_batch in
    let core =
      set_snapshot
        { core with
          sync_view = Some result.sync
        ; submission_owner = owner
        ; active_authoritative_batch = None
        ; queued_authoritative_batch = None
        ; deferred_authoritative_owner = None
        }
        { core.public_state.snapshot with
          sync_phase = Current
        ; applied_server_t = Some applied_server_t
        ; last_error = None
        }
    in
    let planned = plan_submission core in
    let next, queued_effects =
      match queued with
      | Some batch ->
        ( { planned.next with active_authoritative_batch = Some batch }
        , [ Delegate (Apply_authoritative_batch batch) ] )
      | None -> planned.next, []
    in
    { next; effects = (publish core :: planned.effects) @ queued_effects })
;;

let authoritative_deferred core (result : authoritative_deferred_result) =
  if
    (not (graph_scope_is_current core result.scope))
    || Option.is_none core.active_authoritative_batch
  then unchanged core
  else (
    let (Overlay.Await_submission_outcome batch_id) = result.defer in
    match core.submission_owner with
    | Some owner when Overlay.Submission_batch_id.equal owner.batch_id batch_id ->
      unchanged { core with deferred_authoritative_owner = Some batch_id }
    | None | Some _ -> fail core During_catalog "authoritative defer owner mismatch")
;;

let consume_ticket : type a. t -> a effect_ticket -> t option =
  fun core ticket ->
  let rec loop kept = function
    | [] -> None
    | Pending_effect candidate :: rest when candidate.id = ticket.id ->
      Some { core with pending_effects = List.rev_append kept rest }
    | item :: rest -> loop (item :: kept) rest
  in
  loop [] core.pending_effects
;;

let graph_key_loaded core key =
  match core.current_graph_scope with
  | Some scope when graph_key_handle_scope key = scope ->
    (match core.pending_graph_open with
     | Some request when request.scope = scope ->
       { next =
           { core with
             graph_key = Some key
           ; pending_graph_open = None
           ; pending_attachment = Some request
           }
       ; effects = [ Delegate (Attach_graph request) ]
       }
     | None ->
       let core = { core with graph_key = Some key } in
       let next, token = issue_token core Snapshot_bootstrap in
       { next; effects = [ token ] }
     | Some _ -> unchanged core)
  | None | Some _ ->
    fail core During_e2ee "graph key handle is outside the selected graph scope"
;;

let complete_runner : type a. t -> a effect_ticket -> a -> transition =
  fun core ticket value ->
  match ticket.kind with
  | Load_catalog_kind ->
    let catalog, selected_graph =
      match value with
      | None -> [], None
      | Some cache -> cache.cache_graphs, cache.cache_selected_graph
    in
    let startup =
      { core.public_state.snapshot.startup with
        restoring_local = false
      ; awaiting_selection = true
      }
    in
    let next =
      set_snapshot
        core
        { core.public_state.snapshot with catalog; selected_graph; startup }
    in
    { next; effects = [ publish next ] }
  | Save_catalog_kind -> unchanged core
  | Fetch_catalog_kind ->
    let startup =
      { core.public_state.snapshot.startup with
        catalog_loading = false
      ; awaiting_selection = true
      ; failure = None
      }
    in
    let core =
      set_snapshot core { core.public_state.snapshot with catalog = value; startup }
    in
    let next, effects = save_cache core in
    { next; effects = publish next :: effects }
  | Fetch_snapshot_baseline_kind ->
    (match
       ( decode_snapshot_baseline value
       , core.current_graph_scope
       , core.snapshot_authorization )
     with
     | Ok server_t, Some graph, Some authorization when authorization.graph = graph ->
       let next, request_effect =
         issue_request core (Fetch_snapshot_metadata authorization)
       in
       { next = { next with snapshot_server_t = Some server_t }
       ; effects = [ Run request_effect ]
       }
     | Error message, _, _ -> fail core During_bootstrap message
     | Ok _, _, _ -> unchanged core)
  | Fetch_snapshot_metadata_kind ->
    (match decode_snapshot_uri value, core.snapshot_authorization with
     | Ok uri, Some scope ->
       let request =
         { scope
         ; uri
         ; expected_bytes = None
         ; maximum_bytes = core.config.limits.maximum_artifact_bytes
         }
       in
       let next, request_effect = issue_request core (Download_snapshot request) in
       { next = { next with active_snapshot_download = Some scope.graph }
       ; effects = [ Run request_effect ]
       }
     | Error message, _ -> fail core During_bootstrap message
     | Ok _, None -> unchanged core)
  | Download_snapshot_kind ->
    let core = { core with active_snapshot_download = None } in
    (match
       core.current_graph_scope, core.snapshot_server_t, core.selected_graph_value
     with
     | Some scope, Some applied_server_t, Some graph when graph.encrypted ->
       (match core.graph_key with
        | Some key when graph_key_handle_scope key = scope ->
          { next = core
          ; effects =
              [ Delegate
                  (Activate_snapshot
                     { artifact = value; scope; applied_server_t; key = Some key })
              ]
          }
        | None ->
          fail core During_bootstrap "encrypted snapshot requires a graph key handle"
        | Some _ ->
          fail
            core
            During_bootstrap
            "graph key handle is outside the selected graph scope")
     | Some scope, Some applied_server_t, Some _ ->
       { next = core
       ; effects =
           [ Delegate
               (Activate_snapshot
                  { artifact = value; scope; applied_server_t; key = None })
           ]
       }
     | _ -> unchanged core)
  | Load_and_unlock_graph_key_kind -> graph_key_loaded core value
  | Fetch_e2ee_graph_key_kind ->
    (match core.snapshot_authorization with
     | Some authorization ->
       let core = { core with pending_encrypted_graph_key = Some value } in
       let account =
         { account = authorization.graph.account; token = authorization.token }
       in
       let next, request = issue_request core (Fetch_e2ee_user_keys account) in
       { next; effects = [ Run request ] }
     | None -> unchanged core)
  | Fetch_e2ee_user_keys_kind ->
    let startup =
      { core.public_state.snapshot.startup with
        awaiting_e2ee_password = true
      ; failure = None
      }
    in
    let next =
      set_snapshot
        { core with pending_private_key_package = Some value }
        { core.public_state.snapshot with startup; last_error = None }
    in
    { next; effects = [ publish next ] }
  | Unlock_private_key_kind ->
    (match core.snapshot_authorization, core.pending_encrypted_graph_key with
     | Some scope, Some encrypted_graph_key ->
       let next, request =
         issue_request core (Fetch_and_unlock_graph_key { scope; encrypted_graph_key })
       in
       { next; effects = [ Run request ] }
     | _ -> unchanged core)
  | Fetch_and_unlock_graph_key_kind ->
    let core =
      { core with pending_encrypted_graph_key = None; pending_private_key_package = None }
    in
    graph_key_loaded core value
  | Delete_wrapped_graph_key_kind -> unchanged core
  | Delete_account_secrets_kind -> unchanged core
  | Encrypt_protected_values_kind -> unchanged core
  | Decrypt_protected_values_kind -> unchanged core
;;

let consume_completion core (Completion (ticket, result)) =
  match consume_ticket core ticket with
  | None -> unchanged core
  | Some core ->
    (match result with
     | Ok value -> complete_runner core ticket value
     | Error (Effect_failed message | Crypto_failed (_, message)) ->
       let core =
         match ticket.kind with
         | Download_snapshot_kind -> { core with active_snapshot_download = None }
         | _ -> core
       in
       (match ticket.kind with
        | Load_and_unlock_graph_key_kind -> fail core During_local_restore message
        | Fetch_e2ee_graph_key_kind
        | Fetch_e2ee_user_keys_kind
        | Fetch_and_unlock_graph_key_kind
        | Unlock_private_key_kind -> fail core During_e2ee message
        | Delete_wrapped_graph_key_kind ->
          cleanup_failed core "wrapped graph key cleanup failed"
        | Delete_account_secrets_kind ->
          cleanup_failed core "account secret cleanup failed"
        | Fetch_snapshot_baseline_kind
        | Fetch_snapshot_metadata_kind
        | Download_snapshot_kind -> fail core During_bootstrap message
        | _ -> fail core During_catalog message))
;;

let websocket_closed core connection message =
  if not (connection_is_current core connection)
  then unchanged core
  else (
    let next =
      set_snapshot
        { core with
          websocket_live = false
        ; pending_sync_inspection = None
        ; pending_outbox_transition = None
        ; submission_owner = None
        ; active_authoritative_batch = None
        ; queued_authoritative_batch = None
        ; deferred_authoritative_owner = None
        }
        { core.public_state.snapshot with sync_phase = Offline; last_error = message }
    in
    { next; effects = [ publish next ] })
;;

let return_to_graph_picker core =
  let detach =
    Option.fold
      ~none:[]
      ~some:(fun scope -> [ Delegate (Detach_graph scope) ])
      core.current_graph_scope
  in
  let startup =
    { core.public_state.snapshot.startup with
      awaiting_selection = true
    ; catalog_loading = false
    ; restoring_local = false
    ; bootstrapping = false
    ; awaiting_e2ee_password = false
    ; failure = None
    ; graph_generation = core.public_state.snapshot.startup.graph_generation + 1
    ; presentation_generation =
        core.public_state.snapshot.startup.presentation_generation + 1
    }
  in
  let next =
    set_snapshot
      { core with
        selected_graph_value = None
      ; current_graph_scope = None
      ; graph_key = None
      ; pending_graph_open = None
      ; pending_mirror_inspection = None
      ; pending_attachment = None
      ; pending_encrypted_graph_key = None
      ; pending_private_key_package = None
      ; snapshot_authorization = None
      ; snapshot_server_t = None
      ; active_snapshot_download = None
      ; sync_view = None
      ; pending_token = None
      ; pending_effects = []
      ; pending_sync_inspection = None
      ; pending_outbox_transition = None
      ; websocket_live = false
      ; submission_owner = None
      ; active_authoritative_batch = None
      ; queued_authoritative_batch = None
      ; deferred_authoritative_owner = None
      }
      { core.public_state.snapshot with
        sync_phase = Offline
      ; selected_graph = None
      ; applied_server_t = None
      ; timeline_presentation_pending = false
      ; startup
      ; last_error = None
      }
  in
  let cancel =
    Option.fold
      ~none:[]
      ~some:(fun scope -> [ Run (Cancel_effects (effect_scope_of_graph scope)) ])
      core.current_graph_scope
  in
  { next; effects = cancel @ detach @ [ publish next ] }
;;

let scoped_error_is_current core (error : scoped_error) =
  Option.fold
    ~none:false
    ~some:(fun (scope : graph_scope) -> effect_scope_of_graph scope = error.scope)
    core.current_graph_scope
;;

let inspect_sync core scope =
  match core.pending_sync_inspection with
  | None ->
    { next = { core with pending_sync_inspection = Some scope }
    ; effects = [ Delegate (Inspect_sync scope) ]
    }
  | Some _ -> unchanged core
;;

let step core event =
  if core.closed
  then unchanged core
  else (
    match event with
    | Restore_local_account { user_id } -> restore_local core user_id
    | Account_authenticated { user_id = Some user_id } -> authenticate core user_id
    | Account_authenticated { user_id = None } -> sign_out core
    | Local_outbox_changed ->
      (match core.current_graph_scope with
       | Some scope -> inspect_sync core scope
       | None -> unchanged core)
    | Token_provided (request, token) -> provide_token core request token
    | Token_rejected request ->
      if core.pending_token = Some request
      then
        fail
          { core with pending_token = None }
          During_authentication
          "token request rejected"
      else unchanged core
    | Runner_completed completion -> consume_completion core completion
    | Graph_selected graph_id -> select_graph core graph_id
    | Mirror_inspected inspection -> mirror_inspected core inspection
    | Graph_attached attachment -> graph_attached core attachment
    | Sync_inspected inspection ->
      if
        graph_scope_is_current core inspection.scope
        && core.pending_sync_inspection = Some inspection.scope
      then
        plan_submission
          { core with pending_sync_inspection = None; sync_view = Some inspection.sync }
      else unchanged core
    | Outbox_transition_applied result -> outbox_transition_applied core result
    | Websocket_opened connection -> websocket_opened core connection
    | Websocket_message (connection, message) -> websocket_message core connection message
    | Websocket_protocol_error (connection, error)
      when connection_is_current core connection ->
      fail core During_catalog (Sync_protocol.error_to_string error)
    | Websocket_protocol_error _ -> unchanged core
    | Websocket_closed (connection, message) -> websocket_closed core connection message
    | Authoritative_batch_applied result -> authoritative_applied core result
    | Authoritative_batch_deferred result -> authoritative_deferred core result
    | Snapshot_activated activation ->
      (match core.selected_graph_value with
       | Some graph when graph_scope_is_current core activation.scope ->
         let request = { graph; scope = activation.scope } in
         { next = { core with pending_mirror_inspection = Some request }
         ; effects = [ Delegate (Inspect_mirror request) ]
         }
       | _ -> unchanged core)
    | Snapshot_download_progress progress ->
      (match core.active_snapshot_download with
       | Some scope
         when graph_scope_is_current core scope
              && Logseq_db_types.Graph_types.Uuid.equal scope.graph_id progress.graph_id
         -> { next = core; effects = [ Publish (Bootstrap_progressed progress) ] }
       | None | Some _ -> unchanged core)
    | Graph_picker_requested -> return_to_graph_picker core
    | Catalog_refresh_requested ->
      (match core.user_id with
       | None -> unchanged core
       | Some _ ->
         let next, token = issue_token core Catalog_discovery in
         { next; effects = [ token ] })
    | Online_recovery_requested ->
      (match core.current_graph_scope, core.public_state.snapshot.startup.failure with
       | Some _, Some During_local_restore ->
         let startup =
           { core.public_state.snapshot.startup with
             awaiting_e2ee_password = false
           ; failure = None
           }
         in
         let core =
           set_snapshot
             core
             { core.public_state.snapshot with
               sync_phase = Offline
             ; startup
             ; last_error = None
             }
         in
         let next, token = issue_token core E2ee_key_access in
         { next; effects = [ publish next; token ] }
       | Some scope, _ -> inspect_sync core scope
       | None, _ -> unchanged core)
    | Local_cache_deletion_requested graph_id ->
      let scope =
        match core.current_graph_scope with
        | Some scope -> effect_scope_of_graph scope
        | None ->
          { account_generation = None
          ; graph_generation = None
          ; connection_generation = None
          ; presentation_generation = None
          ; lifecycle_generation = None
          }
      in
      let mirror = Delegate (Delete_mirror { graph_id; scope }) in
      (match core.user_id with
       | None -> { next = core; effects = [ mirror ] }
       | Some user_id ->
         let account = account_scope core user_id in
         let next, deletion =
           issue_request core (Delete_wrapped_graph_key { account; graph_id })
         in
         { next; effects = [ mirror; Run deletion ] })
    | Foreground_changed { foreground = false; lifecycle_generation } ->
      let core =
        { core with
          lifecycle_generation
        ; websocket_live = false
        ; pending_sync_inspection = None
        ; pending_outbox_transition = None
        ; submission_owner = None
        ; active_authoritative_batch = None
        ; queued_authoritative_batch = None
        ; deferred_authoritative_owner = None
        }
      in
      (match core.current_graph_scope with
       | None -> unchanged core
       | Some graph ->
         { next = core
         ; effects =
             [ Run
                 (Close_websocket
                    { graph; connection_generation = core.connection_generation })
             ]
         })
    | Foreground_changed { foreground = true; lifecycle_generation } ->
      let core = { core with lifecycle_generation } in
      (match core.current_graph_scope with
       | None -> unchanged core
       | Some _ ->
         let next, token = issue_token core Websocket_connect in
         { next; effects = [ token ] })
    | Timeline_presented ->
      let next =
        set_snapshot
          core
          { core.public_state.snapshot with timeline_presentation_pending = false }
      in
      { next; effects = [ publish next ] }
    | Graph_attachment_failed error
    | Authoritative_batch_failed error
    | Snapshot_activation_failed error
      when scoped_error_is_current core error -> fail core During_bootstrap error.message
    | Graph_attachment_failed _
    | Authoritative_batch_failed _
    | Snapshot_activation_failed _ -> unchanged core
    | E2ee_password_submitted password ->
      (match
         ( core.snapshot_authorization
         , core.pending_private_key_package
         , core.public_state.snapshot.startup.awaiting_e2ee_password )
       with
       | Some authorization, Some private_key_package, true ->
         let startup =
           { core.public_state.snapshot.startup with awaiting_e2ee_password = false }
         in
         let core = set_snapshot core { core.public_state.snapshot with startup } in
         let scope =
           { account = authorization.graph.account; token = authorization.token }
         in
         let next, request =
           issue_request
             core
             (Unlock_private_key { scope; password; private_key_package })
         in
         { next; effects = [ publish next; Run request ] }
       | _ -> unchanged core)
    | Local_feed_acknowledged | Timer_elapsed _ -> unchanged core
    | Shutdown ->
      let scope =
        { account_generation = None
        ; graph_generation = None
        ; connection_generation = None
        ; presentation_generation = None
        ; lifecycle_generation = None
        }
      in
      { next =
          { core with
            closed = true
          ; pending_token = None
          ; pending_effects = []
          ; pending_graph_open = None
          ; pending_mirror_inspection = None
          ; pending_attachment = None
          ; active_snapshot_download = None
          ; pending_sync_inspection = None
          ; pending_outbox_transition = None
          ; submission_owner = None
          ; active_authoritative_batch = None
          ; queued_authoritative_batch = None
          ; deferred_authoritative_owner = None
          }
      ; effects = [ Run (Cancel_effects scope) ]
      })
;;
