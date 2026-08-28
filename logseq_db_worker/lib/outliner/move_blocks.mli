include module type of Planner_contract

val plan
  :  now_ms:int64
  -> Datascript.db
  -> roots:Graph_types.block_uuid list
  -> position:Logseq_db_types.Mutation.relative_position
  -> context:Logseq_db_types.Mutation.context
  -> (t, error) result

val plan_up_down
  :  now_ms:int64
  -> Datascript.db
  -> roots:Graph_types.block_uuid list
  -> direction:Logseq_db_types.Mutation.direction
  -> context:Logseq_db_types.Mutation.context
  -> (t, error) result
