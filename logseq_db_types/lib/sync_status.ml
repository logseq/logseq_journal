type state =
  | Active
  | Paused

type activity =
  | Pull_applied
  | Pull_duplicate
  | Pull_required
  | Sync_paused
  | Sync_submission_blocked

type t =
  { state : state
  ; applied_server_t : int
  ; checksum : string
  ; last_error : string option
  }

type pending =
  { payload : string option
  ; count : int
  ; blocked_error : string option
  }

type success =
  { activity : activity
  ; state : state
  ; applied_server_t : int
  ; checksum : string
  ; last_error : string option
  ; mutation : Mutation.success option
  }
