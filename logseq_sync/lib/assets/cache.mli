(** The owner serializes calls. Handles pin bytes until checked release. *)
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
  -> scope:Namespace.graph_scope
  -> budget_bytes:int64
  -> maximum_file_bytes:int
  -> (t, error) result

val report : t -> (Sync_dsl.Core.cache_report, error) result
val prune : t -> (Sync_dsl.Core.cache_report, error) result

val lookup
  :  t
  -> asset:Logseq_db_types.Graph_types.Uuid.t
  -> version:Logseq_db_types.Asset_descriptor.version
  -> (handle option, error) result

val publish
  :  t
  -> asset:Logseq_db_types.Graph_types.Uuid.t
  -> current:(unit -> bool)
  -> verified:Logseq_sync_native_crypto.Asset_codec.verified
  -> (handle, error) result

val path : t -> handle -> string option
val retain : t -> handle -> handle option
val release : t -> handle -> unit
val release_checked : t -> handle -> (unit, error) result

(** Preserve all retained handles and failed cleanup ownership on error. *)
val close_checked : t -> (unit, error) result

val close : t -> unit

(** Remove durable files for one origin/account after its live caches are closed. *)
val delete_account
  :  root:string
  -> account:Namespace.account_scope
  -> (unit, error) result

val graph_deletion_terminal
  :  root:string
  -> scope:Namespace.graph_scope
  -> retirement:Namespace.retirement_id
  -> ([ `Committed | `Aborted ] option, error) result

val prepare_graph_deletion
  :  root:string
  -> scope:Namespace.graph_scope
  -> retirement:Namespace.retirement_id
  -> (unit, error) result

val finish_graph_deletion
  :  root:string
  -> deletion:Namespace.asset_deletion
  -> commit:bool
  -> (unit, error) result

type staged = private
  { file : string
  ; checksum : string
  ; size : int64
  }

(** Copy an explicit import into the durable, non-evictable pending namespace.
      Each copy has a distinct physical file identity, including copies of the
      same operation. Legacy operation-only filenames remain readable.
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
val release_staged_if_unused : t -> file:string -> (unit, error) result

(** Remove recognized orphan staging files only after all ownership checks succeed.
      Ownership checks receive the exact physical file identity, including legacy
      filenames. The caller must serialize this with staging and intent persistence. *)
val prune_staged : t -> keep:(string -> (bool, string) result) -> (int, error) result
