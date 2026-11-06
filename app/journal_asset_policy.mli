module Asset = Logseq_db_types.Asset_descriptor
module Graph = Logseq_db_types.Graph_types
module Transfer = Logseq_db_worker_lui.Logseq_db_worker_lui_service.Asset
module Worker = Journal_worker_coordination.Worker_api

type reason =
  | Recent
  | Favorites

type settings

val settings : recent_days:int -> (settings, string) result
val default_settings : settings
val recent_interval : settings -> today:int -> (int * int) option

(** Opaque equality-comparable cursor payloads stay with their data owner.
    Scanning never decodes a cursor or turns pagination into completeness. *)
type 'cursor query =
  | Recent_roots of
      { from_day : int
      ; through_day : int
      ; cursor : 'cursor option
      }
  | Favorite_roots of 'cursor option
  | Assets of
      { roots : Graph.Uuid.t list
      ; cursor : 'cursor option
      }

type 'cursor ticket = private
  { id : int
  ; graph_generation : int
  ; revision : int
  ; reason : reason
  ; query : 'cursor query
  }

type 'cursor instruction =
  | Read of 'cursor ticket
  | Demand of
      { consumer : string
      ; priority : Worker.asset_priority
      ; assets : Asset.t list
      }
  | Release of string

type 'cursor event =
  | Refresh of
      { graph_generation : int
      ; today : int
      ; settings : settings
      } (** Only an explicit resync invalidates every configured scan. *)
  | Resync
  | Roots_changed of Graph.Uuid.t list
  | Index_changed of reason
  | Dependencies_unavailable
  | Roots_loaded of 'cursor ticket * Graph.Uuid.t list * 'cursor option
  | Assets_loaded of 'cursor ticket * Asset.t list * 'cursor option
  | Read_failed of 'cursor ticket
  | Demand_accepted of string
  | Backpressure of string
  | Capacity_available
  | Availability of
      { consumer : string
      ; asset : Graph.Uuid.t
      ; availability : Transfer.availability
      }
  | Visible of
      { consumer : string
      ; assets : Asset.t list
      }
  | Hidden of string
  | Shutdown

type progress =
  | Inactive
  | Enumerating
  | Paused
  | Complete
  | Failed

type 'cursor t

val empty : 'cursor t
val progress : 'cursor t -> reason -> progress
val step : 'cursor t -> 'cursor event -> 'cursor t * 'cursor instruction list
val page_size : int
val roots : 'cursor t -> reason -> Graph.Uuid.t Seq.t

(** Pending causal read work, including pagination whose I/O is deferred until
    this exact demand is accepted. A final demand with no future read is absent. *)
type 'cursor read_dependency = private
  { ticket : 'cursor ticket
  ; after_demand : string option
  }

val read_dependencies : 'cursor t -> 'cursor read_dependency list
val completed_deferred_reads : 'cursor t -> 'cursor event -> 'cursor read_dependency list
val affected_reasons : 'cursor t -> 'cursor event -> reason list
val step_with_dependencies : 'cursor t -> 'cursor event
  -> 'cursor t * 'cursor instruction list * 'cursor read_dependency list

type offline =
  { enumeration : progress
  ; total : int
  ; ready : int
  ; failed : int
  }

val offline : 'cursor t -> reason -> offline
