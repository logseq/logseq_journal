type session_error =
  | Local_decode_error of string
  | Fatal_lifecycle_error of string

val execute_once
  :  dependencies:Logseq_db_worker.Engine.dependencies
  -> Logseq_db_worker.Config.t
  -> Logseq_db_worker.Protocol.request
  -> (Logseq_db_worker.Protocol.response, session_error) result

val run_ndjson_lines
  :  dependencies:Logseq_db_worker.Engine.dependencies
  -> Logseq_db_worker.Config.t
  -> string list
  -> (string list, session_error) result

val create_snapshot
  :  application_support_directory:string
  -> source_graph_dir:string
  -> (Logseq_db_worker.Graph_types.Uuid.t, string) result

val import_snapshot
  :  application_support_directory:string
  -> inbox_entry:string
  -> (Logseq_db_worker.Graph_types.Uuid.t, string) result

val resolve_desktop_target
  :  home_directory:string
  -> graph_name:string
  -> (Logseq_db_worker.Config.target, string) result

val command : Cmdliner.Cmd.Exit.code Cmdliner.Cmd.t

module For_testing : sig
  val execute_once
    :  dependencies:Logseq_db_worker.Engine.dependencies
    -> after_execute:(unit -> unit)
    -> Logseq_db_worker.Config.t
    -> Logseq_db_worker.Protocol.request
    -> (Logseq_db_worker.Protocol.response, session_error) result
end
