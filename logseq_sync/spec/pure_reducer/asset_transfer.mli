(** {1 TLDR}

    Coordinate bounded cache lookup and download demand for explicit asset
    versions. The caller owns {!t}; {!step} performs no I/O or persistence and
    returns the next state plus ordered {!instruction}s for a runner. It never
    discovers graph assets. {!availability} reports per-consumer progress;
    successful file handles still require release through emitted instructions.

    The dependent event and instruction variants appear below; these are excerpts
    of the actual entry points, not additional declarations:
    {[
      val create : config -> scope:Core.graph_scope -> online:bool -> unlocked:bool -> t
      val step : t -> event -> t * instruction list
      val availability : t -> consumer:string
        -> (Logseq_db_types.Graph_types.Uuid.t * availability) list
    ]} *)

module Asset = Logseq_db_types.Asset_descriptor

type config

val config
  :  active:int
  -> foreground_reserved:int
  -> pending:int
  -> retries:int
  -> (config, string) result

type t

val create : config -> scope:Core.graph_scope -> online:bool -> unlocked:bool -> t

(** {1 Minimal usage example}

    The caller supplies validated [config], current [scope], connectivity flags,
    an explicit [consumer] and [assets], plus [interpret]:
    {[
      let state = ref (create config ~scope ~online ~unlocked) in
      let next, instructions =
        step !state (Replace { consumer; priority = Foreground; assets })
      in
      state := next;
      List.iter interpret instructions;
      availability !state ~consumer
    ]}
    [interpret] queues cache/download/timer completions for later serialized turns.
    On retirement, feed [Release consumer] (or [Shutdown] for the whole owner),
    install its next state and interpret every cleanup instruction the same way. *)

(** {1 Capability details} *)

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

type lookup_source =
  | Local_checksum of string
  | Remote_version of Asset.version
  | Local_and_remote of
      { current_checksum : string
      ; remote_version : Asset.version
      }

(** {1 Lifecycle and recovery}

    Tickets are created by this reducer for one graph scope, asset and lookup
    source/version. The runner returns the exact ticket; {!ticket_current} checks
    current ownership before I/O. Replacing demand, version changes and shutdown
    can retire work. Stale successful completions may emit [Release_handle] and
    must still be interpreted. Tickets are not persisted across restart. *)

type lookup_ticket = private
  { id : int
  ; scope : Core.graph_scope
  ; asset : Logseq_db_types.Graph_types.Uuid.t
  ; source : lookup_source
  }

type fetch_ticket = private
  { id : int
  ; scope : Core.graph_scope
  ; asset : Logseq_db_types.Graph_types.Uuid.t
  ; version : Asset.version
  }

type ticket =
  | Lookup of lookup_ticket
  | Download of fetch_ticket

type instruction =
  | Check_cache of lookup_ticket
  | Fetch of fetch_ticket
  | Cancel of ticket
  | Release_handle of handle
  | Retry_after of
      { id : int
      ; seconds : float
      }
  | Notify of
      { consumer : string
      ; asset : Logseq_db_types.Graph_types.Uuid.t
      ; descriptor : Asset.t
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
  | Cache_checked of lookup_ticket * (handle option, failure) result
  | Downloaded of fetch_ticket * (handle, failure) result
  | Retry of Logseq_db_types.Graph_types.Uuid.t
  | Retry_elapsed of int
  | Network_changed of bool
  | Unlock_changed of bool
  | Shutdown

(** {1 Observation and helpers} *)

val availability
  :  t
  -> consumer:string
  -> (Logseq_db_types.Graph_types.Uuid.t * availability) list

val pending_count : t -> int
val step : t -> event -> t * instruction list
val ticket_current : t -> ticket -> bool
