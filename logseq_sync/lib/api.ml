module Private = struct
  module Action = Action
  module Artifact_decoder = Artifact_decoder
  module Auth = Auth
  module Bootstrap = Bootstrap
  module Catalog = Catalog
  module Catalog_store = Catalog_store
  module E2ee = E2ee
  module Graph_key = Graph_key
  module Http = Http
  module Http_eio = Http_eio
  module Mirror = Mirror
  module Network_scope = Network_scope
  module Platform_crypto = Platform_crypto
  module Protocol = Protocol
  module Startup_phase = Startup_phase
  module Websocket_eio = Websocket_eio
end

exception Network_cancelled

type graph_id = Logseq_db_types.Graph_types.Uuid.t
type graph = Logseq_db_types.Managed_graph.t

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
  ; account_generation : int
  ; graph_generation : int
  ; presentation_generation : int
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

type token_purpose =
  | Catalog_discovery
  | Snapshot_bootstrap
  | E2ee_key_access
  | Websocket_connect

type token_request = Auth.challenge

let token_request_id request = request.Auth.challenge_id

let token_request_purpose request =
  match request.Auth.purpose with
  | Catalog_discovery -> Catalog_discovery
  | Snapshot_bootstrap -> Snapshot_bootstrap
  | E2ee_key_access -> E2ee_key_access
  | Websocket_connect -> Websocket_connect
;;

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

type outbox_record = Pending.entry

type graph_open_request =
  { graph : graph
  ; graph_directory : string
  ; database_path : string
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; account_generation : int
  ; graph_generation : int
  }

type authoritative_batch =
  { payload : string
  ; account_generation : int
  ; graph_generation : int
  ; connection_generation : int
  ; presentation_generation : int
  ; lifecycle_generation : int64
  }

let authoritative_batch_payload batch = batch.payload

let authoritative_batch_scope batch =
  ( batch.account_generation
  , batch.graph_generation
  , batch.connection_generation
  , batch.presentation_generation
  , batch.lifecycle_generation )
;;

type authoritative_commit =
  { transactions : Datascript.tx_op list list
  ; checkpoint : Logseq_db_types.Sync_checkpoint.t
  ; outbox_records : string list
  ; activity : Logseq_db_types.Sync_status.activity
  }

type authoritative_plan =
  | No_authoritative_commit of
      { checkpoint : Logseq_db_types.Sync_checkpoint.t
      ; outbox_records : string list
      ; activity : Logseq_db_types.Sync_status.activity
      }
  | Commit_authoritative of authoritative_commit

type outbox_transition =
  { account_generation : int
  ; graph_generation : int
  ; presentation_generation : int
  ; lifecycle_generation : int64
  ; expected_outbox_records : string list
  ; outbox_records : string list
  ; pending_payload : string option
  }

let outbox_transition_scope transition =
  ( transition.account_generation
  , transition.graph_generation
  , transition.presentation_generation
  , transition.lifecycle_generation )
;;

let outbox_transition_records transition = transition.outbox_records
let outbox_transition_expected_records transition = transition.expected_outbox_records
let outbox_transition_pending_payload transition = transition.pending_payload

type local_operation =
  | Local_action : Private.Action.local Private.Action.t -> local_operation
  | Activate_snapshot_local of Private.Action.activate_snapshot
  | Load_catalog_local of string
  | Save_catalog_local of Private.Catalog.cache

type completion = Manager.event

type sync_effect =
  | State_changed of state
  | Token_requested of token_request
  | Bootstrap_progressed of bootstrap_progress
  | Graph_invalidated of invalidation
  | Attach_graph of graph_open_request
  | Detach_graph of { graph_generation : int }
  | Apply_authoritative_batch of authoritative_batch
  | Commit_outbox_transition of outbox_transition
  | Run_local_operation of local_operation
  | Resume of completion

type event =
  | Restore_local_account of { user_id : string }
  | Account_authenticated of { user_id : string option }
  | Local_feed_acknowledged
  | Timeline_presented
  | Token_provided of token_request * string
  | Token_rejected of token_request
  | Graph_selected of graph_id
  | Graph_picker_requested
  | Catalog_refresh_requested
  | Online_recovery_requested
  | E2ee_password_submitted of string
  | Local_cache_deletion_requested of graph_id
  | Foreground_changed of bool
  | Graph_attached of
      { account_generation : int
      ; graph_generation : int
      ; checkpoint : Logseq_db_types.Sync_checkpoint.t
      ; outbox_records : string list
      }
  | Graph_attachment_failed of
      { account_generation : int
      ; graph_generation : int
      ; message : string
      }
  | Local_batch_committed of { outbox_records : string list }
  | Authoritative_batch_applied of
      { account_generation : int
      ; graph_generation : int
      ; checkpoint : Logseq_db_types.Sync_checkpoint.t
      ; outbox_records : string list
      ; activity : Logseq_db_types.Sync_status.activity
      ; invalidation : invalidation option
      }
  | Authoritative_batch_failed of
      { account_generation : int
      ; graph_generation : int
      ; message : string
      }
  | Outbox_transition_committed of
      { outbox_records : string list
      ; pending_payload : string option
      }
  | Outbox_transition_rejected of
      { outbox_records : string list
      ; message : string
      }
  | Shutdown

let graph_open_request_graph (request : graph_open_request) = request.graph

let graph_open_request_graph_directory (request : graph_open_request) =
  request.graph_directory
;;

let graph_open_request_database_path (request : graph_open_request) =
  request.database_path
;;

let graph_open_request_checkpoint (request : graph_open_request) = request.checkpoint

let graph_open_request_account_generation (request : graph_open_request) =
  request.account_generation
;;

let graph_open_request_generation (request : graph_open_request) =
  request.graph_generation
;;

type crypto = E2ee.crypto =
  { decrypt_private_key :
      password:string
      -> iterations:int
      -> salt:string
      -> iv:string
      -> ciphertext:string
      -> (string, string) result
  ; decrypt_graph_key : private_key:string -> ciphertext:string -> (string, string) result
  ; encrypt_aes_gcm : key:string -> plaintext:string -> (string * string, string) result
  ; decrypt_aes_gcm :
      key:string -> iv:string -> ciphertext:string -> (string, string) result
  }

type wrapped_key_load_error =
  | Wrapped_graph_key_unavailable of string
  | Local_private_key_unavailable of string

type secrets =
  { has_private_key : managed_sync_origin:Uri.t -> user_id:string -> bool
  ; unlock_private_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> password:string
      -> private_key_package:string
      -> (unit, string) result
  ; unlock_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> encrypted_graph_key:string
      -> (string, string) result
  ; load_and_verify_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:graph_id
      -> (string, wrapped_key_load_error) result
  ; verify_and_save_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:graph_id
      -> encrypted_graph_key:string
      -> (unit, string) result
  ; delete_wrapped_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> graph_id:graph_id
      -> (unit, string) result
  ; delete_account_secrets :
      managed_sync_origin:Uri.t -> user_id:string -> (unit, string) result
  }

let secrets
      ~has_private_key
      ~unlock_private_key
      ~unlock_graph_key
      ~load_and_verify_wrapped_graph_key
      ~verify_and_save_wrapped_graph_key
      ~delete_wrapped_graph_key
      ~delete_account_secrets
  =
  Ok
    { has_private_key
    ; unlock_private_key
    ; unlock_graph_key
    ; load_and_verify_wrapped_graph_key
    ; verify_and_save_wrapped_graph_key
    ; delete_wrapped_graph_key
    ; delete_account_secrets
    }
;;

let crypto ~decrypt_private_key ~decrypt_graph_key ~encrypt_aes_gcm ~decrypt_aes_gcm =
  Ok { decrypt_private_key; decrypt_graph_key; encrypt_aes_gcm; decrypt_aes_gcm }
;;

let apple_secrets () =
  secrets
    ~has_private_key:Private.Platform_crypto.has_private_key
    ~unlock_private_key:Private.Platform_crypto.unlock_private_key
    ~unlock_graph_key:Private.Platform_crypto.unlock_graph_key
    ~load_and_verify_wrapped_graph_key:(fun ~managed_sync_origin ~user_id ~graph_id ->
      match
        Private.Platform_crypto.load_and_verify_wrapped_graph_key
          ~managed_sync_origin
          ~user_id
          ~graph_id
      with
      | Ok key -> Ok key
      | Error (Wrapped_graph_key_unavailable message) ->
        Error (Wrapped_graph_key_unavailable message)
      | Error (Local_private_key_unavailable message) ->
        Error (Local_private_key_unavailable message))
    ~verify_and_save_wrapped_graph_key:
      Private.Platform_crypto.verify_and_save_wrapped_graph_key
    ~delete_wrapped_graph_key:Private.Platform_crypto.delete_wrapped_graph_key
    ~delete_account_secrets:Private.Platform_crypto.delete_account_secrets
;;

let apple_crypto () =
  let adapter = Private.Platform_crypto.crypto in
  crypto
    ~decrypt_private_key:adapter.decrypt_private_key
    ~decrypt_graph_key:adapter.decrypt_graph_key
    ~encrypt_aes_gcm:adapter.encrypt_aes_gcm
    ~decrypt_aes_gcm:adapter.decrypt_aes_gcm
;;

type dependency_error = Invalid_dependency of string
type config_error = Invalid_config of string
type create_error = Invalid_create of string

type limits =
  { maximum_response_bytes : int
  ; maximum_artifact_bytes : int
  ; submission_batch_size : int
  }

let limits ~maximum_response_bytes ~maximum_artifact_bytes ~submission_batch_size =
  if
    maximum_response_bytes <= 0
    || maximum_response_bytes > Logseq_db_types.Limits.maximum_response_bytes
  then Error (Invalid_config "maximum response bytes are outside the supported bound")
  else if maximum_artifact_bytes <= 0
  then Error (Invalid_config "maximum artifact bytes must be positive")
  else if submission_batch_size <= 0 || submission_batch_size > 4096
  then Error (Invalid_config "pending batch size is outside the supported bound")
  else Ok { maximum_response_bytes; maximum_artifact_bytes; submission_batch_size }
;;

type config =
  { managed_sync_origin : Uri.t
  ; limits : limits
  }

let config ~managed_sync_origin ~limits =
  match Private.Http.validate_base_url managed_sync_origin with
  | Ok () -> Ok { managed_sync_origin; limits }
  | Error message -> Error (Invalid_config message)
;;

type runtime =
  { fork : sw:Eio.Switch.t -> (unit -> unit) -> unit
  ; sleep : float -> unit
  ; monotonic_ns : unit -> int64
  }

let runtime ~fork ~sleep ~monotonic_ns = Ok { fork; sleep; monotonic_ns }

type transport =
  { perform_http :
      sw:Eio.Switch.t
      -> Private.Http.request
      -> (Private.Http_eio.response, string) result
  ; download :
      sw:Eio.Switch.t
      -> request:Private.Http.request
      -> destination:string
      -> maximum_bytes:int
      -> on_progress:(Private.Bootstrap.progress -> unit)
      -> (Private.Http_eio.response, string) result
  ; connect_websocket :
      sw:Eio.Switch.t
      -> uri:Uri.t
      -> token:string
      -> maximum_frame_bytes:int
      -> on_message:(string -> unit)
      -> on_close:(string option -> unit)
      -> (Private.Websocket_eio.t, string) result
  ; send_websocket : Private.Websocket_eio.t -> string -> (unit, string) result
  ; close_websocket : Private.Websocket_eio.t -> unit
  }

let transport ~network ~clock =
  Ok
    { perform_http =
        (fun ~sw request -> Private.Http_eio.perform ~sw ~network ~clock request)
    ; download =
        (fun ~sw ~request ~destination ~maximum_bytes ~on_progress ->
          Private.Http_eio.download
            ~sw
            ~network
            ~clock
            ~request
            ~destination
            ~maximum_bytes
            ~on_progress)
    ; connect_websocket =
        (fun ~sw ~uri ~token ~maximum_frame_bytes ~on_message ~on_close ->
          Private.Websocket_eio.connect
            ~sw
            ~network
            ~clock
            ~uri
            ~token
            ~maximum_frame_bytes
            ~on_message
            ~on_close)
    ; send_websocket = Private.Websocket_eio.send
    ; close_websocket = Private.Websocket_eio.close
    }
;;

let valid_directory path =
  (not (Filename.is_relative path))
  && Sys.file_exists path
  && (Unix.stat path).st_kind = Unix.S_DIR
;;

type local_store =
  { load_catalog :
      user_id:string -> base_url:string -> (Private.Catalog.cache option, string) result
  ; save_catalog : Private.Catalog.cache -> (unit, string) result
  ; resolve_mirror :
      graph_id:graph_id -> (Private.Mirror.resolved, Private.Mirror.error) result
  ; bootstrap_mirror :
      graph_id:graph_id
      -> applied_server_t:int
      -> checksum:string option
      -> expected_rows:int
      -> snapshot_path:string
      -> decrypt_protected:(string -> (string, string) result) option
      -> (Private.Mirror.resolved, Private.Mirror.error) result
  ; delete_mirror : graph_id:graph_id -> (unit, Private.Mirror.error) result
  }

let local_store ~application_support_directory =
  if valid_directory application_support_directory
  then
    Ok
      { load_catalog =
          (fun ~user_id ~base_url ->
            Private.Catalog_store.load ~application_support_directory ~user_id ~base_url)
      ; save_catalog =
          (fun cache -> Private.Catalog_store.save ~application_support_directory cache)
      ; resolve_mirror =
          (fun ~graph_id ->
            Private.Mirror.resolve ~application_support_directory ~graph_id)
      ; bootstrap_mirror =
          (fun ~graph_id
            ~applied_server_t
            ~checksum
            ~expected_rows
            ~snapshot_path
            ~decrypt_protected ->
            Private.Mirror.bootstrap
              ~application_support_directory
              ~graph_id
              ~applied_server_t
              ?checksum
              ~expected_rows
              ~snapshot_path
              ?decrypt_protected
              ())
      ; delete_mirror =
          (fun ~graph_id ->
            Private.Mirror.delete ~application_support_directory ~graph_id)
      }
  else Error (Invalid_dependency "application-support directory must exist")
;;

type artifact_paths =
  { artifact : string
  ; snapshot : string
  ; temporary_paths : string list
  }

type artifact_store =
  { allocate :
      graph_generation:int -> graph_id:graph_id -> (artifact_paths, string) result
  ; cleanup : string list -> unit
  ; peel_gzip_layers : maximum_bytes:int -> artifact_paths -> (unit, string) result
  ; remove : string -> unit
  ; file_size : string -> int
  }

let artifact_store ~staging_directory =
  let parent = Filename.dirname staging_directory in
  if Filename.is_relative staging_directory || not (valid_directory parent)
  then Error (Invalid_dependency "artifact staging parent must exist")
  else (
    let ensure_private_directory path =
      if Sys.file_exists path
      then
        if (Unix.stat path).st_kind = Unix.S_DIR
        then Ok ()
        else Error "staging path is not a directory"
      else (
        try
          Unix.mkdir path 0o700;
          Ok ()
        with
        | exception_ -> Error (Printexc.to_string exception_))
    in
    let remove path =
      try Sys.remove path with
      | Sys_error _ -> ()
    in
    Ok
      { allocate =
          (fun ~graph_generation ~graph_id ->
            let directory =
              Filename.concat
                staging_directory
                (Printf.sprintf
                   "%s-%d"
                   (Logseq_db_types.Graph_types.Uuid.to_string graph_id)
                   graph_generation)
            in
            Result.bind (ensure_private_directory staging_directory) (fun () ->
              Result.map
                (fun () ->
                   { artifact = Filename.concat directory "artifact.part"
                   ; snapshot = Filename.concat directory "snapshot.transit"
                   ; temporary_paths =
                       [ Filename.concat directory "gzip-1.part"
                       ; Filename.concat directory "gzip-2.part"
                       ]
                   })
                (ensure_private_directory directory)))
      ; cleanup = Private.Bootstrap.cleanup
      ; peel_gzip_layers =
          (fun ~maximum_bytes paths ->
            Private.Bootstrap.peel_gzip_layers
              ~decompress_gzip:Private.Artifact_decoder.decompress_gzip
              ~maximum_bytes
              ~source:paths.artifact
              ~destination:paths.snapshot
              ~temporary_paths:paths.temporary_paths)
      ; remove
      ; file_size = (fun path -> (Unix.stat path).st_size)
      })
;;

type dependencies =
  { runtime : runtime
  ; transport : transport
  ; artifact_store : artifact_store
  ; secrets : secrets
  ; crypto : crypto
  ; on_effect : sync_effect -> unit
  }

let dependencies ~runtime ~transport ~artifact_store ~secrets ~crypto ~on_effect =
  Ok { runtime; transport; artifact_store; secrets; crypto; on_effect }
;;

type request =
  | Manager_command of Manager.command
  | Stop

type response = Manager_state of Manager.state

type push =
  | Manager_state_changed of Manager.state
  | Need_id_token of Private.Auth.challenge
  | Bootstrap_progress of
      { account_generation : int
      ; graph_generation : int
      ; progress : Private.Bootstrap.progress
      }

let manager_topic = 1
let auth_topic = 2
let bootstrap_topic = 3

type websocket_control =
  | Websocket_send of string
  | Websocket_close

type message =
  | Handle of request * (response, string) result Eio.Promise.u
  | Network_finished of Network_scope.operation_id

type managed =
  { sw : Eio.Switch.t
  ; runtime : runtime
  ; transport : transport
  ; artifact_store : artifact_store
  ; secrets : secrets
  ; crypto : crypto
  ; config : config
  ; base_url : Uri.t
  ; on_effect : sync_effect -> unit
  ; mutable effect_collector : sync_effect list ref option
  ; manager : Manager.t
  ; messages : message Eio.Stream.t
  ; mutable attached_checkpoint : Logseq_db_types.Sync_checkpoint.t option
  ; mutable outbox : Pending.entry list
  ; mutable outbox_transition_in_flight : bool
  ; mutable graph_key : Graph_key.t option
  ; mutable websocket : websocket_control Eio.Stream.t option
  ; mutable catalog_cache : Private.Catalog.cache option
  ; mutable catalog_dirty : bool
  ; mutable catalog_flush_in_flight : bool
  ; network_scope : Network_scope.t
  ; mutable lifecycle_generation : int64
  ; mutable closed : bool
  }

type t = managed

let emit_public_effect runtime output =
  match runtime.effect_collector with
  | None -> runtime.on_effect output
  | Some effects -> effects := output :: !effects
;;

let decode_outbox_records = Pending.decode
let encode_outbox_records = Pending.encode
let outbox_record_mutation_id (record : outbox_record) = record.mutation_id
let outbox_record_fingerprint (record : outbox_record) = record.mutation_fingerprint

let prepare_local_batch
      runtime
      ~outbox
      ~mutation_id
      ~mutation_payload
      ~mutation_fingerprint
      ~outliner_op
      ~database
      ~operations
  =
  let encrypt_protected =
    Option.map
      (fun graph_key plaintext ->
         Graph_key.encrypt_value
           ~crypto:runtime.crypto
           graph_key
           (Transit_core.Json.String plaintext))
      runtime.graph_key
  in
  Result.bind
    (Tx_encoder.encode ?encrypt_protected database operations)
    (fun encoded_tx ->
       let entry =
         Pending.
           { mutation_id
           ; mutation_payload
           ; mutation_fingerprint
           ; encoded_tx
           ; outliner_op
           ; state = Queued
           }
       in
       Pending.append_entry outbox entry)
;;

let restore_outbox_projection runtime ~database ~outbox_records =
  let decrypt_protected =
    Option.map
      (fun graph_key ~attribute:_ ciphertext ->
         Graph_key.decrypt_value ~crypto:runtime.crypto graph_key ciphertext)
      runtime.graph_key
  in
  Result.bind (Pending.decode outbox_records) (fun outbox ->
    let rec decode current transactions = function
      | [] -> Ok (List.rev transactions)
      | (entry : Pending.entry) :: rest ->
        Result.bind
          (Tx.decode ?decrypt_protected ~db:current entry.encoded_tx)
          (fun operations ->
             try
               decode
                 (Datascript.db_with operations current)
                 (operations :: transactions)
                 rest
             with
             | exn -> Error (Printexc.to_string exn))
    in
    decode database [] outbox)
;;

let public_sync_phase (diagnostics : Manager.diagnostics) =
  match diagnostics.phase with
  | Failed -> Failed
  | Sync_paused -> Paused
  | _ ->
    (match diagnostics.pull, diagnostics.serialization with
     | Diagnostic_pull_in_flight _, _ | _, Diagnostic_serialization_applying_pull ->
       Pulling
     | Diagnostic_pull_idle, _ ->
       (match diagnostics.submission, diagnostics.serialization with
        | (Diagnostic_submission_deferred _ | Diagnostic_submission_in_flight _), _
        | _, Diagnostic_serialization_applying_transaction -> Submitting
        | Diagnostic_submission_none, _ ->
          (match diagnostics.transport, diagnostics.websocket_initialized with
           | Live, Some true -> Current
           | (Awaiting_token | Connecting | Revalidating | Backing_off), _ -> Connecting
           | Disconnected, _ | Live, (None | Some false) ->
             (match diagnostics.phase with
              | Awaiting_token _ | Loading_catalog | Bootstrapping | Recovering_online _
                -> Connecting
              | Signed_out
              | Awaiting_selection
              | Awaiting_e2ee_password
              | Opening_graph
              | Graph_open
              | Stopping_graph -> Offline
              | Sync_paused | Failed -> assert false))))
;;

let public_startup_facts (snapshot : Manager.snapshot) =
  let catalog_loading =
    match snapshot.phase with
    | Awaiting_token Catalog_discovery | Loading_catalog -> true
    | Signed_out
    | Awaiting_token _
    | Awaiting_selection
    | Bootstrapping
    | Recovering_online _
    | Awaiting_e2ee_password
    | Opening_graph
    | Graph_open
    | Sync_paused
    | Stopping_graph
    | Failed -> false
  in
  let bootstrapping =
    match snapshot.phase with
    | Awaiting_token Snapshot_bootstrap | Bootstrapping | Recovering_online _ -> true
    | Signed_out
    | Awaiting_token _
    | Loading_catalog
    | Awaiting_selection
    | Awaiting_e2ee_password
    | Opening_graph
    | Graph_open
    | Sync_paused
    | Stopping_graph
    | Failed -> false
  in
  let awaiting_e2ee_password =
    match snapshot.phase with
    | Awaiting_token E2ee_key_access | Awaiting_e2ee_password -> true
    | Signed_out
    | Awaiting_token _
    | Loading_catalog
    | Awaiting_selection
    | Bootstrapping
    | Recovering_online _
    | Opening_graph
    | Graph_open
    | Sync_paused
    | Stopping_graph
    | Failed -> false
  in
  let failure =
    match
      snapshot.phase, snapshot.user_id, snapshot.selected_graph, snapshot.applied_server_t
    with
    | Failed, None, _, _ -> Some During_authentication
    | Failed, Some _, None, _ -> Some During_catalog
    | Failed, Some _, Some _, None -> Some During_bootstrap
    | Failed, Some _, Some _, Some _ -> None
    | ( ( Signed_out
        | Awaiting_token _
        | Loading_catalog
        | Awaiting_selection
        | Bootstrapping
        | Recovering_online _
        | Awaiting_e2ee_password
        | Opening_graph
        | Graph_open
        | Sync_paused
        | Stopping_graph )
      , _
      , _
      , _ ) -> None
  in
  { authenticated = Option.is_some snapshot.user_id
  ; catalog_loading
  ; awaiting_selection = snapshot.phase = Awaiting_selection
  ; restoring_local =
      (Option.is_some snapshot.selected_graph
       &&
       match snapshot.startup_presentation with
       | Restoring_local | Local_feed_ready -> true
       | Timeline_presented | Reconciled -> false)
  ; bootstrapping
  ; awaiting_e2ee_password
  ; failure
  ; account_generation = snapshot.account_generation
  ; graph_generation = snapshot.graph_generation
  ; presentation_generation = snapshot.presentation_generation
  }
;;

let public_snapshot (manager_state : Manager.state) =
  let snapshot = manager_state.snapshot in
  { sync_phase = public_sync_phase manager_state.diagnostics
  ; catalog = snapshot.catalog
  ; selected_graph = snapshot.selected_graph
  ; applied_server_t = snapshot.applied_server_t
  ; timeline_presentation_pending =
      (match snapshot.startup_presentation with
       | Restoring_local | Local_feed_ready -> true
       | Timeline_presented | Reconciled -> false)
  ; startup = public_startup_facts snapshot
  ; last_error = snapshot.last_error
  }
;;

let sync_phase_name = function
  | Offline -> "Offline"
  | Connecting -> "Connecting"
  | Pulling -> "Pulling"
  | Submitting -> "Submitting"
  | Current -> "Current"
  | Paused -> "Paused"
  | Failed -> "Failed"
;;

let optional_diagnostic_value render = function
  | None -> "Not available"
  | Some value -> render value
;;

let bool_diagnostic_value value = if value then "true" else "false"

let diagnostic_history_lines history =
  List.concat_map
    (fun (entry : Manager.diagnostic_history_entry) ->
       List.map
         (fun (change : Manager.diagnostic_change) ->
            Printf.sprintf
              "#%d %s: %s -> %s"
              entry.sequence
              (Manager.diagnostic_change_category_name change.category)
              change.before
              change.after)
         entry.changes)
    history
;;

let public_diagnostics (diagnostics : Manager.diagnostics) =
  let phase = public_sync_phase diagnostics in
  let group title entries = { title; entries } in
  { groups =
      [ group
          "Manager"
          [ "Sync phase", sync_phase_name phase
          ; ( "Startup presentation"
            , Manager.startup_presentation_name diagnostics.startup_presentation )
          ; "Last error", Option.value diagnostics.last_error ~default:"None"
          ]
      ; group
          "Scope fences"
          [ "Account generation", string_of_int diagnostics.account_generation
          ; "Graph generation", string_of_int diagnostics.graph_generation
          ; "Presentation generation", string_of_int diagnostics.presentation_generation
          ; "Connection generation", string_of_int diagnostics.connection_generation
          ]
      ; group
          "Graph"
          [ "Graph selected", bool_diagnostic_value diagnostics.graph_selected
          ; ( "Selected graph"
            , optional_diagnostic_value
                Logseq_db_types.Graph_types.Uuid.to_string
                diagnostics.selected_graph )
          ; ( "Applied server transaction"
            , optional_diagnostic_value string_of_int diagnostics.applied_server_t )
          ]
      ; group
          "Transport"
          [ ( "Transport scope"
            , Manager.diagnostic_transport_scope_name diagnostics.transport_scope )
          ; "Transport", Manager.diagnostic_transport_name diagnostics.transport
          ; ( "WebSocket initialized"
            , optional_diagnostic_value
                bool_diagnostic_value
                diagnostics.websocket_initialized )
          ]
      ; group "Pull" [ "Pull", Manager.diagnostic_pull_name diagnostics.pull ]
      ; group
          "Submission"
          [ "Submission", Manager.diagnostic_submission_name diagnostics.submission ]
      ; group
          "Recovery"
          [ "Reconnect attempt", string_of_int diagnostics.reconnect_attempt
          ; ( "Uncertain transactions"
            , string_of_int diagnostics.uncertain_transaction_count )
          ]
      ; group
          "Serialization"
          [ ( "Serialization"
            , Manager.diagnostic_serialization_name diagnostics.serialization )
          ]
      ; group
          "Authorization"
          [ ( "Pending token challenges"
            , string_of_int diagnostics.pending_token_challenge_count )
          ]
      ]
  ; history = diagnostic_history_lines diagnostics.history
  }
;;

let public_state (manager_state : Manager.state) =
  { snapshot = public_snapshot manager_state
  ; diagnostics = public_diagnostics manager_state.diagnostics
  }
;;

let emit runtime ~topic:_ = function
  | Manager_state_changed state ->
    emit_public_effect runtime (State_changed (public_state state))
  | Need_id_token request -> emit_public_effect runtime (Token_requested request)
  | Bootstrap_progress { progress; _ } ->
    Option.iter
      (fun graph_id ->
         emit_public_effect
           runtime
           (Bootstrap_progressed
              { graph_id
              ; received_bytes = Int64.of_int progress.received_bytes
              ; total_bytes = Option.map Int64.of_int progress.total_bytes
              }))
      (Manager.snapshot runtime.manager).selected_graph
;;

let publish_manager runtime =
  emit
    runtime
    ~topic:manager_topic
    (Manager_state_changed (Manager.state runtime.manager))
;;

let enqueue runtime event = emit_public_effect runtime (Resume event)
let status_ok status = status >= 200 && status < 300

let network_error
      runtime
      ~account_generation
      ?graph_generation
      ?connection_generation
      message
  =
  enqueue
    runtime
    (Manager.Network_failed
       { account_generation; graph_generation; connection_generation; message })
;;

let fork_network
      runtime
      ~name
      ~account_generation
      ?graph_generation
      ?connection_generation
      operation
  =
  let cancelled, cancel = Eio.Promise.create () in
  let _started_at_ns = runtime.runtime.monotonic_ns () in
  let operation_id =
    Network_scope.register
      runtime.network_scope
      ~account_generation
      ~graph_generation
      ~cancel:(fun () -> ignore (Eio.Promise.try_resolve cancel () : bool))
  in
  ignore name;
  runtime.runtime.fork ~sw:runtime.sw (fun () ->
    Fun.protect
      ~finally:(fun () -> Eio.Stream.add runtime.messages (Network_finished operation_id))
      (fun () ->
         try
           Eio.Fiber.first
             (fun () -> Eio.Switch.run operation)
             (fun () ->
                Eio.Promise.await cancelled;
                raise Network_cancelled)
         with
         | Network_cancelled | Eio.Cancel.Cancelled Network_cancelled -> ()
         | exception_ ->
           network_error
             runtime
             ~account_generation
             ?graph_generation
             ?connection_generation
             (Printexc.to_string exception_)))
;;

let cancel_obsolete_network runtime =
  let snapshot = Manager.snapshot runtime.manager in
  Network_scope.cancel_obsolete
    runtime.network_scope
    ~account_generation:snapshot.account_generation
    ~graph_generation:snapshot.graph_generation
;;

let perform_http
      runtime
      ~name
      request
      on_success
      ~account_generation
      ?graph_generation
      ?connection_generation
      ()
  =
  fork_network
    runtime
    ~name
    ~account_generation
    ?graph_generation
    ?connection_generation
    (fun sw ->
       match runtime.transport.perform_http ~sw request with
       | Ok response when status_ok response.status -> on_success response
       | Ok response ->
         network_error
           runtime
           ~account_generation
           ?graph_generation
           ?connection_generation
           (Printf.sprintf "sync HTTP request failed with status %d" response.status)
       | Error message ->
         network_error
           runtime
           ~account_generation
           ?graph_generation
           ?connection_generation
           message)
;;

let close_websocket runtime =
  match runtime.websocket with
  | None -> ()
  | Some controls ->
    runtime.websocket <- None;
    Eio.Stream.add controls Websocket_close
;;

let detach_graph runtime =
  Option.iter Graph_key.clear runtime.graph_key;
  runtime.graph_key <- None;
  runtime.attached_checkpoint <- None;
  runtime.outbox <- [];
  runtime.outbox_transition_in_flight <- false;
  let snapshot = Manager.snapshot runtime.manager in
  emit_public_effect
    runtime
    (Detach_graph { graph_generation = snapshot.graph_generation })
;;

let uuid_exn value = Logseq_db_types.Graph_types.Uuid.of_string value |> Result.get_ok
let catalog_graph (graph : Private.Action.graph) : Private.Catalog.graph = graph

let challenge_from_scoped (challenge : Private.Action.scoped_challenge) =
  let account, graph_generation, connection_generation =
    match challenge.scope with
    | Account_scope account -> account, None, None
    | Graph_scope graph -> graph.account, Some graph.graph_generation, None
    | Connection_scope connection ->
      ( connection.graph.account
      , Some connection.graph.graph_generation
      , Some connection.connection_generation )
  in
  let purpose =
    match challenge.purpose with
    | Catalog_discovery_name -> Private.Auth.Catalog_discovery
    | Snapshot_bootstrap_name -> Snapshot_bootstrap
    | E2ee_key_access_name -> E2ee_key_access
    | Websocket_connect_name -> Websocket_connect
  in
  Private.Auth.
    { challenge_id = challenge.challenge_id
    ; purpose
    ; user_id = account.user_id
    ; account_generation = account.account_generation
    ; graph_generation
    ; connection_generation
    }
;;

let take count values =
  let rec loop count taken = function
    | _ when count = 0 -> List.rev taken
    | [] -> List.rev taken
    | value :: rest -> loop (count - 1) (value :: taken) rest
  in
  loop count [] values
;;

let pending_submission runtime =
  match runtime.attached_checkpoint with
  | Some checkpoint ->
    let entries = runtime.outbox in
    if
      List.exists
        (fun (entry : Pending.entry) ->
           match entry.state with
           | Blocked _ -> true
           | Queued | Submitted | Accepted _ -> false)
        entries
    then None
    else (
      let outgoing =
        entries
        |> List.filter (fun (entry : Pending.entry) ->
          match entry.state with
          | Queued -> true
          | Submitted | Accepted _ | Blocked _ -> false)
        |> take runtime.config.limits.submission_batch_size
      in
      match outgoing with
      | [] -> None
      | outgoing ->
        let transactions =
          List.map
            (fun (entry : Pending.entry) ->
               Protocol.
                 { tx = entry.encoded_tx
                 ; tx_id = Graph_types.Uuid.to_string entry.mutation_id
                 ; outliner_op = Some entry.outliner_op
                 })
            outgoing
        in
        (match
           Protocol.encode_tx_batch ~t_before:checkpoint.applied_server_t transactions
         with
         | Error _ -> None
         | Ok payload
           when String.length payload > runtime.config.limits.maximum_response_bytes ->
           None
         | Ok payload ->
           let outgoing_ids =
             List.map (fun entry -> entry.Pending.mutation_id) outgoing
           in
           let submitted =
             List.map
               (fun (entry : Pending.entry) ->
                  if List.exists (Graph_types.Uuid.equal entry.mutation_id) outgoing_ids
                  then { entry with state = Submitted }
                  else entry)
               entries
           in
           Some (submitted, payload)))
  | None -> None
;;

let schedule_pending_submission runtime =
  match runtime.outbox_transition_in_flight, pending_submission runtime with
  | true, _ -> ()
  | false, None -> ()
  | false, Some (outbox, payload) ->
    (match Pending.encode runtime.outbox, Pending.encode outbox with
     | Error _, _ | _, Error _ -> ()
     | Ok expected_outbox_records, Ok outbox_records ->
       let snapshot = Manager.snapshot runtime.manager in
       runtime.outbox_transition_in_flight <- true;
       emit_public_effect
         runtime
         (Commit_outbox_transition
            { account_generation = snapshot.account_generation
            ; graph_generation = snapshot.graph_generation
            ; presentation_generation = snapshot.presentation_generation
            ; lifecycle_generation = runtime.lifecycle_generation
            ; expected_outbox_records
            ; outbox_records
            ; pending_payload = Some payload
            }))
;;

let plan_authoritative_batch
      runtime
      batch
      ~(checkpoint : Logseq_db_types.Sync_checkpoint.t)
      ~database
      ~outbox_records
  =
  let no_commit checkpoint outbox_records activity =
    Ok (No_authoritative_commit { checkpoint; outbox_records; activity })
  in
  let commit transactions checkpoint outbox_records activity =
    Ok (Commit_authoritative { transactions; checkpoint; outbox_records; activity })
  in
  let decode_outbox () = Pending.decode outbox_records in
  let encode_outbox entries = Pending.encode entries in
  match Protocol.decode_server_message batch.payload with
  | Error message -> Error message
  | Ok (Protocol.Pull_ok { t; checksum; txs } as message) ->
    Result.bind
      (Protocol.validate_pull_continuity ~applied_t:checkpoint.applied_server_t message)
      (fun () ->
         if t = checkpoint.applied_server_t
         then (
           match checksum with
           | None ->
             no_commit
               checkpoint
               outbox_records
               Logseq_db_types.Sync_status.Pull_duplicate
           | Some remote when String.equal remote checkpoint.checksum ->
             no_commit
               checkpoint
               outbox_records
               Logseq_db_types.Sync_status.Pull_duplicate
           | Some remote ->
             let message =
               Printf.sprintf
                 "Entity checksum mismatch at server t %d (local %s, remote %s)."
                 t
                 checkpoint.checksum
                 remote
             in
             Result.bind (State.pause checkpoint ~message) (fun paused ->
               commit [] paused outbox_records Logseq_db_types.Sync_status.Sync_paused))
         else (
           let decrypt_protected =
             Option.map
               (fun graph_key ~attribute:_ ciphertext ->
                  Graph_key.decrypt_value ~crypto:runtime.crypto graph_key ciphertext)
               runtime.graph_key
           in
           let rec decode current decoded = function
             | [] -> Ok (List.rev decoded, current)
             | (transaction : Protocol.pull_tx) :: rest ->
               Result.bind
                 (Tx.decode ?decrypt_protected ~db:current transaction.tx)
                 (fun operations ->
                    try
                      decode
                        (Datascript.db_with operations current)
                        (operations :: decoded)
                        rest
                    with
                    | exn -> Error (Printexc.to_string exn))
           in
           Result.bind (decode database [] txs) (fun (transactions, database_after) ->
             let local_checksum =
               Checksum.recompute
                 ~e2ee:(Checksum.graph_e2ee database_after)
                 database_after
             in
             match checksum with
             | Some remote when not (String.equal remote local_checksum) ->
               let message =
                 Printf.sprintf
                   "Entity checksum mismatch at server t %d (local %s, remote %s)."
                   t
                   local_checksum
                   remote
               in
               Result.bind (State.pause checkpoint ~message) (fun paused ->
                 commit [] paused outbox_records Logseq_db_types.Sync_status.Sync_paused)
             | None | Some _ ->
               let checksum = Option.value checksum ~default:local_checksum in
               Result.bind
                 (State.advance checkpoint ~applied_server_t:t ~checksum)
                 (fun advanced ->
                    Result.bind (decode_outbox ()) (fun outbox ->
                      let outbox =
                        List.filter
                          (fun (entry : Pending.entry) ->
                             match entry.state with
                             | Accepted accepted_t -> accepted_t > t
                             | Queued | Submitted | Blocked _ -> true)
                          outbox
                      in
                      Result.bind (encode_outbox outbox) (fun outbox_records ->
                        commit
                          transactions
                          advanced
                          outbox_records
                          Logseq_db_types.Sync_status.Pull_applied))))))
  | Ok (Hello { t; _ } | Changed { t }) ->
    no_commit
      checkpoint
      outbox_records
      (if t > checkpoint.applied_server_t
       then Logseq_db_types.Sync_status.Pull_required
       else Pull_duplicate)
  | Ok (Tx_batch_ok { t = accepted_t; _ }) ->
    Result.bind (decode_outbox ()) (fun outbox ->
      let outbox =
        List.map
          (fun (entry : Pending.entry) ->
             match entry.state with
             | Submitted -> { entry with state = Accepted accepted_t }
             | Queued | Accepted _ | Blocked _ -> entry)
          outbox
      in
      Result.bind (encode_outbox outbox) (fun outbox_records ->
        commit [] checkpoint outbox_records Logseq_db_types.Sync_status.Pull_required))
  | Ok (Tx_reject { reason = Stale; _ }) ->
    Result.bind (decode_outbox ()) (fun outbox ->
      let outbox =
        List.map
          (fun (entry : Pending.entry) ->
             match entry.state with
             | Submitted -> { entry with state = Queued }
             | Queued | Accepted _ | Blocked _ -> entry)
          outbox
      in
      Result.bind (encode_outbox outbox) (fun outbox_records ->
        commit [] checkpoint outbox_records Logseq_db_types.Sync_status.Pull_required))
  | Ok
      (Tx_reject
         { reason = Db_transact_failed
         ; t = Some accepted_t
         ; success_tx_ids
         ; failed_tx_id
         ; data
         }) ->
    let accepted =
      List.filter_map
        (fun value -> Graph_types.Uuid.of_string value |> Result.to_option)
        success_tx_ids
    in
    let failed_id =
      Option.bind failed_tx_id (fun value ->
        Graph_types.Uuid.of_string value |> Result.to_option)
    in
    let message = Option.value data ~default:"database transaction failed" in
    Result.bind (decode_outbox ()) (fun outbox ->
      let outbox =
        List.map
          (fun (entry : Pending.entry) ->
             if List.exists (Graph_types.Uuid.equal entry.mutation_id) accepted
             then { entry with state = Accepted accepted_t }
             else if
               Option.fold
                 ~none:false
                 ~some:(Graph_types.Uuid.equal entry.mutation_id)
                 failed_id
             then { entry with state = Blocked message }
             else entry)
          outbox
      in
      Result.bind (encode_outbox outbox) (fun outbox_records ->
        commit
          []
          checkpoint
          outbox_records
          Logseq_db_types.Sync_status.Sync_submission_blocked))
  | Ok (Tx_reject { reason; data; _ }) ->
    let message =
      Printf.sprintf
        "Sync service rejected the transaction (%s)%s"
        (match reason with
         | Protocol.Stale -> "stale"
         | Db_transact_failed -> "db transact failed"
         | Empty_tx_data -> "empty tx data"
         | Invalid_tx -> "invalid tx"
         | Invalid_t_before -> "invalid t-before"
         | Snapshot_upload_in_progress -> "snapshot upload in progress")
        (match data with
         | Some detail when String.length detail > 0 -> ": " ^ detail
         | Some _ | None -> "")
    in
    Result.bind (decode_outbox ()) (fun outbox ->
      let outbox =
        List.map
          (fun (entry : Pending.entry) ->
             match entry.state with
             | Submitted -> { entry with state = Blocked message }
             | Queued | Accepted _ | Blocked _ -> entry)
          outbox
      in
      Result.bind (encode_outbox outbox) (fun outbox_records ->
        commit
          []
          checkpoint
          outbox_records
          Logseq_db_types.Sync_status.Sync_submission_blocked))
  | Ok (Server_error _ | Pong | Online_users) -> Error "unsupported sync server message"
;;

let catalog_base_url runtime = Uri.to_string runtime.base_url

let replace_catalog_cache runtime cache =
  if runtime.catalog_cache = cache
  then ()
  else (
    runtime.catalog_cache <- cache;
    runtime.catalog_dirty <- true)
;;

let cache_catalog runtime graphs =
  let snapshot = Manager.snapshot runtime.manager in
  replace_catalog_cache
    runtime
    (match runtime.catalog_cache, snapshot.user_id with
     | Some cache, _ -> Some (Private.Catalog.merge cache graphs)
     | None, Some user_id ->
       Some
         (Private.Catalog.create_cache
            ~user_id
            ~base_url:(catalog_base_url runtime)
            ~graphs
            ~selected_graph:snapshot.selected_graph)
     | None, None -> None)
;;

let cache_selection runtime graph_id =
  replace_catalog_cache
    runtime
    (Option.bind runtime.catalog_cache (fun cache ->
       match Private.Catalog.select cache graph_id with
       | Ok cache -> Some cache
       | Error _ -> Some cache))
;;

let cache_mirror_status runtime graph_id status =
  replace_catalog_cache
    runtime
    (Option.map
       (fun cache -> Private.Catalog.set_mirror_status cache graph_id status)
       runtime.catalog_cache)
;;

let schedule_catalog_flush runtime =
  let snapshot = Manager.snapshot runtime.manager in
  let presentation_allows_flush =
    match snapshot.startup_presentation with
    | Manager.Timeline_presented | Reconciled -> true
    | Restoring_local | Local_feed_ready -> false
  in
  match
    ( runtime.catalog_dirty
    , runtime.catalog_flush_in_flight
    , presentation_allows_flush
    , runtime.catalog_cache )
  with
  | true, false, true, Some cache ->
    runtime.catalog_flush_in_flight <- true;
    emit_public_effect runtime (Run_local_operation (Save_catalog_local cache))
  | false, _, _, _ | true, true, _, _ | true, false, false, _ | true, false, true, None ->
    ()
;;

let rec dispatch_event runtime event =
  let cached_selection =
    match event, runtime.catalog_cache with
    | (Manager.Catalog_loaded _ | Cached_catalog_loaded _), Some cache ->
      Private.Catalog.selected_graph cache
    | _ -> None
  in
  let effects = Manager.handle_event runtime.manager event in
  cancel_obsolete_network runtime;
  (match event with
   | Catalog_loaded { graphs; _ } -> cache_catalog runtime graphs
   | Cached_catalog_loaded _ -> ()
   | Wrapped_graph_key_loaded _
   | Wrapped_graph_key_load_failed _
   | Wrapped_graph_key_saved _
   | Local_secret_cleanup_finished _ -> ()
   | Mirror_ready { graph_id; _ } ->
     cache_mirror_status runtime graph_id Private.Catalog.Ready
   | Mirror_missing { graph_id; _ } ->
     cache_mirror_status runtime graph_id Private.Catalog.Downloading
   | Local_cache_deleted _
   | Catalog_failed _
   | Snapshot_baseline_loaded _
   | Snapshot_metadata_loaded _
   | Snapshot_artifact_ready _
   | E2ee_graph_key_loaded _
   | E2ee_user_keys_loaded _
   | Graph_opened _
   | Websocket_opened _
   | Websocket_frame _
   | Websocket_closed _
   | Reconnect_timer_elapsed _
   | Foreground_probe_timed_out _
   | Pending_batch _
   | Sync_applied _
   | Network_failed _ -> ());
  let effects =
    match event, cached_selection, (Manager.snapshot runtime.manager).selected_graph with
    | (Catalog_loaded _ | Cached_catalog_loaded _), Some graph_id, None ->
      effects @ Manager.handle_command runtime.manager (Select_graph graph_id)
    | _ -> effects
  in
  publish_manager runtime;
  process_effects runtime effects;
  schedule_catalog_flush runtime

and process_sync_frame runtime payload =
  let snapshot = Manager.snapshot runtime.manager in
  emit_public_effect
    runtime
    (Apply_authoritative_batch
       { payload
       ; account_generation = snapshot.account_generation
       ; graph_generation = snapshot.graph_generation
       ; connection_generation = snapshot.connection_generation
       ; presentation_generation = snapshot.presentation_generation
       ; lifecycle_generation = runtime.lifecycle_generation
       })

and process_effects runtime = function
  | [] -> ()
  | next_effect :: rest ->
    process_effect runtime next_effect;
    process_effects runtime rest

and process_effect runtime action =
  match Private.Action.classify action with
  | Local_action action ->
    emit_public_effect runtime (Run_local_operation (Local_action action))
  | Network_action action -> interpret_network_action runtime action

and interpret_local_action runtime local_store
  : Private.Action.local Private.Action.t -> unit
  = function
  | Inspect_mirror { request; graph } ->
    let scope =
      Private.Startup_phase.local_request_graph_scope request
      |> Private.Startup_phase.graph_scope_view
    in
    let graph = catalog_graph graph in
    (match local_store.resolve_mirror ~graph_id:graph.graph_id with
     | Ok _ ->
       dispatch_event
         runtime
         (Mirror_ready
            { account_generation = scope.account.account_generation
            ; graph_generation = scope.graph_generation
            ; graph_id = graph.graph_id
            })
     | Error _ ->
       let receipt =
         Private.Startup_phase.Local_completion.mirror_failed
           request
           ~diagnostic:"mirror missing"
       in
       dispatch_event
         runtime
         (Mirror_missing
            { account_generation = scope.account.account_generation
            ; graph_generation = scope.graph_generation
            ; graph_id = graph.graph_id
            ; receipt
            }))
  | Load_and_verify_wrapped_graph_key { wrapped_key_request; private_key_request } ->
    let scope =
      Private.Startup_phase.local_request_graph_scope wrapped_key_request
      |> Private.Startup_phase.graph_scope_view
    in
    let graph_id = uuid_exn scope.graph_id in
    (match
       runtime.secrets.load_and_verify_wrapped_graph_key
         ~managed_sync_origin:scope.account.managed_sync_origin
         ~user_id:scope.account.user_id
         ~graph_id
     with
     | Ok encrypted_graph_key ->
       dispatch_event
         runtime
         (Wrapped_graph_key_loaded
            { account_generation = scope.account.account_generation
            ; graph_generation = scope.graph_generation
            ; graph_id
            ; encrypted_graph_key
            })
     | Error failure ->
       let diagnostic, receipt =
         match failure with
         | Wrapped_graph_key_unavailable diagnostic ->
           ( diagnostic
           , Manager.Wrapped_key_failure_receipt
               (Private.Startup_phase.Local_completion.wrapped_graph_key_failed
                  wrapped_key_request
                  ~diagnostic) )
         | Local_private_key_unavailable diagnostic ->
           ( diagnostic
           , Manager.Private_key_failure_receipt
               (Private.Startup_phase.Local_completion.local_private_key_failed
                  private_key_request
                  ~diagnostic) )
       in
       dispatch_event
         runtime
         (Wrapped_graph_key_load_failed
            { account_generation = scope.account.account_generation
            ; graph_generation = scope.graph_generation
            ; graph_id
            ; diagnostic
            ; receipt
            }))
  | Verify_and_save_wrapped_graph_key { scope; encrypted_graph_key } ->
    let graph_id = uuid_exn scope.graph_id in
    let result =
      runtime.secrets.verify_and_save_wrapped_graph_key
        ~managed_sync_origin:scope.account.managed_sync_origin
        ~user_id:scope.account.user_id
        ~graph_id
        ~encrypted_graph_key:
          (Private.Action.wrapped_graph_key_to_string encrypted_graph_key)
    in
    dispatch_event
      runtime
      (Wrapped_graph_key_saved
         { account_generation = scope.account.account_generation
         ; graph_generation = scope.graph_generation
         ; graph_id
         ; diagnostic =
             Result.fold ~ok:(fun () -> None) ~error:(fun message -> Some message) result
         })
  | Delete_wrapped_graph_key { scope } ->
    let graph_id = uuid_exn scope.graph_id in
    let result =
      runtime.secrets.delete_wrapped_graph_key
        ~managed_sync_origin:scope.account.managed_sync_origin
        ~user_id:scope.account.user_id
        ~graph_id
    in
    dispatch_event
      runtime
      (Local_secret_cleanup_finished
         { account_generation = scope.account.account_generation
         ; diagnostic =
             Result.fold ~ok:(fun () -> None) ~error:(fun message -> Some message) result
         })
  | Delete_account_secrets { scope } ->
    let result =
      runtime.secrets.delete_account_secrets
        ~managed_sync_origin:scope.managed_sync_origin
        ~user_id:scope.user_id
    in
    dispatch_event
      runtime
      (Local_secret_cleanup_finished
         { account_generation = scope.account_generation
         ; diagnostic =
             Result.fold ~ok:(fun () -> None) ~error:(fun message -> Some message) result
         })
  | Open_graph { request; graph; encrypted_graph_key } ->
    let scope =
      Private.Startup_phase.local_request_graph_scope request
      |> Private.Startup_phase.graph_scope_view
    in
    let graph = catalog_graph graph in
    detach_graph runtime;
    (match local_store.resolve_mirror ~graph_id:graph.graph_id with
     | Error Private.Mirror.Mirror_missing ->
       dispatch_event
         runtime
         (Network_failed
            { account_generation = scope.account.account_generation
            ; graph_generation = Some scope.graph_generation
            ; connection_generation = None
            ; message = "mirror is missing"
            })
     | Error error ->
       dispatch_event
         runtime
         (Network_failed
            { account_generation = scope.account.account_generation
            ; graph_generation = Some scope.graph_generation
            ; connection_generation = None
            ; message = Private.Mirror.error_message error
            })
     | Ok resolved ->
       let graph_key =
         match encrypted_graph_key with
         | None -> Ok None
         | Some encrypted_graph_key ->
           Result.bind
             (runtime.secrets.unlock_graph_key
                ~managed_sync_origin:scope.account.managed_sync_origin
                ~user_id:scope.account.user_id
                ~encrypted_graph_key:
                  (Private.Action.wrapped_graph_key_to_string encrypted_graph_key))
             (fun value -> Result.map Option.some (Graph_key.of_string value))
       in
       (match graph_key with
        | Error message ->
          dispatch_event
            runtime
            (Network_failed
               { account_generation = scope.account.account_generation
               ; graph_generation = Some scope.graph_generation
               ; connection_generation = None
               ; message
               })
        | Ok graph_key ->
          runtime.graph_key <- graph_key;
          emit_public_effect
            runtime
            (Attach_graph
               { graph
               ; graph_directory = resolved.graph_dir
               ; database_path = resolved.database_path
               ; checkpoint = resolved.metadata
               ; account_generation = scope.account.account_generation
               ; graph_generation = scope.graph_generation
               })))
  | Close_graph -> detach_graph runtime
  | Delete_mirror { scope } ->
    let graph_id = uuid_exn scope.graph_id in
    (match local_store.delete_mirror ~graph_id with
     | Ok () ->
       cache_mirror_status runtime graph_id Private.Catalog.Missing;
       dispatch_event
         runtime
         (Local_cache_deleted
            { account_generation = scope.account.account_generation
            ; graph_generation = scope.graph_generation
            ; graph_id
            })
     | Error error ->
       dispatch_event
         runtime
         (Network_failed
            { account_generation = scope.account.account_generation
            ; graph_generation = None
            ; connection_generation = None
            ; message = Private.Mirror.error_message error
            }))
  | _ -> invalid_arg "network action reached the local interpreter"

and interpret_snapshot_activation
      runtime
      local_store
      ({ scope; graph; server_t; snapshot_path; expected_rows; encrypted_graph_key } :
        Private.Action.activate_snapshot)
  =
  let account_generation = scope.account.account_generation in
  let graph_generation = scope.graph_generation in
  let graph = catalog_graph graph in
  let graph_key =
    Option.map
      (fun encrypted_graph_key ->
         Result.bind
           (runtime.secrets.unlock_graph_key
              ~managed_sync_origin:scope.account.managed_sync_origin
              ~user_id:scope.account.user_id
              ~encrypted_graph_key:
                (Private.Action.wrapped_graph_key_to_string encrypted_graph_key))
           Private.Graph_key.of_string
         |> Result.get_ok)
      encrypted_graph_key
  in
  let decrypt_protected =
    Option.map
      (fun graph_key ciphertext ->
         Result.bind
           (Private.Graph_key.decrypt_value ~crypto:runtime.crypto graph_key ciphertext)
           (function
           | Transit_core.Json.String plaintext -> Ok plaintext
           | _ -> Error "decrypted protected value must be a string"))
      graph_key
  in
  let result =
    Fun.protect
      ~finally:(fun () ->
        Option.iter Private.Graph_key.clear graph_key;
        runtime.artifact_store.remove snapshot_path)
      (fun () ->
         local_store.bootstrap_mirror
           ~graph_id:graph.graph_id
           ~applied_server_t:server_t
           ~checksum:None
           ~expected_rows
           ~snapshot_path
           ~decrypt_protected)
  in
  match result with
  | Ok _ ->
    dispatch_event
      runtime
      (Mirror_ready { account_generation; graph_generation; graph_id = graph.graph_id })
  | Error error ->
    dispatch_event
      runtime
      (Network_failed
         { account_generation
         ; graph_generation = Some graph_generation
         ; connection_generation = None
         ; message = Private.Mirror.error_message error
         })

and interpret_network_action runtime : Private.Action.network Private.Action.t -> unit
  = function
  | Need_id_token challenge ->
    emit runtime ~topic:auth_topic (Need_id_token (challenge_from_scoped challenge))
  | Fetch_catalog { scope; token } ->
    let account_generation = scope.account_generation in
    perform_http
      runtime
      ~name:"sync-catalog"
      (Private.Http.catalog ~base_url:scope.managed_sync_origin ~token)
      (fun response ->
         match Private.Catalog.decode response.body with
         | Ok graphs -> enqueue runtime (Catalog_loaded { account_generation; graphs })
         | Error message ->
           enqueue runtime (Catalog_failed { account_generation; message }))
      ~account_generation
      ()
  | Fetch_snapshot_baseline { scope; graph; token } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph = catalog_graph graph in
    perform_http
      runtime
      ~name:"sync-snapshot-baseline"
      (Private.Http.snapshot_baseline
         ~base_url:runtime.base_url
         ~graph_id:graph.graph_id
         ~token)
      (fun response ->
         match Private.Bootstrap.decode_baseline response.body with
         | Ok baseline ->
           enqueue
             runtime
             (Snapshot_baseline_loaded
                { account_generation
                ; graph_generation
                ; graph_id = graph.graph_id
                ; baseline
                })
         | Error message ->
           network_error runtime ~account_generation ~graph_generation message)
      ~account_generation
      ~graph_generation
      ()
  | Fetch_snapshot_metadata { scope; graph; token } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph = catalog_graph graph in
    perform_http
      runtime
      ~name:"sync-snapshot-metadata"
      (Private.Http.snapshot_metadata
         ~base_url:runtime.base_url
         ~graph_id:graph.graph_id
         ~token)
      (fun response ->
         match Private.Bootstrap.decode_snapshot_metadata response.body with
         | Ok metadata ->
           enqueue
             runtime
             (Snapshot_metadata_loaded
                { account_generation
                ; graph_generation
                ; graph_id = graph.graph_id
                ; metadata
                })
         | Error message ->
           network_error runtime ~account_generation ~graph_generation message)
      ~account_generation
      ~graph_generation
      ()
  | Download_snapshot_artifact { scope; graph; baseline = _; metadata; token } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph = catalog_graph graph in
    fork_network
      runtime
      ~name:"sync-snapshot-artifact"
      ~account_generation
      ~graph_generation
      (fun sw ->
         match
           runtime.artifact_store.allocate ~graph_generation ~graph_id:graph.graph_id
         with
         | Error message ->
           network_error runtime ~account_generation ~graph_generation message
         | Ok paths ->
           runtime.artifact_store.cleanup
             (paths.artifact :: paths.snapshot :: paths.temporary_paths);
           (match
              runtime.transport.download
                ~sw
                ~request:(Private.Http.artifact ~uri:metadata.url ~token)
                ~destination:paths.artifact
                ~maximum_bytes:runtime.config.limits.maximum_artifact_bytes
                ~on_progress:(fun progress ->
                  emit
                    runtime
                    ~topic:bootstrap_topic
                    (Bootstrap_progress { account_generation; graph_generation; progress }))
            with
            | Ok response when status_ok response.status ->
              (match Private.Bootstrap.artifact_row_count response.headers with
               | Error message ->
                 runtime.artifact_store.cleanup
                   (paths.artifact :: paths.snapshot :: paths.temporary_paths);
                 network_error runtime ~account_generation ~graph_generation message
               | Ok expected_rows ->
                 (match
                    runtime.artifact_store.peel_gzip_layers
                      ~maximum_bytes:(1024 * 1024 * 1024)
                      paths
                  with
                  | Error message ->
                    runtime.artifact_store.cleanup
                      (paths.artifact :: paths.snapshot :: paths.temporary_paths);
                    network_error runtime ~account_generation ~graph_generation message
                  | Ok () ->
                    runtime.artifact_store.remove paths.artifact;
                    emit
                      runtime
                      ~topic:bootstrap_topic
                      (Bootstrap_progress
                         { account_generation
                         ; graph_generation
                         ; progress =
                             { received_bytes =
                                 runtime.artifact_store.file_size paths.snapshot
                             ; total_bytes = None
                             ; datom_count = Some expected_rows
                             }
                         });
                    enqueue
                      runtime
                      (Snapshot_artifact_ready
                         { account_generation
                         ; graph_generation
                         ; graph_id = graph.graph_id
                         ; snapshot_path = paths.snapshot
                         ; expected_rows
                         })))
            | Ok response ->
              runtime.artifact_store.cleanup
                (paths.artifact :: paths.snapshot :: paths.temporary_paths);
              network_error
                runtime
                ~account_generation
                ~graph_generation
                (Printf.sprintf "snapshot artifact failed with status %d" response.status)
            | Error message ->
              runtime.artifact_store.cleanup
                (paths.artifact :: paths.snapshot :: paths.temporary_paths);
              network_error runtime ~account_generation ~graph_generation message))
  | Activate_snapshot operation ->
    emit_public_effect runtime (Run_local_operation (Activate_snapshot_local operation))
  | Fetch_e2ee_graph_key { scope; graph; token } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph = catalog_graph graph in
    let request =
      Private.Http.e2ee_graph_key
        ~base_url:runtime.base_url
        ~graph_id:graph.graph_id
        ~token
    in
    perform_http
      runtime
      ~name:"sync-e2ee-graph-key"
      request
      (fun response ->
         enqueue
           runtime
           (E2ee_graph_key_loaded
              { account_generation
              ; graph_generation
              ; graph_id = graph.graph_id
              ; response = response.body
              }))
      ~account_generation
      ~graph_generation
      ()
  | Fetch_e2ee_user_keys { scope; token } ->
    let account_generation = scope.account.account_generation in
    let graph_generation = scope.graph_generation in
    let graph_id = uuid_exn scope.graph_id in
    let request = Private.Http.e2ee_user_keys ~base_url:runtime.base_url ~token in
    perform_http
      runtime
      ~name:"sync-e2ee-user-keys"
      request
      (fun response ->
         enqueue
           runtime
           (E2ee_user_keys_loaded
              { account_generation; graph_generation; graph_id; response = response.body }))
      ~account_generation
      ~graph_generation
      ()
  | Connect_websocket { scope; token } ->
    let account_generation = scope.graph.account.account_generation in
    let graph_generation = scope.graph.graph_generation in
    let connection_generation = scope.connection_generation in
    let graph_id = uuid_exn scope.graph.graph_id in
    close_websocket runtime;
    let controls = Eio.Stream.create 64 in
    runtime.websocket <- Some controls;
    fork_network
      runtime
      ~name:"sync-websocket"
      ~account_generation
      ~graph_generation
      ~connection_generation
      (fun sw ->
         match Private.Http.websocket_uri ~base_url:runtime.base_url ~graph_id with
         | Error message ->
           network_error
             runtime
             ~account_generation
             ~graph_generation
             ~connection_generation
             message
         | Ok uri ->
           (match
              runtime.transport.connect_websocket
                ~sw
                ~uri
                ~token
                ~maximum_frame_bytes:runtime.config.limits.maximum_response_bytes
                ~on_message:(fun payload ->
                  enqueue
                    runtime
                    (Websocket_frame
                       { account_generation
                       ; graph_generation
                       ; connection_generation
                       ; payload
                       }))
                ~on_close:(fun message ->
                  enqueue
                    runtime
                    (Websocket_closed
                       { account_generation
                       ; graph_generation
                       ; connection_generation
                       ; message = Option.value message ~default:"WebSocket closed"
                       }))
            with
            | Error message ->
              enqueue
                runtime
                (Websocket_closed
                   { account_generation
                   ; graph_generation
                   ; connection_generation
                   ; message
                   })
            | Ok socket ->
              enqueue
                runtime
                (Websocket_opened
                   { account_generation; graph_generation; connection_generation });
              let rec control_loop () =
                match Eio.Stream.take controls with
                | Websocket_close -> runtime.transport.close_websocket socket
                | Websocket_send payload ->
                  (match runtime.transport.send_websocket socket payload with
                   | Ok () -> control_loop ()
                   | Error message ->
                     runtime.transport.close_websocket socket;
                     enqueue
                       runtime
                       (Websocket_closed
                          { account_generation
                          ; graph_generation
                          ; connection_generation
                          ; message
                          }))
              in
              control_loop ()))
  | Close_websocket -> close_websocket runtime
  | Send_websocket { payload; _ } ->
    Option.iter
      (fun controls -> Eio.Stream.add controls (Websocket_send payload))
      runtime.websocket
  | Schedule_reconnect { scope; delay_seconds } ->
    let account_generation = scope.graph.account.account_generation in
    let graph_generation = scope.graph.graph_generation in
    let connection_generation = scope.connection_generation in
    close_websocket runtime;
    Network_scope.cancel_graph runtime.network_scope ~account_generation ~graph_generation;
    fork_network
      runtime
      ~name:"sync-reconnect-timer"
      ~account_generation
      ~graph_generation
      (fun _sw ->
         runtime.runtime.sleep delay_seconds;
         enqueue
           runtime
           (Reconnect_timer_elapsed
              { account_generation; graph_generation; connection_generation }))
  | Schedule_foreground_probe { scope; delay_seconds } ->
    let account_generation = scope.graph.account.account_generation in
    let graph_generation = scope.graph.graph_generation in
    let connection_generation = scope.connection_generation in
    let lifecycle_generation = scope.lifecycle_generation in
    fork_network
      runtime
      ~name:"sync-foreground-probe-timer"
      ~account_generation
      ~graph_generation
      (fun _sw ->
         runtime.runtime.sleep delay_seconds;
         enqueue
           runtime
           (Foreground_probe_timed_out
              { account_generation
              ; graph_generation
              ; connection_generation
              ; lifecycle_generation
              }))
  | Apply_sync_frame { frame; _ } -> process_sync_frame runtime frame
  | Recover_submitted { transaction_ids; _ } ->
    let ids =
      List.filter_map
        (fun value -> Graph_types.Uuid.of_string value |> Result.to_option)
        transaction_ids
    in
    runtime.outbox
    <- List.map
         (fun (entry : Pending.entry) ->
            if
              List.exists (Graph_types.Uuid.equal entry.mutation_id) ids
              && entry.state = Submitted
            then { entry with state = Queued }
            else entry)
         runtime.outbox;
    schedule_pending_submission runtime
  | _ -> invalid_arg "local action reached the network interpreter"
;;

let rec manager_loop runtime =
  match Eio.Stream.take runtime.messages with
  | Network_finished operation_id ->
    Network_scope.complete runtime.network_scope operation_id;
    manager_loop runtime
  | Handle (Manager_command command, resolve) ->
    let effects = Manager.handle_command runtime.manager command in
    cancel_obsolete_network runtime;
    let actions =
      match command with
      | Manager.Restore_local_account { user_id; _ } ->
        emit_public_effect runtime (Run_local_operation (Load_catalog_local user_id));
        []
      | Reconcile_authenticated_user { user_id = Some user_id; _ } ->
        emit_public_effect runtime (Run_local_operation (Load_catalog_local user_id));
        effects
      | Reconcile_authenticated_user { user_id = None; _ }
      | Local_feed_ready _ | Timeline_presented _ -> effects
      | Manager.Authenticated_user { user_id } ->
        emit_public_effect runtime (Run_local_operation (Load_catalog_local user_id));
        []
      | Select_graph graph_id ->
        cache_selection runtime graph_id;
        effects
      | Return_to_graph_picker -> effects
      | Delete_local_cache graph_id ->
        cache_mirror_status runtime graph_id Private.Catalog.Missing;
        effects
      | Signed_out_command
      | Provide_id_token _
      | Token_failed _
      | Refresh_catalog
      | Begin_online_recovery
      | Backgrounded _
      | Foreground_resumed _
      | Submit_e2ee_password _ -> effects
    in
    publish_manager runtime;
    process_effects runtime actions;
    schedule_catalog_flush runtime;
    Eio.Promise.resolve resolve (Ok (Manager_state (Manager.state runtime.manager)));
    manager_loop runtime
  | Handle (Stop, resolve) ->
    runtime.closed <- true;
    Network_scope.cancel_all runtime.network_scope;
    close_websocket runtime;
    detach_graph runtime;
    runtime.catalog_flush_in_flight <- false;
    (match runtime.catalog_dirty, runtime.catalog_cache with
     | true, Some cache ->
       emit_public_effect runtime (Run_local_operation (Save_catalog_local cache))
     | false, _ | true, None -> ());
    Eio.Promise.resolve resolve (Ok (Manager_state (Manager.state runtime.manager)))
;;

let create ~sw config (dependencies : dependencies) =
  let base_url = config.managed_sync_origin in
  let sequence = ref 0 in
  let manager =
    Manager.create
      ~e2ee_platform:
        { has_private_key = dependencies.secrets.has_private_key
        ; unlock_private_key = dependencies.secrets.unlock_private_key
        }
      ~next_challenge_id:(fun () ->
        incr sequence;
        Printf.sprintf "token-challenge-%d" !sequence)
      ~base_url
  in
  let client =
    { sw
    ; runtime = dependencies.runtime
    ; transport = dependencies.transport
    ; artifact_store = dependencies.artifact_store
    ; secrets = dependencies.secrets
    ; crypto = dependencies.crypto
    ; config
    ; base_url
    ; on_effect = dependencies.on_effect
    ; effect_collector = None
    ; manager
    ; messages = Eio.Stream.create 256
    ; attached_checkpoint = None
    ; outbox = []
    ; outbox_transition_in_flight = false
    ; graph_key = None
    ; websocket = None
    ; catalog_cache = None
    ; catalog_dirty = false
    ; catalog_flush_in_flight = false
    ; network_scope = Network_scope.create ()
    ; lifecycle_generation = 0L
    ; closed = false
    }
  in
  dependencies.runtime.fork ~sw (fun () -> manager_loop client);
  dependencies.on_effect (State_changed (public_state (Manager.state manager)));
  Ok client
;;

let state runtime = public_state (Manager.state runtime.manager)

let call runtime request =
  if runtime.closed
  then ()
  else (
    let result, resolve = Eio.Promise.create () in
    Eio.Stream.add runtime.messages (Handle (request, resolve));
    ignore (Eio.Promise.await result : (response, string) result))
;;

let command runtime command = call runtime (Manager_command command)

let restore_local_account runtime ~user_id =
  command
    runtime
    (Manager.Restore_local_account
       { user_id; managed_sync_origin = Uri.to_string runtime.base_url })
;;

let reconcile_authenticated_user runtime ~user_id =
  command
    runtime
    (Manager.Reconcile_authenticated_user
       { user_id; managed_sync_origin = Uri.to_string runtime.base_url })
;;

let current_scope runtime = Manager.snapshot runtime.manager

let acknowledge_local_feed runtime =
  let snapshot = current_scope runtime in
  command
    runtime
    (Manager.Local_feed_ready
       { account_generation = snapshot.account_generation
       ; graph_generation = snapshot.graph_generation
       ; presentation_generation = snapshot.presentation_generation
       })
;;

let acknowledge_timeline_presented runtime =
  let snapshot = current_scope runtime in
  command
    runtime
    (Manager.Timeline_presented
       { account_generation = snapshot.account_generation
       ; graph_generation = snapshot.graph_generation
       ; presentation_generation = snapshot.presentation_generation
       })
;;

let provide_token runtime request ~token =
  command
    runtime
    (Manager.Provide_id_token
       { challenge_id = request.Private.Auth.challenge_id
       ; user_id = request.user_id
       ; account_generation = request.account_generation
       ; graph_generation = request.graph_generation
       ; connection_generation = request.connection_generation
       ; token
       })
;;

let reject_token runtime request =
  command
    runtime
    (Manager.Token_failed { challenge_id = request.Private.Auth.challenge_id })
;;

let select_graph runtime graph_id = command runtime (Manager.Select_graph graph_id)
let return_to_graph_picker runtime = command runtime Manager.Return_to_graph_picker
let refresh_catalog runtime = command runtime Manager.Refresh_catalog
let begin_online_recovery runtime = command runtime Manager.Begin_online_recovery

let submit_e2ee_password runtime password =
  command runtime (Manager.Submit_e2ee_password password)
;;

let delete_local_cache runtime graph_id =
  command runtime (Manager.Delete_local_cache graph_id)
;;

let set_foreground runtime foreground =
  if foreground
  then
    command
      runtime
      (Manager.Foreground_resumed { lifecycle_generation = runtime.lifecycle_generation })
  else (
    runtime.lifecycle_generation <- Int64.succ runtime.lifecycle_generation;
    command
      runtime
      (Manager.Backgrounded { lifecycle_generation = runtime.lifecycle_generation }))
;;

let shutdown runtime = call runtime Stop

let handle runtime event =
  let effects = ref [] in
  Fun.protect
    ~finally:(fun () -> runtime.effect_collector <- None)
    (fun () ->
       runtime.effect_collector <- Some effects;
       match event with
       | Restore_local_account { user_id } -> restore_local_account runtime ~user_id
       | Account_authenticated { user_id } ->
         reconcile_authenticated_user runtime ~user_id
       | Local_feed_acknowledged -> acknowledge_local_feed runtime
       | Timeline_presented -> acknowledge_timeline_presented runtime
       | Token_provided (request, token) -> provide_token runtime request ~token
       | Token_rejected request -> reject_token runtime request
       | Graph_selected graph_id -> select_graph runtime graph_id
       | Graph_picker_requested -> return_to_graph_picker runtime
       | Catalog_refresh_requested -> refresh_catalog runtime
       | Online_recovery_requested -> begin_online_recovery runtime
       | E2ee_password_submitted password -> submit_e2ee_password runtime password
       | Local_cache_deletion_requested graph_id -> delete_local_cache runtime graph_id
       | Foreground_changed foreground -> set_foreground runtime foreground
       | Graph_attached
           { account_generation; graph_generation; checkpoint; outbox_records } ->
         let snapshot = Manager.snapshot runtime.manager in
         if
           snapshot.account_generation = account_generation
           && snapshot.graph_generation = graph_generation
         then (
           match Pending.decode outbox_records with
           | Error message ->
             dispatch_event
               runtime
               (Network_failed
                  { account_generation
                  ; graph_generation = Some graph_generation
                  ; connection_generation = None
                  ; message
                  })
           | Ok outbox ->
             runtime.attached_checkpoint <- Some checkpoint;
             runtime.outbox <- outbox;
             dispatch_event
               runtime
               (Manager.Graph_opened
                  { account_generation
                  ; graph_generation
                  ; graph_id = checkpoint.graph_id
                  ; applied_server_t = checkpoint.applied_server_t
                  });
             schedule_pending_submission runtime)
       | Graph_attachment_failed { account_generation; graph_generation; message } ->
         dispatch_event
           runtime
           (Network_failed
              { account_generation
              ; graph_generation = Some graph_generation
              ; connection_generation = None
              ; message
              })
       | Local_batch_committed { outbox_records } ->
         (match Pending.decode outbox_records with
          | Error _ -> ()
          | Ok outbox ->
            runtime.outbox <- outbox;
            schedule_pending_submission runtime)
       | Authoritative_batch_applied
           { account_generation
           ; graph_generation
           ; checkpoint
           ; outbox_records
           ; activity
           ; invalidation
           } ->
         let snapshot = Manager.snapshot runtime.manager in
         if
           snapshot.account_generation = account_generation
           && snapshot.graph_generation = graph_generation
         then (
           runtime.attached_checkpoint <- Some checkpoint;
           (match Pending.decode outbox_records with
            | Error _ -> ()
            | Ok outbox -> runtime.outbox <- outbox);
           Option.iter
             (fun invalidation ->
                emit_public_effect runtime (Graph_invalidated invalidation))
             invalidation;
           dispatch_event
             runtime
             (Manager.Sync_applied
                { account_generation
                ; graph_generation
                ; applied_server_t = checkpoint.applied_server_t
                ; activity
                ; pending_payload = None
                });
           schedule_pending_submission runtime)
       | Authoritative_batch_failed { account_generation; graph_generation; message } ->
         dispatch_event
           runtime
           (Network_failed
              { account_generation
              ; graph_generation = Some graph_generation
              ; connection_generation = None
              ; message
              })
       | Outbox_transition_committed { outbox_records; pending_payload } ->
         runtime.outbox_transition_in_flight <- false;
         (match Pending.decode outbox_records with
          | Error _ -> ()
          | Ok outbox ->
            runtime.outbox <- outbox;
            Option.iter
              (fun payload -> dispatch_event runtime (Pending_batch payload))
              pending_payload)
       | Outbox_transition_rejected { outbox_records; message = _ } ->
         runtime.outbox_transition_in_flight <- false;
         (match Pending.decode outbox_records with
          | Error _ -> ()
          | Ok outbox ->
            runtime.outbox <- outbox;
            schedule_pending_submission runtime)
       | Shutdown -> shutdown runtime);
  List.rev !effects
;;

let run_local_operation runtime local_store operation =
  let effects = ref [] in
  Fun.protect
    ~finally:(fun () -> runtime.effect_collector <- None)
    (fun () ->
       runtime.effect_collector <- Some effects;
       match operation with
       | Local_action action -> interpret_local_action runtime local_store action
       | Activate_snapshot_local operation ->
         interpret_snapshot_activation runtime local_store operation
       | Load_catalog_local user_id ->
         let snapshot = Manager.snapshot runtime.manager in
         if snapshot.user_id = Some user_id
         then (
           runtime.catalog_cache
           <- (match
                 local_store.load_catalog ~user_id ~base_url:(catalog_base_url runtime)
               with
               | Ok cache -> cache
               | Error _ -> None);
           runtime.catalog_dirty <- false;
           Option.iter
             (fun cache ->
                dispatch_event
                  runtime
                  (Cached_catalog_loaded
                     { account_generation = snapshot.account_generation
                     ; graphs = Private.Catalog.graphs cache
                     }))
             runtime.catalog_cache)
       | Save_catalog_local cache ->
         let result =
           try local_store.save_catalog cache with
           | exception_ -> Error (Printexc.to_string exception_)
         in
         runtime.catalog_flush_in_flight <- false;
         (match result with
          | Ok () ->
            if runtime.catalog_cache = Some cache then runtime.catalog_dirty <- false;
            if not runtime.closed then schedule_catalog_flush runtime
          | Error _ -> ()));
  List.rev !effects
;;

let resume runtime completion =
  let effects = ref [] in
  Fun.protect
    ~finally:(fun () -> runtime.effect_collector <- None)
    (fun () ->
       runtime.effect_collector <- Some effects;
       dispatch_event runtime completion);
  List.rev !effects
;;
