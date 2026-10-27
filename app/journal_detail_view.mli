type content =
  | Loading of bool
  | Missing
  | Failed of string
  | Empty
  | Ready of Journal_detail.t

type props =
  { content : content
  ; scope : string
  ; enabled : bool
  ; copy_enabled : bool
  ; copy_feedback : string option
  ; import_request : Journal_asset_import.request
  ; import_completion : (string * string option) option
  ; render_title : string -> Journal_model.Title.t
  ; status_name : Journal_model.task_state -> string
  }

type action =
  | Append
  | Open_block of string
  | Delete_block of string
  | Copy_block of string
  | Load_more of string
  | Retry
  | Visible_range of int64 * int64
  | Import_asset of string

val view
  :  props
  -> render_media:
       (known_images:(string * string) list
        -> title:string
        -> root:string
        -> Journal_view.View.t
        -> Journal_view.View.t)
  -> on_scroll_completed:Journal_view.Event.Handler.t
  -> on_action:(action -> unit)
  -> Journal_view.View.Body.t
