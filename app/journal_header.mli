module Date_row : sig
  val view
    :  tokens:Journal_visual_tokens.t
    -> typography:Journal_visual_tokens.typography
    -> effective_scale:float
    -> ambient_scale:float
    -> date_id:string
    -> weekday_id:string
    -> Journal_calendar.date_presentation option
    -> Bonsai_flutter_ui.Widget.t
end

module Context : sig
  type t

  val favorites : t
  val today : date:Journal_calendar.date_presentation option -> t
  val date : t -> Journal_calendar.date_presentation option
  val semantics_label : t -> string
end

val sliver
  :  tokens:Journal_visual_tokens.t
  -> typography:Journal_visual_tokens.typography
  -> text_scale:float
  -> viewport_width:float
  -> top_inset:float
  -> device_pixel_ratio:float
  -> context:Context.t
  -> sync_phase:Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.sync_phase option
  -> on_error_info:Bonsai_flutter_ui.Event.Handler.t option
  -> on_account_menu:Bonsai_flutter_ui.Event.Handler.t option
  -> Bonsai_flutter_ui.Widget.Sliver.t
