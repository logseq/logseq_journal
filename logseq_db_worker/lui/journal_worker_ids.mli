(** Identity types at the worker-session and native-entrypoint boundaries.

    Replaces the subset of [Bonsai_swiftui_spec.Id] used by the journal worker
    runtime and the lui-based app layer. All values are private wrappers over
    plain scalars so they can cross the C ABI and the lui protocol directly. *)

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

(** Runtime lifecycle identity fencing worker messages to one runtime
    lifetime. *)
module Runtime : sig
  type epoch = private int64

  module Epoch : Int64_id with type t = epoch
end

(** Worker Domain and attached worker-session identities. *)
module Worker : sig
  (** Identity of one session attached to the process-wide Worker Domain. *)
  type generation = private int64

  module Generation : Int64_id with type t = generation

  (** Diagnostic identity of the process-wide OCaml Worker Domain. *)
  type domain_id = private Domain.id

  module Domain_id : sig
    type t = domain_id

    val of_domain_id : Domain.id -> t
    val to_domain_id : t -> Domain.id
  end

  (** Correlation identity for one worker-session request. *)
  type request_id = private int64

  module Request_id : Int64_id with type t = request_id

  (** Monotonic ordering identity for one worker push. *)
  type push_sequence = private int64

  module Push_sequence : Int64_id with type t = push_sequence

  (** Latest-wins mailbox topic identity declared by a worker service. *)
  type push_topic = private int

  module Push_topic : Int_id with type t = push_topic
end

(** Native application registry identities. *)
module Application : sig
  (** Stable application identity at the native entrypoint boundary. *)
  type entrypoint_name = private string

  module Entrypoint_name : String_id with type t = entrypoint_name
end
