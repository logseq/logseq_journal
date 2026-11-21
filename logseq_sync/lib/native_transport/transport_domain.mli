type error_attention =
  | Transient_connection
  | Requires_attention

type websocket_termination =
  | Recoverable_close of
      { message : string option
      ; attention : error_attention
      }
  | Local_close
  | Authentication_failure of string
  | Protocol_failure of string
