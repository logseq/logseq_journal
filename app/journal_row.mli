(** {1 TLDR}

    Render a Timeline entry using the supplied title and media renderers.
    Creation time and tags appear in the Timeline details rail.
    [creator_name] returns [None] to hide the creator, or a signal whose name
    is empty until the profile becomes available. The row borrows this signal
    for its mount scope.

    {1 Minimal usage example}

    Given a Timeline [entry] and the caller's [render_media] callback:
    {[
      let row = view ~render_media entry
    ]}
    Pass the returned view to the Timeline row container.

    {1 Capability details} *)

val view
  :  ?status_name:(Journal_model.task_state -> string)
  -> ?creator_name:(Lui_ui.ui_context -> string -> string Signal.signal option)
  -> ?render_source:(string -> string)
  -> ?render_title:(string -> Journal_model.Title.t)
  -> render_media:
       (title:string
        -> root:string
        -> image_children:(string * string) list
        -> Journal_view.View.t
        -> Journal_view.View.t)
  -> Journal_graph_projection.timeline_entry
  -> Journal_view.View.t

(** {1 Observation and helpers} *)

(** Status and tag presentation for Block Detail. *)
val metadata
  :  ?status_name:(Journal_model.task_state -> string)
  -> Journal_model.t
  -> Journal_view.View.t list
