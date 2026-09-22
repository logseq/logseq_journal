(** Per-version transfer policy. It never discovers graph assets. *)
module Asset = Logseq_db_types.Asset_descriptor

type priority =
  | Foreground
  | Background

type handle = string

type failure =
  | Network
  | Not_found
  | Checksum_mismatch
  | Authentication
  | Locked
  | Storage_full
  | Invalid_content of string

type availability =
  | Queued
  | Downloading
  | Ready of handle
  | Waiting_remote
  | Waiting_network
  | Waiting_unlock
  | Failed of
      { failure : failure
      ; attempts : int
      ; retry_scheduled : bool
      }

type ticket = private
  { id : int
  ; scope : Core.graph_scope
  ; asset : Logseq_db_types.Graph_types.Uuid.t
  ; version : Asset.version
  }

type instruction =
  | Check_cache of ticket
  | Fetch of ticket
  | Cancel of ticket
  | Release_handle of handle
  | Retry_after of
      { id : int
      ; seconds : float
      }
  | Notify of
      { consumer : string
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; availability : availability
      }
  | Backpressure of string
  | Capacity_available

type event =
  | Replace of
      { consumer : string
      ; priority : priority
      ; assets : Asset.t list
      }
  | Release of string
  | Descriptor_changed of Asset.t
  | Cache_checked of ticket * (handle option, failure) result
  | Downloaded of ticket * (handle, failure) result
  | Retry of Logseq_db_types.Graph_types.Uuid.t
  | Retry_elapsed of int
  | Network_changed of bool
  | Unlock_changed of bool
  | Shutdown

type config

val config
  :  active:int
  -> foreground_reserved:int
  -> pending:int
  -> retries:int
  -> (config, string) result

type t

val create : config -> scope:Core.graph_scope -> online:bool -> unlocked:bool -> t

val availability
  :  t
  -> consumer:string
  -> (Logseq_db_types.Graph_types.Uuid.t * availability) list

val pending_count : t -> int
val step : t -> event -> t * instruction list
val ticket_current : t -> ticket -> bool
