module Asset = Logseq_db_types.Asset_descriptor
module Graph = Logseq_db_types.Graph_types
module Transfer = Logseq_db_worker_lui.Logseq_db_worker_lui_service.Asset

type reason =
  | Recent
  | Favorites

type settings

val settings : recent_days:int -> (settings, string) result
val default_settings : settings
val recent_interval : settings -> today:int -> (int * int) option

type query =
  | Recent_roots of
      { from_day : int
      ; through_day : int
      ; cursor : Graph.Cursor.t option
      }
  | Favorite_roots of Graph.Cursor.t option
  | Assets of
      { roots : Graph.Uuid.t list
      ; cursor : Graph.Cursor.t option
      }

type ticket = private
  { id : int
  ; graph_generation : int
  ; revision : int
  ; reason : reason
  ; query : query
  }

type instruction =
  | Read of ticket
  | Demand of
      { consumer : string
      ; priority : Transfer.priority
      ; assets : Asset.t list
      }
  | Release of string

type event =
  | Refresh of
      { graph_generation : int
      ; today : int
      ; settings : settings
      }
  | Roots_loaded of ticket * Graph.Uuid.t list * Graph.Cursor.t option
  | Assets_loaded of ticket * Asset.t list * Graph.Cursor.t option
  | Read_failed of ticket
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

type t

val empty : t
val progress : t -> reason -> progress
val step : t -> event -> t * instruction list
val page_size : int

type offline =
  { enumeration : progress
  ; total : int
  ; ready : int
  ; failed : int
  }

val offline : t -> reason -> offline
