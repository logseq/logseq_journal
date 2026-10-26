type t

type event =
  | Start of Logseq_db_types.Graph_types.block_uuid
  | Completed of int64 * Logseq_db_worker.Protocol.v2_outcome
  | Read_failed of int64 * string
  | Cancel

type output_action =
  | Read of int64 * Logseq_db_worker.Protocol.command
  | Copied of string
  | Failed of string

val initial : t
val step : t -> event -> t * output_action list
