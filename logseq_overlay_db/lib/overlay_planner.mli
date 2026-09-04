module Graph = Logseq_db_types.Graph_types

val mutation_id : Types.local_mutation -> Graph.Uuid.t
val operation : Types.local_mutation -> Types.outliner_operation
val identity : Types.local_mutation -> string
val fingerprint : Types.local_mutation -> string
val validate : Types.local_mutation -> (unit, string) result
