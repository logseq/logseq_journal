type t =
  { operation : Graph_types.Uuid.t
  ; asset : Graph_types.Uuid.t
  ; replace_reference : Graph_types.Uuid.t option
  ; target : Graph_types.Uuid.t
  ; local_mutation : Graph_types.Uuid.t
  ; metadata_mutation : Graph_types.Uuid.t
  ; source_file : string
  ; title : string
  ; file_type : string
  }


(** Complete logical import input. Pure validation and canonical bytes carry no
    execution authority, perform no file access, and never replace source or IDs. *)
module Pure_intent : sig
  type source=t
  type t
  type error=Invalid of string|Wrong_namespace
  val maximum_bytes:int
  val create:namespace:string -> source -> (t,error)result
  val restore:namespace:string -> string -> (t,error)result
  val encode:t -> string
  val namespace:t -> string
  val source:t -> source
  val operation:t -> Graph_types.Uuid.t
end
