type node =
  { uuid : Graph_types.block_uuid
  ; title : string
  ; parent_uuid : Graph_types.block_uuid option
  ; depth : int
  ; sibling_index : int
  }

type error =
  | Empty_roots
  | Too_many_roots
  | Too_many_nodes
  | Too_deep
  | Duplicate_uuid of Graph_types.block_uuid

val flatten : Protocol.block_tree list -> (node list, error) result
