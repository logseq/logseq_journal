include module type of Planner_contract

val plan
  :  now_ms:int64
  -> Datascript.db
  -> roots:Protocol.block_tree list
  -> position:Protocol.insert_position
  -> context:Protocol.mutation_context
  -> (t, error) result
