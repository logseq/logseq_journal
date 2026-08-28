include module type of Planner_contract

val plan
  :  now_ms:int64
  -> Datascript.db
  -> block:Graph_types.block_uuid
  -> title:string
  -> context:Logseq_db_types.Mutation.context
  -> (t, error) result
