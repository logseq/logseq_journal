type task_state =
  | Not_a_task
  | Todo
  | Done

type t

val create
  :  id:string
  -> page_id:string
  -> journal_day:int
  -> parent_id:string option
  -> sibling_order:string
  -> source:string
  -> task_state:task_state
  -> child_count:int
  -> creation_time:Journal_time.t
  -> revision:int
  -> last_mutation_id:string
  -> (t, string) result

val id : t -> string
val page_id : t -> string
val parent_id : t -> string option
val sibling_order : t -> string
val source : t -> string
val task_state : t -> task_state
val child_count : t -> int
val creation_time : t -> Journal_time.t
val journal_day : t -> int
val revision : t -> int
val last_mutation_id : t -> string
val with_child_count : t -> child_count:int -> (t, string) result
