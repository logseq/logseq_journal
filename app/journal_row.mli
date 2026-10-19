val view
  :  ?status_name:(Journal_model.task_state -> string)
  -> ?render_source:(string -> string)
  -> ?render_title:(string -> Journal_model.Title.t)
  -> render_media:
       (title:string
        -> root:string
        -> image_children:(string * string) list
        -> Journal_view.View.t
        -> Journal_view.View.t)
  -> show_timestamp:bool
  -> Journal_graph_projection.timeline_entry
  -> Journal_view.View.t

(** Shared status and tag presentation. *)
val metadata
  :  ?status_name:(Journal_model.task_state -> string)
  -> Journal_model.t
  -> Journal_view.View.t list
