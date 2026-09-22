module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Asset = Logseq_db_types.Asset_descriptor

type ticket = private
  { id : int
  ; scope : Service.asset_scope
  ; handle : string
  }

type presentation =
  | Hidden
  | Placeholder of string
  | File of string
  | External of string

type instruction =
  | Demand of
      { graph_generation : int
      ; consumer : string
      ; asset : Asset.t
      }
  | Release of
      { graph_generation : int
      ; consumer : string
      }
  | Acquire of ticket
  | Release_file of
      { scope : Service.asset_scope
      ; lease : string
      }
  | Retry of
      { graph_generation : int
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      }

type event =
  | Show of
      { graph_generation : int
      ; consumer : string
      ; asset : Asset.t
      }
  | Hide
  | Availability of
      { scope : Service.asset_scope
      ; consumer : string
      ; availability : Service.Asset.availability
      }
  | Acquired of ticket * (string * string) option
  | Retry_requested
  | Demand_backpressured
  | Demand_accepted
  | Capacity_available

type t

val empty : t
val step : t -> event -> t * instruction list
val presentation : t -> presentation
val descriptor : t -> Asset.t option
val ticket_current : t -> ticket -> bool
