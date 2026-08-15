type classification =
  | Success
  | Local_error
  | Execute_error
  | Open_error
  | Fatal_error

val exit_code : classification -> int
val classify_response : Logseq_db_worker.Protocol.response -> classification
val response_line : Logseq_db_worker.Protocol.response -> string
