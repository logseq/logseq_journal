type picker_live =
  { status : string
  ; authenticated : bool
  ; checking : bool
  ; deleting : Logseq_db_worker_lui.Logseq_db_worker_lui_service.local_copy_request option
  ; presence :
      string
      -> (Logseq_db_worker_lui.Logseq_db_worker_lui_service.local_copy_presence, string) result option
  }

type picker =
  { graphs : Logseq_db_worker_lui.Logseq_db_worker_lui_service.graph Rrbvec.t
  ; selected_graph : Logseq_db_types.Graph_types.Uuid.t option
  ; live : picker_live
  }

type unlock =
  { graph_name : string
  ; password : Journal_capture.t
  ; pending : bool
  ; challenge_ready : bool
  ; error : string option
  }

type busy =
  { loading : bool
  ; initial : bool
  ; active : bool
  ; value : float option
  ; message : string
  ; choose_graph : bool
  }

type recovery = Refresh | Retry_local of string | Recover_online of string

type props =
  | Account_failure
  | Signed_out
  | Busy of busy
  | Picker of picker
  | Unlock of unlock
  | Failed of { message : string; recovery : recovery option; choose_graph : bool }
  | Graph_unavailable of Journal_view.View.t

type action =
  | Startup_retry
  | Refresh_catalog
  | Begin_online_recovery
  | Select_graph of string
  | Switch_graph
  | Close_picker
  | Visible_range of int64 * int64
  | Request_local_copy_reset of string
  | Sign_out
  | Submit_password
  | Edit_password of Journal_view.Event.Payload.text_edit
  | Diagnostics

val view
  :  ?picker_signal:picker_live Signal.signal
  -> props
  -> on_action:(action -> unit)
  -> Journal_view.View.Body.t
