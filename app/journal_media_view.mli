module Store : sig
  type t

  val create : ?observe:(string -> unit) -> unit -> t

  (* Callers own the returned idempotent unsubscribe function. Notifications are
     indexed by the dependency, not by the global Application model. *)
  val subscribe_structure : t -> string -> (unit -> unit) -> unit -> unit
  val subscribe_item : t -> string -> string -> (unit -> unit) -> unit -> unit
  val find : t -> string -> Journal_media_runtime.view option
  val update : t -> root:string -> Journal_media_runtime.view option -> unit

  (* Reset presentation and fence subscribers from the previous graph/session. *)
  val reset : t -> unit
end

type action =
  | Root
  | Asset
  | Preview
  | Retry
  | Next

type event =
  { action : action
  ; root : string
  ; asset : string
  ; visible : bool
  ; slot : string
  }

val view
  :  store:Store.t
  -> ?title:string
  -> ?on_region:(string -> unit)
  -> ?observed_roots:string list
  -> ?asset_root:(string -> string)
  -> ?known_images:(string * string) list
  -> scope:string
  -> root:string
  -> on_event:(event -> unit)
  -> Journal_view.View.t
  -> Journal_view.View.t

val is_image_type : string -> bool

(** [image_children] carries known graph image identities and types, including
    the root itself when it is an image asset. No runtime descriptor is required. *)
val row
  :  store:Store.t
  -> ?title:string
  -> ?on_region:(string -> unit)
  -> scope:string
  -> root:string
  -> image_children:(string * string) list
  -> on_event:(event -> unit)
  -> Journal_view.View.t
  -> Journal_view.View.t
