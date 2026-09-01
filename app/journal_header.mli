module Context : sig
  type t

  val today : subtitle:string -> t
  val selected : title:string -> subtitle:string -> t
  val is_today : t -> bool
  val title : t -> string
  val subtitle : t -> string
  val semantics_label : t -> string
end

val sliver
  :  typography:Journal_visual_tokens.typography
  -> text_scale:float
  -> top_inset:float
  -> device_pixel_ratio:float
  -> context:Context.t
  -> sync_phase:Logseq_sync_pure_reducer.Core.sync_phase option
  -> on_error_info:Bonsai_flutter_ui.Event.Handler.t option
  -> on_account_menu:Bonsai_flutter_ui.Event.Handler.t option
  -> Bonsai_flutter_ui.Widget.Sliver.t
