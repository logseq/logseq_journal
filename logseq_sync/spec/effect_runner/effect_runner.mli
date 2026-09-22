(** Eio-native interpreter for [Logseq_sync_pure_reducer.Core.runner_effect]. *)

type t
type dependency_error = Invalid_dependency of string
type create_error = Invalid_create of string
type runtime

val runtime
  :  fork:(sw:Eio.Switch.t -> (unit -> unit) -> unit)
  -> sleep:(float -> unit)
  -> (runtime, dependency_error) result

type transport
type tls_authenticator
type id_token_provider

val id_token_provider
  :  acquire:(Logseq_sync_pure_reducer.Core.account_scope -> (string, string) result)
  -> invalidate:(Logseq_sync_pure_reducer.Core.account_scope -> token:string -> unit)
  -> id_token_provider

type authenticated_failure =
  | Unauthorized
  | Forbidden
  | Request_failed of string

val authenticated_operation
  :  id_token_provider
  -> account:Logseq_sync_pure_reducer.Core.account_scope
  -> perform:(string -> ('a, authenticated_failure) result)
  -> ('a, string) result

val tls_authenticator : X509.Authenticator.t -> tls_authenticator
val system_tls_authenticator : unit -> (tls_authenticator, dependency_error) result

type websocket_liveness =
  | Disabled
  | Ping_pong of
      { interval_seconds : float
      ; timeout_seconds : float
      }

val transport
  :  tls_authenticator:tls_authenticator
  -> network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> websocket_liveness:websocket_liveness
  -> (transport, dependency_error) result

type local_store

val local_store
  :  application_support_directory:string
  -> (local_store, dependency_error) result

type artifact_store

val artifact_store : staging_directory:string -> (artifact_store, dependency_error) result

type wrapped_key_load_error =
  | Wrapped_graph_key_unavailable of string
  | Local_private_key_unavailable of string

type secrets

val secrets
  :  unlock_private_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> password:string
        -> private_key_package:string
        -> (unit, string) result)
  -> unlock_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> encrypted_graph_key:string
        -> (string, string) result)
  -> load_wrapped_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> graph_id:Logseq_sync_pure_reducer.Core.graph_id
        -> (string, wrapped_key_load_error) result)
  -> verify_and_save_wrapped_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> graph_id:Logseq_sync_pure_reducer.Core.graph_id
        -> encrypted_graph_key:string
        -> (unit, string) result)
  -> delete_account_secrets:
       (managed_sync_origin:Uri.t -> user_id:string -> (unit, string) result)
  -> (secrets, dependency_error) result

type crypto

val crypto
  :  encrypt_aes_gcm:(key:string -> plaintext:string -> (string * string, string) result)
  -> decrypt_aes_gcm:
       (key:string -> iv:string -> ciphertext:string -> (string, string) result)
  -> (crypto, dependency_error) result

val apple_secrets : unit -> (secrets, dependency_error) result
val apple_crypto : unit -> (crypto, dependency_error) result

type dependencies

val dependencies
  :  runtime:runtime
  -> transport:transport
  -> local_store:local_store
  -> artifact_store:artifact_store
  -> secrets:secrets
  -> crypto:crypto
  -> id_token_provider:id_token_provider
  -> (dependencies, dependency_error) result

val create
  :  sw:Eio.Switch.t
  -> dependencies
  -> post:(Logseq_sync_pure_reducer.Core.event -> unit)
  -> (t, create_error) result

val submit : t -> Logseq_sync_pure_reducer.Core.runner_effect -> unit

val decrypt_protected_value
  :  t
  -> Logseq_sync_pure_reducer.Core.graph_key_handle
  -> string
  -> (string, string) result

val encrypt_protected_values
  :  t
  -> Logseq_sync_pure_reducer.Core.graph_key_handle
  -> string list
  -> ((string * string) list, string) result

val shutdown : t -> unit

type asset_encryption =
  | Plaintext
  | Encrypted of Logseq_sync_pure_reducer.Core.graph_key_handle option

(** Executes explicit asset instructions with the existing authentication/key owner.
    [current] must check the exact scope, version and request identity immediately;
    it is rechecked before atomic publication and before delivering a result.
    A runner admits at most three binary downloads, including response decoding
    and publication, across all graph scopes. Cache-only checks bypass this gate.
    GET decoding/publication and PUT source reading/encoding share one codec permit;
    network requests retain their independent transfer permits. Every admitted
    transfer also reserves its worst-case wire plus plaintext footprint against one
    shared 64 MiB byte budget, bounding total in-flight asset memory across lanes. *)
val submit_asset
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> cache:Asset_cache.t
  -> encryption:asset_encryption
  -> maximum_plaintext_bytes:int
  -> current:(Logseq_sync_pure_reducer.Asset_transfer.ticket -> bool)
  -> post:(Logseq_sync_pure_reducer.Asset_transfer.event -> unit)
  -> Logseq_sync_pure_reducer.Asset_transfer.instruction
  -> unit

(** Scoped cache adapter for the worker's live asset session. *)
val run_scoped_asset
  :  t
  -> context:Logseq_sync_pure_reducer.Core.asset_context
  -> current:(Logseq_sync_pure_reducer.Asset_transfer.ticket -> bool)
  -> post:(Logseq_sync_pure_reducer.Asset_transfer.event -> unit)
  -> Logseq_sync_pure_reducer.Asset_transfer.instruction
  -> unit

val close_asset_scope : t -> Logseq_sync_pure_reducer.Core.graph_scope -> unit

val retain_asset_file
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> handle:string
  -> (string * string) option

val release_asset_file
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> handle:string
  -> unit

val delete_graph_assets
  :  t
  -> Logseq_sync_pure_reducer.Core.mirror_deletion
  -> (unit, string) result

type upload_failure =
  | Upload_network
  | Upload_authentication
  | Upload_locked
  | Upload_missing_source
  | Upload_size_rejected
  | Upload_revoked_access
  | Upload_invalid_content
  | Upload_cancelled

(** Upload an explicit, immutable staged file. Graph publication belongs to the worker.
    A runner reserves one upload permit alongside its three download permits.
    Admission precedes source reads and encoding; cancellation or failure releases
    the permit. The upload reserves its wire plus plaintext footprint against the
    shared 64 MiB byte budget before encoding. Waiting callers must supply a live
    [current] predicate. *)
val upload_asset
  :  t
  -> context:Logseq_sync_pure_reducer.Core.asset_context
  -> asset:Logseq_db_types.Graph_types.Uuid.t
  -> version:Logseq_db_types.Asset_descriptor.version
  -> source_file:string
  -> maximum_plaintext_bytes:int
  -> current:(unit -> bool)
  -> (unit, upload_failure) result

val staged_asset_path
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> file:string
  -> string option

val release_staged_asset
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> file:string
  -> (unit, string) result

val stage_asset
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> operation:Logseq_db_types.Graph_types.Uuid.t
  -> file_type:string
  -> source_file:string
  -> (string * string * int64, string) result

val prune_staged_assets
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> keep:(Logseq_db_types.Graph_types.Uuid.t -> (bool, string) result)
  -> (int, string) result

val retain_staged_file
  :  t
  -> scope:Logseq_sync_pure_reducer.Core.graph_scope
  -> file:string
  -> (string * string) option
