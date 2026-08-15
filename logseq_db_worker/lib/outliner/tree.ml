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

module Uuid_set = Set.Make (struct
    type t = Graph_types.Uuid.t

    let compare left right =
      String.compare (Graph_types.Uuid.to_string left) (Graph_types.Uuid.to_string right)
    ;;
  end)

let flatten roots =
  if roots = []
  then Error Empty_roots
  else if List.length roots > Protocol.maximum_roots
  then Error Too_many_roots
  else
    let seen = ref Uuid_set.empty in
    let count = ref 0 in
    let rec visit parent_uuid depth sibling_index tree acc =
      if depth > Protocol.maximum_tree_depth
      then Error Too_deep
      else if Uuid_set.mem tree.Protocol.uuid !seen
      then Error (Duplicate_uuid tree.uuid)
      else (
        incr count;
        if !count > Protocol.maximum_tree_nodes
        then Error Too_many_nodes
        else (
          seen := Uuid_set.add tree.uuid !seen;
          let node =
            { uuid = tree.uuid
            ; title = tree.title
            ; parent_uuid
            ; depth
            ; sibling_index
            }
          in
          visit_children (Some tree.uuid) (depth + 1) 0 tree.children (node :: acc)))
    and visit_children parent_uuid depth sibling_index children acc =
      match children with
      | [] -> Ok acc
      | child :: rest ->
        (match visit parent_uuid depth sibling_index child acc with
         | Error _ as error -> error
         | Ok acc -> visit_children parent_uuid depth (sibling_index + 1) rest acc)
    in
    match visit_children None 1 0 roots [] with
    | Error _ as error -> error
    | Ok reversed -> Ok (List.rev reversed)
;;
