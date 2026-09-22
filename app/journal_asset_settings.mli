module Ui = Bonsai_swiftui_ui

type event =
  | Days of Journal_asset_policy.settings
  | Dismissed
  | Retry_upload of Logseq_db_types.Graph_types.Uuid.t

val decode : string -> event option

val view
  :  uploads:Journal_uploads.row list
  -> offline:(Journal_asset_policy.offline * Journal_asset_policy.offline) option
  -> presented:bool
  -> on_event:(string -> unit)
  -> Ui.View.t
  -> Ui.View.t
