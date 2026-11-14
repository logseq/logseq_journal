(** {1 TLDR}
    Typed native platform envelopes and account-scoped restart draft storage.
    Platform replies are validated before use; draft storage never restores
    execution sessions or mutation authority.

    {1 Minimal usage example}
    Caller-provided [directory] is the configured application support directory:
    {[
      let store = Draft_store.create ~directory ~binding in
      match Draft_store.load store with
      | Ok drafts -> install_drafts drafts
      | Error cause -> report_draft_failure cause
    ]}

    {1 Platform capabilities} *)

type network_lifecycle =
  | Backgrounded of { generation : int64 }
  | Foreground_resumed of { generation : int64 }

type local_account_binding =
  { user_id : string
  ; managed_sync_origin : string
  }

(** Decode one coalesced Apple-platform background epoch transition. *)
val decode_network_lifecycle : bytes -> (network_lifecycle, string) result

val authenticated_user_request : bytes
val decode_authenticated_user : bytes -> (string option, string) result
val local_account_binding_request : bytes
val decode_local_account_binding : bytes -> (local_account_binding option, string) result
val timeline_presented_request : bytes
val decode_timeline_presented : bytes -> (unit, string) result

val id_token_request
  :  Logseq_db_worker_lui.Logseq_db_worker_lui_service.token_request
  -> bytes

val decode_id_token_response : challenge_id:string -> bytes -> (string, string) result
val sign_out_request : bytes
val decode_sign_out_response : bytes -> (unit, string) result

(** Recognize the bounded host event requesting cooperative graph cleanup. *)
val is_prepare_to_terminate_event : bytes -> bool

(** Notify the host that graph ownership and network activity are closed. *)
val termination_ready_request : bytes

val decode_termination_ready_response : bytes -> (unit, string) result

(** Host -> OCaml environment snapshot push (tag 24). *)
val decode_environment_event : bytes -> (Journal_environment.snapshot, string) result

val is_environment_event : bytes -> bool

val copy_text_request : text:string -> (bytes, string) result
val decode_copy_text_response : bytes -> (unit, string) result

val online_requested_request : bytes
val online_cancelled_request : bytes
val scoped_online_requested_request : Logseq_db_worker_lui.Logseq_db_worker_lui_service.startup_scope -> bytes
val scoped_online_cancelled_request : Logseq_db_worker_lui.Logseq_db_worker_lui_service.startup_scope -> bytes
val scoped_timeline_presented_request : Logseq_db_worker_lui.Logseq_db_worker_lui_service.startup_scope -> bytes
val decode_online_event : bytes -> (bool * Logseq_db_worker_lui.Logseq_db_worker_lui_service.startup_scope, string) result
val decode_authenticated_scope : bytes -> (Logseq_db_worker_lui.Logseq_db_worker_lui_service.startup_scope, string) result

(** {1 Restart draft lifecycle}
    At most 128 drafts, 256 attachments, 256 KiB per text, 2 MiB metadata and 128 MiB media
    per account. Media is copied into private owned storage (32 MiB per file).
    Before manifest rename, failed saves preserve the last complete snapshot.
    Rename publishes the replacement; directory synchronization confirms its
    restart durability. A synchronization error after publication is explicitly
    reported as an unknown durable outcome, not a rollback, and must prevent
    mutation dispatch. Old media is retained in that case. After confirmed
    publication, orphan cleanup is best-effort and cannot turn success into an
    error; a later save retries cleanup. Save/discard replace the snapshot;
    [clear] removes only this account's owned files. Caller serializes operations
    and reports errors. Recovered interrupted saves remain locked. *)
module Draft_store : sig
  type t
  type draft = { graph : string; parent : string option; capture : Journal_capture.t }
  val create : directory:string -> binding:local_account_binding -> t
  val save : t -> draft list -> (unit, string) result
  val load : t -> (draft list, string) result
  val clear : t -> (unit, string) result
end
