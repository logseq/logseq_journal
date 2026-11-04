module Pure : sig
  module Worker = Journal_worker_coordination.Worker_api

  type t

  type result =
    | Info_result of Worker.graph_info
    | Block_result of Worker_pure_data.block_lookup
    | Page_result of Worker_pure_data.page_lookup
    | Children_result of Worker.children

  type event =
    | Start of Logseq_db_types.Graph_types.block_uuid
    | Completed of int64 * result
    | Read_failed of int64 * string
    | Cancel

  type output_action =
    | Read : int64 * 'a Worker.query * ('a -> result) -> output_action
    | Copied of string
    | Failed of string

  val initial : t
  val step : t -> event -> t * output_action list
end
