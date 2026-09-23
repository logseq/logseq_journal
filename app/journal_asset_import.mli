val decode
  :  target:Logseq_db_types.Graph_types.Uuid.t
  -> string
  -> (Logseq_db_types.Asset_import.t, string) result

val is_dismissal : string -> bool

val view
  :  key:Journal_view.Key.t
  -> enabled:bool
  -> completion:(string * string option) option
  -> replacement:string option
  -> request:int
  -> on_select:(string -> unit)
  -> Journal_view.View.t
