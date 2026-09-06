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
val typography_preset_preference_request : bytes
val decode_typography_preset_preference : bytes -> (string option, string) result
val set_typography_preset_preference_request : string -> bytes
val decode_set_typography_preset_preference : bytes -> (unit, string) result

val id_token_request
  :  Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service.token_request
  -> bytes

val decode_id_token_response : challenge_id:string -> bytes -> (string, string) result
val sign_out_request : bytes
val decode_sign_out_response : bytes -> (unit, string) result

(** Recognize the bounded host event requesting cooperative graph cleanup. *)
val is_prepare_to_terminate_event : bytes -> bool

(** Notify the host that graph ownership and network activity are closed. *)
val termination_ready_request : bytes

val decode_termination_ready_response : bytes -> (unit, string) result
