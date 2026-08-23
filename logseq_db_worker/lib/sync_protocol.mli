type pull_tx =
  { t : int
  ; tx : string
  ; outliner_op : string option
  }

type reject_reason =
  | Stale
  | Db_transact_failed
  | Empty_tx_data
  | Invalid_tx
  | Invalid_t_before
  | Snapshot_upload_in_progress

type server_message =
  | Hello of
      { t : int
      ; checksum : string option
      }
  | Pull_ok of
      { t : int
      ; checksum : string option
      ; txs : pull_tx list
      }
  | Changed of { t : int }
  | Tx_batch_ok of
      { t : int
      ; checksum : string option
      }
  | Tx_reject of
      { reason : reject_reason
      ; t : int option
      ; success_tx_ids : string list
      ; failed_tx_id : string option
      ; data : string option
      }
  | Server_error of { message : string }
  | Pong
  | Online_users

type outgoing_tx =
  { tx : string
  ; tx_id : string
  ; outliner_op : string option
  }

val decode_server_message : string -> (server_message, string) result
val decode_http_pull_response : string -> (server_message, string) result
val validate_pull_continuity : applied_t:int -> server_message -> (unit, string) result
val validate_checksum : local:string -> remote:string -> (unit, string) result
val encode_hello : client:string -> string
val encode_pull : since:int -> string
val decode_tx_batch_ids : string -> (Graph_types.Uuid.t list, string) result
val encode_tx_batch : t_before:int -> outgoing_tx list -> (string, string) result
