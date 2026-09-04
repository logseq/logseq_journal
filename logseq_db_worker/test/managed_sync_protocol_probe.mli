module Protocol = Logseq_sync_pure_reducer.Sync_protocol

type t

val connect
  :  sw:Eio.Switch.t
  -> network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> base_url:string
  -> graph_id:Logseq_db_types.Graph_types.Uuid.t
  -> token:string
  -> (t, string) result

val send : t -> Protocol.Client.message -> (unit, string) result

val await
  :  clock:_ Eio.Time.clock
  -> timeout_seconds:float
  -> (Protocol.Server.message -> 'a option)
  -> t
  -> ('a, string) result

val close : t -> unit
