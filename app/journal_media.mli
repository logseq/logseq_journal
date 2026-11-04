module Worker = Journal_worker_coordination.Worker_api
module Asset = Logseq_db_types.Asset_descriptor

type ticket = private
  { id : int
  ; file : Worker.asset_file
  }

type presentation =
  | Hidden
  | Placeholder of string
  | Failed of string
  | Network_failed of string
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
  | Release_file of Worker.file_lease
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
  | Pin_preview of string
  | Unpin_preview of string
  | Availability of Worker.asset_notice
  | Acquired of ticket * Worker.file_lease option
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
