module Graph = Logseq_db_types.Graph_types

val acceptance_barriers_equal
  :  Types.acceptance_barrier
  -> Types.acceptance_barrier
  -> bool

val validate_rejection_partition
  :  expected:Graph.Uuid.t list
  -> Types.rejection_member_partition
  -> (unit, string) result
