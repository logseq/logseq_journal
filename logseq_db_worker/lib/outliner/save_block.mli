type t =
  { tx_ops : Datascript.tx_op list
  ; tx_meta : Datascript.tx_meta
  ; changed_uuids : Graph_types.Uuid.t list
  }

type error =
  | Unsupported_semantics of string
  | Invalid_selection of string
  | Built_in_protected

val plan
  :  now_ms:int64
  -> Datascript.db
  -> block:Graph_types.block_uuid
  -> title:string
  -> context:Protocol.mutation_context
  -> (t, error) result
