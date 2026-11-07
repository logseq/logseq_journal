(** {1 TLDR}

    Interpret [Logseq_sync_pure_reducer.Core.runner_effect] with Eio and
    caller-supplied validated dependencies. {!create} binds a runner to an Eio
    switch; {!submit} performs I/O and queues exact Core completion events through
    [post]. The serial reducer remains the state owner. Asset and protected-value
    tickets execute at most once during this runner's lifetime; that process-local
    rule is not durable replay evidence. The lifecycle owner calls {!shutdown}.

    Construction depends on the capability types below. Primary excerpts:
    {[
      val create :
        ?on_asset_diagnostic:(scope:Logseq_sync_pure_reducer.Core.graph_scope
          -> operation:string -> request_operation:string
          -> Logseq_db_types.Failure_diagnostic.t -> unit)
        -> sw:Eio.Switch.t -> dependencies
        -> post:(Logseq_sync_pure_reducer.Core.event -> unit)
        -> (t, create_error) result
      val submit : t -> Logseq_sync_pure_reducer.Core.runner_effect -> unit
      val shutdown : t -> unit
    ]} *)

type t
type dependency_error = Invalid_dependency of string
type create_error = Invalid_create of string

(** {1 Minimal usage example}

    The caller supplies [sw], validated [dependencies], a Core-produced [runner_effect],
    and [post] that queues later serialized reducer turns:
    {[
      match create ~sw dependencies ~post with
      | Error error -> Error error
      | Ok runner ->
        Fun.protect
          ~finally:(fun () -> shutdown runner)
          (fun () ->
            submit runner runner_effect;
            run_until_retired runner;
            Ok ())
    ]}
    [run_until_retired] is the caller's event loop, not a runner API. It keeps the
    switch, pump and callback delivery alive through the owner's retirement
    protocol. [submit] returning is not the effect's completion acknowledgement. *)

(** {1 Construction and validation} *)

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

(** {2 Storage, secrets and crypto} *)

type local_store

val local_store
  :  ?asset_cache_budget_bytes:int64
  -> ?asset_maximum_file_bytes:int
  -> ?asset_pending_budget_bytes:int64
  -> application_support_directory:string
  -> unit
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
  :  ?on_asset_diagnostic:(scope:Logseq_sync_pure_reducer.Core.graph_scope
       -> operation:string
       -> request_operation:string
       -> Logseq_db_types.Failure_diagnostic.t
       -> unit)
  -> sw:Eio.Switch.t
  -> dependencies
  -> post:(Logseq_sync_pure_reducer.Core.event -> unit)
  -> (t, create_error) result

(** {1 Capability details} *)

(** Asset and protected-value tickets execute at most once for the runner's lifetime.
    Replaying an already submitted ticket does not execute I/O or post a second completion. *)
val submit : t -> Logseq_sync_pure_reducer.Core.runner_effect -> unit

(** {1 Lifecycle and recovery} *)

(** Checked physical cleanup for the original retired logical account. The
    caller must hold its lifecycle fence and join admitted IO first. Retained
    native leases preserve their cache and return Error; this issues no authority. *)
val retire_account:t -> account:Logseq_sync_pure_reducer.Core.account_scope -> (unit,string)result

(** Stop this runner's admission and cancel owned work. The enclosing switch and
    lifecycle owner still own actual I/O/callback joining; this unit return is not
    a checked per-account cleanup receipt. *)
val shutdown : t -> unit
