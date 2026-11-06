module Graph = Logseq_db_types.Graph_types

val mutation_id : Types.local_mutation -> Graph.Uuid.t
val operation : Types.local_mutation -> Types.outliner_operation
val identity : Types.local_mutation -> string
val fingerprint : Types.local_mutation -> string
val validate : Types.local_mutation -> (unit, string) result

val append_nodes : Types.append_node -> Types.append_node Rrbvec.t
val append_parent : parent:Graph.Uuid.t -> target:Graph.Uuid.t -> Types.append_node
  -> (Types.append_node * Graph.Uuid.t) option
val append_children : Types.append_node -> Graph.Uuid.t -> Types.append_node Rrbvec.t
