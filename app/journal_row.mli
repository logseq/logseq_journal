val view
  :  render_media:(root:string -> Journal_view.View.t -> Journal_view.View.t)
  -> show_timestamp:bool
  -> Journal_graph_projection.timeline_entry
  -> Journal_view.View.t
