type row_interaction =
  | Display_only
  | Toggle_children of Bonsai_flutter_ui.Event.Handler.t

module Item : sig
  type t

  val of_favorite : Journal_graph_projection.favorite -> t
  val of_block : Journal_model.t -> t
  val of_timeline_entry : Journal_graph_projection.timeline_entry -> t
  val corrupt : id:string -> source:string option -> t
  val source_for_detail : t -> string option
  val semantic_label : t -> string

  val visible_extent
    :  t
    -> profile:Journal_visual_tokens.row_profile
    -> expanded:bool
    -> float
end

val preview_text
  :  token:Journal_visual_tokens.text_token
  -> profile:Journal_visual_tokens.row_profile
  -> id:string
  -> fade_id:string
  -> max_lines:int
  -> did_overflow:bool
  -> string
  -> Bonsai_flutter_ui.Widget.t

val view
  :  tokens:Journal_visual_tokens.t
  -> typography:Journal_visual_tokens.typography
  -> profile:Journal_visual_tokens.row_profile
  -> device_pixel_ratio:float
  -> rtl:bool
  -> item:Item.t
  -> show_timestamp:bool
  -> expanded:bool
  -> show_divider:bool
  -> sort_base:float
  -> reduced_motion:bool
  -> interaction:row_interaction
  -> Bonsai_flutter_ui.Widget.t

val rail_body
  :  color:Bonsai_flutter_ui.Style.Color.t
  -> task_state:Journal_model.task_state
  -> height:float
  -> id:string
  -> Bonsai_flutter_ui.Widget.t
