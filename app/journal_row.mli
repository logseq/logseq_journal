val view
  :  ?render_source:(string -> string)
  -> render_media:
       (root:string
        -> image_children:(string * string) list
        -> Journal_view.View.t
        -> Journal_view.View.t)
  -> show_timestamp:bool
  -> Journal_graph_projection.timeline_entry
  -> Journal_view.View.t
