include module type of Planner_contract

val plan
  :  now_ms:int64
  -> Datascript.db
  -> Logseq_db_types.Mutation.page_mutation
  -> (t, error) result
