val view
  :  ?observed_roots:string list
  -> ?asset_root:(string -> string)
  -> scope:string
  -> root:string
  -> media:Journal_media_runtime.view option
  -> editable:bool
  -> on_event:(string -> unit)
  -> Journal_view.View.t
  -> Journal_view.View.t

val is_image_type : string -> bool

val row
  :  scope:string
  -> root:string
  -> image_children:(string * string) list
  -> media_for_root:(string -> Journal_media_runtime.view option)
  -> on_event:(string -> unit)
  -> Journal_view.View.t
  -> Journal_view.View.t
