(** Eio-native interpreter for [Logseq_sync_pure_reducer.Core.runner_effect]. *)

type t
type dependency_error = Invalid_dependency of string
type create_error = Invalid_create of string
type runtime

val runtime
  :  fork:(sw:Eio.Switch.t -> (unit -> unit) -> unit)
  -> sleep:(float -> unit)
  -> monotonic_ns:(unit -> int64)
  -> (runtime, dependency_error) result

type transport
type tls_authenticator

val tls_authenticator : X509.Authenticator.t -> tls_authenticator
val system_tls_authenticator : unit -> (tls_authenticator, dependency_error) result

val transport
  :  tls_authenticator:tls_authenticator
  -> network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
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
  :  has_private_key:(managed_sync_origin:Uri.t -> user_id:string -> bool)
  -> unlock_private_key:
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
  -> delete_wrapped_graph_key:
       (managed_sync_origin:Uri.t
        -> user_id:string
        -> graph_id:Logseq_sync_pure_reducer.Core.graph_id
        -> (unit, string) result)
  -> delete_account_secrets:
       (managed_sync_origin:Uri.t -> user_id:string -> (unit, string) result)
  -> (secrets, dependency_error) result

type crypto

val crypto
  :  decrypt_private_key:
       (password:string
        -> iterations:int
        -> salt:string
        -> iv:string
        -> ciphertext:string
        -> (string, string) result)
  -> decrypt_graph_key:
       (private_key:string -> ciphertext:string -> (string, string) result)
  -> encrypt_aes_gcm:(key:string -> plaintext:string -> (string * string, string) result)
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

val shutdown : t -> unit
