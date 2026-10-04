module Context : sig
  type t

  val favorites : t
  val journals : t
  val semantics_label : t -> string
end

type account_action =
  | Open_asset_settings
  | Open_diagnostics
  | Switch_graph
  | Request_local_cache_reset
  | Sign_out

type presentation =
  { sync_phase : Logseq_db_worker_lui.Logseq_db_worker_lui_service.sync_phase option
  ; sync_error : string option
  ; error_available : bool
  ; local_deletion_available : bool
  ; capture_enabled : bool
  }

val view
  :  key:Journal_view.Key.t
  -> platform:string
  -> context:Context.t
  -> sync_phase:Logseq_db_worker_lui.Logseq_db_worker_lui_service.sync_phase option
  -> sync_error:string option
  -> on_error_info:Journal_view.Event.Handler.t option
  -> on_account_action:(account_action -> unit) option
  -> local_deletion_available:bool
  -> on_journals:Journal_view.Event.Handler.t
  -> on_favorites:Journal_view.Event.Handler.t
  -> on_capture:Journal_view.Event.Handler.t
  -> capture_enabled:bool
  -> capture_expanded:Journal_view.View.t option
  -> body:Journal_view.View.Body.t
  -> Journal_view.View.Body.t

val reactive_view
  :  presentation_signal:presentation Signal.signal
  -> key:Journal_view.Key.t
  -> platform:string
  -> context:Context.t
  -> sync_phase:Logseq_db_worker_lui.Logseq_db_worker_lui_service.sync_phase option
  -> sync_error:string option
  -> on_error_info:Journal_view.Event.Handler.t option
  -> on_account_action:(account_action -> unit) option
  -> local_deletion_available:bool
  -> on_journals:Journal_view.Event.Handler.t
  -> on_favorites:Journal_view.Event.Handler.t
  -> on_capture:Journal_view.Event.Handler.t
  -> capture_enabled:bool
  -> capture_expanded:Journal_view.View.t option
  -> body:Journal_view.View.Body.t
  -> Journal_view.View.Body.t

val feedback
  :  key:Journal_view.Key.t
  -> top:bool
  -> visible:bool
  -> compact:Journal_view.View.t
  -> expanded:Journal_view.View.t
  -> Journal_view.View.Body.t
  -> Journal_view.View.Body.t

val date_header : title:string -> Journal_view.View.t

val detail
  :  actions:Journal_view.View.buttons_action list
  -> Journal_view.View.Body.t
  -> Journal_view.View.Body.t
