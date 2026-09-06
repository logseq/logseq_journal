type task_state =
  | No_status
  | Todo
  | Doing
  | In_review
  | Now
  | Done
  | Canceled
  | Backlog
  | Waiting
  | Later

type status_category =
  | Todo_category
  | Doing_category
  | Done_category
  | Later_category

val status_category : task_state -> status_category option
val status_name : task_state -> string
val status_default_value : task_state -> string option

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
  -> revision:string
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
val revision : t -> string
val last_mutation_id : t -> string
val with_child_count : t -> child_count:int -> (t, string) result
