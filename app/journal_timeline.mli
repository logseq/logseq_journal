(** {1 TLDR}

    Render Timeline state as a native collection. The caller owns the state,
    action handlers, presentation callbacks and optional mounted row store.
    The mounted store publishes creator names to rows for the supplied account.

    {1 Minimal usage example}

    The caller supplies the current [state], [day_presentation], rendering
    callbacks and event handlers:
    {[
      let timeline =
        view ~render_source ~render_media ~state ~day_presentation
          ~on_visible_range ~on_scroll_completed ~on_retry_day ~on_open_block
          ~delete_enabled ~actions_enabled ~on_status ~on_delete ~on_copy ()
    ]}
    Mount the resulting body on the Timeline host.

    {1 Capability details} *)

module Ui = Journal_view

module Store : sig
  type t

  val create : ?observe:(string -> unit) -> unit -> t
  val synchronize : t -> Journal_timeline_state.t -> int
  val set_active : t -> bool -> unit
  (** Publish names by creator ID within this graph. Cached names are also used
      by rows mounted after publication. *)
  val publish_creators : t -> (string * string option) list -> unit

  (* Return the native collection's structural presentation revision. Only
      actual timeline changes reconcile retained slots; item publications go
      to indexed mounted subscribers, never per-row global model selectors. *)
  val reset : t -> unit
end

val view
  :  ?status_name:(Journal_model.task_state -> string)
  -> ?account_user_id:string
  -> ?current_day:int
  -> ?store:Store.t
  -> ?on_sync:Ui.Event.Handler.t
  -> ?on_region:(string -> unit)
  -> render_source:(string -> string)
  -> ?render_title:(string -> Journal_model.Title.t)
  -> render_media:
       (title:string
        -> root:string
        -> image_children:(string * string) list
        -> Ui.View.t
        -> Ui.View.t)
  -> state:Journal_timeline_state.t
  -> day_presentation:(int -> Journal_calendar.date_presentation option)
  -> on_visible_range:Ui.Event.Handler.t
  -> on_scroll_completed:Ui.Event.Handler.t
  -> on_retry_day:Ui.Event.Handler.t
  -> on_open_block:Ui.Event.Handler.t
  -> delete_enabled:bool
  -> actions_enabled:bool
  -> on_status:Ui.Event.Handler.t
  -> on_delete:Ui.Event.Handler.t
  -> on_copy:Ui.Event.Handler.t
  -> unit
  -> Ui.View.Body.t

val loading_view : unit -> Ui.View.t
