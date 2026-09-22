(** One durable explicit import, owned by the worker and independent of download demand. *)
module Intent = Logseq_db_types.Asset_upload_intent

module Scope = Logseq_sync_pure_reducer.Core

type failure =
  | Network
  | Authentication
  | Missing_source
  | Size_rejected
  | Revoked_access
  | Invalid_content
  | Persistence_failed of string

type status =
  | Preparing
  | Waiting
  | Sending
  | Publishing
  | Cancelling
  | Uploaded
  | Cancelled
  | Failed_upload of failure

type ticket =
  { id : int
  ; scope : Scope.graph_scope
  ; operation : Logseq_db_types.Graph_types.Uuid.t
  }

type observation =
  | Absent
  | Local_present
  | Metadata_present
  | Publication_acknowledged
  | Entity_cancelled

type completion =
  | Persisted
  | Inspected of observation
  | Local_applied
  | Put_succeeded
  | Metadata_applied
  | Publication_acked
  | Failed of failure

type instruction =
  | Persist of ticket * Intent.t * int option
  | Inspect of ticket * Intent.t
  | Apply_local of ticket * Intent.t
  | Put of ticket * Intent.t
  | Apply_metadata of ticket * Intent.t
  | Await_publication of ticket * Intent.t
  | Release_staging of Intent.t
  | Cancel_operation of ticket

type event =
  | Start of Intent.t
  | Restore of Intent.t
  | Completed of ticket * completion
  | Cancel
  | Retry
  | Availability_changed of bool
  | Shutdown

type work =
  | Save of Intent.t * int option
  | Observe of Intent.t
  | Insert of Intent.t
  | Upload of Intent.t
  | Publish of Intent.t
  | Await of Intent.t

type t =
  { scope : Scope.graph_scope
  ; durable : Intent.t option
  ; pending : (ticket * work) option
  ; retry : work option
  ; last_failure : failure option
  ; serial : int
  ; cancel_requested : bool
  ; stopped : bool
  ; available : bool
  }

let create ~scope ~available =
  { scope
  ; durable = None
  ; pending = None
  ; retry = None
  ; last_failure = None
  ; serial = 0
  ; cancel_requested = false
  ; stopped = false
  ; available
  }
;;

let checkpoint t = t.durable
let failure t = t.last_failure

let work_intent = function
  | Save (i, _) | Observe i | Insert i | Upload i | Publish i | Await i -> i
;;

let issue t work =
  match work with
  | Upload _ when not t.available ->
    { t with pending = None; retry = Some work; last_failure = None }, []
  | Save _ | Observe _ | Insert _ | Upload _ | Publish _ | Await _ ->
    let intent = work_intent work in
    let ticket =
      { id = t.serial + 1; scope = t.scope; operation = intent.operation_id }
    in
    let instruction =
      match work with
      | Save (intent, expected) -> Persist (ticket, intent, expected)
      | Observe intent -> Inspect (ticket, intent)
      | Insert intent -> Apply_local (ticket, intent)
      | Upload intent -> Put (ticket, intent)
      | Publish intent -> Apply_metadata (ticket, intent)
      | Await intent -> Await_publication (ticket, intent)
    in
    ( { t with
        pending = Some (ticket, work)
      ; retry = None
      ; last_failure = None
      ; serial = ticket.id
      }
    , [ instruction ] )
;;

let save_phase t intent phase =
  match Intent.advance intent phase with
  | Error _ -> { t with last_failure = Some Invalid_content }, []
  | Ok next -> issue t (Save (next, Option.map (fun i -> i.Intent.revision) t.durable))
;;

let terminal intent = intent.Intent.phase = Complete || intent.phase = Cancelled

let after_save t intent =
  if t.cancel_requested && not (terminal intent)
  then save_phase t intent Cancelled
  else (
    match intent.Intent.phase with
    | Prepared -> issue t (Insert intent)
    | Local_committed -> save_phase t intent Uploading
    | Uploading -> issue t (Upload intent)
    | Remote_stored -> save_phase t intent Metadata_pending
    | Metadata_pending -> issue t (Publish intent)
    | Complete | Cancelled -> t, [ Release_staging intent ])
;;

let belongs t intent =
  intent.Intent.origin = Uri.to_string t.scope.account.managed_sync_origin
  && intent.account = t.scope.account.user_id
  && Logseq_db_types.Graph_types.Uuid.equal intent.graph t.scope.graph_id
;;

let recover t intent observation =
  match observation, intent.Intent.phase with
  | _, (Complete | Cancelled) -> t, [ Release_staging intent ]
  | Entity_cancelled, _ -> save_phase t intent Cancelled
  | Absent, Prepared -> issue t (Insert intent)
  | Absent, _ -> save_phase t intent Cancelled
  | Local_present, Prepared -> save_phase t intent Local_committed
  | Local_present, _ -> after_save t intent
  | Metadata_present, Metadata_pending -> issue t (Await intent)
  | Publication_acknowledged, Metadata_pending -> save_phase t intent Complete
  | (Metadata_present | Publication_acknowledged), _ ->
    { t with last_failure = Some Invalid_content }, []
;;

let cancel t =
  let t = { t with cancel_requested = true } in
  match t.pending with
  | Some (_, Save _) -> t, []
  | pending ->
    let intent =
      match t.durable, t.retry with
      | Some intent, _ -> Some intent
      | None, Some work -> Some (work_intent work)
      | None, None -> None
    in
    let effects =
      match pending with
      | Some (ticket, _) -> [ Cancel_operation ticket ]
      | None -> []
    in
    let t = { t with pending = None; retry = None } in
    (match intent with
     | Some intent when not (terminal intent) ->
       let t, persisted = save_phase t intent Cancelled in
       t, effects @ persisted
     | Some _ | None -> t, effects)
;;

let complete t ticket completion =
  match t.pending with
  | Some (expected, work) when expected = ticket ->
    let t = { t with pending = None } in
    (match completion, work with
     | Failed failure, _ -> { t with retry = Some work; last_failure = Some failure }, []
     | Persisted, Save (intent, _) -> after_save { t with durable = Some intent } intent
     | Inspected observation, Observe intent -> recover t intent observation
     | Local_applied, Insert intent -> save_phase t intent Local_committed
     | Put_succeeded, Upload intent -> save_phase t intent Remote_stored
     | Metadata_applied, Publish intent -> issue t (Await intent)
     | Publication_acked, Await intent -> save_phase t intent Complete
     | _ -> { t with pending = Some (expected, work) }, [])
  | Some _ | None -> t, []
;;

let step t event =
  if t.stopped
  then t, []
  else (
    match event with
    | Start intent
      when t.durable = None
           && t.pending = None
           && t.retry = None
           && belongs t intent
           && intent.phase = Prepared
           && intent.revision = 0 -> issue t (Save (intent, None))
    | Restore intent
      when t.durable = None && t.pending = None && t.retry = None && belongs t intent ->
      let t = { t with durable = Some intent } in
      if terminal intent then t, [ Release_staging intent ] else issue t (Observe intent)
    | Start _ | Restore _ -> t, []
    | Completed (ticket, completion) -> complete t ticket completion
    | Cancel -> cancel t
    | Retry ->
      (match t.retry, t.pending with
       | Some work, None -> if t.cancel_requested then cancel t else issue t work
       | None, _ | Some _, Some _ -> t, [])
    | Availability_changed available ->
      if t.available = available
      then t, []
      else (
        let t = { t with available } in
        match available, t.pending, t.retry, t.last_failure with
        | false, Some (ticket, (Upload _ as work)), _, _ ->
          ( { t with pending = None; retry = Some work; last_failure = None }
          , [ Cancel_operation ticket ] )
        | true, None, Some (Upload _ as work), None -> issue t work
        | _ -> t, [])
    | Shutdown ->
      let instructions =
        match t.pending with
        | Some (ticket, _) -> [ Cancel_operation ticket ]
        | None -> []
      in
      { t with pending = None; stopped = true }, instructions)
;;

let ticket_current t ticket =
  (not t.stopped)
  &&
  match t.pending with
  | Some (expected, _) -> expected = ticket
  | None -> false
;;

let status t =
  if t.stopped
  then None
  else (
    match t.last_failure with
    | Some failure -> Some (Failed_upload failure)
    | None ->
      let phase = Option.map (fun intent -> intent.Intent.phase) t.durable in
      if t.cancel_requested && phase <> Some Intent.Cancelled
      then Some Cancelling
      else (
        match t.pending, t.retry, phase with
        | _, _, Some Intent.Cancelled -> Some Cancelled
        | _, _, Some Intent.Complete -> Some Uploaded
        | Some (_, Upload _), _, _ -> Some Sending
        | Some (_, (Publish _ | Await _)), _, _ -> Some Publishing
        | ( Some (_, Save ({ phase = Remote_stored | Metadata_pending | Complete; _ }, _))
          , _
          , _ ) -> Some Publishing
        | Some (_, Save ({ phase = Cancelled; _ }, _)), _, _ -> Some Cancelling
        | Some _, _, _ -> Some Preparing
        | None, Some (Upload _), _ -> Some Waiting
        | None, Some _, _ -> Some Preparing
        | None, None, _ -> None))
;;
