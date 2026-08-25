include module type of Planner_contract

val plan
  :  now_ms:int64
  -> Datascript.db
  -> roots:Graph_types.block_uuid list
  -> context:Protocol.mutation_context
  -> (t, error) result
