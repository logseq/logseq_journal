type t =
  { account_generation : int
  ; graph_generation : int
  ; connection_generation : int
  ; applied_server_t : int
  }

type incoming =
  | Ignore_late
  | Ignore_presence
  | Deliver of string
  | Pull_hint of int

let create ~account_generation ~graph_generation ~connection_generation ~applied_server_t =
  { account_generation; graph_generation; connection_generation; applied_server_t }
;;

let current t ~account_generation ~graph_generation ~connection_generation =
  t.account_generation = account_generation
  && t.graph_generation = graph_generation
  && t.connection_generation = connection_generation
;;

let opened t ~account_generation ~graph_generation ~connection_generation =
  if current t ~account_generation ~graph_generation ~connection_generation
  then
    [ Protocol.encode_hello ~client:"logseq-journal"
    ; Protocol.encode_pull ~since:t.applied_server_t
    ]
  else []
;;

let receive t ~account_generation ~graph_generation ~connection_generation payload =
  if not (current t ~account_generation ~graph_generation ~connection_generation)
  then Ok Ignore_late
  else (
    match Protocol.decode_server_message payload with
    | Error _ as error -> error
    | Ok (Changed { t }) -> Ok (Pull_hint t)
    | Ok Online_users -> Ok Ignore_presence
    | Ok (Hello _ | Pull_ok _ | Tx_batch_ok _ | Tx_reject _ | Server_error _ | Pong) ->
      Ok (Deliver payload))
;;

let reconnect t = { t with connection_generation = t.connection_generation + 1 }
let connection_generation t = t.connection_generation
let applied_server_t t = t.applied_server_t
let set_applied_server_t t applied_server_t = { t with applied_server_t }
