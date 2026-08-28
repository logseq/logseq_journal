include module type of Planner_contract

val plan
  :  now_ms:int64
  -> Datascript.db
  -> roots:Logseq_db_types.Mutation.block_tree list
  -> position:Logseq_db_types.Mutation.insert_position
  -> context:Logseq_db_types.Mutation.context
  -> (t, error) result
