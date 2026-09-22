val view
  :  scope:string
  -> root:string
  -> media:Journal_media_runtime.view option
  -> editable:bool
  -> on_event:(string -> unit)
  -> Bonsai_swiftui_ui.View.t
  -> Bonsai_swiftui_ui.View.t
