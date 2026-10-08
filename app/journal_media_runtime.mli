module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Asset = Logseq_db_types.Asset_descriptor

type ticket

type item =
  { token : string
  ; asset : Asset.t
  ; file_type : string
  ; presentation : Journal_media.presentation
  }

type view =
  { items : item list
  ; more : bool
  ; error : string option
  }

type t

val create
  :  send:(ticket option -> Service.request -> bool)
  -> changed:(string -> view -> unit)
  -> t

val reset : t -> graph_generation:int option -> unit

(** Visibility belongs to a retained presentation. Shared roots and assets are
    released after their last owner leaves; omitting [owner] uses one legacy owner. *)
val root_visible : ?owner:string -> t -> root:string -> bool -> unit

val retain_visible_roots : ?owner:string -> t -> string list -> unit
val retain_owners : t -> string list -> unit
val asset_visible : ?owner:string -> t -> root:string -> asset:string -> bool -> unit

(** A preview is an independent consumer of the current file. Its slot is
    replaced/dismissed separately from row visibility and retired with [owner]. *)
val preview_visible
  :  t
  -> owner:string
  -> slot:string
  -> root:string
  -> asset:string
  -> bool
  -> unit

val next : t -> root:string -> unit
val retry : ?owner:string -> t -> root:string -> asset:string -> unit

(** Mark retained metadata dirty after a projection change or resync. Only
    active root/asset/preview owners read immediately; hidden groups restart
    lazily. Each root keeps one request and at most one dirty follow-up, always
    from the first page because cursors belong to the global projection. *)
val refresh : t -> unit

val receive : t -> ticket -> Service.response -> unit
val reject : t -> ticket -> unit
val notice : t -> Service.asset_scope -> Service.asset_notice -> unit
val pump : t -> unit
val imported : t -> current:bool -> Logseq_db_worker.import_receipt -> unit
