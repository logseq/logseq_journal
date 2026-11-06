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

module Make_int64_id () = struct
  type t = int64

  let of_int64 x = x
  let to_int64 x = x
  let compare = Int64.compare
  let equal = Int64.equal
  let succ = Int64.succ
  let pred = Int64.pred
  let zero = 0L
  let one = 1L
  let max_value = Int64.max_int
end

module Make_int_id () = struct
  type t = int

  let of_int x = x
  let to_int x = x
  let compare = Int.compare
  let equal = Int.equal
end

module Make_string_id () = struct
  type t = string

  let of_string x = x
  let to_string x = x
  let compare = String.compare
  let equal = String.equal
end

module Runtime = struct
  type epoch = int64

  module Epoch = Make_int64_id ()
end

module Worker = struct
  type generation = int64

  module Generation = Make_int64_id ()

  type domain_id = Domain.id

  module Domain_id = struct
    type t = domain_id

    let of_domain_id x = x
    let to_domain_id x = x
  end

  type request_id = int64

  module Request_id = Make_int64_id ()

  type push_sequence = int64

  module Push_sequence = Make_int64_id ()

  type push_topic = int

  module Push_topic = Make_int_id ()
end

module Application = struct
  type entrypoint_name = string

  module Entrypoint_name = Make_string_id ()
end
