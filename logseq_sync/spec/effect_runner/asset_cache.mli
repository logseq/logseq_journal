(** Verified files are local state, scoped by origin, account and graph. Calls are
    serialized by the effect runner; handles pin files until explicitly released. *)
type t

type handle = string

type error =
  | Invalid of string
  | Io of string
  | Full
  | Stale
  | Checksum_mismatch

val create
  :  root:string
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> budget_bytes:int64
  -> maximum_file_bytes:int
  -> (t, error) result

val lookup
  :  t
  -> asset:Logseq_db_types.Graph_types.Uuid.t
  -> version:Logseq_db_types.Asset_descriptor.version
  -> (handle option, error) result

val publish
  :  t
  -> asset:Logseq_db_types.Graph_types.Uuid.t
  -> version:Logseq_db_types.Asset_descriptor.version
  -> current:(unit -> bool)
  -> plaintext:string
  -> (handle, error) result

val path : t -> handle -> string option
val retain : t -> handle -> handle option
val release : t -> handle -> unit
val close : t -> unit
val delete : t -> (unit, error) result

(** Remove durable files for one origin/account after its live caches are closed. *)
val delete_account
  :  root:string
  -> account:Logseq_sync_pure_reducer.Core.account_scope
  -> (unit, error) result

val delete_graph
  :  root:string
  -> account:Logseq_sync_pure_reducer.Core.account_scope
  -> graph_id:Logseq_db_types.Graph_types.Uuid.t
  -> (unit, error) result

type staged = private
  { file : string
  ; checksum : string
  ; size : int64
  }

(** Copy an explicit import into the durable, non-evictable pending namespace.
    The caller persists the returned identity before graph mutation or upload. *)
val stage
  :  t
  -> operation:Logseq_db_types.Graph_types.Uuid.t
  -> file_type:string
  -> source_file:string
  -> pending_budget_bytes:int64
  -> (staged, error) result

(** Retain a staged file for a local preview. Completion cleanup waits for all leases. *)
val retain_staged : t -> file:string -> handle option

val staged_path : t -> file:string -> string option
val release_staged : t -> file:string -> (unit, error) result

(** Remove recognized orphan staging files only after all ownership checks succeed.
    The caller must serialize this operation with staging and intent persistence. *)
val prune_staged
  :  t
  -> keep:(Logseq_db_types.Graph_types.Uuid.t -> (bool, string) result)
  -> (int, error) result
