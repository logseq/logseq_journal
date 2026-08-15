module Item : sig
  type t

  val of_block : Journal_model.t -> t
  val of_timeline_entry : Journal_graph_projection.timeline_entry -> t
  val corrupt : id:string -> source:string option -> t
  val source_for_detail : t -> string option
  val semantic_label : t -> string
end

val view
  :  tokens:Journal_visual_tokens.t
  -> profile:Journal_visual_tokens.row_profile
  -> device_pixel_ratio:float
  -> rtl:bool
  -> item:Item.t
  -> show_timestamp:bool
  -> expanded:bool
  -> show_divider:bool
  -> sort_base:float
  -> reduced_motion:bool
  -> on_task_toggle:Bonsai_flutter_ui.Event.Handler.t
  -> on_toggle_children:Bonsai_flutter_ui.Event.Handler.t
  -> Bonsai_flutter_ui.Widget.t
