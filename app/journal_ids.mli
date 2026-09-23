(** Application-layer identity types, replacing [Journal_ids] for
    the journal UI. *)

module type Int64_id = sig
  type t = private int64

  val of_int64 : int64 -> t
  val to_int64 : t -> int64
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val succ : t -> t
  val pred : t -> t
  val zero : t
  val one : t
  val max_value : t
end

module type Int_id = sig
  type t = private int

  val of_int : int -> t
  val to_int : t -> int
  val compare : t -> t -> int
  val equal : t -> t -> bool
end

module type String_id = sig
  type t = private string

  val of_string : string -> t
  val to_string : t -> string
  val compare : t -> t -> int
  val equal : t -> t -> bool
end

(** Text-input session and document revision identities. *)
module Text_input : sig
  type session_id = private int64

  module Session_id : Int64_id with type t = session_id

  type document_revision = private int64

  module Document_revision : Int64_id with type t = document_revision

  type local_revision = private int64

  module Local_revision : Int64_id with type t = local_revision
end

(** Declarative navigation identities. *)
module Navigation : sig
  type page_key = private string

  module Page_key : String_id with type t = page_key
end

(** Registered native-widget extension identities. *)
module Native_widget : sig
  type kind_id = private int

  module Kind_id : Int_id with type t = kind_id

  type event_id = private int

  module Event_id : Int_id with type t = event_id
end
