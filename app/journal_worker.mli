type rejection =
  | Recovery_only
  | Editing_locked
  | Stale_calendar_generation
  | Invalid_calendar_snapshot
  | Invalid_request of string
  | Storage_unavailable

type startup_failure =
  | Restart_required
  | Configuration_unavailable

type request =
  | Get_status
  | Observe_calendar of
      { generation : int64
      ; local_day : int
      }
  | Capture of
      { calendar_generation : int64
      ; command : Journal_repository.capture
      }
  | Create_child of Journal_repository.create_child
  | Update_source of Journal_repository.update_source
  | Set_task_state of Journal_repository.set_task_state
  | Delete_subtree of Journal_repository.delete_subtree
  | Reconcile of
      { mutation_id : string
      ; block_id : string
      }
  | Find_block of string
  | Load_feed of
      { before_day : int option
      ; day_limit : int
      ; blocks_per_day : int
      ; slot_limit : int
      ; request_generation : int64
      }
  | Load_day_blocks of
      { day : int
      ; after : Journal_repository.block_cursor option
      ; limit : int
      ; request_generation : int64
      }
  | Load_detail of
      { block_id : string
      ; after : Journal_repository.block_cursor option
      ; limit : int
      ; request_generation : int64
      }

type payload =
  | Store_ready of Journal_storage.disposition
  | Status of Journal_storage.state
  | Calendar_observed of int64
  | Block_captured of Journal_repository.block
  | Child_created of
      { child : Journal_repository.block
      ; parent_revision : int
      }
  | Block_updated of Journal_repository.block
  | Update_conflict of Journal_repository.block
  | Subtree_deleted of
      { block_id : string
      ; deleted_count : int
      ; parent : Journal_repository.block option
      }
  | Delete_conflict of Journal_repository.block
  | Reconciled_applied of Journal_repository.block
  | Reconciled_not_applied
  | Reconciled_superseded of Journal_repository.block
  | Block_found of Journal_repository.block option
  | Feed_loaded of
      { request_generation : int64
      ; feed : Journal_repository.feed
      }
  | Day_blocks_loaded of
      { request_generation : int64
      ; page : Journal_repository.block_page
      }
  | Detail_loaded of
      { request_generation : int64
      ; detail : Journal_repository.detail
      }
  | Oversized_source of Journal_repository.Error.oversized_source
  | Startup_failed of startup_failure
  | Rejected of rejection

type response =
  { store_id : string
  ; basis_tx : int
  ; access_mode : Journal_startup.access_mode
  ; calendar : Journal_startup.calendar_snapshot
  ; calendar_generation : int64
  ; local_day : int
  ; payload : payload
  }

type push = Ready of response

(** Deterministic application-level size estimate used for the 256 KiB
    Worker response budget. *)
val estimated_payload_bytes : response -> int

(** One Serial Worker service that exclusively owns the canonical SQLite
    session and current DataScript database. *)
val service : (Journal_startup.t, request, response, push) Worker.Service.t
