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

type notice_result =
  | Notice_action
  | Notice_dismiss
  | Notice_swipe
  | Notice_timeout

(** Host -> OCaml environment snapshot push (tag 24). *)
val decode_environment_event : bytes -> (Journal_environment.snapshot, string) result

val is_environment_event : bytes -> bool

(** OCaml -> host notice request (tag 25); response arrives on tag 26. *)
val show_notice_request
  :  token:int64
  -> message:string
  -> action_label:string option
  -> duration_ms:int
  -> bytes

val decode_notice_response : token:int64 -> bytes -> (notice_result, string) result

(** OCaml -> host request cancelling a pending notice (tag 27). *)
val notice_cancel_request : token:int64 -> bytes
