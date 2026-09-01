open Graph_types

val api_version : int
val maximum_request_bytes : int
val maximum_response_bytes : int
val maximum_push_bytes : int
val default_page_size : int
val maximum_page_size : int
val maximum_tree_nodes : int
val maximum_tree_depth : int
val maximum_title_bytes : int
val maximum_roots : int
val maximum_changed_uuids : int
val maximum_property_values : int
val maximum_filter_values : int

type request =
  { api_version : int
  ; request_id : Uuid.t
  ; command : command
  }

and command =
  | Read of read_command
  | Mutate of Mutation.t

and read_command =
  | Graph_info
  | Get_block of { block : block_uuid }
  | Get_page of { page : page_selector }
  | Get_children of
      { parent : Uuid.t
      ; limit : int
      ; cursor : Cursor.t option
      }
  | Get_page_tree of
      { page : page_uuid
      ; maximum_depth : int
      ; limit : int
      ; cursor : Cursor.t option
      }
  | Get_ancestors of
      { block : block_uuid
      ; limit : int
      }
  | Get_siblings of
      { block : block_uuid
      ; limit : int
      ; cursor : Cursor.t option
      }
  | List_pages of
      { kind : page_kind_filter
      ; limit : int
      ; cursor : Cursor.t option
      }
  | List_tags of
      { limit : int
      ; cursor : Cursor.t option
      }
  | List_properties of
      { scope : property_scope
      ; limit : int
      ; cursor : Cursor.t option
      }
  | List_tasks of
      { filter : task_filter
      ; limit : int
      ; cursor : Cursor.t option
      }
  | Get_references of
      { target : Uuid.t
      ; direction : reference_direction
      ; limit : int
      ; cursor : Cursor.t option
      }

type success =
  | Graph_info_result of graph_info
  | Block_result of block
  | Page_result of page
  | Children_result of block page_result
  | Page_tree_result of block_tree_item page_result
  | Ancestors_result of block list
  | Siblings_result of sibling_result
  | Pages_result of page_summary page_result
  | Tags_result of tag_summary page_result
  | Properties_result of property_definition page_result
  | Tasks_result of task page_result
  | References_result of reference page_result
  | Mutation_result of Mutation.success

type failure_phase =
  | Open
  | Execute

type failure =
  { request_id : Uuid.t
  ; phase : failure_phase
  ; basis : int64 option
  ; error : Error.t
  }

type response =
  | Succeeded of
      { request_id : Uuid.t
      ; basis : int64
      ; success : success
      }
  | Failed of failure

type invalidation =
  { basis : int64
  ; changed_uuids : Uuid.t list
  ; changed_uuids_truncated : bool
  ; invalidate_graph_info : bool
  ; invalidate_pages : bool
  ; invalidate_tags : bool
  ; invalidate_properties : bool
  ; invalidate_tasks : bool
  ; invalidate_references : bool
  }

type push = Graph_invalidated of invalidation

val failed
  :  request_id:Uuid.t
  -> phase:failure_phase
  -> basis:int64 option
  -> Error.t
  -> response

val request_to_yojson : request -> Yojson.Safe.t
val request_of_yojson : Yojson.Safe.t -> (request, Error.t) result
val response_to_yojson : response -> Yojson.Safe.t
val response_of_yojson : Yojson.Safe.t -> (response, string) result
val push_to_yojson : push -> Yojson.Safe.t
val push_of_yojson : Yojson.Safe.t -> (push, string) result
val encoded_response_bytes : response -> int
