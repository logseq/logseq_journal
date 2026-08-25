include module type of Planner_contract

val plan
  :  now_ms:int64
  -> Datascript.db
  -> Protocol.property_mutation
  -> (t, error) result
