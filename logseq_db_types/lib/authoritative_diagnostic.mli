(** A bounded diagnostic containing no transaction values or exception text.
    String descriptors are reduced to finite allowlists by [create].
    [Application] records use [Application_exception] and omit [operation_index];
    other stages do not use that reason. Integrity uses [integrity] and its
    separate versioned carrier. Invalid decoded combinations fail closed. *)
type t

type stage =
  | Prepare
  | Decode
  | Application
  | Integrity

type reason =
  | Transit_syntax
  | Empty_transaction
  | Transaction_shape
  | Operation_shape
  | Operation_keyword
  | Unsupported_operation
  | Operation_fields
  | Entity_shape
  | Reference_shape
  | Integer_range
  | Source_tx_type
  | Protected_value_type
  | Decrypted_value_count
  | Decimal_value
  | Integer_value
  | Application_exception
  | Unknown

val create
  :  stage:stage
  -> reason:reason
  -> ?transaction:int
  -> ?operation_index:int
  -> ?operation_count:int
  -> ?lookup_refs:int
  -> ?arity:int
  -> ?operation:string
  -> ?attribute:string
  -> ?field:string
  -> ?actual:string
  -> ?exception_kind:string
  -> unit
  -> t

val with_context
  :  ?stage:stage
  -> ?transaction:int
  -> ?operation_index:int
  -> ?operation_count:int
  -> ?lookup_refs:int
  -> ?arity:int
  -> ?operation:string
  -> ?attribute:string
  -> ?field:string
  -> t
  -> t

val encode : t -> string
val decode : string -> t option
val message : t -> string
val detail_name : string
val signal_prefix : string

(** Integrity reason and context are reduced to finite descriptors and bounded
    counters. Cursors are canonical nonnegative decimal int64 strings. *)
val integrity : reason:string -> ?context:(string * string) list -> unit -> t

val integrity_of_source : string -> t
val with_integrity_context : (string * string) list -> t -> t
val integrity_signal_prefix : string
