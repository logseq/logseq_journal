type cold
type ready
type draining
type retired

type _ phase =
  | Cold : cold phase
  | Ready : ready phase
  | Draining : draining phase
  | Retired : retired phase

type _ drainable =
  | Cold_context : cold drainable
  | Ready_context : ready drainable
  | Draining_context : draining drainable

type identity =
  { origin : string
  ; account : string
  ; graph : string
  ; account_generation : int64
  ; graph_generation : int64
  }

module Overlay = Logseq_overlay_db

type error =
  | Invalid_input of string
  | Identity_mismatch of string
  | Stale_context
  | Network_closed
  | Network_failure of string
  | Authentication_failure of string
  | Locked
  | Crypto_failure of string
  | Protocol_failure of string
  | Storage_failure of string
  | Cancelled
  | Outcome_unknown of string
  | Cleanup_failure of
      { primary : error option
      ; failures : error Rrbvec.t
      }
  | Capacity_exceeded of string
  | Sync_read_failure of Overlay.Types.sync_read_error
  | Outbox_failure of Overlay.Types.outbox_transition_error
  | Authoritative_failure of Overlay.Types.authoritative_transition_error
  | Activation_failure of Overlay.Types.snapshot_activation_error
  | Asset_failure of Logseq_db_types.Failure_diagnostic.t
  | Unexpected_failure of string

type limits =
  { maximum_items : int
  ; maximum_bytes : int
  ; maximum_pending : int
  ; maximum_resources : int
  ; steps_per_turn : int
  ; maximum_tasks : int
  ; maximum_messages : int
  ; maximum_message_bytes : int
  ; maximum_websocket_downlink_bytes : int
  ; maximum_demands : int
  ; maximum_active_assets : int
  ; foreground_reserve : int
  ; foreground_demand_reserve : int
  ; foreground_descriptor_reserve_bytes : int
  ; asset_cache_budget_bytes : int64
  ; asset_maximum_file_bytes : int
  ; asset_pending_budget_bytes : int64
  ; snapshot_maximum_artifact_bytes : int64
  ; snapshot_staging_budget_bytes : int64
  ; snapshot_scratch_budget_bytes : int64
  }

type retry_policy =
  { initial_seconds : float
  ; maximum_seconds : float
  ; multiplier : float
  ; maximum_attempts : int
  }

type network_gate =
  | Closed
  | Open of { authorization_epoch : int64 }

type key_status =
  | Unencrypted
  | Key_locked
  | Key_available

type observation =
  { identity : identity
  ; keys : key_status
  ; network : network_gate
  ; checkpoint : Overlay.Types.server_cursor option
  ; pending_submissions : int
  ; pending_assets : int
  ; cleanup_pending : int
  ; last_failure : error option
  }

type restore_report =
  { keys : key_status
  ; checkpoint : Overlay.Types.server_cursor option
  ; recovery_pending : bool
  }

type activation =
  | Activated of Overlay.Types.generation
  | Activation_deferred of string

type authoritative_result =
  | Applied of Overlay.Types.authoritative_commit
  | Deferred of Overlay.Types.authoritative_defer

type resource_release =
  { mutable release_owner : identity ref option
  ; mutable release_metadata : string option
  ; mutable release_acknowledged : bool
  }

let resource_release () =
  { release_owner = None; release_metadata = None; release_acknowledged = false }
;;

type resource =
  { owner : identity
  ; token : string
  ; release : resource_release
  }

type snapshot =
  { resource : resource
  ; through : Overlay.Types.server_cursor
  ; checksum : string
  ; encrypted : bool
  }

type _ database =
  | Inspect : Overlay.Types.sync_view database
  | Verify_checksum :
      Overlay.Types.server_cursor * Overlay.Types.checksum
      -> unit database
  | Prepare_submission :
      Overlay.Types.sync_token * Overlay.Types.outbox_transition
      -> Overlay.Types.outbox_commit database
  | Apply_authoritative :
      Overlay.Types.sync_token * Overlay.Types.authoritative_batch
      -> authoritative_result database
  | Activate_snapshot : snapshot -> activation database
  | Release_snapshot : snapshot -> unit database

type remote_head =
  { through : Overlay.Types.server_cursor
  ; snapshot_available : bool
  ; expected_checksum : Overlay.Types.checksum option
  }

type pull_result =
  | Pulled of Overlay.Types.authoritative_batch
  | No_progress of
      { since : Overlay.Types.server_cursor
      ; through : Overlay.Types.server_cursor
      ; expected_checksum : Overlay.Types.checksum option
      }

type submission_reply =
  | Accepted of Overlay.Types.acceptance_barrier
  | Rejected of Overlay.Types.rejection_resolution

type connection = Connection of identity * string * int64 * resource_release

type connection_end =
  | Remote_closed
  | Network_lost of string
  | Access_revoked of string
  | Invalid_protocol of string
  | Locally_closed

type remote_message =
  | Remote_error of string
  | Remote_changed of remote_head
  | Connection_ended of connection_end

type received =
  { connection : connection
  ; message : remote_message
  }

type _ transport =
  | Connect : connection transport
  | Receive : connection -> received transport
  | Retire_connection : connection -> unit transport
  | On_connection : connection * 'a transport -> 'a transport
  | Head : remote_head transport
  | Fetch_snapshot : snapshot transport
  | Pull : Overlay.Types.server_cursor -> pull_result transport
  | Push : Overlay.Types.submission_batch -> submission_reply transport

type unlock_input = string

type _ crypto =
  | Unlock : unlock_input -> key_status crypto
  | Encrypt_values : string Rrbvec.t -> (string * string) Rrbvec.t crypto
  | Decrypt_value : string -> string crypto
  | Protect :
      Overlay.Database.protection_request
      -> (Overlay.Types.crypto_item_id * string) list crypto
  | Unprotect :
      Overlay.Database.unprotection_request
      -> (Overlay.Types.crypto_item_id * string) list crypto

type asset = Logseq_db_types.Asset_descriptor.t

type asset_file =
  { file : resource
  ; asset : asset
  }

type asset_lease =
  { lease : resource
  ; source : asset_file
  }

type resource_reference =
  | Snapshot_reference of snapshot
  | Connection_reference of connection
  | File_reference of asset_file
  | Lease_reference of asset_lease

type asset_result =
  | Available of asset_file
  | Waiting_remote
  | Missing_local

type cache_report =
  { resident_bytes : int64
  ; pending_bytes : int64
  ; retained_bytes : int64
  ; cleanup_pending : int
  ; over_budget : bool
  }

type _ assets =
  | Prune_cache : cache_report assets
  | Reconcile_staging : int assets
  | Lookup : asset -> asset_file option assets
  | Download : asset -> asset_result assets
  | Upload : asset -> unit assets
  | Retain : asset_file -> asset_lease assets
  | Release_file : asset_file -> unit assets
  | Release_lease : asset_lease -> unit assets

type scope =
  { scope_owner : identity ref
  ; mutable scope_live : bool
  ; mutable registrations : (unit ref * (unit -> unit)) list
  }

type 'a child_state =
  | Pending_child of (unit -> ('a, error) result option)
  | Completed_child of ('a, error) result
  | Consumed_child

type handle = { handle_scope : scope }
type demand_id = string

type priority =
  | Foreground
  | Background

type demand_change =
  | Demand of
      { id : demand_id
      ; asset : asset
      ; priority : priority
      }
  | Withdraw of demand_id

type demand_receipt = Demand_receipt of handle
type unlock_receipt = Unlock_receipt of handle

type service_input =
  | Unlock_requested of unlock_receipt
  | Demand_changed of demand_receipt * demand_change
  | Network_changed of network_gate
  | Stop_requested

type asset_failure_reason =
  | Asset_network of string
  | Asset_network_closed
  | Asset_not_found
  | Asset_checksum_mismatch
  | Asset_authentication of string
  | Asset_locked
  | Asset_storage_full
  | Asset_missing_source
  | Asset_size_rejected
  | Asset_revoked_access
  | Asset_cancelled
  | Asset_invalid_content of string
  | Asset_other of error

type demand_transfer =
  { result : (asset_result, asset_failure_reason) result
  ; attempts : int
  }

type demand_availability =
  | Demand_queued
  | Demand_downloading
  | Demand_waiting_network
  | Demand_waiting_unlock
  | Demand_failed of
      { reason : asset_failure_reason
      ; attempts : int
      ; retry_scheduled : bool
      }
  | Demand_available of asset_file * asset_lease
  | Demand_waiting_remote
  | Demand_missing_local
  | Demand_revoked

type demand_delivery = Delivery of identity ref * bool ref

type demand_output =
  { delivery : demand_delivery
  ; id : demand_id
  ; demand : demand_receipt
  ; availability : demand_availability
  }

type outbox_check = Outbox_check of handle

type capacity_revision =
  { capacity_scope : scope
  ; sequence : int64
  }

type notifications = Notifications_handle of handle

type notification =
  | Policy_failure of error
  | Connected of connection
  | Remote_received of received
  | Connection_retired of connection

type service_status =
  | Service_idle
  | Service_connecting
  | Service_pulling
  | Service_submitting
  | Service_online
  | Service_waiting_network
  | Service_waiting_unlock
  | Service_backoff of
      { attempt : int
      ; seconds : float
      ; cause : error
      }
  | Service_blocked of error

type 'a task = Task of 'a task_node

and 'a child =
  { child_scope : scope
  ; registration : unit ref
  ; mutable child_task : 'a task option
  ; mutable child_state : 'a child_state
  }

and 'a wake =
  | Input of service_input
  | Child_ready of 'a child

and _ task_operation =
  | Notifications : scope -> notifications task_operation
  | Notify : notifications * notification -> unit task_operation
  | Next_notification : notifications -> notification task_operation
  | Await_outbox_changed : outbox_check task_operation
  | Acknowledge_outbox_check : outbox_check -> unit task_operation
  | Abandon_outbox_check : outbox_check -> unit task_operation
  | Resample_outbox : unit task_operation
  | Capacity_revision : capacity_revision task_operation
  | Await_capacity_changed : capacity_revision -> unit task_operation
  | Task_observe : observation task_operation
  | Publish_status : service_status -> unit task_operation
  | Task_database : 'a database -> 'a task_operation
  | Task_transport : 'a transport -> 'a task_operation
  | Task_crypto : 'a crypto -> 'a task_operation
  | Task_assets : 'a assets -> 'a task_operation
  | Consume_unlock : unlock_receipt -> key_status task_operation
  | Publish_demand : demand_receipt * demand_availability -> unit task_operation
  | Download_demand : demand_receipt -> demand_transfer task_operation
  | Finish_demand : demand_receipt -> unit task_operation
  | Wait_network_open : unit task_operation
  | Next_input : service_input task_operation
  | Await_input_or_child : 'a child Rrbvec.t -> 'a wake task_operation
  | Sleep : float -> unit task_operation
  | Yield : unit task_operation

and _ task_node =
  | Task_return : 'a -> 'a task_node
  | Task_fail : error -> 'a task_node
  | Task_perform :
      'a task_operation * ('a -> 'b task) * (error -> 'b task)
      -> 'b task_node
  | Task_scope : (scope -> 'a task) -> 'a task_node
  | Task_spawn : scope * 'a task -> ('a child, error) result task_node
  | Task_spawn_asset :
      scope * demand_receipt * 'a task
      -> ('a child, error) result task_node
  | Task_join : 'a child -> ('a, error) result task_node
  | Task_cancel : 'a child -> unit task_node
  | Task_bind : 'a task * ('a -> 'b task) -> 'b task_node

type (_, _, _, _) operation =
  | Run_task : 'a task -> (ready, ready, ready, 'a) operation
  | Restore : (cold, ready, cold, restore_report) operation
  | Install_initial_network : network_gate -> (ready, ready, ready, unit) operation
  | Set_network : network_gate -> (ready, ready, ready, unit) operation
  | Database : 'a database -> (ready, ready, ready, 'a) operation
  | Transport : 'a transport -> (ready, ready, ready, 'a) operation
  | Crypto : 'a crypto -> (ready, ready, ready, 'a) operation
  | Assets : 'a assets -> (ready, ready, ready, 'a) operation
  | Observe : ('s, 's, 's, observation) operation
  | Begin_drain : 's drainable -> ('s, draining, draining, unit) operation
  | Finish_retirement : (draining, retired, draining, unit) operation
  | Release_file : asset_file -> ('s, 's, 's, unit) operation
  | Release_lease : asset_lease -> ('s, 's, 's, unit) operation
  | Release_snapshot : snapshot -> ('s, 's, 's, unit) operation

module Program = Logseq_sync_indexed_program.Make (struct
    type nonrec error = error
    type nonrec ('a, 'b, 'c, 'd) operation = ('a, 'b, 'c, 'd) operation
  end)

type ('before, 'after, 'value) program = ('before, 'after, 'value) Program.t

type (_, _, _) node =
  | Return : 'a -> ('s, 's, 'a) node
  | Abort : error -> ('s, 'final, 'a) node
  | Perform :
      ('before, 'after, 'failed, 'a) operation
      * ('a -> ('after, 'final, 'b) program)
      * (error -> ('failed, 'final, 'b) program)
      -> ('before, 'final, 'b) node

type policy_config =
  { sync_retry : retry_policy
  ; asset_retry : retry_policy
  ; no_progress_seconds : float
  }

let return = Program.return
let abort = Program.abort
let bind = Program.bind
let perform = Program.perform

let view
  : type before after value. (before, after, value) program -> (before, after, value) node
  =
  fun program ->
  match Program.view program with
  | Program.Return value -> Return value
  | Program.Abort error -> Abort error
  | Program.Perform (operation, success, failure) -> Perform (operation, success, failure)
;;

let task_return value = Task (Task_return value)
let task_bind task continuation = Task (Task_bind (task, continuation))
let task_fail error = Task (Task_fail error)

let task_perform operation ~success ~failure =
  Task (Task_perform (operation, success, failure))
;;

let with_scope body = Task (Task_scope body)
let spawn scope task = Task (Task_spawn (scope, task))
let spawn_asset scope receipt task = Task (Task_spawn_asset (scope, receipt, task))
let equal_child first second = first == second
let join child = Task (Task_join child)
let cancel_child child = Task (Task_cancel child)
let task_view (Task node) = node
let run_task task = Run_task task
let restore = Restore
let install_initial_network gate = Install_initial_network gate
let set_network gate = Set_network gate
let database operation = Database operation
let transport operation = Transport operation
let crypto operation = Crypto operation
let assets operation = Assets operation
let observe = Observe
let begin_drain phase = Begin_drain phase
let finish_retirement = Finish_retirement
let release_file file = Release_file file
let release_lease lease = Release_lease lease
let release_snapshot snapshot = Release_snapshot snapshot
let invalid field = Error (Invalid_input field)
let finite value = Float.is_finite value
let nonempty value = String.length value > 0 && String.trim value = value

let identity ~origin ~account ~graph ~account_generation ~graph_generation =
  if
    (not (nonempty account && nonempty graph))
    || account_generation < 0L
    || graph_generation < 0L
  then invalid "identity"
  else (
    try
      let uri = Uri.of_string origin in
      match Uri.scheme uri, Uri.host uri with
      | Some scheme, Some host
        when String.lowercase_ascii scheme = "https"
             && nonempty host
             && Uri.userinfo uri = None
             && Uri.query uri = []
             && Uri.fragment uri = None
             && (Uri.path uri = "" || Uri.path uri = "/")
             &&
             match Uri.port uri with
             | None -> true
             | Some port -> port > 0 && port <= 65535 ->
        let port =
          match Uri.port uri with
          | Some 443 -> None
          | port -> port
        in
        let origin =
          Uri.to_string
            (Uri.make ~scheme:"https" ~host:(String.lowercase_ascii host) ?port ())
        in
        Ok { origin; account; graph; account_generation; graph_generation }
      | _ -> invalid "HTTPS origin"
    with
    | _ -> invalid "HTTPS origin")
;;

let limits
      ~maximum_items
      ~maximum_bytes
      ~maximum_pending
      ~maximum_resources
      ~steps_per_turn
      ~maximum_tasks
      ~maximum_messages
      ~maximum_message_bytes
      ~maximum_demands
      ~maximum_active_assets
      ~foreground_reserve
      ~foreground_demand_reserve
      ~foreground_descriptor_reserve_bytes
      ~asset_cache_budget_bytes
      ~asset_maximum_file_bytes
      ~asset_pending_budget_bytes
      ~snapshot_maximum_artifact_bytes
      ~snapshot_staging_budget_bytes
      ~snapshot_scratch_budget_bytes
  =
  let bounded value maximum = value > 0 && value <= maximum in
  if
    not
      (bounded maximum_items 4096
       && bounded maximum_pending 4096
       && bounded maximum_messages 4096
       && bounded maximum_demands 4096
       && bounded maximum_bytes 16777216
       && bounded maximum_message_bytes 16777216
       && bounded maximum_resources 1024
       && bounded steps_per_turn 65536
       && bounded maximum_tasks 256
       && bounded maximum_active_assets maximum_pending
       && maximum_tasks >= maximum_active_assets + 4
       && maximum_pending >= maximum_active_assets + 4
       && bounded foreground_reserve maximum_active_assets
       && bounded foreground_demand_reserve maximum_demands
       && bounded foreground_descriptor_reserve_bytes maximum_message_bytes
       && maximum_messages >= foreground_demand_reserve + 3
       && asset_cache_budget_bytes >= 0L
       && asset_pending_budget_bytes >= 0L
       && asset_maximum_file_bytes >= 0
       && asset_maximum_file_bytes <= 104857600
       && snapshot_maximum_artifact_bytes > 0L
       && snapshot_staging_budget_bytes > 0L
       && snapshot_scratch_budget_bytes > 0L)
  then invalid "limits"
  else
    Ok
      { maximum_items
      ; maximum_bytes
      ; maximum_pending
      ; maximum_resources
      ; steps_per_turn
      ; maximum_tasks
      ; maximum_messages
      ; maximum_message_bytes
      ; maximum_websocket_downlink_bytes =
          Logseq_db_types.Limits.maximum_sync_websocket_downlink_bytes
      ; maximum_demands
      ; maximum_active_assets
      ; foreground_reserve
      ; foreground_demand_reserve
      ; foreground_descriptor_reserve_bytes
      ; asset_cache_budget_bytes
      ; asset_maximum_file_bytes
      ; asset_pending_budget_bytes
      ; snapshot_maximum_artifact_bytes
      ; snapshot_staging_budget_bytes
      ; snapshot_scratch_budget_bytes
      }
;;

let retry_policy ~initial_seconds ~maximum_seconds ~multiplier ~maximum_attempts =
  if
    not
      (finite initial_seconds
       && finite maximum_seconds
       && finite multiplier
       && initial_seconds > 0.
       && maximum_seconds >= initial_seconds
       && multiplier >= 1.
       && maximum_attempts >= 0
       && maximum_attempts <= 10)
  then invalid "retry policy"
  else Ok { initial_seconds; maximum_seconds; multiplier; maximum_attempts }
;;

let policy_config ~sync_retry ~asset_retry ~no_progress_seconds =
  if not (finite no_progress_seconds && no_progress_seconds > 0.)
  then invalid "no-progress delay"
  else Ok { sync_retry; asset_retry; no_progress_seconds }
;;

let resource ~owner ~token =
  if nonempty token
  then Ok { owner; token; release = resource_release () }
  else invalid "resource token"
;;

let snapshot ~resource ~through ~checksum ~encrypted =
  if nonempty checksum
  then Ok { resource; through; checksum; encrypted }
  else invalid "snapshot checksum"
;;

let connection ~owner ~token ~generation =
  if nonempty token && generation >= 0L
  then Ok (Connection (owner, token, generation, resource_release ()))
  else invalid "connection"
;;

let unlock_input ~wrapped_graph_key =
  if String.length wrapped_graph_key > 0
  then Ok wrapped_graph_key
  else invalid "wrapped graph key"
;;

let wrapped_graph_key input = input
let asset_file file asset = Ok { file; asset }

let asset_lease lease source =
  if lease.owner <> source.file.owner
  then Error (Identity_mismatch "asset lease")
  else if lease.token = source.file.token
  then invalid "duplicate resource reference"
  else Ok { lease; source }
;;

let demand_id value =
  if nonempty value && String.length value <= 256 then Ok value else invalid "demand ID"
;;

let compare_demand_id = String.compare

module Producer = struct
  type owner = { stamp : identity ref }

  let create identity = { stamp = ref identity }
  let scope owner = { scope_owner = owner.stamp; scope_live = true; registrations = [] }
  let original_scope owner scope = scope.scope_owner == owner.stamp

  let check_scope owner scope =
    if original_scope owner scope && scope.scope_live then Ok () else Error Stale_context
  ;;

  let close_scope owner scope =
    if original_scope owner scope
    then (
      scope.scope_live <- false;
      List.iter (fun (_, release) -> release ()) scope.registrations;
      scope.registrations <- [];
      Ok ())
    else Error Stale_context
  ;;

  let child owner scope task ~poll =
    match check_scope owner scope with
    | Error error -> Error error
    | Ok () ->
      let child =
        { child_scope = scope
        ; registration = ref ()
        ; child_task = Some task
        ; child_state = Pending_child poll
        }
      in
      scope.registrations
      <- ( child.registration
         , fun () ->
             child.child_state <- Consumed_child;
             child.child_task <- None )
         :: scope.registrations;
      Ok child
  ;;

  let check_child owner scope child =
    match check_scope owner scope with
    | Error error -> Error error
    | Ok () ->
      if child.child_scope == scope && Option.is_some child.child_task
      then Ok ()
      else Error Stale_context
  ;;

  let child_result owner scope child =
    match check_child owner scope child with
    | Error error -> Error error
    | Ok () ->
      (match child.child_state with
       | Consumed_child -> Error Stale_context
       | Completed_child result -> Ok (Some result)
       | Pending_child poll ->
         let result = poll () in
         (match result with
          | None -> ()
          | Some value -> child.child_state <- Completed_child value);
         Ok result)
  ;;

  let forget_child owner scope child =
    if original_scope owner scope && child.child_scope == scope
    then (
      child.child_state <- Consumed_child;
      child.child_task <- None;
      scope.registrations
      <- List.filter
           (fun (registration, _) -> registration != child.registration)
           scope.registrations;
      Ok ())
    else Error Stale_context
  ;;

  let make owner scope build =
    match check_scope owner scope with
    | Error error -> Error error
    | Ok () -> Ok (build { handle_scope = scope })
  ;;

  let demand_receipt owner scope = make owner scope (fun handle -> Demand_receipt handle)
  let unlock_receipt owner scope = make owner scope (fun handle -> Unlock_receipt handle)
  let outbox_check owner scope = make owner scope (fun handle -> Outbox_check handle)

  let notifications owner scope =
    make owner scope (fun handle -> Notifications_handle handle)
  ;;

  let capacity_revision owner scope ~sequence =
    match check_scope owner scope with
    | Error error -> Error error
    | Ok () -> Ok { capacity_scope = scope; sequence }
  ;;

  let capacity_sequence owner scope revision =
    match check_scope owner scope with
    | Error error -> Error error
    | Ok () ->
      if revision.capacity_scope == scope
      then Ok revision.sequence
      else Error Stale_context
  ;;

  let check_handle owner scope handle =
    match check_scope owner scope with
    | Error error -> Error error
    | Ok () -> if handle.handle_scope == scope then Ok () else Error Stale_context
  ;;

  let check_demand_receipt owner scope (Demand_receipt handle) =
    check_handle owner scope handle
  ;;

  let check_unlock_receipt owner scope (Unlock_receipt handle) =
    check_handle owner scope handle
  ;;

  let check_outbox_check owner scope (Outbox_check handle) =
    check_handle owner scope handle
  ;;

  let check_notifications owner scope (Notifications_handle handle) =
    check_handle owner scope handle
  ;;

  let demand_output owner scope demand ~id availability =
    match check_demand_receipt owner scope demand with
    | Error error -> Error error
    | Ok () ->
      Ok { delivery = Delivery (owner.stamp, ref false); id; demand; availability }
  ;;

  let check_delivery owner (Delivery (stamp, _)) =
    if owner.stamp == stamp then Ok () else Error Stale_context
  ;;

  let delivery_released owner (Delivery (stamp, released)) =
    if owner.stamp == stamp then Ok !released else Error Stale_context
  ;;

  let acknowledge_delivery owner (Delivery (stamp, released)) =
    if owner.stamp == stamp
    then (
      released := true;
      Ok ())
    else Error Stale_context
  ;;

  let reference_registration = function
    | Snapshot_reference snapshot ->
      ( snapshot.resource.release
      , Marshal.to_string (0, snapshot.through, snapshot.checksum, snapshot.encrypted) []
      )
    | File_reference file -> file.file.release, Marshal.to_string (1, file.asset) []
    | Lease_reference lease ->
      ( lease.lease.release
      , Marshal.to_string
          (2, lease.source.file.owner, lease.source.file.token, lease.source.asset)
          [] )
    | Connection_reference (Connection (identity, token, generation, release)) ->
      release, Marshal.to_string (3, identity, token, generation) []
  ;;

  let same_reference_registration left right =
    let left, _ = reference_registration left
    and right, _ = reference_registration right in
    left == right
  ;;

  let reference_state owner reference =
    let release, metadata = reference_registration reference in
    match release.release_owner with
    | None -> Ok `Unregistered
    | Some stamp when stamp == owner.stamp && release.release_metadata = Some metadata ->
      Ok (if release.release_acknowledged then `Released else `Retained)
    | Some _ -> Error Stale_context
  ;;

  let register_reference owner reference =
    match reference_state owner reference with
    | Error error -> Error error
    | Ok `Released -> Error Stale_context
    | Ok `Retained -> Ok ()
    | Ok `Unregistered ->
      let release, metadata = reference_registration reference in
      release.release_owner <- Some owner.stamp;
      release.release_metadata <- Some metadata;
      Ok ()
  ;;

  let acknowledge_reference owner reference =
    match reference_state owner reference with
    | Error error -> Error error
    | Ok `Unregistered -> Error Stale_context
    | Ok (`Retained | `Released) ->
      let release, _ = reference_registration reference in
      release.release_acknowledged <- true;
      Ok ()
  ;;
end

let error_message = function
  | Invalid_input message -> "Invalid input: " ^ message
  | Identity_mismatch message -> "Identity mismatch: " ^ message
  | Stale_context -> "Stale context"
  | Network_closed -> "Network closed"
  | Network_failure message -> "Network failure: " ^ message
  | Authentication_failure message -> "Authentication failure: " ^ message
  | Locked -> "Locked"
  | Crypto_failure message -> "Crypto failure: " ^ message
  | Protocol_failure message -> "Protocol failure: " ^ message
  | Storage_failure message -> "Storage failure: " ^ message
  | Cancelled -> "Cancelled"
  | Outcome_unknown message -> "Outcome unknown: " ^ message
  | Cleanup_failure _ -> "Cleanup failure"
  | Capacity_exceeded message -> "Capacity exceeded: " ^ message
  | Sync_read_failure _ -> "Sync read failure"
  | Outbox_failure _ -> "Outbox transition failure"
  | Authoritative_failure error ->
    let module T = Overlay.Types in
    let module Diagnostic = Logseq_db_types.Authoritative_diagnostic in
    let classified reason = "Authoritative transition failed: " ^ reason in
    let diagnostic fallback source =
      match Diagnostic.decode source with
      | Some detail -> Diagnostic.message detail
      | None -> classified fallback
    in
    (match error with
     | T.Authoritative_database_closed -> classified "database closed during preparation"
     | Authoritative_sync_token_conflict -> classified "preparation sync token conflict"
     | Authoritative_cursor_discontinuous -> classified "server cursor discontinuous"
     | Authoritative_checksum_mismatch -> classified "checksum mismatch"
     | Authoritative_crypto_required -> classified "decryption result required"
     | Authoritative_crypto_unexpected -> classified "unexpected decryption result"
     | Authoritative_crypto_error error ->
       classified
         (match error with
          | Crypto_result_missing_item _ -> "decryption result missing item"
          | Crypto_result_extra_item _ -> "decryption result extra item"
          | Crypto_result_duplicate_item _ -> "decryption result duplicate item"
          | Crypto_result_reordered -> "decryption result reordered"
          | Crypto_result_stale -> "decryption result stale"
          | Crypto_result_limit_exceeded -> "decryption result limit exceeded")
     | Authoritative_decode_failed source ->
       diagnostic "transaction decode rejected" source
     | Authoritative_origin_unresolved -> classified "origin unresolved"
     | Authoritative_preparation_consumed -> classified "preparation already consumed"
     | Authoritative_prepare_busy -> classified "preparation busy"
     | Authoritative_integrity_failure source ->
       diagnostic "integrity validation rejected" source
     | Authoritative_commit_database_closed -> classified "database closed during commit"
     | Authoritative_commit_token_conflict -> classified "commit sync token conflict"
     | Authoritative_commit_generation_invalidated ->
       classified "commit generation invalidated"
     | Authoritative_commit_busy -> classified "commit busy"
     | Authoritative_commit_persistence_failed _ -> classified "commit persistence failed"
     | Authoritative_commit_fatal_state _ -> classified "commit fatal state")
  | Activation_failure _ -> "Snapshot activation failure"
  | Asset_failure diagnostic -> Logseq_db_types.Failure_diagnostic.message diagnostic
  | Unexpected_failure message -> "Unexpected failure: " ^ message
;;

let ( let* ) = task_bind
let task_effect operation = task_perform operation ~success:task_return ~failure:task_fail

let attempt operation =
  task_perform
    operation
    ~success:(fun value -> task_return (Ok value))
    ~failure:(fun error -> task_return (Error error))
;;

let rec capacity_task_effect : type value. value task_operation -> value task =
  fun operation ->
  let* revision = task_effect Capacity_revision in
  let* result = attempt operation in
  match result with
  | Ok value -> task_return value
  | Error (Capacity_exceeded _) ->
    let* () = task_effect (Await_capacity_changed revision) in
    capacity_task_effect operation
  | Error error -> task_fail error
;;

let rec capture_task : type value. value task -> (value, error) result task =
  fun task ->
  match task_view task with
  | Task_return value -> task_return (Ok value)
  | Task_fail error -> task_return (Error error)
  | Task_perform (operation, success, failure) ->
    task_perform
      operation
      ~success:(fun value -> capture_task (success value))
      ~failure:(fun error -> capture_task (failure error))
  | Task_bind (first, continuation) ->
    let* result = capture_task first in
    (match result with
     | Ok value -> capture_task (continuation value)
     | Error error -> task_return (Error error))
  | Task_scope body -> with_scope (fun scope -> capture_task (body scope))
  | Task_spawn (scope, body) ->
    let* value = spawn scope body in
    task_return (Ok value)
  | Task_spawn_asset (scope, receipt, body) ->
    let* value = spawn_asset scope receipt body in
    task_return (Ok value)
  | Task_join child ->
    let* value = join child in
    task_return (Ok value)
  | Task_cancel child ->
    let* () = cancel_child child in
    task_return (Ok ())
;;

let finalize primary cleanup =
  let* cleaned = capture_task cleanup in
  match primary, cleaned with
  | Ok value, Ok () -> task_return value
  | Error error, Ok () -> task_fail error
  | Ok _, Error error ->
    task_fail (Cleanup_failure { primary = None; failures = Rrbvec.singleton error })
  | Error error, Error cleanup ->
    task_fail
      (Cleanup_failure { primary = Some error; failures = Rrbvec.singleton cleanup })
;;

let retry_delay retry attempt =
  let rec grow remaining seconds =
    if remaining = 0 || seconds >= retry.maximum_seconds
    then min seconds retry.maximum_seconds
    else grow (remaining - 1) (min retry.maximum_seconds (seconds *. retry.multiplier))
  in
  grow attempt retry.initial_seconds
;;

module Types = Overlay.Types
module Cursor = Types.Server_cursor

let request connection operation =
  capacity_task_effect (Task_transport (On_connection (connection, operation)))
;;

let inspect () = capacity_task_effect (Task_database Inspect)
let checkpoint view = Types.sync_view_checkpoint view
let token view = Types.sync_view_token view
let greatest first second = if Cursor.compare first second >= 0 then first else second

let rec settle_reply batch reply =
  let* view = inspect () in
  let batch_id = Types.submission_batch_id batch in
  let transition =
    match reply with
    | Accepted barrier -> Types.Accept_group { batch_id; barrier }
    | Rejected resolution -> Types.Reject_group { batch_id; resolution }
  in
  let* result =
    capture_task
      (capacity_task_effect (Task_database (Prepare_submission (token view, transition))))
  in
  match result with
  | Ok _ -> task_return ()
  | Error
      (Outbox_failure
         (Types.Outbox_sync_token_conflict | Types.Outbox_commit_token_conflict)) ->
    let* () = task_effect Yield in
    settle_reply batch reply
  | Error error -> task_fail error
;;

let rec frozen_batch view transition =
  let* outcome =
    capture_task
      (capacity_task_effect (Task_database (Prepare_submission (token view, transition))))
  in
  match outcome with
  | Error
      (Outbox_failure
         (Types.Outbox_sync_token_conflict | Types.Outbox_commit_token_conflict)) ->
    let* view = inspect () in
    frozen_batch view transition
  | Error error -> task_fail error
  | Ok commit ->
    (match commit.Types.submission_batch with
     | Some batch -> task_return batch
     | None ->
       task_fail (Protocol_failure "submission preparation returned no durable wires"))
;;

let submitted view =
  List.find_map
    (fun (descriptor : Types.submission_descriptor) ->
       match descriptor.state with
       | Types.Submitted batch -> Some batch
       | _ -> None)
    (Types.sync_view_submissions view)
;;

let queued view =
  List.find_opt
    (fun (descriptor : Types.submission_descriptor) ->
       descriptor.state = Types.Queued && descriptor.dependency_eligible)
    (Types.sync_view_submissions view)
;;

let recover_submission connection view batch_id =
  let* () = task_effect (Publish_status Service_submitting) in
  let* batch = frozen_batch view (Types.Retry_group batch_id) in
  let* reply = request connection (Push batch) in
  settle_reply batch reply
;;

let rec apply_batch config connection batch =
  let* view = inspect () in
  let* applied =
    capture_task
      (capacity_task_effect (Task_database (Apply_authoritative (token view, batch))))
  in
  match applied with
  | Error
      (Authoritative_failure
         ( Types.Authoritative_sync_token_conflict
         | Types.Authoritative_commit_token_conflict )) ->
    let* () = task_effect Yield in
    apply_batch config connection batch
  | Error error -> task_fail error
  | Ok (Applied _) -> task_return ()
  | Ok (Deferred (Types.Await_submission_outcome batch_id)) ->
    let* fresh = inspect () in
    (match submitted fresh with
     | Some current when Types.Submission_batch_id.equal current batch_id ->
       let* () = recover_submission connection fresh batch_id in
       apply_batch config connection batch
     | _ ->
       let* () = task_effect (Sleep config.no_progress_seconds) in
       apply_batch config connection batch)
;;

let pull_once ?head config connection view =
  let* () = task_effect (Publish_status Service_pulling) in
  let since = checkpoint view in
  let* pulled = request connection (Pull since) in
  match pulled with
  | Pulled batch ->
    if Cursor.compare (Types.authoritative_batch_through batch) since <= 0
    then task_fail (Protocol_failure "non-advancing authoritative batch")
    else
      let* batch =
        match head with
        | Some head
          when Cursor.equal head.through (Types.authoritative_batch_through batch) ->
          (match head.expected_checksum, Types.authoritative_batch_checksum batch with
           | Some expected, None ->
             let transactions = Types.authoritative_batch_transactions batch in
             let bytes =
               List.fold_left
                 (fun total transaction ->
                    total
                    + Types.encoded_transaction_byte_length
                        (Types.authoritative_transaction_payload transaction))
                 0
                 transactions
             in
             (match
                Types.authoritative_batch
                  ~maximum_count:(List.length transactions)
                  ~maximum_bytes:bytes
                  ~transactions
                  ~through:head.through
                  ~checksum:(Some expected)
              with
              | Ok batch -> task_return batch
              | Error _ -> task_fail (Protocol_failure "Invalid authoritative batch"))
           | None, _ | Some _, Some _ -> task_return batch)
        | None | Some _ -> task_return batch
      in
      let* () = apply_batch config connection batch in
      task_return (Types.authoritative_batch_through batch)
  | No_progress report ->
    if (not (Cursor.equal report.since since)) || Cursor.compare report.through since < 0
    then task_fail (Protocol_failure "invalid no-progress baseline")
    else
      let* () =
        match report.expected_checksum with
        | Some expected when Cursor.equal report.through since ->
          task_effect (Task_database (Verify_checksum (report.through, expected)))
        | None | Some _ -> task_return ()
      in
      let* () = task_effect (Sleep config.no_progress_seconds) in
      task_return report.through
;;

let send_batch ?head config connection batch =
  let* () = task_effect (Publish_status Service_submitting) in
  let* outcome = capture_task (request connection (Push batch)) in
  match outcome with
  | Ok reply ->
    let* () = settle_reply batch reply in
    let target =
      match reply with
      | Accepted barrier -> barrier.Types.through
      | Rejected (Types.Stale { through }) -> through
      | Rejected (Types.Definitive { partition; _ }) ->
        (match partition.acceptance_barrier with
         | Some barrier -> barrier.through
         | None -> Types.submission_batch_t_before batch)
    in
    task_return target
  | Error (Outcome_unknown _) ->
    let* view = inspect () in
    pull_once ?head config connection view
  | Error error -> task_fail error
;;

let rec round config connection head target check =
  let* inspected = capture_task (inspect ()) in
  let* view =
    match inspected with
    | Ok view -> task_return view
    | Error error ->
      let cleanup =
        match check with
        | None -> task_return ()
        | Some check -> task_effect (Abandon_outbox_check check)
      in
      finalize (Error error) cleanup
  in
  let recovery = submitted view in
  let fresh = queued view in
  let* () =
    match check with
    | None -> task_return ()
    | Some check -> task_effect (Acknowledge_outbox_check check)
  in
  let* () =
    match head.expected_checksum with
    | Some expected when Cursor.equal head.through (checkpoint view) ->
      task_effect (Task_database (Verify_checksum (head.through, expected)))
    | None | Some _ -> task_return ()
  in
  match recovery with
  | Some batch_id ->
    let* batch = frozen_batch view (Types.Retry_group batch_id) in
    let* through = send_batch ~head config connection batch in
    let* () = task_effect Yield in
    round config connection head (greatest target through) None
  | None when Cursor.compare (checkpoint view) target < 0 ->
    let* through = pull_once ~head config connection view in
    let* () = task_effect Yield in
    round config connection head (greatest target through) None
  | None ->
    (match fresh with
     | Some descriptor ->
       let* batch = frozen_batch view (Types.Submit_group [ descriptor.mutation_id ]) in
       let* through = send_batch ~head config connection batch in
       let* head = request connection Head in
       round config connection head (greatest through (greatest target head.through)) None
     | None ->
       let unsettled =
         List.exists
           (fun (descriptor : Types.submission_descriptor) ->
              match descriptor.state with
              | Types.Accepted_pending_authoritative _
              | Types.Stale_rejected_pending_authoritative _ -> true
              | Types.Submitted _ | Types.Queued | Types.Blocked -> false)
           (Types.sync_view_submissions view)
       in
       if unsettled
       then
         let* through = pull_once ~head config connection view in
         round config connection head (greatest target through) None
       else task_return (checkpoint view))
;;

let rec activate_initial () =
  let* observation = task_effect Task_observe in
  match observation.checkpoint with
  | Some _ -> task_return ()
  | None ->
    let* check = task_effect Await_outbox_changed in
    let* fetched = capture_task (capacity_task_effect (Task_transport Fetch_snapshot)) in
    let* staged =
      match fetched with
      | Ok staged -> task_return staged
      | Error error -> finalize (Error error) (task_effect (Abandon_outbox_check check))
    in
    let* activation =
      capture_task
        (let* () = task_effect (Acknowledge_outbox_check check) in
         task_effect (Task_database (Activate_snapshot staged)))
    in
    let* activation =
      finalize activation (task_effect (Task_database (Release_snapshot staged)))
    in
    (match activation with
     | Activated _ -> task_return ()
     | Activation_deferred _ -> activate_initial ())
;;

type demand_wait =
  | Demand_complete
  | Wait_network
  | Wait_unlock
  | Wait_remote
  | Wait_repair
  | Wait_network_repair
  | Retry_asset of asset_failure_reason

type demand_progress =
  { asset_wait : demand_wait
  ; asset_attempts : int
  ; asset_retries : int
  }

let asset_reason = function
  | Network_failure message -> Asset_network message
  | Network_closed -> Asset_network_closed
  | Authentication_failure message -> Asset_authentication message
  | Locked -> Asset_locked
  | Cancelled -> Asset_cancelled
  | error -> Asset_other error
;;

let publish receipt state = capacity_task_effect (Publish_demand (receipt, state))

let release_asset file lease =
  let* lease_result =
    match lease with
    | None -> task_return (Ok ())
    | Some lease -> attempt (Task_assets (Release_lease lease))
  in
  let* file_result = attempt (Task_assets (Release_file file)) in
  match lease_result, file_result with
  | Ok (), Ok () -> task_return ()
  | Error error, Ok () | Ok (), Error error -> task_fail error
  | Error first, Error second ->
    task_fail
      (Cleanup_failure { primary = Some first; failures = Rrbvec.singleton second })
;;

let deliver_file receipt file =
  let* retained = attempt (Task_assets (Retain file)) in
  match retained with
  | Error error -> finalize (Error error) (release_asset file None)
  | Ok lease ->
    let* delivered = capture_task (publish receipt (Demand_available (file, lease))) in
    (match delivered with
     | Ok () -> task_return Demand_complete
     | Error error -> finalize (Error error) (release_asset file (Some lease)))
;;

let demand_task config receipt ~attempts ~retries ~retry =
  let* () =
    match retry with
    | None -> publish receipt Demand_queued
    | Some reason ->
      let* () =
        publish receipt (Demand_failed { reason; attempts; retry_scheduled = true })
      in
      task_effect (Sleep (retry_delay config.asset_retry retries))
  in
  let* report = capacity_task_effect (Download_demand receipt) in
  let attempts = attempts + report.attempts in
  let retries = retries + if retry <> None && report.attempts > 0 then 1 else 0 in
  let* wait =
    match report.result with
    | Ok (Available file) -> deliver_file receipt file
    | Ok Waiting_remote ->
      let* () = publish receipt Demand_waiting_remote in
      task_return Wait_remote
    | Ok Missing_local ->
      let* () = publish receipt Demand_missing_local in
      task_return Wait_repair
    | Error Asset_network_closed ->
      let* () = publish receipt Demand_waiting_network in
      task_return Wait_network
    | Error Asset_locked ->
      let* () = publish receipt Demand_waiting_unlock in
      task_return Wait_unlock
    | Error reason ->
      let* () =
        publish receipt (Demand_failed { reason; attempts; retry_scheduled = false })
      in
      (match reason with
       | Asset_network _
         when report.attempts > 0 && retries < config.asset_retry.maximum_attempts ->
         task_return (Retry_asset reason)
       | Asset_network _ -> task_return Wait_network_repair
       | _ -> task_return Wait_repair)
  in
  let* () =
    match wait with
    | Retry_asset _ -> task_return ()
    | _ -> task_effect (Finish_demand receipt)
  in
  task_return
    { asset_wait = wait
    ; asset_attempts = attempts
    ; asset_retries = (if wait = Demand_complete then 0 else retries)
    }
;;

type policy_event =
  | Policy_initial
  | Policy_connected of connection
  | Policy_head of remote_head
  | Policy_round of Types.server_cursor
  | Policy_received of received
  | Policy_outbox of outbox_check
  | Policy_timer
  | Policy_capacity
  | Policy_demand of demand_progress
  | Policy_unlocked of key_status

type job_kind =
  | Initial_job
  | Connecting_job
  | Head_job
  | Round_job
  | Receive_job
  | Outbox_job
  | Retry_job
  | Capacity_job
  | Unlock_job
  | Demand_job of demand_id * demand_receipt

type policy_job =
  { kind : job_kind
  ; child : policy_event child
  }

type policy_demand =
  { demand_id : demand_id
  ; receipt : demand_receipt
  ; change : demand_change
  ; wait : demand_wait option
  ; attempts : int
  ; retries : int
  }

type policy_state =
  { jobs : policy_job list
  ; connection : connection option
  ; head : remote_head option
  ; target : Types.server_cursor option
  ; checked : outbox_check option
  ; initialized : bool
  ; snapshot_ready : bool
  ; dirty : bool
  ; failure : error option
  ; retries : int
  ; retry_pending : bool
  ; backoff : (float * error) option
  ; unlock_pending : unlock_receipt option
  ; gate : network_gate
  ; keys : key_status
  ; demands : policy_demand list
  }

let same_kind first second =
  match first, second with
  | Initial_job, Initial_job
  | Connecting_job, Connecting_job
  | Head_job, Head_job
  | Round_job, Round_job
  | Receive_job, Receive_job
  | Outbox_job, Outbox_job
  | Retry_job, Retry_job
  | Capacity_job, Capacity_job
  | Unlock_job, Unlock_job -> true
  | Demand_job (first_id, first_receipt), Demand_job (second_id, second_receipt) ->
    compare_demand_id first_id second_id = 0 && first_receipt == second_receipt
  | _ -> false
;;

let has_job state kind = List.exists (fun job -> same_kind job.kind kind) state.jobs

let network_open = function
  | Open _ -> true
  | Closed -> false
;;

let epoch = function
  | Closed -> None
  | Open { authorization_epoch } -> Some authorization_epoch
;;

let sync_retryable = function
  | Network_failure _ -> true
  | _ -> false
;;

let add_job scope state kind task =
  let* _revision = task_effect Capacity_revision in
  let* spawned =
    match kind with
    | Demand_job (_, receipt) -> spawn_asset scope receipt task
    | _ -> spawn scope task
  in
  match spawned with
  | Ok child -> task_return { state with jobs = state.jobs @ [ { kind; child } ] }
  | Error (Capacity_exceeded _) -> task_return state
  | Error error -> task_fail error
;;

let mapped task constructor =
  let* value = task in
  task_return (constructor value)
;;

let schedule config scope state =
  let* state =
    if has_job state Capacity_job
    then task_return state
    else
      let* revision = task_effect Capacity_revision in
      let* next =
        add_job
          scope
          state
          Capacity_job
          (let* () = task_effect (Await_capacity_changed revision) in
           task_return Policy_capacity)
      in
      if has_job next Capacity_job
      then task_return next
      else task_fail (Capacity_exceeded "reserved policy control task")
  in
  let* state =
    match state.unlock_pending with
    | Some receipt when not (has_job state Unlock_job) ->
      let* next =
        add_job
          scope
          state
          Unlock_job
          (mapped (task_effect (Consume_unlock receipt)) (fun keys ->
             Policy_unlocked keys))
      in
      if has_job next Unlock_job
      then task_return { next with unlock_pending = None }
      else task_return next
    | _ -> task_return state
  in
  let* state =
    match state.backoff with
    | Some (seconds, _) when network_open state.gate && not (has_job state Retry_job) ->
      let* next =
        add_job
          scope
          state
          Retry_job
          (let* () = task_effect (Sleep seconds) in
           task_return Policy_timer)
      in
      if has_job next Retry_job
      then task_return { next with backoff = None }
      else task_return next
    | _ -> task_return state
  in
  let* state =
    if
      (not (network_open state.gate))
      || state.keys = Key_locked
      || state.failure <> None
      || state.backoff <> None
      || has_job state Retry_job
    then task_return state
    else if not state.snapshot_ready
    then
      if has_job state Initial_job
      then task_return state
      else
        add_job
          scope
          state
          Initial_job
          (let* () = task_effect (Publish_status Service_pulling) in
           let* () = task_effect Resample_outbox in
           let* () = activate_initial () in
           task_return Policy_initial)
    else (
      match state.connection with
      | None ->
        if has_job state Connecting_job
        then task_return state
        else
          let* () = task_effect (Publish_status Service_connecting) in
          add_job
            scope
            state
            Connecting_job
            (mapped (capacity_task_effect (Task_transport Connect)) (fun connection ->
               Policy_connected connection))
      | Some connection ->
        let* state =
          if has_job state Receive_job
          then task_return state
          else
            add_job
              scope
              state
              Receive_job
              (mapped (task_effect (Task_transport (Receive connection))) (fun received ->
                 Policy_received received))
        in
        (match state.head with
         | None ->
           if has_job state Head_job
           then task_return state
           else
             add_job
               scope
               state
               Head_job
               (mapped (request connection Head) (fun head -> Policy_head head))
         | Some head ->
           let* state =
             if
               state.initialized
               && (not (has_job state Outbox_job))
               && state.checked = None
             then
               add_job
                 scope
                 state
                 Outbox_job
                 (mapped (task_effect Await_outbox_changed) (fun check ->
                    Policy_outbox check))
             else task_return state
           in
           if (state.dirty || state.checked <> None) && not (has_job state Round_job)
           then (
             let target =
               match state.target with
               | Some target -> target
               | None -> head.through
             in
             let task =
               let* () = task_effect (Publish_status Service_pulling) in
               mapped (round config connection head target state.checked) (fun cursor ->
                 Policy_round cursor)
             in
             let* next = add_job scope state Round_job task in
             if has_job next Round_job
             then task_return { next with dirty = false; checked = None }
             else task_return next)
           else task_return state))
  in
  let rec demands state = function
    | [] -> task_return state
    | demand :: rest ->
      let kind = Demand_job (demand.demand_id, demand.receipt) in
      let retry =
        match demand.wait with
        | Some (Retry_asset reason) -> Some reason
        | _ -> None
      in
      if (demand.wait <> None && retry = None) || has_job state kind
      then demands state rest
      else (
        let task =
          match demand.change with
          | Withdraw _ ->
            let* () = publish demand.receipt Demand_revoked in
            let* () = task_effect (Finish_demand demand.receipt) in
            task_return
              (Policy_demand
                 { asset_wait = Demand_complete; asset_attempts = 0; asset_retries = 0 })
          | Demand _ ->
            mapped
              (demand_task
                 config
                 demand.receipt
                 ~attempts:demand.attempts
                 ~retries:demand.retries
                 ~retry)
              (fun progress -> Policy_demand progress)
        in
        let* next = add_job scope state kind task in
        demands next rest)
  in
  demands state state.demands
;;

let cancel_jobs jobs =
  let rec cancel = function
    | [] -> task_return ()
    | job :: rest ->
      let* () = cancel_child job.child in
      cancel rest
  in
  let rec collect failures = function
    | [] ->
      (match List.rev failures with
       | [] -> task_return ()
       | failures ->
         task_fail
           (Cleanup_failure { primary = None; failures = Rrbvec.of_list failures }))
    | job :: rest ->
      let* result = join job.child in
      let* cleanup =
        match result with
        | Ok (Policy_connected connection) ->
          attempt (Task_transport (Retire_connection connection))
        | Ok (Policy_outbox check) -> attempt (Abandon_outbox_check check)
        | Ok _ | Error _ -> task_return (Ok ())
      in
      let failures =
        match cleanup with
        | Ok () -> failures
        | Error error -> error :: failures
      in
      let failures =
        match result with
        | Ok _ | Error Cancelled | Error Network_closed | Error Stale_context -> failures
        | Error error -> error :: failures
      in
      collect failures rest
  in
  let* () = cancel jobs in
  collect [] jobs
;;

let abandon = function
  | None -> task_return ()
  | Some check -> task_effect (Abandon_outbox_check check)
;;

let disconnect state =
  let connection_jobs, other_jobs =
    List.partition
      (fun job ->
         match job.kind with
         | Initial_job
         | Connecting_job
         | Head_job
         | Round_job
         | Receive_job
         | Outbox_job
         | Retry_job -> true
         | Capacity_job | Unlock_job | Demand_job _ -> false)
      state.jobs
  in
  let* cancelled = capture_task (cancel_jobs connection_jobs) in
  let* () = abandon state.checked in
  let cleanup =
    match state.connection with
    | None -> task_return ()
    | Some connection -> task_effect (Task_transport (Retire_connection connection))
  in
  let* () = finalize cancelled cleanup in
  task_return
    { state with
      jobs = other_jobs
    ; connection = None
    ; head = None
    ; target = None
    ; checked = None
    ; initialized = false
    ; dirty = true
    ; backoff = None
    ; retry_pending = false
    }
;;

let block_sync config _scope state error =
  let* state = disconnect state in
  match error with
  | Cleanup_failure _ -> task_fail error
  | Network_closed ->
    let* () = task_effect (Publish_status Service_waiting_network) in
    task_return { state with failure = Some error }
  | Locked ->
    let* () = task_effect (Publish_status Service_waiting_unlock) in
    task_return { state with failure = Some error; keys = Key_locked }
  | error
    when sync_retryable error
         && network_open state.gate
         && state.retries < config.sync_retry.maximum_attempts ->
    let seconds = retry_delay config.sync_retry state.retries in
    let attempt = state.retries + 1 in
    let* () =
      task_effect (Publish_status (Service_backoff { attempt; seconds; cause = error }))
    in
    task_return { state with backoff = Some (seconds, error) }
  | error ->
    let* () = task_effect (Publish_status (Service_blocked error)) in
    task_return { state with failure = Some error }
;;

let replace_demand state receipt change =
  let id =
    match change with
    | Demand demand -> demand.id
    | Withdraw id -> id
  in
  let removed, jobs =
    List.partition
      (fun job ->
         match job.kind with
         | Demand_job (current, _) -> compare_demand_id current id = 0
         | _ -> false)
      state.jobs
  in
  let* () = cancel_jobs removed in
  let demands =
    List.filter (fun demand -> compare_demand_id demand.demand_id id <> 0) state.demands
  in
  task_return
    { state with
      jobs
    ; demands =
        demands
        @ [ { demand_id = id; receipt; change; wait = None; attempts = 0; retries = 0 } ]
    }
;;

let resume_demands predicate state =
  { state with
    demands =
      List.map
        (fun demand ->
           if predicate demand.wait then { demand with wait = None } else demand)
        state.demands
  }
;;

let suspend_demands state =
  let affected, remaining =
    List.partition
      (fun job ->
         match job.kind with
         | Demand_job _ -> true
         | _ -> false)
      state.jobs
  in
  let rec cancel = function
    | [] -> task_return ()
    | job :: rest ->
      let* () = cancel_child job.child in
      cancel rest
  in
  let rec collect demands = function
    | [] -> task_return { state with jobs = remaining; demands }
    | job :: rest ->
      let* result = join job.child in
      let* id, receipt =
        match job.kind with
        | Demand_job (id, receipt) -> task_return (id, receipt)
        | _ -> task_fail (Protocol_failure "mismatched asset cancellation")
      in
      let update demand =
        if compare_demand_id id demand.demand_id <> 0 || receipt != demand.receipt
        then demand
        else (
          match result with
          | Ok (Policy_demand progress) ->
            let wait =
              match progress.asset_wait with
              | Retry_asset _ -> None
              | wait -> Some wait
            in
            { demand with
              wait
            ; attempts = progress.asset_attempts
            ; retries = progress.asset_retries
            }
          | Error Cancelled | Error Network_closed -> { demand with wait = None }
          | _ -> { demand with wait = Some Wait_repair })
      in
      (match result with
       | Error (Cleanup_failure _ as error) -> task_fail error
       | _ -> collect (List.map update demands) rest)
  in
  let* () = cancel affected in
  collect state.demands affected
;;

let policy_task config =
  with_scope (fun scope ->
    let* observation = task_effect Task_observe in
    let initial =
      { jobs = []
      ; connection = None
      ; head = None
      ; target = None
      ; checked = None
      ; initialized = false
      ; snapshot_ready = Option.is_some observation.checkpoint
      ; dirty = true
      ; failure = None
      ; retries = 0
      ; retry_pending = false
      ; backoff = None
      ; unlock_pending = None
      ; gate = observation.network
      ; keys = observation.keys
      ; demands = []
      }
    in
    let rec loop state =
      let* state = schedule config scope state in
      let children = Rrbvec.of_list (List.map (fun job -> job.child) state.jobs) in
      let* wake = task_effect (Await_input_or_child children) in
      match wake with
      | Input Stop_requested ->
        let* cancelled = capture_task (cancel_jobs state.jobs) in
        let* () = abandon state.checked in
        let cleanup =
          match state.connection with
          | None -> task_return ()
          | Some connection -> task_effect (Task_transport (Retire_connection connection))
        in
        let* () = finalize cancelled cleanup in
        task_effect (Publish_status Service_idle)
      | Input (Demand_changed (receipt, change)) ->
        let* state = replace_demand state receipt change in
        loop state
      | Input (Unlock_requested receipt) ->
        loop { state with unlock_pending = Some receipt }
      | Input (Network_changed gate) ->
        let new_epoch = network_open gate && epoch gate <> epoch state.gate in
        let* state =
          if network_open gate
          then task_return state
          else
            let* state = disconnect state in
            suspend_demands state
        in
        let failure =
          match state.failure with
          | Some Network_closed when network_open gate -> None
          | Some (Network_failure _) when new_epoch -> None
          | failure -> failure
        in
        let state =
          { state with
            gate
          ; failure
          ; retries = (if new_epoch then 0 else state.retries)
          ; dirty = true
          }
        in
        let state =
          if network_open gate
          then
            resume_demands
              (function
                | Some Wait_network -> true
                | _ -> false)
              state
          else state
        in
        let state =
          if new_epoch
          then
            { state with
              demands =
                List.map
                  (fun demand ->
                     match demand.wait with
                     | Some Wait_network_repair ->
                       { demand with wait = None; retries = 0 }
                     | _ -> demand)
                  state.demands
            }
          else state
        in
        let* () =
          if not (network_open gate)
          then task_effect (Publish_status Service_waiting_network)
          else (
            match state.failure with
            | Some Locked -> task_effect (Publish_status Service_waiting_unlock)
            | Some error -> task_effect (Publish_status (Service_blocked error))
            | None -> task_effect Resample_outbox)
        in
        loop state
      | Child_ready child ->
        (match List.find_opt (fun job -> equal_child child job.child) state.jobs with
         | None -> task_fail (Protocol_failure "foreign policy completion")
         | Some job ->
           let* result = join child in
           let state =
             { state with
               jobs =
                 List.filter (fun job -> not (equal_child child job.child)) state.jobs
             }
           in
           (match result with
            | Error (Cleanup_failure _ as error) -> task_fail error
            | Error error ->
              (match job.kind with
               | Demand_job (id, receipt) ->
                 let* delivered =
                   attempt
                     (Publish_demand
                        ( receipt
                        , Demand_failed
                            { reason = asset_reason error
                            ; attempts = 0
                            ; retry_scheduled = false
                            } ))
                 in
                 (match delivered with
                  | Error (Cleanup_failure _ as error) -> task_fail error
                  | _ ->
                    let demands =
                      List.map
                        (fun demand ->
                           if compare_demand_id demand.demand_id id = 0
                           then { demand with wait = Some Wait_repair }
                           else demand)
                        state.demands
                    in
                    loop { state with demands })
               | Unlock_job ->
                 let* () = task_effect (Publish_status (Service_blocked error)) in
                 loop state
               | Capacity_job -> task_fail error
               | _ ->
                 let retries =
                   if
                     (same_kind job.kind Connecting_job || same_kind job.kind Initial_job)
                     && state.retry_pending
                     && error <> Network_closed
                     && error <> Locked
                   then state.retries + 1
                   else state.retries
                 in
                 let* state = block_sync config scope { state with retries } error in
                 loop state)
            | Ok event ->
              (match event with
               | Policy_initial -> loop { state with snapshot_ready = true }
               | Policy_capacity -> loop state
               | Policy_timer -> loop { state with retry_pending = true }
               | Policy_connected connection ->
                 let* () = task_effect Resample_outbox in
                 loop
                   { state with
                     connection = Some connection
                   ; retries = (state.retries + if state.retry_pending then 1 else 0)
                   ; retry_pending = false
                   }
               | Policy_head head ->
                 loop
                   { state with
                     head = Some head
                   ; target = Some head.through
                   ; dirty = true
                   }
               | Policy_round cursor ->
                 let dirty =
                   state.dirty
                   ||
                   match state.target with
                   | Some target -> Cursor.compare cursor target < 0
                   | None -> false
                 in
                 let* () =
                   task_effect
                     (Publish_status (if dirty then Service_pulling else Service_online))
                 in
                 loop { state with initialized = true; retries = 0; dirty }
               | Policy_outbox check ->
                 loop { state with checked = Some check; dirty = true }
               | Policy_unlocked keys ->
                 let failure =
                   match state.failure with
                   | Some Locked -> None
                   | failure -> failure
                 in
                 let state =
                   resume_demands
                     (function
                       | Some Wait_unlock -> true
                       | _ -> false)
                     state
                 in
                 let* () = task_effect Resample_outbox in
                 loop { state with keys; failure; dirty = true }
               | Policy_demand progress ->
                 (match job.kind with
                  | Demand_job (id, _) ->
                    let demands =
                      List.map
                        (fun demand ->
                           if compare_demand_id demand.demand_id id = 0
                           then
                             { demand with
                               wait = Some progress.asset_wait
                             ; attempts = progress.asset_attempts
                             ; retries = progress.asset_retries
                             }
                           else demand)
                        state.demands
                    in
                    let demands =
                      List.filter
                        (fun demand ->
                           match demand.change, demand.wait with
                           | Withdraw _, Some Demand_complete -> false
                           | _ -> true)
                        demands
                    in
                    loop { state with demands }
                  | _ -> task_fail (Protocol_failure "mismatched demand completion"))
               | Policy_received received ->
                 (match received.message with
                  | Remote_changed head ->
                    let target =
                      match state.target with
                      | None -> head.through
                      | Some target -> greatest target head.through
                    in
                    let state =
                      resume_demands
                        (function
                          | Some Wait_remote -> true
                          | _ -> false)
                        state
                    in
                    loop { state with target = Some target; dirty = true }
                  | Remote_error message ->
                    let* state =
                      block_sync config scope state (Protocol_failure message)
                    in
                    loop state
                  | Connection_ended reason ->
                    let error =
                      match reason with
                      | Remote_closed -> Network_failure "remote closed"
                      | Network_lost message -> Network_failure message
                      | Access_revoked message -> Authentication_failure message
                      | Invalid_protocol message -> Protocol_failure message
                      | Locally_closed -> Network_closed
                    in
                    let* state = block_sync config scope state error in
                    loop state))))
    in
    let* () =
      task_effect
        (Publish_status
           (if not (network_open initial.gate)
            then Service_waiting_network
            else if initial.keys = Key_locked
            then Service_waiting_unlock
            else Service_idle))
    in
    loop initial)
;;

let sync_policy config ~initial_network =
  perform Restore ~failure:abort ~success:(fun _ ->
    perform (Install_initial_network initial_network) ~failure:abort ~success:(fun () ->
      perform (Run_task (policy_task config)) ~success:return ~failure:abort))
;;
