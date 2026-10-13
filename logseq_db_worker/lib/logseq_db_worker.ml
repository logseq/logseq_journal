module Config = Logseq_db_worker_contract.Config
module Error = Logseq_db_worker_contract.Error
module Protocol = Logseq_db_worker_contract.Protocol
module Pure_reducer = Logseq_db_worker_pure_reducer.Core
module Effect_runner = Logseq_db_worker_effect_runner.Effect_runner

module Sync = Logseq_sync_pure_reducer.Core

let unlock_log_count = Atomic.make 0
let unlock_attempt_count = Atomic.make 0

let unlock_log format =
  Printf.ksprintf (fun fields ->
    if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1" then (
      let count = Atomic.fetch_and_add unlock_log_count 1 in
      try
        if count < 256 then Printf.eprintf "[journal-unlock] source=core %s\n%!" fields
        else if count = 256 then Printf.eprintf "[journal-unlock] source=core limit=reached\n%!"
      with _ -> ())) format
;;

let unlock_failure = function
  | None -> "none"
  | Some Sync.During_e2ee -> "e2ee"
  | Some During_catalog -> "catalog"
  | Some During_authentication -> "authentication"
  | Some During_local_restore -> "local-restore"
  | Some During_bootstrap -> "bootstrap"
;;

let observe_unlock before (transition : Pure_reducer.transition) event =
  if Sys.getenv_opt "JOURNAL_UNLOCK_DIAGNOSTICS" = Some "1" then (
    let previous = (Pure_reducer.view before).sync.snapshot.startup in
    let next = (Pure_reducer.view transition.next).sync.snapshot.startup in
    match event with
    | Pure_reducer.Sync_event (Sync.E2ee_password_submitted _) ->
      let attempt = Atomic.fetch_and_add unlock_attempt_count 1 in
      let operation = List.find_map (function
        | Pure_reducer.Run_sync (Sync.Request (ticket, Sync.Unlock_private_key _)) ->
          Some (Sync.effect_ticket_id ticket |> Sync.effect_id_to_string)
        | _ -> None) transition.effects in
      unlock_log "attempt=%d op=%s phase=password decision=%s challenge_advertised=%b challenge_ready=%b failure=%s account_generation=%d graph_generation=%d"
        attempt (Option.value operation ~default:"none")
        (if Option.is_some operation then "accepted" else "ignored")
        previous.awaiting_e2ee_password (Option.is_some operation)
        (unlock_failure previous.failure) previous.account_generation previous.graph_generation
    | Sync_event (Sync.Runner_completed (Sync.Completion (ticket, _))) ->
      unlock_log "op=%s phase=completion effects=%d challenge_advertised=%b failure=%s account_generation=%d graph_generation=%d"
        (Sync.effect_ticket_id ticket |> Sync.effect_id_to_string)
        (List.length transition.effects)
        next.awaiting_e2ee_password (unlock_failure next.failure)
        next.account_generation next.graph_generation
    | _ -> ())
;;

type graph_phase = Pure_reducer.graph_phase =
  | Graph_closed
  | Graph_opening
  | Graph_open
  | Graph_closing
  | Graph_failed

type graph_state = Pure_reducer.graph_state =
  { generation : int
  ; graph_id : Logseq_db_types.Graph_types.Uuid.t option
  ; phase : graph_phase
  ; error : Error.t option
  }

type t =
  { state : Pure_reducer.state ref
  ; runner : Effect_runner.t
  ; events : Pure_reducer.event Eio.Stream.t
  ; mutable next_request_id : int64
  ; mutable stopped : bool
  }

type create_error = Invalid_create of string

let dispatch t event =
  let before = !(t.state) in
  let transition = Pure_reducer.step before event in
  observe_unlock before transition event;
  t.state := transition.next;
  List.iter (Effect_runner.submit t.runner) transition.effects
;;

let accepts_after_shutdown = function
  | Pure_reducer.Sync_event
      ( Logseq_sync_pure_reducer.Core.Asset_requested _ | Protected_requested _
      | Runner_completed (Asset_completion _ | Protected_completion _)
      | Shutdown ) -> true
  | _ -> false
;;

let route_event t event =
  if t.stopped
  then (if accepts_after_shutdown event then dispatch t event)
  else Eio.Stream.add t.events event
;;

let create ~sw ~config ~runner_dependencies =
  match Pure_reducer.initial config with
  | Error (Pure_reducer.Invalid_create message) -> Error (Invalid_create message)
  | Ok state ->
    let events = Eio.Stream.create 256 in
    let state_ref = ref state in
    let event_sink = ref (fun event -> Eio.Stream.add events event) in
    (match
       Effect_runner.create
         ~sw
         runner_dependencies
         ~recovery_current:(fun ticket ->
           Pure_reducer.upload_recovery_current !state_ref ticket)
         ~upload_current:(fun ticket ->
           Pure_reducer.upload_ticket_current !state_ref ticket)
         ~asset_current:(fun ticket ->
           Pure_reducer.asset_ticket_current !state_ref ticket)
         ~post:(fun event -> !event_sink event)
     with
     | Error (Effect_runner.Invalid_create message) -> Error (Invalid_create message)
     | Ok runner ->
       let t =
         { state = state_ref; runner; events; next_request_id = 0L; stopped = false }
       in
       event_sink := route_event t;
       dispatch t Pure_reducer.Start;
       Eio.Fiber.fork ~sw (fun () ->
         while not t.stopped do
           dispatch t (Eio.Stream.take events)
         done);
       Ok t)
;;

let post t event = route_event t event
let view t = Pure_reducer.view !(t.state)
let graph_state t = (view t).graph

let request t request =
  let id = Pure_reducer.request_id_of_int64 t.next_request_id in
  t.next_request_id <- Int64.succ t.next_request_id;
  Effect_runner.await_reply t.runner ~id ~request ~post:(fun () ->
    post t (Pure_reducer.Graph_request { id; request }))
;;

let shutdown t =
  if not t.stopped
  then (
    t.stopped <- true;
    dispatch t Pure_reducer.Shutdown;
    let rec drain () =
      match Eio.Stream.take_nonblocking t.events with
      | None -> ()
      | Some event ->
        if accepts_after_shutdown event then dispatch t event;
        drain ()
    in
    drain ();
    Eio.Stream.add t.events Pure_reducer.Shutdown;
    Effect_runner.shutdown t.runner)
;;

let retain_asset_file t ~scope ~handle =
  if t.stopped || not (Pure_reducer.asset_scope_current !(t.state) scope)
  then None
  else Effect_runner.retain_asset_file t.runner ~scope ~handle
;;

let release_asset_file t ~scope ~handle =
  Effect_runner.release_asset_file t.runner ~scope ~handle
;;

type import_receipt =
  { operation : Logseq_db_types.Graph_types.Uuid.t
  ; graph_generation : int
  ; scope : Logseq_sync_pure_reducer.Core.graph_scope
  ; target : Logseq_db_types.Graph_types.Uuid.t
  ; asset : Logseq_db_types.Asset_descriptor.t
  ; file_type : string
  ; preview : (string * string) option
  }

let import_asset t ~graph_generation request =
  match Pure_reducer.import_context !(t.state) ~graph_generation with
  | None -> Error "The graph is unavailable or its import queue is full"
  | Some context ->
    let current () =
      (not t.stopped)
      &&
      match Pure_reducer.import_context !(t.state) ~graph_generation with
      | Some latest -> latest.scope = context.scope
      | None -> false
    in
    Result.map
      (fun intent ->
         let preview =
           Effect_runner.retain_imported_file
             t.runner
             ~scope:context.scope
             ~operation:intent.Logseq_db_types.Asset_upload_intent.operation_id
         in
         let asset =
           Logseq_db_types.Asset_descriptor.create
             ~uuid:intent.asset
             ~source:(Managed None)
             ~current_checksum:(Some intent.version.checksum)
             ~size:(Some intent.size)
             ~dimensions:None
           |> Result.get_ok
         in
         dispatch
           t
           (Pure_reducer.Upload_requested
              { graph_generation
              ; operation = intent.Logseq_db_types.Asset_upload_intent.operation_id
              ; event = Logseq_db_worker_pure_reducer.Asset_upload.Restore intent
              });
         { operation = intent.operation_id
         ; graph_generation
         ; scope = context.scope
         ; target = intent.target
         ; asset
         ; file_type = intent.version.file_type
         ; preview
         })
      (Effect_runner.prepare_import t.runner ~context request ~current)
;;

let retain_imported_file t ~scope ~operation =
  if t.stopped || not (Pure_reducer.asset_scope_current !(t.state) scope)
  then None
  else Effect_runner.retain_imported_file t.runner ~scope ~operation
;;
