include module type of Planner_contract

val plan
  :  now_ms:int64
  -> Datascript.db
  -> block:Graph_types.block_uuid
  -> title:string
  -> context:Protocol.mutation_context
  -> (t, error) result
