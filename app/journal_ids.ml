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

module Int64_id_make () : Int64_id = struct
  type t = int64

  let of_int64 value = value
  let to_int64 value = value
  let compare = Int64.compare
  let equal = Int64.equal
  let succ = Int64.succ
  let pred = Int64.pred
  let zero = 0L
  let one = 1L
  let max_value = Int64.max_int
end

module Int_id_make () : Int_id = struct
  type t = int

  let of_int value = value
  let to_int value = value
  let compare = Int.compare
  let equal = Int.equal
end

module String_id_make () : String_id = struct
  type t = string

  let of_string value = value
  let to_string value = value
  let compare = String.compare
  let equal = String.equal
end

module Text_input = struct
  module Session_id = Int64_id_make ()
  module Document_revision = Int64_id_make ()
  module Local_revision = Int64_id_make ()

  type session_id = Session_id.t
  type document_revision = Document_revision.t
  type local_revision = Local_revision.t
end

module Navigation = struct
  module Page_key = String_id_make ()

  type page_key = Page_key.t
end

module Native_widget = struct
  module Kind_id = Int_id_make ()
  module Event_id = Int_id_make ()

  type kind_id = Kind_id.t
  type event_id = Event_id.t
end
