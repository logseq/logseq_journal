module Dsl = Sync_dsl.Core
module Owner = Logseq_sync_execute_owners.Database_owner

let ( let* ) = Result.bind

type snapshot_source =
  { path : string
  ; expected_rows : int
  }

type database_owner =
  { binding : Owner.t
  ; snapshot_source : (Dsl.snapshot -> (snapshot_source, Dsl.error) result) option
  ; mutable bound : bool
  }

type callback_control =
  { stop : unit -> (unit, Dsl.error) result
  ; await_stopped : deadline:float -> (unit, Dsl.error) result
  }

type effect_scope =
  { check : unit -> (unit, Dsl.error) result
  ; admit : unit -> (unit, Dsl.error) result
  ; transfer : Dsl.resource_reference Rrbvec.t -> (unit, Dsl.error) result
  ; reserve_producer : callback_control -> (unit, Dsl.error) result
  ; forget_producer : callback_control -> unit
  ; retain_failure : Dsl.error -> unit
  ; now : unit -> float
  ; cleanup_seconds : float
  ; mutable live : bool
  }

let check_current scope = if scope.live then scope.check () else Error Dsl.Stale_context

let admit_network scope =
  let* () = check_current scope in
  scope.admit ()
;;

let handoff scope resources = scope.transfer resources

type dispatch =
  { database :
      'a.
      owner:database_owner
      -> scope:effect_scope
      -> identity:Dsl.identity
      -> 'a Dsl.database
      -> ('a, Dsl.error) result
  ; transport :
      'a.
      scope:effect_scope
      -> identity:Dsl.identity
      -> 'a Dsl.transport
      -> ('a, Dsl.error) result
  ; crypto :
      'a.
      scope:effect_scope
      -> identity:Dsl.identity
      -> 'a Dsl.crypto
      -> ('a, Dsl.error) result
  ; assets :
      'a.
      scope:effect_scope
      -> identity:Dsl.identity
      -> 'a Dsl.assets
      -> ('a, Dsl.error) result
  }

type websocket_liveness =
  | Peer_close_only
  | Ping_pong of
      { interval_seconds : float
      ; timeout_seconds : float
      }

type network_deadlines =
  { setup_seconds : float
  ; tls_handshake_seconds : float
  ; http_response_seconds : float
  ; download_seconds : float
  }

type worker_network =
  { with_admission : 'a. (unit -> ('a, Dsl.error) result) -> ('a, Dsl.error) result }

module type WORKER_OWNER = sig
  type scope
  type imported_file

  val bind_runtime
    :  identity:Dsl.identity
    -> database_owner:database_owner
    -> limits:Dsl.limits
    -> cleanup_seconds:float
    -> network:worker_network
    -> (unit, Dsl.error) result

  val with_scope
    :  identity:Dsl.identity
    -> operation:Logseq_db_types.Graph_types.Uuid.t
    -> (scope -> ('a, Dsl.error) result)
    -> ('a, Dsl.error) result

  val crypto : scope -> 'a Dsl.crypto -> ('a, Dsl.error) result

  val prepare_import
    :  scope
    -> Logseq_db_types.Asset_import.t
    -> (Logseq_db_types.Asset_upload_intent.t, Dsl.error) result

  val publish_import_preview
    :  scope
    -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result

  val persist_import
    :  scope
    -> Logseq_db_types.Asset_upload_intent.t
    -> expected:int option
    -> (unit, Dsl.error) result

  val inspect_import
    :  scope
    -> Logseq_db_types.Asset_upload_intent.t
    -> ( [ `Import_absent
         | `Local_present
         | `Metadata_present
         | `Publication_acknowledged
         | `Entity_cancelled
         ]
         , Dsl.error )
         result

  val apply_local_import
    :  scope
    -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result

  val put_import
    :  scope
    -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result

  val apply_import_metadata
    :  scope
    -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result

  val await_import_publication
    :  scope
    -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result

  val cancel_import
    :  scope
    -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result

  val release_import_staging
    :  scope
    -> Logseq_db_types.Asset_upload_intent.t
    -> (unit, Dsl.error) result

  val recover_import_inputs
    :  scope
    -> after:int64 option
    -> maximum_items:int
    -> maximum_bytes:int
    -> (Logseq_db_types.Asset_import.Recovery.page, Dsl.error) result

  val confirm_import_input
    :  scope
    -> string
    -> (Logseq_db_types.Asset_import.Recovery.item option, Dsl.error) result

  val acknowledge_import_input
    :  scope
    -> input:string
    -> prepared:string
    -> (unit, Dsl.error) result

  val cancel : scope -> (unit, Dsl.error) result

  val retain_imported_file
    :  scope
    -> Logseq_db_types.Asset_upload_intent.t
    -> (imported_file option, Dsl.error) result

  val imported_file_path : imported_file -> string
  val release_imported_file : imported_file -> (unit, Dsl.error) result
  val fence : identity:Dsl.identity -> (unit, Dsl.error) result
  val await_quiescent : identity:Dsl.identity -> (unit, Dsl.error) result
end

type capabilities =
  { validate_identity : Dsl.identity -> (unit, Dsl.error) result
  ; validate_limits : Dsl.limits -> (unit, Dsl.error) result
  ; websocket_liveness : websocket_liveness
  ; network_deadlines : network_deadlines
  ; cleanup_seconds : float
  ; acquire : Dsl.identity -> (unit, Dsl.error) result
  ; fence_network : Dsl.identity -> (unit, Dsl.error) result
  ; close_network : Dsl.identity -> (unit, Dsl.error) result
  ; authorize_network : Dsl.identity -> epoch:int64 -> (unit, Dsl.error) result
  ; validate_resource : Dsl.resource_reference -> (unit, Dsl.error) result
  ; restore : scope:effect_scope -> Dsl.identity -> (Dsl.restore_report, Dsl.error) result
  ; worker_owner : (module WORKER_OWNER)
  ; dispatch : dispatch
  ; observe : Dsl.identity -> (Dsl.observation, Dsl.error) result
  ; fence : Dsl.identity -> (unit, Dsl.error) result
  ; retire : Dsl.identity -> (unit, Dsl.error) result
  ; release_file : Dsl.identity -> Dsl.asset_file -> (unit, Dsl.error) result
  ; release_lease : Dsl.identity -> Dsl.asset_lease -> (unit, Dsl.error) result
  ; release_snapshot : Dsl.identity -> Dsl.snapshot -> (unit, Dsl.error) result
  }

type version = unit ref

type t =
  { sw : Eio.Switch.t
  ; now : unit -> float
  ; sleep : float -> unit
  ; id : Dsl.identity
  ; limits : Dsl.limits
  ; caps : capabilities
  ; owner : database_owner
  ; producer : Dsl.Producer.owner
  ; changed : Eio.Condition.t
  ; mutable actual : context option
  ; mutable revision : int64
  ; mutable current_version : version
  ; mutable busy : unit ref option
  ; mutable fenced : bool
  ; mutable gate : Dsl.network_gate
  ; mutable generation : int64
  ; mutable retirement : network_retirement option
  ; mutable initial_eligible : bool
  ; mutable network_calls : network_call list
  ; mutable producers : callback_control list
  ; mutable resources : resource_entry list
  ; mutable reserved_resources : int
  ; mutable cleanup : Dsl.error list
  ; mutable active : task_scope option
  ; mutable scopes : task_scope list
  ; mutable tasks : int
  ; mutable asset_work : asset_work list
  ; mutable capacity : int64
  ; mutable stop : bool
  ; mutable network_input : Dsl.network_gate option
  ; mutable unlock : unlock option
  ; mutable demands : demand_entry list
  ; mutable deliveries : delivery_entry list
  ; mutable receiver : bool
  ; mutable input_reader : bool
  ; mutable outbox_epoch : int64
  ; mutable outbox_acked : int64
  ; mutable outbox_check : (Dsl.outbox_check * int64) option
  ; mutable keys : Dsl.key_status
  ; mutable status : Dsl.service_status
  ; mutable last_failure : Dsl.error option
  ; mutable observation : Dsl.observation option
  ; mutable observation_reader : bool
  }

and 's graph_context =
  { runtime : t
  ; phase : 's Dsl.phase
  ; version : version
  }

and context = Context : 's Dsl.phase * 's graph_context -> context

and network_retirement =
  { runtime : t
  ; generation : int64
  ; fence_result : (unit, Dsl.error) result
  ; mutable result : (unit, Dsl.error) result option
  ; mutable joining : bool
  }

and network_call =
  { generation : int64
  ; mutable cancel_network : (unit -> unit) option
  ; done_ : unit Eio.Promise.t
  }

and resource_entry =
  { reference : Dsl.resource_reference
  ; mutable released : bool
  ; mutable delivery_owned : bool
  ; mutable releasing : bool
  }

and task_scope =
  { handle : Dsl.scope
  ; mutable live : bool
  ; mutable children : child_control list
  ; mutable notifications : notification_channel list
  ; mutable prefer_child : bool
  }

and asset_work =
  { asset : Dsl.asset
  ; mutable interests : (unit ref * Dsl.demand_change option) list
  ; mutable download : Dsl.asset_result asset_attempt option
  ; mutable download_files : Dsl.asset_file list
  ; mutable upload : unit asset_attempt option
  }

and 'a asset_attempt =
  { outcome : ('a, Dsl.error) result Eio.Promise.t
  ; mutable waiters : int
  ; mutable cancellation : Eio.Cancel.t option
  ; mutable physically_joined : bool
  }

and child_control =
  { key : Obj.t
  ; cancel_child : unit -> unit
  ; join_child : unit -> Dsl.error option
  ; mutable consumed : bool
  ; release_capacity : unit -> unit
  }

and notification_channel =
  { handle : Dsl.notifications
  ; queue : (Dsl.notification * int) Queue.t
  ; mutable reading : bool
  }

and unlock =
  { mutable receipt : Dsl.unlock_receipt
  ; input : Dsl.unlock_input
  ; expires : float
  ; mutable queued : bool
  }

and demand_entry =
  { mutable receipt : Dsl.demand_receipt
  ; mutable scope : task_scope
  ; change : Dsl.demand_change
  ; bytes : int
  ; mutable queued : bool
  ; mutable finished : bool
  ; mutable download_waiting_capacity : bool
  }

and delivery_entry =
  { output : Dsl.demand_output
  ; source : demand_entry
  ; references : resource_entry list
  ; mutable received : bool
  ; mutable released : bool
  }

type ('after, 'value) outcome =
  | Completed of 'after graph_context * 'value
  | Failed of context * Dsl.error

type ('after, 'value) running =
  { runtime : t
  ; outcome_promise : ('after, 'value) outcome Eio.Promise.t
  ; mutable cancellation : Eio.Cancel.t option
  ; mutable cancelled : bool
  ; mutable terminal : bool
  }

type ingress_ack =
  | Queued
  | Replaced

type delivery_status =
  | Current
  | Revoked

type observation_revision =
  { owner : t
  ; sequence : int64
  }

type runtime_observation =
  { revision : observation_revision
  ; state : Dsl.observation
  ; status : Dsl.service_status
  }

exception Forced of Dsl.error
exception Cancel_execution
exception Close_attempt

let protect_result f =
  try f () with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Forced _ as exn -> raise exn
  | _ -> Error (Dsl.Unexpected_failure "Capability raised")
;;

let pulse (t : t) =
  t.revision <- Int64.succ t.revision;
  Eio.Condition.broadcast t.changed
;;

let capacity_changed (t : t) =
  t.capacity <- Int64.succ t.capacity;
  pulse t
;;

let mark_dirty (t : t) =
  t.outbox_epoch <- Int64.succ t.outbox_epoch;
  pulse t
;;

let cleanup_error ?primary failures =
  Dsl.Cleanup_failure { primary; failures = Rrbvec.of_list failures }
;;

let record_cleanup (t : t) error =
  t.cleanup <- error :: t.cleanup;
  t.fenced <- true;
  t.gate <- Dsl.Closed;
  let next = { runtime = t; phase = Dsl.Draining; version = t.current_version } in
  t.actual <- Some (Context (Dsl.Draining, next));
  t.last_failure <- Some error;
  pulse t
;;

let set_phase (t : t) phase =
  let next = { runtime = t; phase; version = t.current_version } in
  t.actual <- Some (Context (phase, next));
  pulse t;
  next
;;

let actual (t : t) =
  match t.actual with
  | Some c -> c
  | None -> assert false
;;

let phase c = c.phase
let identity (c : _ graph_context) = c.runtime.id
let version c = c.version
let equal_version a b = a == b
let finite_positive n = Float.is_finite n && n > 0.

let database_owner database =
  { binding = Owner.database_owner database; snapshot_source = None; bound = false }
;;

let database owner = Owner.database owner.binding

let activation_owner ~sw ~snapshot_source ~dependencies ~inspection ~graph_name =
  if String.trim graph_name = ""
  then Error (Dsl.Invalid_input "Empty graph name")
  else
    Ok
      { binding = Owner.activation_owner ~sw ~dependencies ~inspection ~graph_name
      ; snapshot_source = Some snapshot_source
      ; bound = false
      }
;;

let wait (t : t) poll = Eio.Condition.loop_no_mutex t.changed poll

let still_current (t : t) token =
  if
    t.fenced
    || not
         (match t.busy with
          | Some current -> current == token
          | None -> false)
  then Error Dsl.Stale_context
  else Ok ()
;;

let reference_resource = function
  | Dsl.Snapshot_reference s -> Some s.resource
  | Dsl.File_reference f -> Some f.file
  | Dsl.Lease_reference l -> Some l.lease
  | Dsl.Connection_reference _ -> None
;;

let same_reference a b = Dsl.Producer.same_reference_registration a b && a = b

let find_resource (t : t) reference =
  List.find_opt (fun e -> same_reference reference e.reference) t.resources
;;

let validate_reference (t : t) reference =
  let* () =
    match reference_resource reference with
    | Some r when r.owner <> t.id -> Error (Dsl.Identity_mismatch "Foreign resource")
    | _ -> Ok ()
  in
  protect_result (fun () -> t.caps.validate_resource reference)
;;

let release_entry (t : t) entry =
  if entry.released
  then Ok ()
  else if entry.releasing
  then Error (Dsl.Capacity_exceeded "Resource release in progress")
  else (
    entry.releasing <- true;
    Fun.protect
      ~finally:(fun () -> entry.releasing <- false)
      (fun () ->
         let result =
           Eio.Cancel.protect (fun () ->
             protect_result (fun () ->
               match entry.reference with
               | Dsl.File_reference file -> t.caps.release_file t.id file
               | Dsl.Lease_reference lease -> t.caps.release_lease t.id lease
               | Dsl.Snapshot_reference snapshot -> t.caps.release_snapshot t.id snapshot
               | Dsl.Connection_reference connection ->
                 let scope =
                   { check = (fun () -> Ok ())
                   ; admit = (fun () -> Error Dsl.Network_closed)
                   ; transfer = (fun _ -> Error Dsl.Stale_context)
                   ; reserve_producer = (fun _ -> Error Dsl.Stale_context)
                   ; forget_producer = (fun _ -> ())
                   ; retain_failure = record_cleanup t
                   ; now = t.now
                   ; cleanup_seconds = t.caps.cleanup_seconds
                   ; live = true
                   }
                 in
                 Fun.protect
                   ~finally:(fun () -> scope.live <- false)
                   (fun () ->
                      t.caps.dispatch.transport
                        ~scope
                        ~identity:t.id
                        (Dsl.Retire_connection connection))))
         in
         match result with
         | Ok () ->
           let* () = Dsl.Producer.acknowledge_reference t.producer entry.reference in
           entry.released <- true;
           t.resources <- List.filter (fun current -> current != entry) t.resources;
           capacity_changed t;
           Ok ()
         | Error error ->
           record_cleanup t error;
           Error error))
;;

let release_reference (t : t) reference =
  match find_resource t reference with
  | None ->
    let* state = Dsl.Producer.reference_state t.producer reference in
    (match state with
     | `Released -> Ok ()
     | `Retained | `Unregistered -> Error Dsl.Stale_context)
  | Some e when e.delivery_owned ->
    Error (Dsl.Invalid_input "Resource belongs to delivery")
  | Some e -> release_entry t e
;;

let transfer (t : t) reserved ~ceiling references =
  let references = Rrbvec.to_list references in
  let rec validate seen new_count = function
    | [] -> Ok new_count
    | reference :: rest ->
      let* () = validate_reference t reference in
      let* state = Dsl.Producer.reference_state t.producer reference in
      let* () =
        match state with
        | `Released -> Error Dsl.Stale_context
        | `Retained | `Unregistered -> Ok ()
      in
      if List.exists (Dsl.Producer.same_reference_registration reference) seen
      then Error (Dsl.Invalid_input "Duplicate handoff")
      else (
        let count =
          match find_resource t reference with
          | None -> new_count + 1
          | Some _ -> new_count
        in
        validate (reference :: seen) count rest)
  in
  let* count = validate [] 0 references in
  let live = List.fold_left (fun n e -> n + if e.released then 0 else 1) 0 t.resources in
  let consumed = min count !reserved in
  if live + count + List.length t.producers + t.reserved_resources - consumed > ceiling ()
  then Error (Dsl.Capacity_exceeded "Resource ledger")
  else (
    let rec register = function
      | [] -> Ok ()
      | reference :: rest ->
        let* () = Dsl.Producer.register_reference t.producer reference in
        (match find_resource t reference with
         | Some _ -> ()
         | None ->
           t.resources
           <- { reference; released = false; delivery_owned = false; releasing = false }
              :: t.resources);
        register rest
    in
    let* () = register references in
    reserved := !reserved - consumed;
    t.reserved_resources <- t.reserved_resources - consumed;
    pulse t;
    Ok ())
;;

let with_network (t : t) check callback =
  let* () = check () in
  match t.gate with
  | Dsl.Closed -> Error Dsl.Network_closed
  | Dsl.Open { authorization_epoch } ->
    let generation = t.generation in
    let* () =
      protect_result (fun () -> t.caps.authorize_network t.id ~epoch:authorization_epoch)
    in
    let* () = check () in
    if generation <> t.generation || t.gate <> Dsl.Open { authorization_epoch }
    then Error Dsl.Network_closed
    else (
      let done_, resolve = Eio.Promise.create () in
      let call = { generation; cancel_network = None; done_ } in
      t.network_calls <- call :: t.network_calls;
      Fun.protect
        ~finally:(fun () ->
          Eio.Promise.resolve resolve ();
          t.network_calls <- List.filter (fun c -> c != call) t.network_calls;
          pulse t)
        (fun () ->
           try
             Eio.Cancel.sub (fun cc ->
               call.cancel_network <- Some (fun () -> Eio.Cancel.cancel cc Close_attempt);
               let* () = check () in
               if generation <> t.generation
               then Error Dsl.Network_closed
               else callback ())
           with
           | Eio.Cancel.Cancelled Close_attempt -> Error Dsl.Network_closed))
;;

let close_network (t : t) =
  match t.retirement with
  | Some receipt -> Ok receipt
  | None ->
    t.initial_eligible <- false;
    let generation = t.generation in
    t.gate <- Dsl.Closed;
    t.generation <- Int64.succ t.generation;
    t.network_input <- Some Dsl.Closed;
    pulse t;
    let fence_result = protect_result (fun () -> t.caps.fence_network t.id) in
    let receipt =
      { runtime = t; generation; fence_result; result = None; joining = false }
    in
    t.retirement <- Some receipt;
    List.iter
      (fun (c : network_call) ->
         if c.generation = generation then Option.iter (fun f -> f ()) c.cancel_network)
      t.network_calls;
    Ok receipt
;;

let await_network_retirement (receipt : network_retirement) =
  let t = receipt.runtime in
  match receipt.result with
  | Some result -> result
  | None when receipt.joining -> wait t (fun () -> receipt.result)
  | None ->
    receipt.joining <- true;
    Eio.Cancel.protect (fun () ->
      let failures = ref [] in
      let add = function
        | Ok () -> ()
        | Error e -> failures := e :: !failures
      in
      add receipt.fence_result;
      List.iter
        (fun (c : network_call) ->
           if c.generation = receipt.generation then Eio.Promise.await c.done_)
        t.network_calls;
      add (protect_result (fun () -> t.caps.close_network t.id));
      let result =
        match List.rev !failures with
        | [] -> Ok ()
        | xs -> Error (cleanup_error xs)
      in
      receipt.result <- Some result;
      (match result with
       | Ok () -> ()
       | Error e -> record_cleanup t e);
      pulse t;
      result)
;;

let open_network (t : t) ~authorization_epoch =
  t.initial_eligible <- false;
  if t.fenced
  then Error Dsl.Stale_context
  else (
    match t.retirement with
    | Some { result = None; _ } -> Error Dsl.Network_closed
    | Some { result = Some (Error e); _ } -> Error e
    | None | Some { result = Some (Ok ()); _ } ->
      let* () =
        protect_result (fun () ->
          t.caps.authorize_network t.id ~epoch:authorization_epoch)
      in
      if t.fenced
      then Error Dsl.Stale_context
      else (
        t.retirement <- None;
        t.generation <- Int64.succ t.generation;
        t.gate <- Dsl.Open { authorization_epoch };
        t.network_input <- Some t.gate;
        mark_dirty t;
        Ok ()))
;;

let make_effect_scope (t : t) token acquired ~ceiling =
  let check () = still_current t token in
  let scope =
    { check
    ; admit = (fun () -> with_network t check (fun () -> Ok ()))
    ; transfer = transfer t acquired ~ceiling
    ; reserve_producer =
        (fun producer ->
          let* () = check () in
          if
            List.length t.producers
            + List.fold_left
                (fun count entry -> count + if entry.released then 0 else 1)
                0
                t.resources
            + t.reserved_resources
            - min 1 !acquired
            >= ceiling ()
          then Error (Dsl.Capacity_exceeded "Producer ledger")
          else (
            let consumed = min 1 !acquired in
            acquired := !acquired - consumed;
            t.reserved_resources <- t.reserved_resources - consumed;
            t.producers <- producer :: t.producers;
            Ok ()))
    ; forget_producer =
        (fun producer ->
          t.producers <- List.filter (fun entry -> entry != producer) t.producers;
          capacity_changed t)
    ; retain_failure = record_cleanup t
    ; now = t.now
    ; cleanup_seconds = t.caps.cleanup_seconds
    ; live = true
    }
  in
  scope, acquired
;;

let with_effect ?(reserve = 0) ?(background = fun () -> false) (t : t) token callback =
  let ceiling () =
    t.limits.maximum_resources - if background () then t.limits.foreground_reserve else 0
  in
  if
    reserve > 0
    && List.length t.resources + List.length t.producers + t.reserved_resources + reserve
       > ceiling ()
  then Error (Dsl.Capacity_exceeded "Effect resources")
  else (
    let acquired = ref reserve in
    t.reserved_resources <- t.reserved_resources + reserve;
    let scope, _ = make_effect_scope t token acquired ~ceiling in
    Fun.protect
      ~finally:(fun () ->
        scope.live <- false;
        if t.cleanup = []
        then (
          t.reserved_resources <- t.reserved_resources - !acquired;
          if !acquired > 0 then capacity_changed t))
      (fun () ->
         let* () = check_current scope in
         let result = protect_result (fun () -> callback scope) in
         match result with
         | Error (Dsl.Cleanup_failure _ as e) ->
           record_cleanup t e;
           raise (Forced e)
         | result -> result))
;;

module Callback_bridge = struct
  type 'a producer =
    { start :
        deliver:(('a, Dsl.error) result -> (unit, Dsl.error) result)
        -> (unit, Dsl.error) result
    ; stop : unit -> (unit, Dsl.error) result
    ; await_stopped : deadline:float -> (unit, Dsl.error) result
    }

  let run ~scope ~resources producer =
    let control = { stop = producer.stop; await_stopped = producer.await_stopped } in
    let* () = check_current scope in
    let* () = scope.reserve_producer control in
    let terminal, resolve = Eio.Promise.create () in
    let lock = Mutex.create () in
    let selected = ref false in
    let deliver result =
      Mutex.lock lock;
      Fun.protect
        ~finally:(fun () -> Mutex.unlock lock)
        (fun () ->
           let transferred =
             match result with
             | Ok value -> handoff scope (resources value)
             | Error _ -> Ok ()
           in
           let terminal_result =
             match transferred with
             | Ok () -> result
             | Error error -> Error error
           in
           if not !selected
           then (
             selected := true;
             Eio.Promise.resolve resolve terminal_result);
           transferred)
    in
    let cleanup primary =
      Eio.Cancel.protect (fun () ->
        let deadline = scope.now () +. scope.cleanup_seconds in
        let failures = ref [] in
        let add = function
          | Ok () -> ()
          | Error e -> failures := e :: !failures
        in
        add (protect_result control.stop);
        add (protect_result (fun () -> control.await_stopped ~deadline));
        match List.rev !failures with
        | [] ->
          scope.forget_producer control;
          Ok ()
        | xs ->
          let e = cleanup_error ?primary xs in
          scope.retain_failure e;
          Error e)
    in
    let result =
      try
        let result =
          match protect_result (fun () -> producer.start ~deliver) with
          | Error e -> Error e
          | Ok () -> Eio.Promise.await terminal
        in
        let joined =
          cleanup
            (match result with
             | Error e -> Some e
             | Ok _ -> None)
        in
        match joined with
        | Ok () -> result
        | Error e -> Error e
      with
      | exn ->
        (match cleanup (Some Dsl.Cancelled) with
         | Ok () -> raise exn
         | Error e -> raise (Forced e))
    in
    result
  ;;
end

let notify_outbox_changed (t : t) ~owner ~identity =
  if owner != t.owner || identity <> t.id
  then Error (Dsl.Identity_mismatch "Foreign database binding")
  else if t.fenced
  then Error Dsl.Stale_context
  else (
    mark_dirty t;
    Ok ())
;;

let active_scope (t : t) =
  match t.active with
  | Some s when s.live && not t.fenced -> Ok s
  | _ -> Error Dsl.Stale_context
;;

let submit_unlock (t : t) ~identity ~valid_for input =
  let* scope = active_scope t in
  if identity <> t.id
  then Error (Dsl.Identity_mismatch "Foreign unlock identity")
  else if (not (finite_positive valid_for)) || valid_for > 300.
  then Error (Dsl.Invalid_input "Unlock lifetime")
  else if String.length (Dsl.wrapped_graph_key input) > t.limits.maximum_message_bytes
  then Error (Dsl.Capacity_exceeded "Unlock bytes")
  else
    let* receipt = Dsl.Producer.unlock_receipt t.producer scope.handle in
    let ack = if Option.is_some t.unlock then Replaced else Queued in
    t.unlock <- Some { receipt; input; expires = t.now () +. valid_for; queued = true };
    pulse t;
    Ok ack
;;

let demand_id = function
  | Dsl.Demand d -> d.id
  | Dsl.Withdraw id -> id
;;

let same_demand a b = Dsl.compare_demand_id (demand_id a) (demand_id b) = 0

let notification_usage (t : t) =
  List.fold_left
    (fun (count, bytes) scope ->
       List.fold_left
         (fun (count, bytes) channel ->
            Queue.fold
              (fun (count, bytes) (_, size) -> count + 1, bytes + size)
              (count, bytes)
              channel.queue)
         (count, bytes)
         scope.notifications)
    (0, 0)
    t.scopes
;;

let demand_usage (t : t) =
  List.fold_left
    (fun (count, bytes) demand -> count + 1, bytes + demand.bytes)
    (0, 0)
    t.demands
;;

let descriptor_bytes = function
  | Dsl.Withdraw _ -> 256
  | Dsl.Demand d ->
    let module A = Logseq_db_types.Asset_descriptor in
    256
    + (match d.asset.source with
      | A.External s -> String.length s
      | A.Managed None -> 0
      | A.Managed (Some v) -> String.length v.checksum + String.length v.file_type)
    +
      (match d.asset.current_checksum with
      | None -> 0
      | Some s -> String.length s)
;;

let background = function
  | Dsl.Demand { priority = Dsl.Background; _ } -> true
  | _ -> false
;;

let asset_binding : (t * asset_work) Eio.Fiber.key = Eio.Fiber.create_key ()

let work_background ?replacement demands work =
  List.for_all
    (fun (_, original) ->
       match original with
       | None -> false
       | Some change ->
         let current =
           List.find_opt
             (fun d -> (not d.finished) && same_demand d.change change)
             demands
         in
         let selected =
           match replacement with
           | Some replacement when same_demand replacement change -> replacement
           | _ ->
             (match current with
              | Some entry -> entry.change
              | None -> change)
         in
         background
           (match selected with
            | Dsl.Demand demand when demand.asset = work.asset -> Dsl.Demand demand
            | _ -> change))
    work.interests
;;

let attempt_active = function
  | Some attempt -> not attempt.physically_joined
  | None -> false
;;

let work_slots work =
  max
    1
    ((if attempt_active work.download then 1 else 0)
     + if attempt_active work.upload then 1 else 0)
;;

let asset_slots work = List.fold_left (fun count work -> count + work_slots work) 0 work

let asset_background_count demands work =
  List.fold_left
    (fun count entry ->
       count + if work_background demands entry then work_slots entry else 0)
    0
    work
;;

let reserve_asset (t : t) asset change =
  let shared =
    match change with
    | None -> None
    | Some _ ->
      List.find_opt
        (fun work ->
           work.asset = asset
           && List.for_all (fun (_, change) -> Option.is_some change) work.interests)
        t.asset_work
  in
  let interest = ref () in
  let work =
    match shared with
    | Some work -> work
    | None ->
      { asset; interests = []; download = None; download_files = []; upload = None }
  in
  let old = work.interests in
  work.interests <- (interest, change) :: old;
  let proposed =
    match shared with
    | Some _ -> t.asset_work
    | None -> work :: t.asset_work
  in
  if
    asset_slots proposed > t.limits.maximum_active_assets
    || asset_background_count t.demands proposed
       > t.limits.maximum_active_assets - t.limits.foreground_reserve
  then (
    work.interests <- old;
    Error (Dsl.Capacity_exceeded "Active assets"))
  else (
    t.asset_work <- proposed;
    let release () =
      if t.cleanup = []
      then (
        work.interests <- List.filter (fun (key, _) -> key != interest) work.interests;
        if work.interests = []
        then t.asset_work <- List.filter (fun entry -> entry != work) t.asset_work;
        capacity_changed t)
    in
    Ok (work, release))
;;

let update_demand (t : t) change =
  let* scope = active_scope t in
  let previous = List.find_opt (fun d -> same_demand d.change change) t.demands in
  if
    previous = None
    &&
    match change with
    | Dsl.Withdraw _ -> true
    | _ -> false
  then Ok Queued
  else (
    let bytes = descriptor_bytes change in
    let other = List.filter (fun d -> not (same_demand d.change change)) t.demands in
    let count = List.length other + 1 in
    let background_count =
      List.fold_left (fun n d -> n + if background d.change then 1 else 0) 0 other
    in
    let notification_count, notification_bytes = notification_usage t in
    let used_bytes = List.fold_left (fun n d -> n + d.bytes) notification_bytes other in
    let demoting =
      background change
      && Option.fold
           ~none:false
           ~some:(fun previous -> not (background previous.change))
           previous
    in
    let resources =
      List.fold_left
        (fun count entry -> count + if entry.released then 0 else 1)
        0
        t.resources
      + List.length t.producers
      + t.reserved_resources
    in
    if
      (demoting
       && (t.tasks
           > min t.limits.maximum_tasks (t.limits.maximum_pending - 3)
             - t.limits.foreground_reserve
           || resources > t.limits.maximum_resources - t.limits.foreground_reserve))
      || List.fold_left
           (fun count work ->
              count
              +
              if work_background ~replacement:change t.demands work
              then work_slots work
              else 0)
           0
           t.asset_work
         > t.limits.maximum_active_assets - t.limits.foreground_reserve
      || count > t.limits.maximum_demands
      || count + notification_count > t.limits.maximum_messages
      || (background change
          && background_count + 1
             > t.limits.maximum_demands - t.limits.foreground_demand_reserve)
      || used_bytes + bytes > t.limits.maximum_message_bytes
      || (background change
          && List.fold_left
               (fun total d -> total + if background d.change then d.bytes else 0)
               (bytes + notification_bytes)
               other
             > t.limits.maximum_message_bytes
               - t.limits.foreground_descriptor_reserve_bytes)
    then Error (Dsl.Capacity_exceeded "Demand descriptors")
    else
      let* receipt = Dsl.Producer.demand_receipt t.producer scope.handle in
      let entry =
        { receipt
        ; scope
        ; change
        ; bytes
        ; queued = true
        ; finished = false
        ; download_waiting_capacity = false
        }
      in
      t.demands
      <- entry :: List.filter (fun d -> not (same_demand d.change change)) t.demands;
      pulse t;
      Ok
        (match previous with
         | None -> Queued
         | Some _ -> Replaced))
;;

let current_demand (t : t) receipt =
  match
    List.find_opt
      (fun (d : demand_entry) -> d.receipt == receipt && d.scope.live)
      t.demands
  with
  | Some d -> Ok d
  | None -> Error Dsl.Stale_context
;;

let delivery_current (t : t) entry =
  (not t.fenced)
  && entry.source.scope.live
  && List.exists (fun d -> d == entry.source) t.demands
;;

let find_delivery (t : t) delivery =
  let* () = Dsl.Producer.check_delivery t.producer delivery in
  match List.find_opt (fun d -> d.output.delivery == delivery) t.deliveries with
  | Some d -> Ok d
  | None -> Error Dsl.Stale_context
;;

let demand_status (t : t) delivery =
  let* released = Dsl.Producer.delivery_released t.producer delivery in
  if released
  then Ok Revoked
  else
    let* d = find_delivery t delivery in
    Ok (if delivery_current t d then Current else Revoked)
;;

let release_delivery (t : t) (d : delivery_entry) =
  if d.released
  then Ok ()
  else (
    let rec release = function
      | [] -> Ok ()
      | entry :: rest ->
        let* () = release_entry t entry in
        release rest
    in
    let* () = release d.references in
    let* () = Dsl.Producer.acknowledge_delivery t.producer d.output.delivery in
    d.released <- true;
    t.deliveries <- List.filter (fun current -> current != d) t.deliveries;
    capacity_changed t;
    Ok ())
;;

let release_demand (t : t) delivery =
  let* released = Dsl.Producer.delivery_released t.producer delivery in
  if released
  then Ok ()
  else
    let* d = find_delivery t delivery in
    release_delivery t d
;;

let receive_demand (t : t) =
  if t.receiver
  then Error (Dsl.Capacity_exceeded "Demand receiver already waiting")
  else (
    t.receiver <- true;
    Fun.protect
      ~finally:(fun () -> t.receiver <- false)
      (fun () ->
         let rec next () =
           let candidate =
             wait t (fun () ->
               match
                 List.find_opt
                   (fun d -> (not d.received) && not d.released)
                   (List.rev t.deliveries)
               with
               | Some d -> Some (Ok d)
               | None when t.active = None || t.fenced -> Some (Error Dsl.Cancelled)
               | None -> None)
           in
           let* d = candidate in
           Eio.Fiber.check ();
           if not (delivery_current t d)
           then
             let* () = release_delivery t d in
             next ()
           else (
             d.received <- true;
             Ok d.output)
         in
         next ()))
;;

let request_stop (t : t) =
  let* _ = active_scope t in
  t.stop <- true;
  pulse t;
  Ok ()
;;

let observation_state (t : t) =
  let* state = protect_result (fun () -> t.caps.observe t.id) in
  if state.identity <> t.id
  then Error (Dsl.Identity_mismatch "Foreign observation")
  else (
    let state =
      { state with
        Dsl.network = t.gate
      ; keys = t.keys
      ; cleanup_pending = max state.cleanup_pending (List.length t.cleanup)
      ; last_failure =
          (match t.last_failure with
           | None -> state.last_failure
           | Some _ as e -> e)
      }
    in
    if t.observation <> Some state
    then (
      t.observation <- Some state;
      pulse t);
    Ok state)
;;

let observe_runtime (t : t) =
  let* state = observation_state t in
  Ok { revision = { owner = t; sequence = t.revision }; state; status = t.status }
;;

let await_observation (t : t) ~after =
  if after.owner != t
  then Error Dsl.Stale_context
  else if t.observation_reader
  then Error (Dsl.Capacity_exceeded "Observation waiter")
  else (
    t.observation_reader <- true;
    Fun.protect
      ~finally:(fun () -> t.observation_reader <- false)
      (fun () ->
         let* () =
           wait t (fun () ->
             if t.revision <> after.sequence
             then Some (Ok ())
             else (
               match actual t with
               | Context (Dsl.Retired, _) -> Some (Error Dsl.Stale_context)
               | _ -> None))
         in
         observe_runtime t))
;;

let check_scope (t : t) (scope : task_scope) =
  if not scope.live
  then Error Dsl.Stale_context
  else Dsl.Producer.check_scope t.producer scope.handle
;;

let make_task_scope (t : t) _parent =
  let scope =
    { handle = Dsl.Producer.scope t.producer
    ; live = true
    ; children = []
    ; notifications = []
    ; prefer_child = false
    }
  in
  t.scopes <- scope :: t.scopes;
  scope
;;

let child_control (scope : task_scope) child =
  (* Physical identity only; results stay typed in Producer.child_result. *)
  List.find_opt (fun c -> c.key == Obj.repr child && not c.consumed) scope.children
;;

let cleanup_scope (t : t) (scope : task_scope) =
  Eio.Cancel.protect (fun () ->
    List.iter (fun c -> if not c.consumed then c.cancel_child ()) scope.children;
    let failures = ref [] in
    List.iter
      (fun c ->
         if not c.consumed
         then (
           Option.iter (fun e -> failures := e :: !failures) (c.join_child ());
           c.consumed <- true;
           c.release_capacity ();
           t.tasks <- t.tasks - 1))
      scope.children;
    scope.children <- [];
    scope.live <- false;
    ignore (Dsl.Producer.close_scope t.producer scope.handle : (unit, Dsl.error) result);
    List.iter
      (fun d ->
         if d.source.scope == scope && (not d.received) && not d.released
         then (
           match release_delivery t d with
           | Ok () -> ()
           | Error e -> failures := e :: !failures))
      t.deliveries;
    scope.notifications <- [];
    t.scopes <- List.filter (fun s -> s != scope) t.scopes;
    capacity_changed t;
    match List.rev !failures with
    | [] -> Ok ()
    | xs -> Error (cleanup_error xs))
;;

let require_resource (t : t) reference =
  let* () = validate_reference t reference in
  match find_resource t reference with
  | Some e when (not e.released) && not e.delivery_owned -> Ok e
  | _ -> Error Dsl.Stale_context
;;

let perform_crypto : type a. t -> unit ref -> a Dsl.crypto -> (a, Dsl.error) result =
  fun t token operation ->
  with_effect t token (fun scope ->
    let* result = t.caps.dispatch.crypto ~scope ~identity:t.id operation in
    let* () = check_current scope in
    match operation with
    | Dsl.Unlock _ ->
      t.keys <- result;
      mark_dirty t;
      Ok result
    | Dsl.Encrypt_values values ->
      if Rrbvec.length result <> Rrbvec.length values
      then Error (Dsl.Crypto_failure "Encryption cardinality")
      else Ok result
    | Dsl.Decrypt_value _ | Dsl.Protect _ | Dsl.Unprotect _ -> Ok result)
;;

let perform_database : type a. t -> unit ref -> a Dsl.database -> (a, Dsl.error) result =
  fun t token operation ->
  let check_current () = still_current t token in
  let with_database f = Owner.with_database t.owner.binding ~check_current f in
  match operation with
  | Dsl.Release_snapshot snapshot -> release_reference t (Dsl.Snapshot_reference snapshot)
  | Dsl.Inspect ->
    with_database (fun database ->
      match Dsl.Overlay.Database.inspect_sync database with
      | Error e -> Error (Dsl.Sync_read_failure e)
      | Ok view ->
        if
          List.length (Dsl.Overlay.Types.sync_view_submissions view)
          > t.limits.maximum_items
        then Error (Dsl.Invalid_input "Sync view items")
        else Ok view)
  | Dsl.Prepare_submission (expected, transition) ->
    let* prepared, request =
      with_database (fun database ->
        Result.map_error
          (fun e -> Dsl.Outbox_failure e)
          (Dsl.Overlay.Database.begin_outbox_transition database ~expected transition))
    in
    let* encrypted =
      match request with
      | None -> Ok None
      | Some request ->
        let* values = perform_crypto t token (Dsl.Protect request) in
        Ok (Some (request, values))
    in
    let* result =
      with_database (fun database ->
        let* () = check_current () in
        Eio.Cancel.protect (fun () ->
          Result.map_error
            (fun e -> Dsl.Outbox_failure e)
            (Dsl.Overlay.Database.apply_outbox_transition database prepared ~encrypted)))
    in
    mark_dirty t;
    Ok result
  | Dsl.Apply_authoritative (expected, batch) ->
    let* prepared, request =
      with_database (fun database ->
        Result.map_error
          (fun e -> Dsl.Authoritative_failure e)
          (Dsl.Overlay.Database.begin_authoritative database ~expected batch))
    in
    let* decrypted =
      match request with
      | None -> Ok None
      | Some request ->
        let* values = perform_crypto t token (Dsl.Unprotect request) in
        Ok (Some (request, values))
    in
    let* result =
      with_database (fun database ->
        let* () = check_current () in
        Eio.Cancel.protect (fun () ->
          Result.map_error
            (fun e -> Dsl.Authoritative_failure e)
            (Dsl.Overlay.Database.apply_authoritative database prepared ~decrypted)))
    in
    mark_dirty t;
    Ok
      (match result with
       | Dsl.Overlay.Database.Authoritative_applied c -> Dsl.Applied c
       | Dsl.Overlay.Database.Authoritative_deferred d -> Dsl.Deferred d)
  | Dsl.Activate_snapshot snapshot ->
    let* _ = require_resource t (Dsl.Snapshot_reference snapshot) in
    let* source =
      match t.owner.snapshot_source with
      | None -> Error (Dsl.Invalid_input "Active mirror")
      | Some resolve -> protect_result (fun () -> resolve snapshot)
    in
    let* () = check_current () in
    let* result =
      Owner.activate_snapshot
        t.owner.binding
        ~check_current
        { snapshot
        ; path = source.path
        ; expected_rows = source.expected_rows
        ; unprotect = (fun request -> perform_crypto t token (Dsl.Unprotect request))
        }
    in
    mark_dirty t;
    Ok result
;;

let perform_transport : type a. t -> unit ref -> a Dsl.transport -> (a, Dsl.error) result =
  fun t token operation ->
  match operation with
  | Dsl.Retire_connection connection ->
    release_reference t (Dsl.Connection_reference connection)
  | _ ->
    let validate : type b. b Dsl.transport -> (unit, Dsl.error) result = function
      | Dsl.On_connection (connection, request) ->
        let* _ = require_resource t (Dsl.Connection_reference connection) in
        (match request with
         | Dsl.Head | Dsl.Fetch_snapshot _ | Dsl.Pull _ | Dsl.Push _ -> Ok ()
         | _ -> Error (Dsl.Invalid_input "Invalid scoped transport"))
      | Dsl.Receive connection ->
        let* _ = require_resource t (Dsl.Connection_reference connection) in
        Ok ()
      | Dsl.Connect | Dsl.Head | Dsl.Fetch_snapshot _ | Dsl.Pull _ | Dsl.Push _ -> Ok ()
      | Dsl.Retire_connection _ -> Ok ()
    in
    let* () = validate operation in
    with_network
      t
      (fun () -> still_current t token)
      (fun () ->
         with_effect t token (fun scope ->
           let* result = t.caps.dispatch.transport ~scope ~identity:t.id operation in
           let rec check_result : type b. b Dsl.transport -> b -> (unit, Dsl.error) result
             =
             fun op result ->
             match op with
             | Dsl.Connect ->
               let* _ = require_resource t (Dsl.Connection_reference result) in
               Ok ()
             | Dsl.Fetch_snapshot _ ->
               let* _ = require_resource t (Dsl.Snapshot_reference result) in
               Ok ()
             | Dsl.On_connection (_, op) -> check_result op result
             | Dsl.Receive connection ->
               if result.connection = connection
               then Ok ()
               else Error (Dsl.Protocol_failure "Connection mismatch")
             | Dsl.Head | Dsl.Pull _ | Dsl.Push _ | Dsl.Retire_connection _ -> Ok ()
           in
           let* () = check_result operation result in
           let* () = check_current scope in
           Ok result))
;;

let admit_asset_direction (t : t) work opposite =
  if
    attempt_active opposite
    && (asset_slots t.asset_work >= t.limits.maximum_active_assets
        || (work_background t.demands work
            && asset_background_count t.demands t.asset_work
               >= t.limits.maximum_active_assets - t.limits.foreground_reserve))
  then Error (Dsl.Capacity_exceeded "Combined asset transfers")
  else Ok ()
;;

let start_asset_attempt (t : t) ~register callback =
  let outcome, resolve = Eio.Promise.create () in
  let attempt =
    { outcome; waiters = 0; cancellation = None; physically_joined = false }
  in
  register attempt;
  Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
    let result =
      try
        Eio.Cancel.sub (fun cc ->
          attempt.cancellation <- Some cc;
          callback ())
      with
      | Eio.Cancel.Cancelled _ -> Error Dsl.Cancelled
      | Forced error -> Error error
      | _ -> Error (Dsl.Unexpected_failure "Asset transfer raised")
    in
    attempt.cancellation <- None;
    attempt.physically_joined <- true;
    Eio.Promise.resolve resolve result;
    capacity_changed t;
    `Stop_daemon);
  attempt
;;

let await_asset_attempt attempt =
  attempt.waiters <- attempt.waiters + 1;
  Fun.protect
    ~finally:(fun () ->
      attempt.waiters <- attempt.waiters - 1;
      if attempt.waiters = 0 && not attempt.physically_joined
      then
        Eio.Cancel.protect (fun () ->
          Option.iter
            (fun cc -> Eio.Cancel.cancel cc Cancel_execution)
            attempt.cancellation;
          ignore (Eio.Promise.await attempt.outcome)))
    (fun () -> Eio.Promise.await attempt.outcome)
;;

let rec perform_assets : type a. t -> unit ref -> a Dsl.assets -> (a, Dsl.error) result =
  fun t token operation ->
  match operation with
  | Dsl.Release_file file -> release_reference t (Dsl.File_reference file)
  | Dsl.Release_lease lease -> release_reference t (Dsl.Lease_reference lease)
  | _ ->
    let* () =
      match operation with
      | Dsl.Retain file ->
        let* _ = require_resource t (Dsl.File_reference file) in
        Ok ()
      | _ -> Ok ()
    in
    let work () =
      let reserve =
        match operation with
        | Dsl.Download _ -> 2
        | Dsl.Lookup _ | Dsl.Retain _ | Dsl.Upload _ -> 1
        | Dsl.Prune_cache | Dsl.Release_file _ | Dsl.Release_lease _ -> 0
      in
      let binding = Eio.Fiber.get asset_binding in
      let background () =
        match binding with
        | Some (runtime, work) when runtime == t -> work_background t.demands work
        | _ -> false
      in
      with_effect ~reserve ~background t token (fun scope ->
        let* value = t.caps.dispatch.assets ~scope ~identity:t.id operation in
        let* () =
          match operation with
          | Dsl.Lookup asset ->
            (match value with
             | None -> Ok ()
             | Some file ->
               if file.asset <> asset
               then Error (Dsl.Protocol_failure "Asset selection mismatch")
               else
                 let* _ = require_resource t (Dsl.File_reference file) in
                 Ok ())
          | Dsl.Download asset ->
            (match value with
             | Dsl.Available file ->
               if file.asset <> asset
               then Error (Dsl.Protocol_failure "Asset selection mismatch")
               else
                 let* _ = require_resource t (Dsl.File_reference file) in
                 Ok ()
             | _ -> Ok ())
          | Dsl.Retain file ->
            if value.source <> file
            then Error (Dsl.Protocol_failure "Lease source mismatch")
            else
              let* _ = require_resource t (Dsl.Lease_reference value) in
              Ok ()
          | Dsl.Prune_cache | Dsl.Upload _ | Dsl.Release_file _ | Dsl.Release_lease _ ->
            Ok ()
        in
        let* () = check_current scope in
        Ok value)
    in
    (match operation with
     | Dsl.Download asset | Dsl.Upload asset ->
       let remote () = with_network t (fun () -> still_current t token) work in
       let reserved () : (a, Dsl.error) result =
         match Eio.Fiber.get asset_binding with
         | Some (runtime, bound) when runtime == t && bound.asset = asset ->
           (match operation with
            | Dsl.Download selected ->
              let* attempt =
                match bound.download with
                | Some attempt -> Ok attempt
                | None ->
                  let* () = admit_asset_direction t bound bound.upload in
                  Ok
                    (start_asset_attempt
                       t
                       ~register:(fun attempt -> bound.download <- Some attempt)
                       remote)
              in
              let outcome = await_asset_attempt attempt in
              (match outcome with
               | Error (Dsl.Capacity_exceeded _) when attempt.physically_joined ->
                 (match bound.download with
                  | Some current when current == attempt -> bound.download <- None
                  | _ -> ())
               | _ -> ());
              let* result = outcome in
              (match result with
               | Dsl.Available original ->
                 let* file =
                   if bound.download_files = []
                   then Ok original
                   else
                     let* found = perform_assets t token (Dsl.Lookup selected) in
                     match found with
                     | Some file
                       when not
                              (List.exists
                                 (fun claimed ->
                                    Dsl.Producer.same_reference_registration
                                      (Dsl.File_reference claimed)
                                      (Dsl.File_reference file))
                                 bound.download_files) -> Ok file
                     | _ ->
                       Error
                         (Dsl.Protocol_failure
                            "Shared download requires an independent file reference")
                 in
                 let* _ = require_resource t (Dsl.File_reference file) in
                 bound.download_files <- file :: bound.download_files;
                 Ok (Dsl.Available file)
               | result -> Ok result)
            | Dsl.Upload _ ->
              let* attempt =
                match bound.upload with
                | Some attempt -> Ok attempt
                | None ->
                  let* () = admit_asset_direction t bound bound.download in
                  Ok
                    (start_asset_attempt
                       t
                       ~register:(fun attempt -> bound.upload <- Some attempt)
                       remote)
              in
              await_asset_attempt attempt
            | _ -> work ())
         | _ ->
           let* _, release = reserve_asset t asset None in
           Fun.protect ~finally:release remote
       in
       reserved ()
     | _ -> work ())
;;

let take_input (t : t) (scope : task_scope) =
  if t.stop
  then (
    t.stop <- false;
    Some (Ok Dsl.Stop_requested))
  else (
    match t.network_input with
    | Some gate ->
      t.network_input <- None;
      Some (Ok (Dsl.Network_changed gate))
    | None ->
      (match t.unlock with
       | Some u when u.expires <= t.now () ->
         t.unlock <- None;
         None
       | Some u when u.queued ->
         Some
           (let* receipt = Dsl.Producer.unlock_receipt t.producer scope.handle in
            u.receipt <- receipt;
            u.queued <- false;
            Ok (Dsl.Unlock_requested receipt))
       | _ ->
         (match
            List.find_opt
              (fun (d : demand_entry) -> d.queued && not d.finished)
              (List.rev t.demands)
          with
          | None -> None
          | Some d ->
            Some
              (let* receipt = Dsl.Producer.demand_receipt t.producer scope.handle in
               d.scope <- scope;
               d.receipt <- receipt;
               d.queued <- false;
               Ok (Dsl.Demand_changed (receipt, d.change))))))
;;

let input_wait (t : t) callback =
  if t.input_reader
  then Error (Dsl.Capacity_exceeded "Input already waiting")
  else (
    t.input_reader <- true;
    Fun.protect ~finally:(fun () -> t.input_reader <- false) callback)
;;

let publish_demand (t : t) (scope : task_scope) receipt availability =
  let* () = Dsl.Producer.check_demand_receipt t.producer scope.handle receipt in
  let* source = current_demand t receipt in
  let* references =
    match availability, source.change with
    | Dsl.Demand_available (file, lease), Dsl.Demand demand ->
      if file.asset <> demand.asset || lease.source <> file
      then Error (Dsl.Invalid_input "Demand resource selection")
      else
        let* lease_entry = require_resource t (Dsl.Lease_reference lease) in
        let* file_entry = require_resource t (Dsl.File_reference file) in
        Ok [ lease_entry; file_entry ]
    | Dsl.Demand_available _, _ | Dsl.Demand_revoked, Dsl.Demand _ ->
      Error Dsl.Stale_context
    | _ -> Ok []
  in
  if
    List.length (List.filter (fun (d : delivery_entry) -> not d.released) t.deliveries)
    >= t.limits.maximum_messages
  then Error (Dsl.Capacity_exceeded "Demand output messages")
  else (
    let old =
      List.filter
        (fun d -> d.source == source && (not d.received) && not d.released)
        t.deliveries
    in
    let rec release = function
      | [] -> Ok ()
      | d :: rest ->
        let* () = release_delivery t d in
        release rest
    in
    let* () = release old in
    let* _ = current_demand t receipt in
    let* output =
      Dsl.Producer.demand_output
        t.producer
        scope.handle
        receipt
        ~id:(demand_id source.change)
        availability
    in
    List.iter (fun e -> e.delivery_owned <- true) references;
    t.deliveries
    <- { output; source; references; received = false; released = false } :: t.deliveries;
    pulse t;
    Ok ())
;;

let asset_reason = function
  | Dsl.Network_closed -> Dsl.Asset_network_closed
  | Dsl.Network_failure message -> Dsl.Asset_network message
  | Dsl.Locked -> Dsl.Asset_locked
  | Dsl.Cancelled -> Dsl.Asset_cancelled
  | error -> Dsl.Asset_other error
;;

let task_operation
  : type a. t -> unit ref -> task_scope -> a Dsl.task_operation -> (a, Dsl.error) result
  =
  fun t token scope operation ->
  match operation with
  | Dsl.Notifications handle ->
    let* () = Dsl.Producer.check_scope t.producer handle in
    if handle != scope.handle
    then Error Dsl.Stale_context
    else if
      List.fold_left
        (fun count scope -> count + List.length scope.notifications)
        0
        t.scopes
      >= t.limits.maximum_messages
    then Error (Dsl.Capacity_exceeded "Notification channels")
    else
      let* handle = Dsl.Producer.notifications t.producer scope.handle in
      scope.notifications
      <- { handle; queue = Queue.create (); reading = false } :: scope.notifications;
      Ok handle
  | Dsl.Notify (handle, notification) ->
    let* () = Dsl.Producer.check_notifications t.producer scope.handle handle in
    (match
       List.find_opt
         (fun (c : notification_channel) -> c.handle == handle)
         scope.notifications
     with
     | None -> Error Dsl.Stale_context
     | Some channel ->
       let count, bytes = notification_usage t in
       let demands, descriptors = demand_usage t in
       let size = String.length (Marshal.to_string notification []) in
       let* () =
         if not scope.live
         then Error Dsl.Cancelled
         else if
           count + demands >= t.limits.maximum_messages
           || size > t.limits.maximum_message_bytes - bytes - descriptors
         then Error (Dsl.Capacity_exceeded "Notification budget")
         else Ok ()
       in
       Queue.add (notification, size) channel.queue;
       (match notification with
        | Dsl.Connected _ -> mark_dirty t
        | _ -> ());
       pulse t;
       Ok ())
  | Dsl.Next_notification handle ->
    let* () = Dsl.Producer.check_notifications t.producer scope.handle handle in
    (match
       List.find_opt
         (fun (c : notification_channel) -> c.handle == handle)
         scope.notifications
     with
     | None -> Error Dsl.Stale_context
     | Some channel when channel.reading ->
       Error (Dsl.Capacity_exceeded "Notification receiver")
     | Some channel ->
       channel.reading <- true;
       Fun.protect
         ~finally:(fun () -> channel.reading <- false)
         (fun () ->
            wait t (fun () ->
              if not scope.live
              then Some (Error Dsl.Cancelled)
              else if Queue.is_empty channel.queue
              then None
              else (
                let n, _ = Queue.take channel.queue in
                capacity_changed t;
                Some (Ok n)))))
  | Dsl.Await_outbox_changed ->
    if Option.is_some t.outbox_check
    then Error (Dsl.Capacity_exceeded "Outbox inspector")
    else
      let* () =
        wait t (fun () ->
          if not scope.live
          then Some (Error Dsl.Cancelled)
          else if t.outbox_epoch <> t.outbox_acked
          then Some (Ok ())
          else None)
      in
      let* check = Dsl.Producer.outbox_check t.producer scope.handle in
      t.outbox_check <- Some (check, t.outbox_epoch);
      Ok check
  | Dsl.Acknowledge_outbox_check check ->
    let* () = Dsl.Producer.check_outbox_check t.producer scope.handle check in
    (match t.outbox_check with
     | Some (original, epoch) when original == check ->
       t.outbox_acked <- epoch;
       t.outbox_check <- None;
       pulse t;
       Ok ()
     | _ -> Error Dsl.Stale_context)
  | Dsl.Abandon_outbox_check check ->
    let* () = Dsl.Producer.check_outbox_check t.producer scope.handle check in
    (match t.outbox_check with
     | Some (original, _) when original == check ->
       t.outbox_check <- None;
       pulse t;
       Ok ()
     | _ -> Error Dsl.Stale_context)
  | Dsl.Resample_outbox ->
    mark_dirty t;
    Ok ()
  | Dsl.Capacity_revision ->
    Dsl.Producer.capacity_revision t.producer scope.handle ~sequence:t.capacity
  | Dsl.Await_capacity_changed revision ->
    let* sequence = Dsl.Producer.capacity_sequence t.producer scope.handle revision in
    wait t (fun () ->
      if t.capacity <> sequence
      then Some (Ok ())
      else if not scope.live
      then Some (Error Dsl.Cancelled)
      else None)
  | Dsl.Task_observe -> observation_state t
  | Dsl.Publish_status status ->
    t.status <- status;
    pulse t;
    Ok ()
  | Dsl.Task_database operation -> perform_database t token operation
  | Dsl.Task_transport operation -> perform_transport t token operation
  | Dsl.Task_crypto operation -> perform_crypto t token operation
  | Dsl.Task_assets operation -> perform_assets t token operation
  | Dsl.Consume_unlock receipt ->
    let* () = Dsl.Producer.check_unlock_receipt t.producer scope.handle receipt in
    (match t.unlock with
     | Some u when u.receipt == receipt && u.expires > t.now () ->
       t.unlock <- None;
       perform_crypto t token (Dsl.Unlock u.input)
     | _ -> Error Dsl.Stale_context)
  | Dsl.Publish_demand (receipt, availability) ->
    publish_demand t scope receipt availability
  | Dsl.Finish_demand receipt ->
    let* () = Dsl.Producer.check_demand_receipt t.producer scope.handle receipt in
    let* d = current_demand t receipt in
    d.finished <- true;
    (match d.change with
     | Dsl.Withdraw _ -> t.demands <- List.filter (fun current -> current != d) t.demands
     | Dsl.Demand _ -> ());
    capacity_changed t;
    Ok ()
  | Dsl.Download_demand receipt ->
    let* () = Dsl.Producer.check_demand_receipt t.producer scope.handle receipt in
    let* d = current_demand t receipt in
    (match d.change with
     | Dsl.Withdraw _ -> Error Dsl.Stale_context
     | Dsl.Demand demand ->
       let* () =
         if d.download_waiting_capacity
         then (
           let background =
             match Eio.Fiber.get asset_binding with
             | Some (runtime, work) when runtime == t -> work_background t.demands work
             | _ -> false
           in
           if
             List.length t.resources + List.length t.producers + t.reserved_resources + 2
             > t.limits.maximum_resources
               - if background then t.limits.foreground_reserve else 0
           then Error (Dsl.Capacity_exceeded "Effect resources")
           else Ok ())
         else Ok ()
       in
       d.download_waiting_capacity <- false;
       let* found = perform_assets t token (Dsl.Lookup demand.asset) in
       (match found with
        | Some file -> Ok { Dsl.result = Ok (Dsl.Available file); attempts = 0 }
        | None when t.keys = Dsl.Key_locked ->
          Ok { Dsl.result = Error Dsl.Asset_locked; attempts = 0 }
        | None ->
          (match demand.asset.source, t.gate with
           | Logseq_db_types.Asset_descriptor.External _, _ ->
             Ok { Dsl.result = Ok Dsl.Missing_local; attempts = 0 }
           | Managed None, _ -> Ok { Dsl.result = Ok Dsl.Waiting_remote; attempts = 0 }
           | _, Dsl.Closed ->
             Ok { Dsl.result = Error Dsl.Asset_network_closed; attempts = 0 }
           | Managed (Some _), Dsl.Open _ ->
             let result = perform_assets t token (Dsl.Download demand.asset) in
             let* _ = current_demand t receipt in
             (match result with
              | Error (Dsl.Capacity_exceeded _ as e) ->
                d.download_waiting_capacity <- true;
                Error e
              | Error (Dsl.Cleanup_failure _ as e) -> Error e
              | result ->
                Ok { Dsl.result = Result.map_error asset_reason result; attempts = 1 }))))
  | Dsl.Wait_network_open ->
    wait t (fun () ->
      if not scope.live
      then Some (Error Dsl.Cancelled)
      else (
        match t.gate, t.retirement with
        | Dsl.Open _, None -> Some (Ok ())
        | _ -> None))
  | Dsl.Next_input ->
    input_wait t (fun () ->
      wait t (fun () ->
        if not scope.live then Some (Error Dsl.Cancelled) else take_input t scope))
  | Dsl.Await_input_or_child children ->
    let children = Rrbvec.to_list children in
    let rec validate seen = function
      | [] -> Ok ()
      | child :: rest ->
        let* () = Dsl.Producer.check_child t.producer scope.handle child in
        if List.exists (Dsl.equal_child child) seen
        then Error (Dsl.Invalid_input "Duplicate child")
        else validate (child :: seen) rest
    in
    let* () = validate [] children in
    input_wait t (fun () ->
      wait t (fun () ->
        if not scope.live
        then Some (Error Dsl.Cancelled)
        else (
          let rec poll = function
            | [] -> None
            | child :: rest ->
              (match Dsl.Producer.child_result t.producer scope.handle child with
               | Error e -> Some (Error e)
               | Ok (Some _) ->
                 scope.prefer_child <- false;
                 Some (Ok (Dsl.Child_ready child))
               | Ok None -> poll rest)
          in
          let input () =
            match take_input t scope with
            | Some result ->
              scope.prefer_child <- true;
              Some (Result.map (fun input -> Dsl.Input input) result)
            | None -> None
          in
          if t.stop
          then input ()
          else if scope.prefer_child
          then (
            match poll children with
            | Some _ as ready -> ready
            | None -> input ())
          else (
            match input () with
            | Some _ as ready -> ready
            | None -> poll children))))
  | Dsl.Sleep seconds ->
    if (not (Float.is_finite seconds)) || seconds < 0.
    then Error (Dsl.Invalid_input "Sleep duration")
    else (
      t.sleep seconds;
      Ok ())
  | Dsl.Yield ->
    Eio.Fiber.yield ();
    Ok ()
;;

type (_, _) task_continuation =
  | Task_done : ('a, 'a) task_continuation
  | Task_then :
      ('a -> 'b Dsl.task) * task_scope * ('b, 'c) task_continuation
      -> ('a, 'c) task_continuation
  | Task_exit : task_scope * ('a, 'b) task_continuation -> ('a, 'b) task_continuation

type 'a task_step =
  | Task_step of (unit -> 'a task_step)
  | Task_result of ('a, Dsl.error) result

let rec task_step
  : type a b.
    t
    -> unit ref
    -> task_scope
    -> a Dsl.task
    -> (a, b) task_continuation
    -> int
    -> b task_step
  =
  fun t token scope task continuation steps ->
  Task_step
    (fun () ->
      try
        let steps =
          if steps >= t.limits.steps_per_turn
          then (
            Eio.Fiber.yield ();
            0)
          else steps
        in
        Eio.Fiber.check ();
        match Dsl.task_view task with
        | Dsl.Task_return value ->
          task_continue t token scope value continuation (steps + 1)
        | Dsl.Task_fail error -> task_unwind t continuation error
        | Dsl.Task_bind (task, next) ->
          task_step t token scope task (Task_then (next, scope, continuation)) (steps + 1)
        | Dsl.Task_scope f ->
          let inner = make_task_scope t (Some scope) in
          task_step
            t
            token
            inner
            (f inner.handle)
            (Task_exit (inner, continuation))
            (steps + 1)
        | Dsl.Task_perform (operation, success, failure) ->
          (match
             let* () = check_scope t scope in
             task_operation t token scope operation
           with
           | Ok value -> task_step t token scope (success value) continuation (steps + 1)
           | Error (Dsl.Cleanup_failure _ as e) ->
             record_cleanup t e;
             raise (Forced e)
           | Error e -> task_step t token scope (failure e) continuation (steps + 1))
        | Dsl.Task_spawn (handle, task) ->
          let result = spawn_task t token scope handle None task in
          task_continue t token scope result continuation (steps + 1)
        | Dsl.Task_spawn_asset (handle, receipt, task) ->
          let result = spawn_task t token scope handle (Some receipt) task in
          task_continue t token scope result continuation (steps + 1)
        | Dsl.Task_join child ->
          let result =
            let* () = Dsl.Producer.check_child t.producer scope.handle child in
            match child_control scope child with
            | None -> Error Dsl.Stale_context
            | Some control ->
              ignore (control.join_child () : Dsl.error option);
              let* result = Dsl.Producer.child_result t.producer scope.handle child in
              (match result with
               | None -> Error (Dsl.Unexpected_failure "Joined child is unfinished")
               | Some result ->
                 let* () = Dsl.Producer.forget_child t.producer scope.handle child in
                 control.consumed <- true;
                 control.release_capacity ();
                 scope.children <- List.filter (fun c -> c != control) scope.children;
                 t.tasks <- t.tasks - 1;
                 capacity_changed t;
                 result)
          in
          (* Join returns the child's domain result as data. *)
          task_continue t token scope result continuation (steps + 1)
        | Dsl.Task_cancel child ->
          (match child_control scope child with
           | None -> task_unwind t continuation Dsl.Stale_context
           | Some c ->
             c.cancel_child ();
             task_continue t token scope () continuation (steps + 1))
      with
      | Eio.Cancel.Cancelled _ ->
        Eio.Cancel.protect (fun () -> task_unwind t continuation Dsl.Cancelled)
      | Forced error -> Eio.Cancel.protect (fun () -> task_unwind t continuation error)
      | _ ->
        Eio.Cancel.protect (fun () ->
          task_unwind t continuation (Dsl.Unexpected_failure "Task continuation raised")))

and task_continue
  : type a b.
    t -> unit ref -> task_scope -> a -> (a, b) task_continuation -> int -> b task_step
  =
  fun t token scope value continuation steps ->
  match continuation with
  | Task_done -> Task_result (Ok value)
  | Task_then (next, parent, rest) -> task_step t token parent (next value) rest steps
  | Task_exit (inner, rest) ->
    (match cleanup_scope t inner with
     | Ok () -> task_continue t token scope value rest steps
     | Error e -> task_unwind t rest e)

and task_unwind : type a b. t -> (a, b) task_continuation -> Dsl.error -> b task_step =
  fun t continuation error ->
  match continuation with
  | Task_done -> Task_result (Error error)
  | Task_then (_, _, rest) -> task_unwind t rest error
  | Task_exit (scope, rest) ->
    let error =
      match cleanup_scope t scope with
      | Ok () -> error
      | Error e -> cleanup_error ~primary:error [ e ]
    in
    task_unwind t rest error

and spawn_task
  : type a.
    t
    -> unit ref
    -> task_scope
    -> Dsl.scope
    -> Dsl.demand_receipt option
    -> a Dsl.task
    -> (a Dsl.child, Dsl.error) result
  =
  fun t token scope handle receipt task ->
  let* () = Dsl.Producer.check_scope t.producer handle in
  if handle != scope.handle
  then Error Dsl.Stale_context
  else
    let* background =
      match receipt with
      | None -> Ok false
      | Some receipt ->
        let* d = current_demand t receipt in
        Ok (background d.change)
    in
    let pending_ceiling =
      t.limits.maximum_pending - if Option.is_some receipt then 3 else 0
    in
    let ceiling =
      min t.limits.maximum_tasks pending_ceiling
      - if background then t.limits.foreground_reserve else 0
    in
    if t.tasks >= ceiling
    then Error (Dsl.Capacity_exceeded "Child slots")
    else
      let* reservation =
        match receipt with
        | None -> Ok None
        | Some receipt ->
          let* demand = current_demand t receipt in
          (match demand.change with
           | Dsl.Withdraw _ -> Ok None
           | Dsl.Demand d ->
             let* reservation = reserve_asset t d.asset (Some demand.change) in
             Ok (Some reservation))
      in
      let release_capacity () =
        Option.iter (fun (_, release) -> release ()) reservation
      in
      let result = ref None in
      let finished, resolve = Eio.Promise.create () in
      let cancelled = ref false
      and cc = ref None in
      let* child =
        match
          Dsl.Producer.child t.producer scope.handle task ~poll:(fun () -> !result)
        with
        | Ok child -> Ok child
        | Error error ->
          release_capacity ();
          Error error
      in
      let control =
        { key = Obj.repr child
        ; consumed = false
        ; release_capacity
        ; cancel_child =
            (fun () ->
              cancelled := true;
              Option.iter (fun cc -> Eio.Cancel.cancel cc Cancel_execution) !cc)
        ; join_child =
            (fun () ->
              Eio.Promise.await finished;
              match !result with
              | Some (Error (Dsl.Cancelled | Dsl.Network_closed | Dsl.Stale_context))
              | Some (Ok _) -> None
              | Some (Error e) -> Some e
              | None -> Some (Dsl.Unexpected_failure "Child failed to resolve"))
        }
      in
      t.tasks <- t.tasks + 1;
      scope.children <- control :: scope.children;
      Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
        let outcome =
          try
            Eio.Cancel.sub (fun context ->
              cc := Some context;
              if !cancelled
              then Error Dsl.Cancelled
              else (
                match reservation with
                | None -> task_interpret t token scope task Task_done 0
                | Some (work, _) ->
                  Eio.Fiber.with_binding asset_binding (t, work) (fun () ->
                    task_interpret t token scope task Task_done 0)))
          with
          | Eio.Cancel.Cancelled _ -> Error Dsl.Cancelled
          | Forced e -> Error e
          | _ -> Error (Dsl.Unexpected_failure "Task continuation raised")
        in
        cc := None;
        result := Some outcome;
        Eio.Promise.resolve resolve ();
        pulse t;
        `Stop_daemon);
      Ok child

and task_interpret
  : type a b.
    t
    -> unit ref
    -> task_scope
    -> a Dsl.task
    -> (a, b) task_continuation
    -> int
    -> (b, Dsl.error) result
  =
  fun t token scope task continuation steps ->
  let rec drive = function
    | Task_result result -> result
    | Task_step next -> drive (next ())
  in
  drive (task_step t token scope task continuation steps)
;;

let run_task (t : t) token task =
  let root = make_task_scope t None in
  t.active <- Some root;
  t.stop <- false;
  t.network_input <- None;
  t.unlock <- None;
  mark_dirty t;
  let result =
    try task_interpret t token root task Task_done 0 with
    | exn ->
      Eio.Cancel.protect (fun () ->
        List.iter
          (fun scope -> ignore (cleanup_scope t scope : (unit, Dsl.error) result))
          (List.filter (fun s -> s != root) t.scopes);
        ignore (cleanup_scope t root : (unit, Dsl.error) result);
        t.active <- None;
        t.unlock <- None;
        t.outbox_check <- None;
        pulse t);
      raise exn
  in
  let joined = cleanup_scope t root in
  t.active <- None;
  t.unlock <- None;
  t.outbox_check <- None;
  t.demands <- [];
  pulse t;
  match result, joined with
  | result, Ok () -> result
  | result, Error error ->
    let error =
      cleanup_error
        ?primary:
          (match result with
           | Error e -> Some e
           | Ok _ -> None)
        [ error ]
    in
    record_cleanup t error;
    raise (Forced error)
;;

let drain (t : t) =
  t.fenced <- true;
  t.gate <- Dsl.Closed;
  ignore (set_phase t Dsl.Draining);
  let failures = ref [] in
  let add = function
    | Ok () -> ()
    | Error e -> failures := e :: !failures
  in
  let module W = (val t.caps.worker_owner) in
  add (protect_result (fun () -> W.fence ~identity:t.id));
  add (protect_result (fun () -> t.caps.fence t.id));
  (match close_network t with
   | Error e -> failures := e :: !failures
   | Ok receipt -> add (await_network_retirement receipt));
  match List.rev !failures with
  | [] -> Ok ()
  | xs ->
    let e = cleanup_error xs in
    record_cleanup t e;
    Error e
;;

let retire (t : t) =
  let failures = ref [] in
  let add = function
    | Ok () -> ()
    | Error e -> failures := e :: !failures
  in
  List.iter
    (fun e -> if (not e.delivery_owned) && not e.released then add (release_entry t e))
    t.resources;
  let* () =
    wait t (fun () ->
      if t.cleanup <> []
      then Some (Error (cleanup_error (List.rev t.cleanup)))
      else if List.exists (fun (d : delivery_entry) -> not d.released) t.deliveries
      then None
      else Some (Ok ()))
  in
  if t.cleanup <> []
  then Error (cleanup_error (List.rev t.cleanup))
  else
    let module W = (val t.caps.worker_owner) in
    add (protect_result (fun () -> W.await_quiescent ~identity:t.id));
    if !failures = [] then add (protect_result (fun () -> t.caps.retire t.id));
    match List.rev !failures with
    | [] -> Ok ()
    | xs ->
      let error = cleanup_error xs in
      record_cleanup t error;
      Error error
;;

let operation
  : type before after failed a.
    t
    -> unit ref
    -> before Dsl.phase
    -> (before, after, failed, a) Dsl.operation
    -> (after Dsl.phase * a, failed Dsl.phase * Dsl.error) result
  =
  fun t token phase operation ->
  let unchanged result =
    match result with
    | Ok a -> Ok (phase, a)
    | Error e -> Error (phase, e)
  in
  match operation with
  | Dsl.Restore ->
    (match with_effect t token (fun scope -> t.caps.restore ~scope t.id) with
     | Ok report ->
       t.keys <- report.keys;
       mark_dirty t;
       ignore (set_phase t Dsl.Ready);
       Ok (Dsl.Ready, report)
     | Error e -> Error (Dsl.Cold, e))
  | Dsl.Install_initial_network gate ->
    let result =
      if not t.initial_eligible
      then Ok ()
      else (
        t.initial_eligible <- false;
        match gate with
        | Dsl.Closed ->
          let* receipt = close_network t in
          await_network_retirement receipt
        | Dsl.Open { authorization_epoch } -> open_network t ~authorization_epoch)
    in
    (match result with
     | Ok () -> Ok (Dsl.Ready, ())
     | Error e -> Error (Dsl.Ready, e))
  | Dsl.Set_network gate ->
    let result =
      match gate with
      | Dsl.Closed ->
        let* receipt = close_network t in
        await_network_retirement receipt
      | Dsl.Open { authorization_epoch } -> open_network t ~authorization_epoch
    in
    (match result with
     | Ok () -> Ok (Dsl.Ready, ())
     | Error e -> Error (Dsl.Ready, e))
  | Dsl.Run_task task ->
    (match run_task t token task with
     | Ok a -> Ok (Dsl.Ready, a)
     | Error e -> Error (Dsl.Ready, e))
  | Dsl.Database op ->
    (match perform_database t token op with
     | Ok a -> Ok (Dsl.Ready, a)
     | Error e -> Error (Dsl.Ready, e))
  | Dsl.Transport op ->
    (match perform_transport t token op with
     | Ok a -> Ok (Dsl.Ready, a)
     | Error e -> Error (Dsl.Ready, e))
  | Dsl.Crypto op ->
    (match perform_crypto t token op with
     | Ok a -> Ok (Dsl.Ready, a)
     | Error e -> Error (Dsl.Ready, e))
  | Dsl.Assets op ->
    (match perform_assets t token op with
     | Ok a -> Ok (Dsl.Ready, a)
     | Error e -> Error (Dsl.Ready, e))
  | Dsl.Observe -> unchanged (observation_state t)
  | Dsl.Release_file file -> unchanged (release_reference t (Dsl.File_reference file))
  | Dsl.Release_lease lease -> unchanged (release_reference t (Dsl.Lease_reference lease))
  | Dsl.Release_snapshot snapshot ->
    unchanged (release_reference t (Dsl.Snapshot_reference snapshot))
  | Dsl.Begin_drain _ ->
    (match drain t with
     | Ok () -> Ok (Dsl.Draining, ())
     | Error e -> Error (Dsl.Draining, e))
  | Dsl.Finish_retirement ->
    (match retire t with
     | Ok () ->
       ignore (set_phase t Dsl.Retired);
       Ok (Dsl.Retired, ())
     | Error e -> Error (Dsl.Draining, e))
;;

let rec interpret
  : type before after a.
    t
    -> unit ref
    -> before Dsl.phase
    -> (before, after, a) Dsl.program
    -> (after, a) outcome
  =
  fun t token phase program ->
  Eio.Fiber.check ();
  match Dsl.view program with
  | Dsl.Return value -> Completed (set_phase t phase, value)
  | Dsl.Abort error -> Failed (actual t, error)
  | Dsl.Perform (op, success, failure) ->
    (match operation t token phase op with
     | Ok (next, value) ->
       ignore (set_phase t next);
       interpret t token next (success value)
     | Error (next, error) ->
       t.last_failure <- Some error;
       ignore (set_phase t next);
       if t.cleanup <> []
       then Failed (actual t, cleanup_error ~primary:error (List.rev t.cleanup))
       else interpret t token next (failure error))
;;

let start (t : t) (context : _ graph_context) program =
  if context.runtime != t || context.version != t.current_version || Option.is_some t.busy
  then Error Dsl.Stale_context
  else (
    let token = ref () in
    let finished, resolve = Eio.Promise.create () in
    let running =
      { runtime = t
      ; outcome_promise = finished
      ; cancellation = None
      ; cancelled = false
      ; terminal = false
      }
    in
    t.busy <- Some token;
    t.current_version <- ref ();
    ignore (set_phase t context.phase);
    Eio.Fiber.fork_daemon ~sw:t.sw (fun () ->
      let result =
        try
          Eio.Cancel.sub (fun cc ->
            running.cancellation <- Some cc;
            if running.cancelled then raise (Forced Dsl.Cancelled);
            interpret t token context.phase program)
        with
        | Eio.Cancel.Cancelled _ ->
          Eio.Cancel.protect (fun () -> ignore (drain t : (unit, Dsl.error) result));
          Failed
            ( actual t
            , if t.cleanup = []
              then Dsl.Cancelled
              else cleanup_error ~primary:Dsl.Cancelled (List.rev t.cleanup) )
        | Forced error -> Failed (actual t, error)
        | _ -> Failed (actual t, Dsl.Unexpected_failure "Program continuation raised")
      in
      running.terminal <- true;
      t.busy <- None;
      pulse t;
      Eio.Promise.resolve resolve result;
      `Stop_daemon);
    Ok running)
;;

let await running = Eio.Promise.await running.outcome_promise

let cancel (t : t) running =
  if running.runtime != t || (running.terminal && not running.cancelled)
  then Error Dsl.Stale_context
  else if running.cancelled
  then Ok ()
  else (
    running.cancelled <- true;
    t.fenced <- true;
    t.gate <- Dsl.Closed;
    ignore (set_phase t Dsl.Draining);
    Option.iter (fun cc -> Eio.Cancel.cancel cc Cancel_execution) running.cancellation;
    Ok ())
;;

let current (t : t) =
  if Option.is_some t.busy then Error Dsl.Stale_context else Ok (actual t)
;;

let create ~sw ~clock ~database_owner:owner ~identity ~limits caps =
  let* () = protect_result (fun () -> caps.validate_identity identity) in
  let* () = protect_result (fun () -> caps.validate_limits limits) in
  let d = caps.network_deadlines in
  let valid =
    List.for_all
      finite_positive
      [ caps.cleanup_seconds
      ; d.setup_seconds
      ; d.tls_handshake_seconds
      ; d.http_response_seconds
      ; d.download_seconds
      ]
  in
  let valid =
    valid
    &&
    match caps.websocket_liveness with
    | Peer_close_only -> true
    | Ping_pong { interval_seconds; timeout_seconds } ->
      finite_positive interval_seconds && finite_positive timeout_seconds
  in
  if not valid
  then Error (Dsl.Invalid_input "Network timings")
  else if owner.bound
  then Error (Dsl.Identity_mismatch "Database owner already bound")
  else
    let* () = protect_result (fun () -> caps.acquire identity) in
    owner.bound <- true;
    let t =
      { sw
      ; now =
          (fun () ->
            Mtime.to_uint64_ns (Eio.Time.Mono.now clock)
            |> Int64.to_float
            |> fun n -> n /. 1e9)
      ; sleep = (fun seconds -> Eio.Time.Mono.sleep clock seconds)
      ; id = identity
      ; limits
      ; caps
      ; owner
      ; producer = Dsl.Producer.create identity
      ; changed = Eio.Condition.create ()
      ; actual = None
      ; revision = 0L
      ; current_version = ref ()
      ; busy = None
      ; fenced = false
      ; gate = Dsl.Closed
      ; generation = 0L
      ; retirement = None
      ; initial_eligible = true
      ; network_calls = []
      ; producers = []
      ; resources = []
      ; reserved_resources = 0
      ; cleanup = []
      ; active = None
      ; scopes = []
      ; tasks = 0
      ; asset_work = []
      ; capacity = 0L
      ; stop = false
      ; network_input = None
      ; unlock = None
      ; demands = []
      ; deliveries = []
      ; receiver = false
      ; input_reader = false
      ; outbox_epoch = 1L
      ; outbox_acked = 0L
      ; outbox_check = None
      ; keys = Dsl.Key_locked
      ; status = Dsl.Service_idle
      ; last_failure = None
      ; observation = None
      ; observation_reader = false
      }
    in
    let cold = set_phase t Dsl.Cold in
    let module W = (val caps.worker_owner) in
    let network =
      { with_admission =
          (fun callback ->
            with_network
              t
              (fun () -> if t.fenced then Error Dsl.Stale_context else Ok ())
              callback)
      }
    in
    Eio.Switch.on_release sw (fun () ->
      Eio.Cancel.protect (fun () ->
        match actual t with
        | Context (Dsl.Retired, _) -> ()
        | _ ->
          ignore (drain t : (unit, Dsl.error) result);
          ignore (retire t : (unit, Dsl.error) result)));
    match
      protect_result (fun () ->
        W.bind_runtime
          ~identity
          ~database_owner:owner
          ~limits
          ~cleanup_seconds:caps.cleanup_seconds
          ~network)
    with
    | Ok () -> Ok (t, cold)
    | Error primary ->
      Eio.Cancel.protect (fun () ->
        let errors =
          List.filter_map
            (function
              | Ok () -> None
              | Error e -> Some e)
            [ drain t; retire t ]
        in
        match errors with
        | [] -> Error primary
        | xs -> Error (cleanup_error ~primary xs))
;;
