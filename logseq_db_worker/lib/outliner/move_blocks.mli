type t =
  { tx_ops : Datascript.tx_op list
  ; tx_meta : Datascript.tx_meta
  ; changed_uuids : Graph_types.Uuid.t list
  ; status : Protocol.mutation_status
  }

type error =
  | Unsupported_semantics of string
  | Invalid_selection of string
  | Invalid_tree of string
  | Invalid_order of string
  | Invalid_position of string
  | Built_in_protected

val plan
  :  now_ms:int64
  -> Datascript.db
  -> roots:Graph_types.block_uuid list
  -> position:Protocol.relative_position
  -> context:Protocol.mutation_context
  -> (t, error) result

val plan_up_down
  :  now_ms:int64
  -> Datascript.db
  -> roots:Graph_types.block_uuid list
  -> direction:Protocol.direction
  -> context:Protocol.mutation_context
  -> (t, error) result
