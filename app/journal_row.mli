val view
  :  render_media:(root:string -> Bonsai_swiftui_ui.View.t -> Bonsai_swiftui_ui.View.t)
  -> show_timestamp:bool
  -> Journal_graph_projection.timeline_entry
  -> Bonsai_swiftui_ui.View.t
