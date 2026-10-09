module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Asset = Logseq_db_types.Asset_descriptor
module Protocol = Logseq_db_worker.Protocol

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
val observe_response : t -> Protocol.response -> unit

(** Register a successfully admitted current-scope query before its response.
    Observations retire their registration and cannot overwrite newer facts. *)
val observe_request : t -> Protocol.request -> unit

val forget_request : t -> Logseq_db_types.Graph_types.Uuid.t -> unit
val changes : t -> Protocol.v2_change_window list -> unit
val resync : t -> unit
val receive : t -> ticket -> Service.response -> unit
val reject : t -> ticket -> unit
val notice : t -> Service.asset_scope -> Service.asset_notice -> unit
val pump : t -> unit
val imported : t -> current:bool -> Logseq_db_worker.import_receipt -> unit
