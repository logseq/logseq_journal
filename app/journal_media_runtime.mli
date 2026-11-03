module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Asset = Logseq_db_types.Asset_descriptor
module Protocol = Logseq_db_worker.Protocol

type ticket

module Worker = Journal_worker_coordination.Worker_api

type read_result

type read_request = private
  { ticket : ticket
  ; maximum_items : int
  ; query : Worker.asset_listing Worker.query
  ; outcome : Worker.asset_listing -> read_result
  }

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

(** A fixed typed listing port. It returns admission synchronously and delivers
    the read result on a later turn of the existing serial App event entrance.
    Transport IDs and continuation construction stay with the coordinator SDK. *)
val create_coordinated
  :  ?release_file:(Worker.file_lease -> bool)
  -> ?release_consumer:(Worker.asset_consumer -> bool)
  -> ?read_planned:(Logseq_db_types.Graph_types.Uuid.t -> unit)
  -> ?read_retired:(Logseq_db_types.Graph_types.Uuid.t -> unit)
  -> read:(read_request -> bool)
  -> send:(ticket option -> Service.request -> bool)
  -> changed:(string -> view -> unit)
  -> unit
  -> t

(** Business read identities include queued and accepted reads; resource leases
    are excluded. Planning is reported before a possible synchronous refusal. *)
val owns_read : t -> Logseq_db_types.Graph_types.Uuid.t -> bool

(** Logical presentation association only; physical ownership stays in Core. *)
val bind_consumer:t -> name:string -> Worker.asset_consumer -> unit
val acquisition_consumer:ticket -> string option
val consumer_names:t -> string Seq.t
val receive_file:t -> ticket -> Worker.file_lease option -> unit

val receive_read : t -> read_result -> bool
(** Retire only imported preview leases owned by a replaced coordinator binding.
    Keep ordinary display owners and rediscover visible roots after real rebind. *)
val retire_coordinated_previews:t -> unit
val retire_coordinated_resources:t -> unit
val bind_coordinated_resources:t -> Worker.binding -> unit
val resume_coordinated_previews:t -> unit
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
val demand_backpressured : t -> string -> unit
val pump : t -> unit
val imported : t -> current:bool -> Logseq_db_worker.import_receipt -> unit
val idle : t -> bool

(** Page-fact observation only. No enumeration or pagination state is consumed. *)
val observe_journals_request : t -> request_id:Logseq_db_types.Graph_types.Uuid.t -> unit

val observe_journals_result
  :  t
  -> request_id:Logseq_db_types.Graph_types.Uuid.t
  -> Protocol.v2_journal_item Journal_worker_coordination.Worker_api.slice
  -> unit

(** Exact business correlation, independent of Worker transport IDs. *)
val read_request_id : read_request -> Logseq_db_types.Graph_types.Uuid.t

(** Failed visible interests remain obligations of a repeated Changes attempt,
    even when their error view did not change and no new read was planned. *)
val change_application_error : t -> Protocol.v2_change_window list -> string option

(** Only failed DTO/dependency reads, excluding download/lease/import status. An
    actual queued listing retry remains an obligation rather than a final error. *)
val projection_read_error : t -> root:string -> string option

(** Retains the actual typed import preview until its business consumers leave.
    Cleanup uses the fixed sealed-lease port and remains owned by the coordinator. *)
val imported_coordinated : t -> current:bool -> Worker.imported -> unit
