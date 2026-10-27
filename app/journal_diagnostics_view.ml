module Ui = Journal_view
module V = Ui.View
module Graph_service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Admission_refresh = Journal_admission_refresh
module Presentation = Journal_page_layout

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

let view { snapshot; graph; admission; diagnostics; application_errors } ~on_close =
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
    (List.map
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
