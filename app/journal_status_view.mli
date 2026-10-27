type props =
  { catalog : Logseq_db_types.Graph_types.task_status_definition Rrbvec.t
  ; page : int
  ; error : string option
  ; complete : bool
  ; lookup_status : string -> Logseq_db_types.Graph_types.task_status_definition option
  ; current : Journal_model.task_state
  ; id : string
  ; tokens : Journal_visual_tokens.t
  }

type action =
  | Select of string
  | Page of int
  | Retry
  | Close

val view : props -> on_action:(action -> unit) -> Journal_view.View.Body.t

val options
  :  catalog:Logseq_db_types.Graph_types.task_status_definition Rrbvec.t
  -> page:int
  -> (string * Journal_model.task_state) list

val status_name
  :  lookup:(string -> Logseq_db_types.Graph_types.task_status_definition option)
  -> Journal_model.task_state
  -> string
