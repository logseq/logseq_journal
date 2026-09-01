(** Stable, storage-independent graph values exposed by [logseq_db_worker]. *)

module Uuid : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
  val equal : t -> t -> bool
  val compare : t -> t -> int
end

module Cursor : sig
  type t

  val of_string : string -> (t, string) result
  val to_string : t -> string
end

type block_uuid = Uuid.t
type page_uuid = Uuid.t
type class_uuid = Uuid.t
type property_uuid = Uuid.t
type qualified_ident = string

type schema_version =
  { major : int
  ; minor : int
  }

type admission_fact =
  | Compatible_schema of
      { minimum : schema_version
      ; actual : schema_version
      }
  | Local_graph of Uuid.t
  | Remote_flag_absent
  | Remote_flag_false
  | Remote_flag_true
  | No_rtc_identity
  | Synced_graph_identity of Uuid.t
  | Lossless_codec
  | Ownership_verified

type graph_info =
  { local_graph_uuid : Uuid.t
  ; graph_name : string
  ; graph_dir : string
  ; schema : schema_version
  ; basis : int64
  ; admission_facts : admission_fact list
  }

type page_kind =
  | Ordinary_page
  | Journal_page of { journal_day : int }
  | Class_page
  | Property_page
  | Hidden_page
  | Built_in_page

type page_kind_filter =
  | Any_page
  | Only_ordinary_pages
  | Only_journals
  | Only_classes
  | Only_properties

type page_selector =
  | Page_by_uuid of page_uuid
  | Page_by_name of
      { name : string
      ; kind : page_kind_filter
      }

type property_selector =
  | Property_by_ident of qualified_ident
  | Property_by_uuid of property_uuid

type property_type =
  | Default
  | Number
  | Date
  | Datetime
  | Checkbox
  | Url
  | Node
  | Asset
  | Keyword
  | Map
  | Collection
  | Any
  | Entity
  | Class
  | Page
  | Property
  | String
  | Json
  | Raw_number

type property_cardinality =
  | One
  | Many

type internal_value =
  | Internal_null
  | Internal_bool of bool
  | Internal_number of string
  | Internal_string of string
  | Internal_keyword of string
  | Internal_uuid of Uuid.t
  | Internal_list of internal_value list
  | Internal_map of (internal_value * internal_value) list

type property_value =
  | Default_value of string
  | Number_value of string
  | Date_value of { journal_day : int }
  | Datetime_value of { unix_ms : int64 }
  | Checkbox_value of bool
  | Url_value of string
  | Node_value of block_uuid
  | Asset_value of block_uuid
  | Keyword_value of string
  | Map_value of (internal_value * internal_value) list
  | Collection_value of internal_value list
  | Any_value of internal_value
  | Entity_value of Uuid.t
  | Class_value of class_uuid
  | Page_value of page_uuid
  | Property_value of qualified_ident
  | String_value of string
  | Json_value of string
  | Raw_number_value of string

type property_schema =
  { property_type : property_type
  ; cardinality : property_cardinality
  ; hidden : bool
  ; public : bool
  }

type property_summary =
  { ident : qualified_ident
  ; uuid : property_uuid
  ; title : string
  ; schema : property_schema
  ; values : property_value list
  ; values_truncated : bool
  }

type block =
  { uuid : block_uuid
  ; title : string
  ; parent : Uuid.t
  ; page : page_uuid
  ; order : string
  ; created_at_ms : int64
  ; updated_at_ms : int64
  ; refs : Uuid.t list
  ; tags : class_uuid list
  ; properties : property_summary list
  }

type page =
  { uuid : page_uuid
  ; name : string
  ; title : string
  ; kind : page_kind
  ; created_at_ms : int64
  ; updated_at_ms : int64
  ; tags : class_uuid list
  ; properties : property_summary list
  ; recycled : bool
  }

type page_summary =
  { uuid : page_uuid
  ; name : string
  ; title : string
  ; kind : page_kind
  ; recycled : bool
  }

type tag_summary =
  { uuid : class_uuid
  ; title : string
  ; ident : qualified_ident option
  }

type property_definition =
  { uuid : property_uuid
  ; ident : qualified_ident
  ; title : string
  ; schema : property_schema
  ; closed_values : block_uuid list
  }

type task_state =
  | Todo
  | Doing
  | Done
  | Cancelled
  | Waiting
  | Now
  | Later

type task =
  { block : block
  ; state : task_state
  ; scheduled_day : int option
  ; deadline_day : int option
  }

type reference_kind =
  | Block_reference
  | Page_reference
  | Tag_reference
  | Property_reference
  | Scheduled_reference
  | Deadline_reference
  | Alias_reference

type reference =
  { source : Uuid.t
  ; target : Uuid.t
  ; kind : reference_kind
  }

type 'a page_result =
  { items : 'a list
  ; continuation : Cursor.t option
  }

type block_tree_item =
  { block : block
  ; depth : int
  }

type sibling_result =
  { siblings : block page_result
  ; current_index : int
  }

type property_scope =
  | All_properties
  | User_properties
  | Properties_for_block of block_uuid
  | Properties_for_class of class_uuid

type task_filter =
  { states : task_state list
  ; page : page_uuid option
  ; scheduled_from : int option
  ; scheduled_through : int option
  ; deadline_from : int option
  ; deadline_through : int option
  }

type reference_direction =
  | Referring_to
  | Referred_from

val uuid_list_to_strings : Uuid.t list -> string list
