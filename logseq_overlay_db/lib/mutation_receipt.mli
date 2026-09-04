module Graph = Logseq_db_types.Graph_types

val mutation_key : Graph.Uuid.t -> string
val terminal_batch_key : Types.Submission_batch_id.t -> string
