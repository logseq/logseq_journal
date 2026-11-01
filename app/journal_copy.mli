module Pure : sig
  type 'cursor t

  type 'cursor query =
    | Info_query
    | Block_query of Logseq_db_types.Graph_types.Uuid.t
    | Page_query of Logseq_db_types.Graph_types.Uuid.t
    | Children_query of
        { parent : Logseq_db_types.Graph_types.Uuid.t
        ; cursor : 'cursor option
        }

  type 'cursor result =
    | Info_result of
        { graph_uuid : Logseq_db_types.Graph_types.Uuid.t
        ; generation : string
        ; projection_revision : string
        }
    | Block_result of Logseq_db_worker.Protocol.v2_block_lookup
    | Page_result of Logseq_db_worker.Protocol.v2_page_lookup
    | Children_result of
        { parent : Logseq_db_types.Graph_types.Uuid.t
        ; revision_scope : Logseq_db_worker.Protocol.v2_revision_scope
        ; scope_revision : string
        ; items : Logseq_db_worker.Protocol.v2_child_member list
        ; next_cursor : 'cursor option
        }
    | Read_error of string

  type 'cursor event =
    | Start of Logseq_db_types.Graph_types.block_uuid
    | Completed of int64 * 'cursor result
    | Read_failed of int64 * string
    | Cancel

  type 'cursor output_action =
    | Read of int64 * 'cursor query
    | Copied of string
    | Failed of string

  val initial : 'cursor t
  val step : 'cursor t -> 'cursor event -> 'cursor t * 'cursor output_action list
end

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
