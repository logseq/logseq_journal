type context =
  { db : Datascript.db
  ; basis : int64
  ; now_ms : int64
  ; cursor_key : bytes
  }

val execute : context -> Protocol.read_command -> (Protocol.success, Error.t) result
