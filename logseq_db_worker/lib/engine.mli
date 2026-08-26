type t

type clocks =
  { epoch_ms : unit -> int64
  ; monotonic_ns : unit -> int64
  }

type dependencies =
  { clocks : clocks
  ; cursor_authentication_key : bytes
  ; crypto : Sync_e2ee.crypto
  ; unlock_graph_key :
      managed_sync_origin:Uri.t
      -> user_id:string
      -> encrypted_graph_key:string
      -> (Sync_graph_key.t, string) result
  }

exception Fatal_storage_error of string

val open_ : dependencies:dependencies -> Config.t -> (t, Error.t) result
val execute : t -> Protocol.request -> Protocol.response
val requeue_submitted : t -> mutation_ids:Graph_types.Uuid.t list -> (unit, string) result
val close : t -> (unit, string) result
val basis : t -> int64 option
