include module type of Outliner.Planner_contract

val plan : now_ms:int64 -> Datascript.db -> Protocol.mutation -> (t, error) result
