(** Bounded synchronization primitives for the singleton Worker Domain. *)

module Fifo : sig
  type 'a t

  val create : capacity:int -> 'a t
  val try_push : 'a t -> 'a -> [ `Ok | `Full | `Closed ]
  val pop : 'a t -> 'a option
  val length : 'a t -> int

  (** Blocks on a condition until an item is available or the mailbox is both
      closed and empty. *)
  val wait_pop : 'a t -> 'a option

  val drain : 'a t -> max_items:int -> 'a list
  val close : 'a t -> unit
end

module Reserved : sig
  type 'a t

  val create : capacity:int -> 'a t

  (** Reserves capacity before a corresponding request is accepted. *)
  val reserve : 'a t -> bool

  val cancel : 'a t -> unit

  (** Publishes one response against an existing reservation. *)
  val publish : 'a t -> 'a -> unit

  val pop : 'a t -> 'a option
  val drain : 'a t -> max_items:int -> 'a list
end

module Coalesced : sig
  type 'a t

  val create : capacity:int -> 'a t

  (** Stores the latest value for [topic]. A new topic is rejected when all
      topic slots are occupied, while an existing topic is always replaced. *)
  val push : 'a t -> topic:int -> 'a -> [ `Added | `Replaced | `Full ]

  val drain : 'a t -> max_items:int -> (int * 'a) list
end
