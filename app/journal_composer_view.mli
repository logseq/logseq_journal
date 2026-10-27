type kind = Capture | Append

type assets = { camera : bool }

type props =
  { kind : kind
  ; capture : Journal_capture.t
  ; saving : bool
  ; enabled : bool
  ; error : string option
  ; assets : assets option
  }

type action =
  | Edit of Journal_view.Event.Payload.text_edit
  | Toggle_task of bool
  | Save
  | Close
  | Discard
  | Attach of Journal_asset_import.source
  | Remove_attachment of string

val content : props -> on_action:(action -> unit) -> Journal_view.View.t
val page : props -> on_action:(action -> unit) -> Journal_view.View.Body.t
