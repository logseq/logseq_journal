(** {1 TLDR}

    Present timeline metadata and matching children in a native vertical list.
    The caller may provide [empty_state] when the entire timeline is empty. *)

module Ui = Journal_view

type row =
  { id : string
  ; section : string
  ; header : bool
  ; slot_index : int option
  ; block_id : string option
  }

val view
  :  key:Ui.Key.t
  -> test_id:Ui.Test_id.t
  -> rows:row list
  -> scroll_target:(int64 * string * string) option
  -> ?scroll_target_signal:(int64 * string * string) option Signal.signal
  -> ?on_sync:Ui.Event.Handler.t
  -> ?empty_state:Ui.View.t
  -> on_scroll_completed:Ui.Event.Handler.t
  -> actions_enabled:bool
  -> on_visible_range:Ui.Event.Handler.t
  -> on_open:Ui.Event.Handler.t
  -> on_status:Ui.Event.Handler.t
  -> on_delete:Ui.Event.Handler.t
  -> on_copy:Ui.Event.Handler.t
  -> children:Ui.View.t list
  -> unit
  -> Ui.View.Viewport.Vertical.t

(** {1 Minimal usage example}

    Provide the paired rows and views, the current scroll target and the
    application's handlers:

    {[
      view ~key ~test_id ~rows ~children ~scroll_target ~empty_state ~on_scroll_completed
        ~actions_enabled ~on_visible_range ~on_open ~on_status ~on_delete
        ~on_copy ()
    ]} *)
