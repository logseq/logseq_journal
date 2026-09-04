module Graph = Logseq_db_types.Graph_types

let page_for_parent ~parent = function
  | Some (record : Types.block_record) -> record.block.page
  | None -> parent
;;
