module Ui = Journal_view

module Store : sig
  type t

  val create : ?observe:(string -> unit) -> unit -> t
  val synchronize : t -> Journal_timeline_state.t -> int

  (* Return the native collection's structural presentation revision. Only
      actual timeline changes reconcile retained slots; item publications go
      to indexed mounted subscribers, never per-row global model selectors. *)
  val reset : t -> unit
end

val loading_view : unit -> Ui.View.t

val view
  :  ?store:Store.t
  -> ?on_region:(string -> unit)
  -> render_source:(string -> string)
  -> render_media:
       (root:string -> image_children:(string * string) list -> Ui.View.t -> Ui.View.t)
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
