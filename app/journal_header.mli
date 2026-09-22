module Context : sig
  type t

  val favorites : t
  val journals : t
  val semantics_label : t -> string
end

val view
  :  key:Bonsai_swiftui_ui.Key.t
  -> platform:string
  -> context:Context.t
  -> sync_phase:Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.sync_phase option
  -> sync_error:string option
  -> on_error_info:Bonsai_swiftui_ui.Event.Handler.t option
  -> on_account_action:Bonsai_swiftui_ui.Event.Handler.t option
  -> local_deletion_available:bool
  -> on_journals:Bonsai_swiftui_ui.Event.Handler.t
  -> on_favorites:Bonsai_swiftui_ui.Event.Handler.t
  -> on_capture:Bonsai_swiftui_ui.Event.Handler.t
  -> capture_enabled:bool
  -> body:Bonsai_swiftui_ui.View.Body.t
  -> Bonsai_swiftui_ui.View.Body.t

val feedback
  :  key:Bonsai_swiftui_ui.Key.t
  -> top:bool
  -> visible:bool
  -> compact:Bonsai_swiftui_ui.View.t
  -> expanded:Bonsai_swiftui_ui.View.t
  -> Bonsai_swiftui_ui.View.Body.t
  -> Bonsai_swiftui_ui.View.Body.t

val date_header : title:string -> Bonsai_swiftui_ui.View.t
