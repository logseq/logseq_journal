(** {1 TLDR}

    Render a Timeline entry using the supplied title and media renderers.
    [creator_name] returns [None] to hide the creator, or an empty name when
    the creator is visible but their profile name is unavailable. *)

val view
  :  ?status_name:(Journal_model.task_state -> string)
  -> ?creator_name:(string -> string option)
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

(** {1 Minimal usage example}

    Given a Timeline [entry] and the caller's [render_media] callback:
    {[
      let row = view ~render_media ~show_timestamp:true entry
    ]}
    Pass the returned view to the Timeline row container. *)

(** {1 Observation and helpers} *)

(** Shared status and tag presentation. *)
val metadata
  :  ?status_name:(Journal_model.task_state -> string)
  -> Journal_model.t
  -> Journal_view.View.t list
