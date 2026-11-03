module Ui = Journal_view
module V = Ui.View
module Graph_service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Admission_refresh = Journal_admission_refresh
module Presentation = Journal_page_layout

module Pure_recovery = struct
  module Worker = Journal_worker_coordination.Worker_api

  type request =
    { session : Worker.session
    ; serial : int64
    ; after : Worker.mutation_recovery_cursor option
    ; page_number : int
    }

  type t =
    { serial : int64
    ; session : Worker.session option
    ; pending : request option
    ; page : Worker.mutation_recovery option
    ; after : Worker.mutation_recovery_cursor option
    ; page_number : int
    ; error : string option
    }

  type event =
    | Open of Worker.session option
    | Close
    | Reload
    | Retry
    | Next
    | Completed of request * (Worker.mutation_recovery, string) result

  let closed =
    { serial = 0L
    ; session = None
    ; pending = None
    ; page = None
    ; after = None
    ; page_number = 0
    ; error = None
    }
  ;;

  let loading t = t.pending <> None
  let error t = t.error
  let available t = t.session <> None
  let loaded t = t.page <> None

  let can_next t =
    (not (loading t))
    && t.error = None
    && Option.fold
         ~none:false
         ~some:(fun (page : Worker.mutation_recovery) -> page.next <> None)
         t.page
  ;;

  let page_number t = t.page_number

  let items t =
    Option.fold
      ~none:Rrbvec.empty
      ~some:(fun (page : Worker.mutation_recovery) -> page.items)
      t.page
  ;;

  let operation (request : request) =
    Worker.Recover_mutations
      { after = request.after
      ; maximum_items = 20
      ; maximum_bytes = Worker.maximum_mutation_recovery_bytes
      }
  ;;

  let start t session after page_number =
    let request = { session; serial = Int64.succ t.serial; after; page_number } in
    ( { serial = request.serial
      ; session = Some session
      ; pending = Some request
      ; page = None
      ; after
      ; page_number
      ; error = None
      }
    , Some request )
  ;;

  let step t = function
    | Close -> { closed with serial = Int64.succ t.serial }, None
    | Open None -> { closed with serial = Int64.succ t.serial }, None
    | Open (Some session) ->
      if
        loading t
        && Option.fold ~none:false ~some:(Worker.equal_session session) t.session
      then t, None
      else start t session None 1
    | Reload when not (loading t) ->
      (match t.session with
       | None -> t, None
       | Some session -> start t session None 1)
    | Retry when (not (loading t)) && t.error <> None ->
      (match t.session with
       | None -> t, None
       | Some session -> start t session t.after t.page_number)
    | Next when can_next t ->
      start t (Option.get t.session) (Option.get t.page).next (t.page_number + 1)
    | Completed (request, result) when t.pending = Some request ->
      let next =
        match result with
        | Ok page -> { t with pending = None; page = Some page; error = None }
        | Error error -> { t with pending = None; error = Some error }
      in
      next, None
    | Reload | Retry | Next | Completed _ -> t, None
  ;;
end

module Pure_import_recovery = struct
  module Worker=Journal_worker_coordination.Worker_api
  type request={session:Worker.session;serial:int64;after:Worker.import_input_recovery_cursor option;page_number:int}
  type acknowledgement={session:Worker.session;serial:int64;proof:Worker.prepared_import_source}
  type command=Read of request|Acknowledge of acknowledgement
  type t={serial:int64;session:Worker.session option;pending:request option;ack_pending:acknowledgement option;
    page:Worker.import_input_recovery option;after:Worker.import_input_recovery_cursor option;page_number:int;error:string option}
  type event=Open of Worker.session option|Close|Reload|Retry|Next|Mark_reviewed of Worker.prepared_import_source
    |Completed of request * (Worker.import_input_recovery,string)result|Acknowledged of acknowledgement * (unit,string)result
  let closed={serial=0L;session=None;pending=None;ack_pending=None;page=None;after=None;page_number=0;error=None}
  let loading t=t.pending<>None || t.ack_pending<>None
  let available t=t.session<>None
  let loaded t=t.page<>None
  let error t=t.error
  let page_number t=t.page_number
  let items t=Option.fold ~none:Rrbvec.empty ~some:(fun(page:Worker.import_input_recovery)->page.inputs)t.page
  let can_next t=not(loading t) && t.error=None
    && Option.exists(fun(page:Worker.import_input_recovery)->page.continuation<>None)t.page
  let operation (request:request)=Worker.Recover_import_inputs{after=request.after;maximum_items=20;maximum_bytes=262144}
  let exhausted t={t with pending=None;ack_pending=None;error=Some "Recovery request limit reached. Reopen Journal."},None
  let start t session after page_number=
    if t.serial=Int64.max_int then exhausted t else
    let serial=Int64.succ t.serial in
    let request={session;serial;after;page_number} in
    {serial;session=Some session;pending=Some request;ack_pending=None;page=None;after;page_number;error=None},Some(Read request)
  let step t=function
    |Close|Open None->{closed with serial=(if t.serial=Int64.max_int then t.serial else Int64.succ t.serial)},None
    |Open(Some session) when loading t && Option.exists(Worker.equal_session session)t.session->t,None
    |Open(Some session)->start t session None 1
    |Reload when not(loading t)->(match t.session with None->t,None|Some session->start t session None 1)
    |Retry when not(loading t) && t.error<>None->(match t.session with None->t,None|Some session->start t session t.after t.page_number)
    |Next when can_next t->start t (Option.get t.session)(Option.get t.page).continuation(t.page_number+1)
    |Completed(request,result) when t.pending=Some request->
      (match result with
       |Ok page->{t with pending=None;page=Some page;error=None},None
       |Error error->{t with pending=None;error=Some error},None)
    |Mark_reviewed proof when not(loading t) && t.error=None
       && Option.exists(Worker.equal_session(Worker.prepared_import_source_session proof))t.session
       && Rrbvec.exists(fun(row:Worker.recovered_import_input)->Option.exists(Worker.equal_prepared_import_source proof)row.prepared)(items t)->
      if t.serial=Int64.max_int then exhausted t else
      let serial=Int64.succ t.serial in
      let ack={session=Option.get t.session;serial;proof} in
      {t with serial;ack_pending=Some ack;error=None},Some(Acknowledge ack)
    |Acknowledged(ack,result) when t.ack_pending=Some ack->
      (match result with
       |Ok()->start {t with ack_pending=None}ack.session t.after t.page_number
       |Error error->{t with ack_pending=None;error=Some error},None)
    |Reload|Retry|Next|Mark_reviewed _|Completed _|Acknowledged _->t,None
end

type recovery_controls =
  { state : Pure_recovery.t
  ; on_reload : Ui.Event.Handler.t
  ; on_retry : Ui.Event.Handler.t
  ; on_next : Ui.Event.Handler.t
  }

type import_recovery_controls={import_state:Pure_import_recovery.t;
  on_import_reload:Ui.Event.Handler.t;on_import_retry:Ui.Event.Handler.t;on_import_next:Ui.Event.Handler.t;
  on_import_review:Pure_import_recovery.Worker.prepared_import_source -> Ui.Event.Handler.t}

type props =
  { snapshot : Graph_service.snapshot option
  ; graph : Logseq_db_worker.graph_state
  ; admission : Journal_admission_refresh.observation
  ; diagnostics : Graph_service.diagnostics option
  ; application_errors : (string * string) list
  }

let diagnostic_rows (diagnostics : Graph_service.diagnostics) =
  List.concat_map
    (fun (group : Graph_service.diagnostic_group) -> group.entries)
    diagnostics.groups
;;

let sync_phase_name : Graph_service.sync_phase -> string = function
  | Offline -> "Offline"
  | Connecting -> "Connecting"
  | Pulling -> "Pulling"
  | Submitting -> "Submitting"
  | Current -> "Current"
  | Paused -> "Paused"
  | Failed -> "Failed"
;;

let startup_phase_name : Journal_startup.startup_phase -> string = function
  | Signed_out -> "Signed out"
  | Loading_catalog -> "Loading catalog"
  | Awaiting_selection -> "Awaiting selection"
  | Restoring_local -> "Restoring local"
  | Deleting_local -> "Deleting local copy"
  | Bootstrapping -> "Bootstrapping"
  | Awaiting_e2ee_password -> "Awaiting E2EE password"
  | Ready -> "Ready"
  | Failed -> "Failed"
;;

let graph_phase_name : Logseq_db_worker.graph_phase -> string = function
  | Graph_closed -> "Closed"
  | Graph_opening -> "Opening"
  | Graph_open -> "Open"
  | Graph_closing -> "Closing"
  | Graph_failed -> "Failed"
;;

let diagnostic_phase_rows ~snapshot ~(graph : Logseq_db_worker.graph_state) =
  let worker_rows =
    [ "Graph phase", graph_phase_name graph.phase
    ; "Worker graph UUID",
      Option.fold ~none:"Not available"
        ~some:Logseq_db_types.Graph_types.Uuid.to_string graph.graph_id
    ; "Worker graph generation", string_of_int graph.generation
    ]
  in
  match snapshot with
  | None ->
    [ "Sync phase", "Not available"
    ; "Startup phase", "Not available"
    ]
    @ worker_rows
  | Some snapshot ->
    let startup = Journal_startup.derive ~snapshot ~graph in
    [ "Sync phase", sync_phase_name snapshot.sync_phase
    ; "Startup phase", startup_phase_name startup.phase
    ]
    @ worker_rows
    @ Option.fold ~none:[] ~some:(fun message -> [ "Last error", message ]) snapshot.last_error
;;

let format_bytes bytes =
  let bytes = max 0 bytes in
  let format_scaled divisor suffix =
    if bytes mod divisor = 0
    then Printf.sprintf "%d %s" (bytes / divisor) suffix
    else Printf.sprintf "%.1f %s" (Float.of_int bytes /. Float.of_int divisor) suffix
  in
  if bytes < 1024
  then Printf.sprintf "%d B" bytes
  else if bytes < 1024 * 1024
  then format_scaled 1024 "KB"
  else format_scaled (1024 * 1024) "MB"
;;

let admission_rows observation =
  let values =
    match (observation : Admission_refresh.observation) with
    | Available inspection ->
      [ Printf.sprintf "%d / %d" inspection.active_records inspection.maximum_records
      ; Printf.sprintf
          "%s / %s"
          (format_bytes inspection.active_bytes)
          (format_bytes inspection.maximum_bytes)
      ; format_bytes inspection.protected_wire_bytes
      ; format_bytes inspection.retained_origin_evidence_bytes
      ]
    | Loading -> List.init 4 (fun _ -> "Loading")
    | Unavailable -> List.init 4 (fun _ -> "Not available")
  in
  List.combine
    [ "Outbox records"; "Outbox bytes"; "Protected payload"; "Origin evidence" ]
    values
;;

let diagnostic_groups diagnostics =
  let unavailable labels = List.map (fun label -> label, "Not available") labels in
  match diagnostics with
  | None ->
    [ "Manager", unavailable [ "Last error" ]
    ; ( "Scope fences"
      , unavailable
          [ "Account generation"
          ; "Graph generation"
          ; "Presentation generation"
          ; "Connection generation"
          ] )
    ; ( "Graph"
      , unavailable [ "Graph selected"; "Selected graph"; "Applied server transaction" ] )
    ; "Transport", unavailable [ "Transport scope"; "Transport"; "WebSocket initialized" ]
    ; "Pull", unavailable [ "Pull" ]
    ; "Submission", unavailable [ "Submission" ]
    ; "Recovery", unavailable [ "Reconnect attempt"; "Uncertain transactions" ]
    ; "Serialization", unavailable [ "Serialization" ]
    ; "Authorization", unavailable [ "Pending token challenges" ]
    ]
  | Some (diagnostics : Graph_service.diagnostics) ->
    diagnostics.groups
    |> List.filter_map (fun (group : Graph_service.diagnostic_group) ->
      let entries = group.entries in
      if entries = [] then None else Some (group.title, entries))
;;

let recovery_section { state; on_reload; on_retry; on_next } =
  let module R = Pure_recovery in
  let progress = function
    | R.Worker.Outcome_unknown -> "Outcome unknown"
    | Rejected _ -> "Not applied"
    | Committed_pending_presentation _ -> "Committed; awaiting confirmation"
    | Confirmed _ -> "Committed; awaiting application"
  in
  let rows =
    Rrbvec.to_seq (R.items state)
    |> Seq.map (fun (item : R.Worker.recovered_mutation) ->
      V.column
        ~alignment:Leading
        ~spacing:4.
        [ V.text (R.Worker.mutation_intent_id item.intent |> R.Worker.Uuid.to_string)
        ; V.text (progress item.progress)
        ])
    |> List.of_seq
  in
  let status =
    if not (R.available state)
    then "Open a graph to view pending changes."
    else if R.loading state
    then "Loading pending changes…"
    else (
      match R.error state with
      | Some message -> message
      | None when R.loaded state ->
        if rows = []
        then "No entries on this page."
        else
          Printf.sprintf
            "Page %d%s"
            (R.page_number state)
            (if R.can_next state then "; more available" else "; end of results")
      | None -> "Pending changes have not been loaded.")
  in
  let button ~enabled label on_press =
    V.button ~enabled ~child:(V.text label) ~on_press ()
  in
  Presentation.section
    "Pending local changes"
    ([ V.text "Viewing these records does not repeat or acknowledge a change."
     ; V.text status
     ]
     @ rows
     @ [ V.row
           ~spacing:8.
           ([ button
                ~enabled:(R.available state && not (R.loading state))
                "Reload pending changes"
                on_reload
            ]
            @ (if R.error state = None
               then []
               else [ button ~enabled:(not (R.loading state)) "Retry loading" on_retry ])
            @ [ button ~enabled:(R.can_next state) "Next pending changes" on_next ])
       ])
;;

let import_recovery_section {import_state=state;on_import_reload;on_import_retry;on_import_next;on_import_review} =
  let module R=Pure_import_recovery in
  let rows=Rrbvec.to_seq(R.items state) |> Seq.map(fun(item:R.Worker.recovered_import_input)->
    V.column ~alignment:Leading ~spacing:4.
      ([V.text(R.Worker.asset_import_title item.intent);
        V.text(R.Worker.asset_import_intent_id item.intent |> R.Worker.Uuid.to_string);
        V.text(if item.prepared=None then "Preparation outcome unknown; input retained." else "Original source prepared; awaiting review.")]
       @ Option.to_list(Option.map(fun proof->V.button ~enabled:(not(R.loading state) && R.error state=None)
         ~child:(V.text "Mark reviewed") ~on_press:(on_import_review proof)())item.prepared))) |> List.of_seq in
  let status=if not(R.available state)then "Open a graph to view recorded attachment inputs."
    else if R.loading state then "Checking recorded inputs…" else match R.error state with Some message->message
    |None when R.loaded state->if rows=[] then "No pending inputs on this page." else Printf.sprintf "Page %d%s"(R.page_number state)
      (if R.can_next state then "; more available" else "; end of results")
    |None->"Recorded inputs have not been loaded." in
  let button ~enabled label on_press=V.button ~enabled ~child:(V.text label) ~on_press() in
  Presentation.section "Recorded attachment inputs"
    ([V.text "Loading does not retry an import. Mark reviewed keeps the original input and preparation proof.";V.text status]
     @ rows @ [V.row ~spacing:8.
       ([button ~enabled:(R.available state && not(R.loading state)) "Reload attachment inputs" on_import_reload]
        @ (if R.error state=None then []else[button ~enabled:(not(R.loading state)) "Retry loading inputs" on_import_retry])
        @ [button ~enabled:(R.can_next state) "Next attachment inputs" on_import_next])])
;;

let view ?recovery ?imports { snapshot; graph; admission; diagnostics; application_errors } ~on_close =
  let groups =
    [ "Phases", diagnostic_phase_rows ~snapshot ~graph
    ; "Overlay DB", admission_rows admission
    ]
    @ diagnostic_groups diagnostics
    @ (if application_errors=[] then [] else
        [ "Application errors",
          application_errors
        ])
  in
  Presentation.form
    ((Option.to_list (Option.map recovery_section recovery)) @ Option.to_list(Option.map import_recovery_section imports) @ List.map
       (fun (title, rows) ->
          Presentation.section
            title
            (List.map
               (fun (label, value) ->
                  V.column ~spacing:4. ~alignment:Leading [ V.text label; V.text value ])
               rows))
       groups)
  |> Presentation.dismiss_toolbar
       ~test_id:"journal-diagnostics-close"
       ~on_close
  |> V.Body.with_test_id (Ui.Test_id.string "journal-diagnostics-dialog-page")
;;
