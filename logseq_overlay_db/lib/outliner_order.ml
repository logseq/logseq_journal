module Graph = Logseq_db_types.Graph_types

let key value =
  if value < 0 then invalid_arg "outliner order index must be nonnegative";
  Printf.sprintf "a0%016x1" value
;;

let root ~sequence = key sequence
let child ~index = key index

let compare_member (left_order, left_uuid) (right_order, right_uuid) =
  let order = String.compare left_order right_order in
  if order <> 0 then order else Graph.Uuid.compare left_uuid right_uuid
;;
