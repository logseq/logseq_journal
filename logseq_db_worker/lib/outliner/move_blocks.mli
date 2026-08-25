include module type of Planner_contract

val plan
  :  now_ms:int64
  -> Datascript.db
  -> roots:Graph_types.block_uuid list
  -> position:Protocol.relative_position
  -> context:Protocol.mutation_context
  -> (t, error) result

val plan_up_down
  :  now_ms:int64
  -> Datascript.db
  -> roots:Graph_types.block_uuid list
  -> direction:Protocol.direction
  -> context:Protocol.mutation_context
  -> (t, error) result
