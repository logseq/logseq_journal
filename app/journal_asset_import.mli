val decode
  :  target:Logseq_db_types.Graph_types.Uuid.t
  -> string
  -> (Logseq_db_types.Asset_import.t, string) result

val view
  :  key:Bonsai_swiftui_ui.Key.t
  -> enabled:bool
  -> completion:(string * string option) option
  -> on_select:(string -> unit)
  -> Bonsai_swiftui_ui.View.t
