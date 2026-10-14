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

val create_on_page
  :  id:string
  -> page_id:string
  -> journal_day:int option
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
val is_image_file_type : string -> bool
val asset_file_type : t -> string option
val with_asset_file_type : t -> asset_file_type:string option -> t
val has_tags : t -> bool
val has_attachments : t -> bool
val with_content_metadata : t -> tags_present:bool -> attachments_present:bool -> t
val task_state : t -> task_state
val child_count : t -> int
val creation_time : t -> Journal_time.t
val journal_day_opt : t -> int option
val journal_day : t -> int
val revision : t -> string
val last_mutation_id : t -> string
val with_child_count : t -> child_count:int -> (t, string) result
val tag_titles : t -> string list
val with_tag_titles : t -> tag_titles:string list -> t
val maximum_reference_depth : int
val reference_ids : string -> string list
val render_references : lookup:(string -> string option) -> string -> string

(** Typed graph properties retained by the projection, including hidden ownership metadata. *)
val properties : t -> Logseq_db_types.Graph_types.property_summary list

(** Property presentation projected with the active local-time context; semantic values remain in [properties]. *)
val display_properties : t -> Logseq_db_types.Graph_types.property_summary list
val with_properties : ?localtime:(float -> Unix.tm) -> t -> properties:Logseq_db_types.Graph_types.property_summary list -> t

(** Visible named property values. UUID values use the existing bounded reference syntax. *)
val property_sources : ?localtime:(float -> Unix.tm) -> Logseq_db_types.Graph_types.property_summary list -> (string * string) list
