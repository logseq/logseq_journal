type t =
  { tx_ops : Datascript.tx_op list
  ; tx_meta : Datascript.tx_meta
  ; changed_uuids : Graph_types.Uuid.t list
  ; status : Protocol.mutation_status
  }

type error =
  | Unsupported_semantics of string
  | Invalid_selection of string
  | Conflict of string
  | Built_in_protected

val plan
  :  now_ms:int64
  -> Datascript.db
  -> Protocol.property_mutation
  -> (t, error) result
