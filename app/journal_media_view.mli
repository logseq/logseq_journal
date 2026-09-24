val view
  :  scope:string
  -> root:string
  -> media:Journal_media_runtime.view option
  -> editable:bool
  -> on_event:(string -> unit)
  -> Journal_view.View.t
  -> Journal_view.View.t
