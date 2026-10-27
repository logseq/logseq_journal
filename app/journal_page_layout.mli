val form : Journal_view.View.t list -> Journal_view.View.Body.t

val section
  :  ?key:Journal_view.Key.t
  -> string
  -> Journal_view.View.t list
  -> Journal_view.View.t

val labeled : string -> Journal_view.View.t -> Journal_view.View.t

val unavailable
  :  title:string
  -> symbol:string
  -> message:string
  -> actions:Journal_view.View.t
  -> Journal_view.View.t

val dismiss_toolbar
  :  test_id:string
  -> on_close:Journal_view.Event.Handler.t
  -> Journal_view.View.Body.t
  -> Journal_view.View.Body.t
