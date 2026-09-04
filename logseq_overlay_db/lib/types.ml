module Graph = Logseq_db_types.Graph_types

module type VERSIONED_TOKEN = sig
  type t

  val equal : t -> t -> bool
  val compare : t -> t -> int
  val to_string : t -> string
  val of_string : string -> (t, string) result
end

module Make_versioned_token (Name : sig
    val prefix : string
  end) : VERSIONED_TOKEN = struct
  type t = string

  let equal = String.equal
  let compare = String.compare
  let to_string value = value

  let of_string value =
    let prefix = Name.prefix ^ ":v1:" in
    let prefix_length = String.length prefix in
    if String.length value > prefix_length && String.sub value 0 prefix_length = prefix
    then Ok value
    else Error (Printf.sprintf "invalid %s token version" Name.prefix)
  ;;
end

module Generation = Make_versioned_token (struct
    let prefix = "generation"
  end)

module Projection_revision = Make_versioned_token (struct
    let prefix = "projection"
  end)

module Authoritative_revision = Make_versioned_token (struct
    let prefix = "authoritative"
  end)

module Logical_outbox_revision = Make_versioned_token (struct
    let prefix = "logical-outbox"
  end)

module Transport_outbox_revision = Make_versioned_token (struct
    let prefix = "transport-outbox"
  end)

module Block_state_revision = Make_versioned_token (struct
    let prefix = "block-state"
  end)

module Page_state_revision = Make_versioned_token (struct
    let prefix = "page-state"
  end)

module Scope_revision = Make_versioned_token (struct
    let prefix = "scope"
  end)

module Mirror_generation = Make_versioned_token (struct
    let prefix = "mirror-generation"
  end)

module Server_cursor = Make_versioned_token (struct
    let prefix = "server-cursor"
  end)

module Checksum = Make_versioned_token (struct
    let prefix = "checksum"
  end)

module Crypto_item_id = Make_versioned_token (struct
    let prefix = "crypto-item"
  end)

module Submission_batch_id = Make_versioned_token (struct
    let prefix = "submission-batch"
  end)

module Mutation_fingerprint = Make_versioned_token (struct
    let prefix = "mutation-fingerprint"
  end)

type generation = Generation.t
type projection_revision = Projection_revision.t
type authoritative_revision = Authoritative_revision.t
type logical_outbox_revision = Logical_outbox_revision.t
type transport_outbox_revision = Transport_outbox_revision.t
type block_state_revision = Block_state_revision.t
type page_state_revision = Page_state_revision.t
type scope_revision = Scope_revision.t
type mirror_generation = Mirror_generation.t
type server_cursor = Server_cursor.t
type checksum = Checksum.t
type crypto_item_id = Crypto_item_id.t
type submission_batch_id = Submission_batch_id.t
type mutation_fingerprint = Mutation_fingerprint.t

type snapshot_version =
  { generation : generation
  ; projection_revision : projection_revision
  }

type capability_limits =
  { response_budget_bytes : int
  ; outbox_max_records : int
  ; outbox_max_bytes : int
  ; change_max_items : int
  ; change_max_bytes : int
  ; dispatcher_capacity : int
  ; wire_batch_max_bytes : int
  }

type graph_info =
  { graph_uuid : Graph.Uuid.t
  ; graph_name : string
  ; schema : Graph.schema_version
  ; admission_facts : Graph.admission_fact list
  ; limits : capability_limits
  ; version : snapshot_version
  }

type admission_inspection =
  { active_records : int
  ; active_bytes : int
  ; protected_wire_bytes : int
  ; retained_origin_evidence_bytes : int
  ; maximum_records : int
  ; maximum_bytes : int
  }

type task_status =
  | Todo
  | Doing
  | In_review
  | Now
  | Done
  | Canceled
  | Backlog
  | Waiting
  | Later

type block_record =
  { block : Graph.block
  ; task_status : task_status option
  ; rendered_page_title : string
  }

type page_record = { page : Graph.page }

type block_lookup =
  | Present_block of
      { value : block_record
      ; revision : block_state_revision
      }
  | Missing_block of
      { uuid : Graph.block_uuid
      ; revision : block_state_revision
      }

type page_lookup =
  | Present_page of
      { value : page_record
      ; revision : page_state_revision
      }
  | Missing_page of
      { uuid : Graph.page_uuid
      ; revision : page_state_revision
      }

type journal_item =
  { page : page_record
  ; journal_day : int
  ; revision : page_state_revision
  }

type structure_revision_scope =
  | Children_revision of Graph.block_uuid
  | Page_tree_revision of
      { page : Graph.page_uuid
      ; maximum_depth : int
      }
  | Journal_index_revision

type structure_interest =
  | Children_interest of Graph.block_uuid
  | Page_tree_interest of Graph.page_uuid
  | Journal_index_interest

type journal_list_result =
  { items : journal_item list
  ; next_cursor : Graph.Cursor.t option
  ; revision_scope : structure_revision_scope
  ; scope_revision : scope_revision
  }

type structure_request =
  | Children of
      { parent : Graph.block_uuid
      ; limit : int
      ; cursor : Graph.Cursor.t option
      }
  | Page_tree of
      { page : Graph.page_uuid
      ; maximum_depth : int
      ; limit : int
      ; cursor : Graph.Cursor.t option
      }

type child_member =
  { block : block_record
  ; revision : block_state_revision
  }

type tree_member =
  { block : block_record
  ; revision : block_state_revision
  ; depth : int
  ; parent : Graph.Uuid.t
  }

type structure_result =
  | Children_result of
      { parent : Graph.block_uuid
      ; revision_scope : structure_revision_scope
      ; scope_revision : scope_revision
      ; items : child_member list
      ; next_cursor : Graph.Cursor.t option
      }
  | Page_tree_result of
      { page : Graph.page_uuid
      ; maximum_depth : int
      ; revision_scope : structure_revision_scope
      ; scope_revision : scope_revision
      ; items : tree_member list
      ; next_cursor : Graph.Cursor.t option
      }

type resync_reason =
  | Change_limit_exceeded
  | Dispatcher_retention_exceeded
  | Generation_changed
  | Publication_recovered

type projection_change =
  | Exact of
      { generation : generation
      ; before_revision : projection_revision
      ; after_revision : projection_revision
      ; block_uuids : Graph.block_uuid list
      ; page_uuids : Graph.page_uuid list
      ; structure_interests : structure_interest list
      }
  | Projection_resync_required of
      { generation : generation
      ; after_revision : projection_revision
      ; reason : resync_reason
      }

type logical_change_summary =
  | No_logical_change
  | Exact_logical_change of
      { block_uuids : Graph.block_uuid list
      ; page_uuids : Graph.page_uuid list
      ; structure_interests : structure_interest list
      }
  | Logical_resync_required of resync_reason

type block_tree =
  { uuid : Graph.block_uuid
  ; title : string
  ; children : block_tree list
  }

type local_mutation =
  | Save_block of
      { mutation_id : Graph.Uuid.t
      ; block : Graph.block_uuid
      ; title : string
      }
  | Insert_blocks of
      { mutation_id : Graph.Uuid.t
      ; tree : block_tree
      ; parent : Graph.Uuid.t
      }
  | Delete_blocks of
      { mutation_id : Graph.Uuid.t
      ; root : Graph.block_uuid
      }
  | Create_journal_page of
      { mutation_id : Graph.Uuid.t
      ; page : Graph.page_uuid
      ; title : string
      ; journal_day : int
      }
  | Set_task_status of
      { mutation_id : Graph.Uuid.t
      ; block : Graph.block_uuid
      ; status : task_status
      }
  | Clear_task_status of
      { mutation_id : Graph.Uuid.t
      ; block : Graph.block_uuid
      }

type local_status =
  | Applied
  | No_change
  | Already_applied

type local_commit =
  { mutation_id : Graph.Uuid.t
  ; status : local_status
  ; generation : generation
  ; before_projection_revision : projection_revision
  ; after_projection_revision : projection_revision
  ; logical_change_summary : logical_change_summary
  }

type auxiliary_delete_fact =
  | Comment_area
  | Default_property_holder
  | Rewritten_source_title
  | Timestamp
  | Transaction_metadata

type delete_conflict_kind =
  | Frontier_fact_changed
  | Descendant_closure_changed
  | Incoming_reference_changed
  | Auxiliary_write_footprint_changed of auxiliary_delete_fact
  | Page_lifecycle_changed

type delete_conflict_kind_set = delete_conflict_kind list

let delete_conflict_kind_set values = Ok (List.sort_uniq compare values)
let delete_conflict_kinds values = values

type remote_won_reason =
  | Before_submission
  | Proven_unexecuted

type remote_won_proof =
  remote_won_reason
  * submission_batch_id option
  * server_cursor option
  * server_cursor option
  * server_cursor option
  * int
  * mutation_fingerprint

type remote_won_receipt =
  { mutation_id : Graph.Uuid.t
  ; fingerprint : mutation_fingerprint
  ; reason : remote_won_reason
  ; conflicts : delete_conflict_kind_set
  ; proof : remote_won_proof
  }

type transport_state =
  | Queued
  | Submitted of submission_batch_id
  | Accepted_pending_authoritative of submission_batch_id
  | Delete_barrier_rejected_pending_authoritative of
      { batch_id : submission_batch_id
      ; through : server_cursor
      }
  | Blocked

type block_reason =
  | Rejected
  | Stale_barrier
  | Dependency_blocked of Graph.Uuid.t
  | Authoritative_mismatch
  | Planner_dependency_changed

type blocked_mutation =
  { mutation_id : Graph.Uuid.t
  ; fingerprint : mutation_fingerprint
  ; prior_transport_state : transport_state
  ; reason : block_reason
  ; same_id_retry_eligible : bool
  }

type blocked_discard_commit =
  { mutation_id : Graph.Uuid.t
  ; generation : generation
  ; before_projection_revision : projection_revision
  ; after_projection_revision : projection_revision
  ; logical_change_summary : logical_change_summary
  }

type existing_mutation =
  | Existing_applied of local_commit
  | Existing_remote_won of remote_won_receipt
  | Existing_blocked of blocked_mutation
  | Existing_discarded of blocked_discard_commit

type local_commit_outcome =
  | Local_committed of local_commit
  | Local_existing of existing_mutation

type sync_token = string

let sync_token_equal = String.equal

let sync_token_of_string value =
  let prefix = "sync-token:v1:" in
  if
    String.length value > String.length prefix
    && String.sub value 0 (String.length prefix) = prefix
  then Ok value
  else Error "invalid sync token version"
;;

let sync_token_to_string value = value

type outliner_operation =
  | Save_block_operation
  | Insert_blocks_operation
  | Delete_blocks_operation
  | Create_journal_page_operation
  | Set_task_status_operation
  | Clear_task_status_operation

let remote_won_proof
      ~reason
      ~batch_id
      ~t_before
      ~rejection_through
      ~earliest_conflict_cursor
      ~operation
      ~digest
  =
  let operation_code =
    match operation with
    | Save_block_operation -> 0
    | Insert_blocks_operation -> 1
    | Delete_blocks_operation -> 2
    | Create_journal_page_operation -> 3
    | Set_task_status_operation -> 4
    | Clear_task_status_operation -> 5
  in
  match reason with
  | Before_submission ->
    if
      Option.is_none batch_id
      && Option.is_none t_before
      && Option.is_none rejection_through
      && Option.is_none earliest_conflict_cursor
    then
      Ok
        ( reason
        , batch_id
        , t_before
        , rejection_through
        , earliest_conflict_cursor
        , operation_code
        , digest )
    else Error "before-submission proof contains transport evidence"
  | Proven_unexecuted ->
    if
      Option.is_some batch_id
      && Option.is_some t_before
      && Option.is_some earliest_conflict_cursor
      && operation = Delete_blocks_operation
    then
      Ok
        ( reason
        , batch_id
        , t_before
        , rejection_through
        , earliest_conflict_cursor
        , operation_code
        , digest )
    else Error "proven-unexecuted proof is incomplete or is not a delete"
;;

let remote_won_proof_batch_id (_, value, _, _, _, _, _) = value
let remote_won_proof_t_before (_, _, value, _, _, _, _) = value
let remote_won_proof_rejection_through (_, _, _, value, _, _, _) = value
let remote_won_proof_earliest_conflict_cursor (_, _, _, _, value, _, _) = value

let remote_won_proof_operation (_, _, _, _, _, value, _) =
  match value with
  | 0 -> Save_block_operation
  | 1 -> Insert_blocks_operation
  | 2 -> Delete_blocks_operation
  | 3 -> Create_journal_page_operation
  | 4 -> Set_task_status_operation
  | 5 -> Clear_task_status_operation
  | _ -> invalid_arg "invalid remote-won proof operation"
;;

let remote_won_proof_digest (_, _, _, _, _, _, value) = value

type submission_descriptor =
  { mutation_id : Graph.Uuid.t
  ; fingerprint : mutation_fingerprint
  ; state : transport_state
  ; dependency_eligible : bool
  ; attempt_count : int
  ; plaintext_bytes : int
  ; protected_bytes : int option
  }

type sync_view =
  { token : sync_token
  ; checkpoint : server_cursor
  ; submissions : submission_descriptor list
  }

let sync_view ~token ~checkpoint ~submissions = { token; checkpoint; submissions }
let sync_view_token view = view.token
let sync_view_checkpoint view = view.checkpoint
let sync_view_submissions view = view.submissions

type submission_wire =
  { wire_mutation_id : Graph.Uuid.t
  ; wire_operation : outliner_operation
  ; wire_protected_transaction : string
  }

let submission_wire ~maximum_bytes ~mutation_id ~operation ~protected_transaction =
  let byte_length = String.length protected_transaction in
  if maximum_bytes <= 0
  then Error "maximum_bytes must be positive"
  else if byte_length = 0
  then Error "protected transaction must not be empty"
  else if byte_length > maximum_bytes
  then Error "protected transaction exceeds maximum_bytes"
  else
    Ok
      { wire_mutation_id = mutation_id
      ; wire_operation = operation
      ; wire_protected_transaction = protected_transaction
      }
;;

let submission_wire_mutation_id wire = wire.wire_mutation_id
let submission_wire_operation wire = wire.wire_operation
let submission_wire_protected_transaction wire = wire.wire_protected_transaction
let submission_wire_byte_length wire = String.length wire.wire_protected_transaction

type submission_batch =
  { batch_id : submission_batch_id
  ; t_before : server_cursor
  ; wires : submission_wire list
  ; total_bytes : int
  }

let submission_batch ~maximum_wires ~maximum_bytes ~batch_id ~t_before ~wires =
  let total_bytes =
    List.fold_left (fun total wire -> total + submission_wire_byte_length wire) 0 wires
  in
  if maximum_wires <= 0 || maximum_bytes <= 0
  then Error "submission batch limits must be positive"
  else if wires = []
  then Error "submission batch must not be empty"
  else if List.length wires > maximum_wires
  then Error "submission batch exceeds maximum_wires"
  else if total_bytes > maximum_bytes
  then Error "submission batch exceeds maximum_bytes"
  else Ok { batch_id; t_before; wires; total_bytes }
;;

let submission_batch_id batch = batch.batch_id
let submission_batch_t_before batch = batch.t_before
let submission_batch_wires batch = batch.wires
let submission_batch_total_bytes batch = batch.total_bytes

type acceptance_barrier =
  { through : server_cursor
  ; checksum : checksum
  }

type rejection_member_partition =
  { accepted_prefix : Graph.Uuid.t list
  ; failed_member : Graph.Uuid.t option
  ; unexecuted_suffix : Graph.Uuid.t list
  ; acceptance_barrier : acceptance_barrier option
  ; missing_uuids : Graph.Uuid.t list
  ; diagnostics : string list
  }

type rejection_reason =
  | Invalid_request
  | Permission_denied
  | Missing_dependencies
  | Operational_failure

type rejection_resolution =
  | Stale of { through : server_cursor }
  | Definitive of
      { reason : rejection_reason
      ; partition : rejection_member_partition
      }

type outbox_transition =
  | Submit_group of Graph.Uuid.t list
  | Retry_group of submission_batch_id
  | Accept_group of
      { batch_id : submission_batch_id
      ; barrier : acceptance_barrier
      }
  | Reject_group of
      { batch_id : submission_batch_id
      ; resolution : rejection_resolution
      }

type transition_activity =
  | Logically_active
  | Logically_inactive

type outbox_commit =
  { generation : generation
  ; before_projection_revision : projection_revision
  ; after_projection_revision : projection_revision
  ; sync_token : sync_token
  ; transition : outbox_transition
  ; activity : transition_activity
  ; logical_change_summary : logical_change_summary
  ; submission_batch : submission_batch option
  }

type terminal_transport_disposition =
  | No_transport_owner
  | Clear_transport_owner
  | Retain_terminal_owner_until_response of submission_batch_id

type mutation_receipt =
  | Applied_receipt of
      { mutation_id : Graph.Uuid.t
      ; fingerprint : mutation_fingerprint
      }
  | No_change_receipt of
      { mutation_id : Graph.Uuid.t
      ; fingerprint : mutation_fingerprint
      }
  | Remote_won_receipt of remote_won_receipt
  | Discarded_receipt of
      { mutation_id : Graph.Uuid.t
      ; fingerprint : mutation_fingerprint
      ; prior_reason : block_reason
      }

type terminal_receipt =
  { receipt : mutation_receipt
  ; transport_disposition : terminal_transport_disposition
  }

type authoritative_input_error =
  | Invalid_server_cursor
  | Invalid_encoded_transaction
  | Authoritative_transaction_too_large
  | Authoritative_batch_empty
  | Authoritative_batch_too_large
  | Authoritative_cursor_not_strictly_ordered
  | Authoritative_through_mismatch

type encoded_transaction = string

let encoded_transaction_of_string ~maximum_bytes value =
  if maximum_bytes <= 0 || String.length value = 0
  then Error Invalid_encoded_transaction
  else if String.length value > maximum_bytes
  then Error Authoritative_transaction_too_large
  else Ok value
;;

let encoded_transaction_to_string value = value
let encoded_transaction_byte_length = String.length

type authoritative_transaction =
  { authoritative_cursor : server_cursor
  ; encoded_transaction : encoded_transaction
  }

let authoritative_transaction ~cursor ~transaction =
  { authoritative_cursor = cursor; encoded_transaction = transaction }
;;

let authoritative_transaction_cursor transaction = transaction.authoritative_cursor
let authoritative_transaction_payload transaction = transaction.encoded_transaction

type authoritative_batch =
  { authoritative_transactions : authoritative_transaction list
  ; authoritative_through : server_cursor
  ; _authoritative_checksum : checksum option
  }

let authoritative_batch ~maximum_count ~maximum_bytes ~transactions ~through ~checksum =
  let total_bytes =
    List.fold_left
      (fun total transaction -> total + String.length transaction.encoded_transaction)
      0
      transactions
  in
  if transactions = []
  then Error Authoritative_batch_empty
  else if List.length transactions > maximum_count || total_bytes > maximum_bytes
  then Error Authoritative_batch_too_large
  else if
    not
      (List.for_all2
         (fun left right ->
            Server_cursor.compare left.authoritative_cursor right.authoritative_cursor < 0)
         (List.rev (List.tl (List.rev transactions)))
         (List.tl transactions))
  then Error Authoritative_cursor_not_strictly_ordered
  else if
    not
      (Server_cursor.equal (List.hd (List.rev transactions)).authoritative_cursor through)
  then Error Authoritative_through_mismatch
  else
    Ok
      { authoritative_transactions = transactions
      ; authoritative_through = through
      ; _authoritative_checksum = checksum
      }
;;

let authoritative_batch_transactions batch = batch.authoritative_transactions
let authoritative_batch_through batch = batch.authoritative_through
let authoritative_batch_checksum batch = batch._authoritative_checksum

type authoritative_defer = Await_submission_outcome of submission_batch_id

type authoritative_commit =
  { generation : generation
  ; before_projection_revision : projection_revision
  ; after_projection_revision : projection_revision
  ; checkpoint : server_cursor
  ; sync_token : sync_token
  ; terminal_receipts : terminal_receipt list
  ; replanned_queued_ids : Graph.Uuid.t list
  ; blocked_ids : Graph.Uuid.t list
  ; logical_change_summary : logical_change_summary
  }

type mirror_presence =
  | Absent of { generation : mirror_generation }
  | Available of
      { generation : mirror_generation
      ; graph_uuid : Graph.Uuid.t
      ; checkpoint : server_cursor
      ; checksum : checksum option
      }

type mirror_delete =
  { graph_uuid : Graph.Uuid.t option
  ; previous_generation : mirror_generation
  ; absent_generation : mirror_generation
  }

type garbage_collection =
  { mirror_generation : mirror_generation
  ; reclaimed_bytes : int64
  ; retained_mutation_receipts : int
  ; retained_terminal_batch_receipts : int
  }

type limits_error =
  | Non_positive_limit of string
  | Inconsistent_limits of string

type crypto_result_error =
  | Crypto_result_missing_item of crypto_item_id
  | Crypto_result_extra_item of crypto_item_id
  | Crypto_result_duplicate_item of crypto_item_id
  | Crypto_result_reordered
  | Crypto_result_stale
  | Crypto_result_limit_exceeded

type mirror_error =
  | Invalid_application_support_directory
  | Mirror_location_unavailable of string
  | Mirror_inspection_failed of string

type snapshot_activation_error =
  | Invalid_snapshot_path
  | Invalid_expected_rows
  | Snapshot_input_too_large
  | Mirror_exists
  | Stale_snapshot_inspection
  | Snapshot_state_error
  | Snapshot_crypto_result_error of crypto_result_error
  | Snapshot_crypto_error of string
  | Snapshot_parse_error of string
  | Snapshot_limit_exceeded
  | Snapshot_preparation_canceled
  | Snapshot_commit_stale
  | Snapshot_commit_consumed
  | Snapshot_commit_persistence_failed of string

type mirror_delete_error =
  | Mirror_delete_stale
  | Mirror_delete_busy
  | Mirror_delete_failed of string

type garbage_collection_error =
  | Garbage_collection_stale
  | Garbage_collection_busy
  | Garbage_collection_failed of string

type open_error =
  | Mirror_absent
  | Invalid_graph_name
  | Ownership_conflict
  | Attachment_stale
  | Restore_failed of string
  | Corrupt_authoritative_store of string
  | Corrupt_outbox of string
  | Corrupt_mutation_receipt of string
  | Open_resource_failed of string

type close_error =
  | Close_failed of string
  | Fatal_close of string

type read_error =
  | Database_closed
  | Snapshot_released
  | Snapshot_generation_invalidated
  | Read_limit_exceeded
  | Invalid_read_request of string
  | Fatal_read_state of string

type admission_inspection_error =
  | Admission_database_closed
  | Admission_fatal_state of string

type listen_error =
  | Listen_database_closed
  | Subscription_inactive
  | Subscription_already_active
  | Listen_capacity_unavailable
  | Listen_fatal_state of string

type precondition_error =
  | Duplicate_block_precondition of Graph.block_uuid
  | Duplicate_page_precondition of Graph.page_uuid
  | Duplicate_scope_precondition of structure_revision_scope

type local_commit_error =
  | Local_database_closed
  | Invalid_local_mutation of string
  | Mutation_identity_conflict
  | Missing_precondition of structure_revision_scope option
  | Target_precondition_conflict
  | Planner_limit_exceeded
  | Delete_unsupported_for_footprint
  | Local_commit_busy
  | Local_commit_persistence_failed of string
  | Local_commit_fatal_state of string

type blocked_retry_error =
  | Blocked_retry_database_closed
  | Blocked_mutation_missing
  | Blocked_retry_ineligible
  | Blocked_retry_precondition_conflict
  | Blocked_retry_persistence_failed of string

type blocked_discard_error =
  | Blocked_discard_database_closed
  | Blocked_discard_missing
  | Blocked_discard_persistence_failed of string

type sync_read_error =
  | Sync_database_closed
  | Sync_fatal_state of string

type outbox_transition_error =
  | Outbox_database_closed
  | Outbox_sync_token_conflict
  | Outbox_transition_invalid of string
  | Outbox_dependency_ineligible of Graph.Uuid.t
  | Outbox_delete_requires_singleton
  | Outbox_limit_exceeded
  | Outbox_crypto_required
  | Outbox_crypto_unexpected
  | Outbox_crypto_error of crypto_result_error
  | Outbox_preparation_consumed
  | Outbox_commit_database_closed
  | Outbox_commit_token_conflict
  | Outbox_commit_generation_invalidated
  | Outbox_commit_busy
  | Outbox_commit_persistence_failed of string
  | Outbox_commit_integrity_failure of string

type authoritative_transition_error =
  | Authoritative_database_closed
  | Authoritative_sync_token_conflict
  | Authoritative_cursor_discontinuous
  | Authoritative_checksum_mismatch
  | Authoritative_crypto_required
  | Authoritative_crypto_unexpected
  | Authoritative_crypto_error of crypto_result_error
  | Authoritative_decode_failed of string
  | Authoritative_origin_unresolved
  | Authoritative_preparation_consumed
  | Authoritative_prepare_busy
  | Authoritative_integrity_failure of string
  | Authoritative_commit_database_closed
  | Authoritative_commit_token_conflict
  | Authoritative_commit_generation_invalidated
  | Authoritative_commit_busy
  | Authoritative_commit_persistence_failed of string
  | Authoritative_commit_fatal_state of string
