module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Asset = Logseq_db_types.Asset_descriptor

type ticket

type item =
  { token : string
  ; asset : Asset.t
  ; file_type : string
  ; presentation : Journal_media.presentation
  }

type picker =
  { candidates : item list
  ; candidates_more : bool
  ; busy : bool
  }

type view =
  { items : item list
  ; more : bool
  ; error : string option
  ; picker : picker option
  }

type t

val create
  :  send:(ticket option -> Service.request -> bool)
  -> changed:(string -> view -> unit)
  -> armed:(string -> Logseq_db_types.Graph_types.Uuid.t option -> unit)
  -> t

val reset : t -> graph_generation:int option -> unit
val root_visible : t -> root:string -> bool -> unit
val asset_visible : t -> root:string -> asset:string -> bool -> unit
val next : t -> root:string -> unit
val retry : t -> root:string -> asset:string -> unit
val begin_replace : t -> root:string -> unit
val begin_reuse : t -> root:string -> unit
val reuse_next : t -> root:string -> unit
val reuse_select : t -> root:string -> asset:string -> unit
val end_reuse : t -> root:string -> unit
val refresh : t -> unit
val receive : t -> ticket -> Service.response -> unit
val reject : t -> ticket -> unit
val notice : t -> Service.asset_scope -> Service.asset_notice -> unit
val pump : t -> unit
val imported : t -> current:bool -> Logseq_db_worker.import_receipt -> unit
