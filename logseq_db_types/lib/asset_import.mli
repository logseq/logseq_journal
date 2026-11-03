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

(** Bounded read-only recovery DTOs. These bytes carry no session, lease or
    execution authority. Prepared is the original immutable checkpoint proof. *)
module Recovery : sig
  type item={sequence:int64;input:string;prepared:string option;acknowledged:bool}
  type page={items:item list;next:int64 option}
  val maximum_items:int
  val maximum_bytes:int
  val item_encoded_bytes:item -> int
  val page_encoded_bytes:page -> int
  val maximum_page_overhead:int
  type owner={namespace:string;origin:string;account:string;graph:Graph_types.Uuid.t}
  type checked=private {sequence:int64;input:Pure_intent.t;prepared:Asset_upload_intent.t option;
    evidence:string option;acknowledged:bool}
  (** Pure validation of complete input and exact original Prepared owner/IDs.
      The caller supplies namespace from its authoritative logical owner mapper. *)
  val decode:owner:owner -> item -> (checked,string)result

end
