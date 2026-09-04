module Graph = Logseq_db_types.Graph_types
module Json = Persistence_json
open Overlay_effect

let ( let* ) = Result.bind

let list_map_result decode values =
  let rec loop reversed = function
    | [] -> Ok (List.rev reversed)
    | value :: rest ->
      let* decoded = decode value in
      loop (decoded :: reversed) rest
  in
  loop [] values
;;

type t =
  { mutation_id : Graph.Uuid.t
  ; fingerprint : string
  ; mutation : Types.local_mutation
  ; normalized_transaction : string
  ; mutable dependency_shadows : dependency_shadows
  ; effect_footprint : footprint
  ; delete_artifacts : delete_artifacts option
  ; intent_time_ms : int64
  ; planned_tx : int
  ; sequence : int
  ; mutable transport_state : Types.transport_state
  ; mutable protected_transaction : string option
  ; mutable attempt_count : int
  ; mutable blocked_prior_state : Types.transport_state option
  ; mutable blocked_reason : Types.block_reason option
  ; mutable same_id_retry_eligible : bool
  ; mutable acceptance_barrier : Types.acceptance_barrier option
  ; mutable submission_t_before : Types.server_cursor option
  ; mutable submission_ordinal : int option
  ; mutable submission_count : int option
  ; mutable observed_origin_cursor : Types.server_cursor option
  ; mutable stale_earliest_conflict_cursor : Types.server_cursor option
  ; mutable stale_conflicts : Types.delete_conflict_kind list
  }

type block_tree_v14 =
  { children : block_tree_v14 list
  ; title : string
  ; uuid : string
  }
[@@deriving yojson]

let rec block_tree_to_dto (tree : Types.block_tree) =
  { children = List.map block_tree_to_dto tree.children
  ; title = tree.title
  ; uuid = Graph.Uuid.to_string tree.uuid
  }
;;

let rec block_tree_of_dto tree =
  let* uuid = Graph.Uuid.of_string tree.uuid in
  let* children = list_map_result block_tree_of_dto tree.children in
  Ok Types.{ uuid; title = tree.title; children }
;;

type save_block_v14 =
  { block : string
  ; mutation_id : string [@key "mutationId"]
  ; title : string
  ; kind : string [@key "type"]
  }
[@@deriving yojson { strict = false }]

type insert_blocks_v14 =
  { mutation_id : string [@key "mutationId"]
  ; parent : string
  ; tree : block_tree_v14
  ; kind : string [@key "type"]
  }
[@@deriving yojson { strict = false }]

type delete_blocks_v14 =
  { mutation_id : string [@key "mutationId"]
  ; root : string
  ; kind : string [@key "type"]
  }
[@@deriving yojson { strict = false }]

type create_journal_page_v14 =
  { journal_day : int [@key "journalDay"]
  ; mutation_id : string [@key "mutationId"]
  ; page : string
  ; title : string
  ; kind : string [@key "type"]
  }
[@@deriving yojson { strict = false }]

type set_task_status_v14 =
  { block : string
  ; mutation_id : string [@key "mutationId"]
  ; status : string
  ; kind : string [@key "type"]
  }
[@@deriving yojson { strict = false }]

type clear_task_status_v14 =
  { block : string
  ; mutation_id : string [@key "mutationId"]
  ; kind : string [@key "type"]
  }
[@@deriving yojson { strict = false }]

let mutation_to_yojson = function
  | Types.Save_block { mutation_id; block; title } ->
    save_block_v14_to_yojson
      { block = Graph.Uuid.to_string block
      ; mutation_id = Graph.Uuid.to_string mutation_id
      ; title
      ; kind = "saveBlock"
      }
  | Insert_blocks { mutation_id; tree; parent } ->
    insert_blocks_v14_to_yojson
      { mutation_id = Graph.Uuid.to_string mutation_id
      ; parent = Graph.Uuid.to_string parent
      ; tree = block_tree_to_dto tree
      ; kind = "insertBlocks"
      }
  | Delete_blocks { mutation_id; root } ->
    delete_blocks_v14_to_yojson
      { mutation_id = Graph.Uuid.to_string mutation_id
      ; root = Graph.Uuid.to_string root
      ; kind = "deleteBlocks"
      }
  | Create_journal_page { mutation_id; page; title; journal_day } ->
    create_journal_page_v14_to_yojson
      { journal_day
      ; mutation_id = Graph.Uuid.to_string mutation_id
      ; page = Graph.Uuid.to_string page
      ; title
      ; kind = "createJournalPage"
      }
  | Set_task_status { mutation_id; block; status } ->
    set_task_status_v14_to_yojson
      { block = Graph.Uuid.to_string block
      ; mutation_id = Graph.Uuid.to_string mutation_id
      ; status = Json.task_status_to_string status
      ; kind = "setTaskStatus"
      }
  | Clear_task_status { mutation_id; block } ->
    clear_task_status_v14_to_yojson
      { block = Graph.Uuid.to_string block
      ; mutation_id = Graph.Uuid.to_string mutation_id
      ; kind = "clearTaskStatus"
      }
;;

let mutation_of_yojson json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String "saveBlock") ->
       let* value = save_block_v14_of_yojson json in
       let* mutation_id = Graph.Uuid.of_string value.mutation_id in
       let* block = Graph.Uuid.of_string value.block in
       Ok (Types.Save_block { mutation_id; block; title = value.title })
     | Some (`String "insertBlocks") ->
       let* value = insert_blocks_v14_of_yojson json in
       let* () =
         match List.assoc_opt "tree" fields with
         | Some tree when tree = block_tree_v14_to_yojson value.tree -> Ok ()
         | _ -> Error "invalid block tree"
       in
       let* mutation_id = Graph.Uuid.of_string value.mutation_id in
       let* parent = Graph.Uuid.of_string value.parent in
       let* tree = block_tree_of_dto value.tree in
       Ok (Types.Insert_blocks { mutation_id; tree; parent })
     | Some (`String "deleteBlocks") ->
       let* value = delete_blocks_v14_of_yojson json in
       let* mutation_id = Graph.Uuid.of_string value.mutation_id in
       let* root = Graph.Uuid.of_string value.root in
       Ok (Types.Delete_blocks { mutation_id; root })
     | Some (`String "createJournalPage") ->
       let* value = create_journal_page_v14_of_yojson json in
       let* mutation_id = Graph.Uuid.of_string value.mutation_id in
       let* page = Graph.Uuid.of_string value.page in
       Ok
         (Types.Create_journal_page
            { mutation_id; page; title = value.title; journal_day = value.journal_day })
     | Some (`String "setTaskStatus") ->
       let* value = set_task_status_v14_of_yojson json in
       let* mutation_id = Graph.Uuid.of_string value.mutation_id in
       let* block = Graph.Uuid.of_string value.block in
       let* status = Json.task_status_of_string value.status in
       Ok (Types.Set_task_status { mutation_id; block; status })
     | Some (`String "clearTaskStatus") ->
       let* value = clear_task_status_v14_of_yojson json in
       let* mutation_id = Graph.Uuid.of_string value.mutation_id in
       let* block = Graph.Uuid.of_string value.block in
       Ok (Types.Clear_task_status { mutation_id; block })
     | _ -> Error "invalid mutation type")
  | _ -> Error "mutation is not an object"
;;

let structure_interest_to_yojson = function
  | Types.Children_interest parent ->
    `Assoc [ "parent", Json.uuid_to_yojson parent; "type", `String "children" ]
  | Page_tree_interest page ->
    `Assoc [ "page", Json.uuid_to_yojson page; "type", `String "pageTree" ]
  | Journal_index_interest -> `Assoc [ "type", `String "journalIndex" ]
;;

let structure_interest_of_yojson = function
  | `Assoc [ ("parent", parent); ("type", `String "children") ] ->
    Result.map (fun parent -> Types.Children_interest parent) (Json.uuid_of_yojson parent)
  | `Assoc [ ("page", page); ("type", `String "pageTree") ] ->
    Result.map (fun page -> Types.Page_tree_interest page) (Json.uuid_of_yojson page)
  | `Assoc [ ("type", `String "journalIndex") ] -> Ok Types.Journal_index_interest
  | _ -> Error "invalid structure interest"
;;

let structure_interests_to_yojson values =
  `List (List.map structure_interest_to_yojson values)
;;

let structure_interests_of_yojson = function
  | `List values -> list_map_result structure_interest_of_yojson values
  | _ -> Error "invalid structure interest list"
;;

type footprint_v14 =
  { blocks : string list
  ; pages : string list
  ; structures :
      (Types.structure_interest list
      [@to_yojson structure_interests_to_yojson]
      [@of_yojson structure_interests_of_yojson])
  }
[@@deriving yojson]

let footprint_to_dto (footprint : footprint) =
  { blocks = List.map Graph.Uuid.to_string footprint.block_uuids
  ; pages = List.map Graph.Uuid.to_string footprint.page_uuids
  ; structures = footprint.structure_interests
  }
;;

let footprint_of_dto footprint =
  let* block_uuids = list_map_result Graph.Uuid.of_string footprint.blocks in
  let* page_uuids = list_map_result Graph.Uuid.of_string footprint.pages in
  Ok { block_uuids; page_uuids; structure_interests = footprint.structures }
;;

let page_kind_to_yojson = function
  | Graph.Ordinary_page -> `Assoc [ "type", `String "ordinary" ]
  | Journal_page { journal_day } ->
    `Assoc [ "journalDay", `Int journal_day; "type", `String "journal" ]
  | Class_page -> `Assoc [ "type", `String "class" ]
  | Property_page -> `Assoc [ "type", `String "property" ]
  | Hidden_page -> `Assoc [ "type", `String "hidden" ]
  | Built_in_page -> `Assoc [ "type", `String "builtIn" ]
;;

let page_kind_of_yojson = function
  | `Assoc [ ("type", `String "ordinary") ] -> Ok Graph.Ordinary_page
  | `Assoc [ ("journalDay", `Int journal_day); ("type", `String "journal") ] ->
    Ok (Graph.Journal_page { journal_day })
  | `Assoc [ ("type", `String "class") ] -> Ok Graph.Class_page
  | `Assoc [ ("type", `String "property") ] -> Ok Graph.Property_page
  | `Assoc [ ("type", `String "hidden") ] -> Ok Graph.Hidden_page
  | `Assoc [ ("type", `String "builtIn") ] -> Ok Graph.Built_in_page
  | _ -> Error "invalid dependency page kind"
;;

type dependency_block_shadow_v14 =
  { created_at_ms : int64 [@key "createdAtMs"] [@encoding `string]
  ; order : string
  ; page : string
  ; parent : string
  ; task_status : string option [@key "taskStatus"]
  ; title : string
  ; updated_at_ms : int64 [@key "updatedAtMs"] [@encoding `string]
  ; uuid : string
  }
[@@deriving yojson]

type dependency_page_shadow_v14 =
  { created_at_ms : int64 [@key "createdAtMs"] [@encoding `string]
  ; kind :
      (Graph.page_kind[@to_yojson page_kind_to_yojson] [@of_yojson page_kind_of_yojson])
  ; name : string
  ; recycled : bool
  ; title : string
  ; updated_at_ms : int64 [@key "updatedAtMs"] [@encoding `string]
  ; uuid : string
  }
[@@deriving yojson]

type dependency_shadows_v14 =
  { blocks : dependency_block_shadow_v14 list
  ; pages : dependency_page_shadow_v14 list
  }
[@@deriving yojson]

let dependency_block_shadow_to_dto (shadow : dependency_block_shadow) =
  { created_at_ms = shadow.shadow_created_at_ms
  ; order = shadow.shadow_order
  ; page = Graph.Uuid.to_string shadow.shadow_page
  ; parent = Graph.Uuid.to_string shadow.shadow_parent
  ; task_status = Option.map Json.task_status_to_string shadow.shadow_task_status
  ; title = shadow.shadow_title
  ; updated_at_ms = shadow.shadow_updated_at_ms
  ; uuid = Graph.Uuid.to_string shadow.shadow_block_uuid
  }
;;

let dependency_block_shadow_of_dto (shadow : dependency_block_shadow_v14) =
  let* shadow_block_uuid = Graph.Uuid.of_string shadow.uuid in
  let* shadow_parent = Graph.Uuid.of_string shadow.parent in
  let* shadow_page = Graph.Uuid.of_string shadow.page in
  let* shadow_task_status =
    match shadow.task_status with
    | None -> Ok None
    | Some value -> Result.map Option.some (Json.task_status_of_string value)
  in
  Ok
    { shadow_block_uuid
    ; shadow_title = shadow.title
    ; shadow_parent
    ; shadow_page
    ; shadow_order = shadow.order
    ; shadow_created_at_ms = shadow.created_at_ms
    ; shadow_updated_at_ms = shadow.updated_at_ms
    ; shadow_task_status
    }
;;

let dependency_page_shadow_to_dto (shadow : dependency_page_shadow) =
  { created_at_ms = shadow.shadow_page_created_at_ms
  ; kind = shadow.shadow_page_kind
  ; name = shadow.shadow_name
  ; recycled = shadow.shadow_recycled
  ; title = shadow.shadow_page_title
  ; updated_at_ms = shadow.shadow_page_updated_at_ms
  ; uuid = Graph.Uuid.to_string shadow.shadow_page_uuid
  }
;;

let dependency_page_shadow_of_dto (shadow : dependency_page_shadow_v14) =
  let* shadow_page_uuid = Graph.Uuid.of_string shadow.uuid in
  Ok
    { shadow_page_uuid
    ; shadow_name = shadow.name
    ; shadow_page_title = shadow.title
    ; shadow_page_kind = shadow.kind
    ; shadow_page_created_at_ms = shadow.created_at_ms
    ; shadow_page_updated_at_ms = shadow.updated_at_ms
    ; shadow_recycled = shadow.recycled
    }
;;

let dependency_shadows_to_dto (shadows : dependency_shadows) =
  { blocks = List.map dependency_block_shadow_to_dto shadows.shadow_blocks
  ; pages = List.map dependency_page_shadow_to_dto shadows.shadow_pages
  }
;;

let dependency_shadows_of_dto (shadows : dependency_shadows_v14) =
  let* shadow_blocks = list_map_result dependency_block_shadow_of_dto shadows.blocks in
  let* shadow_pages = list_map_result dependency_page_shadow_of_dto shadows.pages in
  Ok { shadow_blocks; shadow_pages }
;;

type delete_block_patch_v14 =
  { refs : string list
  ; title : string
  ; updated_at_ms : int64 [@key "updatedAtMs"] [@encoding `string]
  ; uuid : string
  }
[@@deriving yojson]

type delete_page_patch_v14 =
  { updated_at_ms : int64 [@key "updatedAtMs"] [@encoding `string]
  ; uuid : string
  }
[@@deriving yojson]

type delete_property_patch_v14 =
  { holder_uuid : string [@key "holderUuid"]
  ; property_ident : string [@key "propertyIdent"]
  ; replacement_uuid : string [@key "replacementUuid"]
  ; updated_at_ms : int64 [@key "updatedAtMs"] [@encoding `string]
  }
[@@deriving yojson]

type delete_property_guard_v14 =
  { property_ident : string [@key "propertyIdent"]
  ; property_uuid : string [@key "propertyUuid"]
  ; replacement_uuid : string [@key "replacementUuid"]
  }
[@@deriving yojson]

type delete_artifacts_v14 =
  { block_patches : delete_block_patch_v14 list [@key "blockPatches"]
  ; frontier : string list
  ; page_patches : delete_page_patch_v14 list [@key "pagePatches"]
  ; property_guard : delete_property_guard_v14 option [@key "propertyGuard"]
  ; property_patches : delete_property_patch_v14 list [@key "propertyPatches"]
  }
[@@deriving yojson]

let delete_block_patch_to_dto (patch : delete_block_patch) =
  { refs = List.map Graph.Uuid.to_string patch.refs
  ; title = patch.title
  ; updated_at_ms = patch.updated_at_ms
  ; uuid = Graph.Uuid.to_string patch.block_uuid
  }
;;

let delete_block_patch_of_dto (patch : delete_block_patch_v14) =
  let* refs = list_map_result Graph.Uuid.of_string patch.refs in
  let* block_uuid = Graph.Uuid.of_string patch.uuid in
  Ok { block_uuid; title = patch.title; refs; updated_at_ms = patch.updated_at_ms }
;;

let delete_page_patch_to_dto (patch : delete_page_patch) =
  { updated_at_ms = patch.updated_at_ms; uuid = Graph.Uuid.to_string patch.page_uuid }
;;

let delete_page_patch_of_dto (patch : delete_page_patch_v14) =
  let* page_uuid = Graph.Uuid.of_string patch.uuid in
  Ok { page_uuid; updated_at_ms = patch.updated_at_ms }
;;

let delete_property_patch_to_dto (patch : delete_property_patch) =
  { holder_uuid = Graph.Uuid.to_string patch.holder_uuid
  ; property_ident = patch.property_ident
  ; replacement_uuid = Graph.Uuid.to_string patch.replacement_uuid
  ; updated_at_ms = patch.updated_at_ms
  }
;;

let delete_property_patch_of_dto (patch : delete_property_patch_v14) =
  let* holder_uuid = Graph.Uuid.of_string patch.holder_uuid in
  let* replacement_uuid = Graph.Uuid.of_string patch.replacement_uuid in
  Ok
    ({ holder_uuid
     ; property_ident = patch.property_ident
     ; replacement_uuid
     ; updated_at_ms = patch.updated_at_ms
     }
     : delete_property_patch)
;;

let delete_property_guard_to_dto (guard : delete_property_guard) =
  { property_ident = guard.property_ident
  ; property_uuid = Graph.Uuid.to_string guard.property_uuid
  ; replacement_uuid = Graph.Uuid.to_string guard.replacement_uuid
  }
;;

let delete_property_guard_of_dto (guard : delete_property_guard_v14) =
  let* property_uuid = Graph.Uuid.of_string guard.property_uuid in
  let* replacement_uuid = Graph.Uuid.of_string guard.replacement_uuid in
  Ok
    ({ property_uuid; property_ident = guard.property_ident; replacement_uuid }
     : delete_property_guard)
;;

let delete_artifacts_to_dto (artifacts : delete_artifacts) =
  { block_patches = List.map delete_block_patch_to_dto artifacts.block_patches
  ; frontier = List.map Graph.Uuid.to_string artifacts.frontier
  ; page_patches = List.map delete_page_patch_to_dto artifacts.page_patches
  ; property_guard = Option.map delete_property_guard_to_dto artifacts.property_guard
  ; property_patches = List.map delete_property_patch_to_dto artifacts.property_patches
  }
;;

let delete_artifacts_of_dto (artifacts : delete_artifacts_v14) =
  let* frontier = list_map_result Graph.Uuid.of_string artifacts.frontier in
  let* block_patches =
    list_map_result delete_block_patch_of_dto artifacts.block_patches
  in
  let* page_patches = list_map_result delete_page_patch_of_dto artifacts.page_patches in
  let* property_guard =
    match artifacts.property_guard with
    | None -> Ok None
    | Some guard -> Result.map Option.some (delete_property_guard_of_dto guard)
  in
  let* property_patches =
    list_map_result delete_property_patch_of_dto artifacts.property_patches
  in
  Ok
    ({ frontier; block_patches; page_patches; property_guard; property_patches }
     : delete_artifacts)
;;

let transport_state_to_yojson = function
  | Types.Queued -> `Assoc [ "type", `String "queued" ]
  | Submitted id ->
    `Assoc
      [ "batchId", `String (Types.Submission_batch_id.to_string id)
      ; "type", `String "submitted"
      ]
  | Accepted_pending_authoritative id ->
    `Assoc
      [ "batchId", `String (Types.Submission_batch_id.to_string id)
      ; "type", `String "acceptedPendingAuthoritative"
      ]
  | Delete_barrier_rejected_pending_authoritative { batch_id; through } ->
    `Assoc
      [ "batchId", `String (Types.Submission_batch_id.to_string batch_id)
      ; "through", `String (Types.Server_cursor.to_string through)
      ; "type", `String "deleteBarrierRejectedPendingAuthoritative"
      ]
  | Blocked -> `Assoc [ "type", `String "blocked" ]
;;

let transport_state_of_yojson = function
  | `Assoc [ ("type", `String "queued") ] -> Ok Types.Queued
  | `Assoc [ ("batchId", `String id); ("type", `String "submitted") ] ->
    Result.map (fun id -> Types.Submitted id) (Types.Submission_batch_id.of_string id)
  | `Assoc [ ("batchId", `String id); ("type", `String "acceptedPendingAuthoritative") ]
    ->
    Result.map
      (fun id -> Types.Accepted_pending_authoritative id)
      (Types.Submission_batch_id.of_string id)
  | `Assoc
      [ ("batchId", `String id)
      ; ("through", `String through)
      ; ("type", `String "deleteBarrierRejectedPendingAuthoritative")
      ] ->
    let* batch_id = Types.Submission_batch_id.of_string id in
    let* through = Types.Server_cursor.of_string through in
    Ok (Types.Delete_barrier_rejected_pending_authoritative { batch_id; through })
  | `Assoc [ ("type", `String "blocked") ] -> Ok Types.Blocked
  | _ -> Error "invalid transport state"
;;

let optional_transport_state_to_yojson = Json.optional_to_yojson transport_state_to_yojson
let optional_transport_state_of_yojson = Json.optional_of_yojson transport_state_of_yojson
let optional_block_reason_to_yojson = Json.optional_to_yojson Json.block_reason_to_yojson
let optional_block_reason_of_yojson = Json.optional_of_yojson Json.block_reason_of_yojson

type acceptance_barrier_v14 =
  { checksum : string
  ; through : string
  }
[@@deriving yojson]

let acceptance_barrier_to_dto (barrier : Types.acceptance_barrier) =
  { checksum = Types.Checksum.to_string barrier.checksum
  ; through = Types.Server_cursor.to_string barrier.through
  }
;;

let acceptance_barrier_of_dto barrier =
  let* checksum = Types.Checksum.of_string barrier.checksum in
  let* through = Types.Server_cursor.of_string barrier.through in
  Ok Types.{ through; checksum }
;;

type outbox_record_v14 =
  { acceptance_barrier : acceptance_barrier_v14 option [@key "acceptanceBarrier"]
  ; attempt_count : int [@key "attemptCount"]
  ; blocked_prior_state :
      (Types.transport_state option
      [@to_yojson optional_transport_state_to_yojson]
      [@of_yojson optional_transport_state_of_yojson])
        [@key "blockedPriorState"]
  ; blocked_reason :
      (Types.block_reason option
      [@to_yojson optional_block_reason_to_yojson]
      [@of_yojson optional_block_reason_of_yojson])
        [@key "blockedReason"]
  ; fingerprint : string
  ; format_version : int [@key "formatVersion"]
  ; intent_time_ms : int64 [@key "intentTimeMs"] [@encoding `string]
  ; planned_tx : int [@key "plannedTx"]
  ; sequence : int
  ; dependency_shadows : dependency_shadows_v14 [@key "dependencyShadows"]
  ; effect_footprint : footprint_v14 [@key "effectFootprint"]
  ; delete_artifacts : delete_artifacts_v14 option [@key "deleteArtifacts"]
  ; mutation :
      (Types.local_mutation
      [@to_yojson mutation_to_yojson] [@of_yojson mutation_of_yojson])
  ; normalized_transaction : string [@key "normalizedTransaction"]
  ; protected_transaction : string option [@key "protectedTransaction"]
  ; state :
      (Types.transport_state
      [@to_yojson transport_state_to_yojson] [@of_yojson transport_state_of_yojson])
  ; same_id_retry_eligible : bool [@key "sameIdRetryEligible"]
  ; submission_t_before : string option [@key "submissionTBefore"]
  ; submission_ordinal : int option [@key "submissionOrdinal"]
  ; submission_count : int option [@key "submissionCount"]
  ; observed_origin_cursor : string option [@key "observedOriginCursor"]
  ; stale_earliest_conflict_cursor : string option [@key "staleEarliestConflictCursor"]
  ; stale_conflicts : string list [@key "staleConflicts"]
  ; sync_revision : int [@key "syncRevision"]
  }
[@@deriving yojson { strict = false }]

let mutation_id = function
  | Types.Save_block value -> value.mutation_id
  | Insert_blocks value -> value.mutation_id
  | Delete_blocks value -> value.mutation_id
  | Create_journal_page value -> value.mutation_id
  | Set_task_status value -> value.mutation_id
  | Clear_task_status value -> value.mutation_id
;;

let encode ~sync_revision (record : t) =
  ({ acceptance_barrier = Option.map acceptance_barrier_to_dto record.acceptance_barrier
   ; attempt_count = record.attempt_count
   ; blocked_prior_state = record.blocked_prior_state
   ; blocked_reason = record.blocked_reason
   ; fingerprint = record.fingerprint
   ; format_version = 14
   ; intent_time_ms = record.intent_time_ms
   ; planned_tx = record.planned_tx
   ; sequence = record.sequence
   ; dependency_shadows = dependency_shadows_to_dto record.dependency_shadows
   ; effect_footprint = footprint_to_dto record.effect_footprint
   ; delete_artifacts = Option.map delete_artifacts_to_dto record.delete_artifacts
   ; mutation = record.mutation
   ; normalized_transaction = record.normalized_transaction
   ; protected_transaction = record.protected_transaction
   ; state = record.transport_state
   ; same_id_retry_eligible = record.same_id_retry_eligible
   ; submission_t_before =
       Option.map Types.Server_cursor.to_string record.submission_t_before
   ; submission_ordinal = record.submission_ordinal
   ; submission_count = record.submission_count
   ; observed_origin_cursor =
       Option.map Types.Server_cursor.to_string record.observed_origin_cursor
   ; stale_earliest_conflict_cursor =
       Option.map Types.Server_cursor.to_string record.stale_earliest_conflict_cursor
   ; stale_conflicts = List.map Delete_conflict.code record.stale_conflicts
   ; sync_revision
   }
   : outbox_record_v14)
  |> outbox_record_v14_to_yojson
  |> Yojson.Safe.to_string
;;

let optional_token parse = function
  | None -> Ok None
  | Some value -> Result.map Option.some (parse value)
;;

let decode_conflicts values =
  let* conflicts = list_map_result Delete_conflict.of_code values in
  Ok (List.sort_uniq compare conflicts)
;;

let encoded_option encode = Json.optional_to_yojson encode

let field_matches fields name expected =
  match List.assoc_opt name fields with
  | Some actual -> actual = expected
  | None -> false
;;

let nested_values_are_canonical fields dto =
  field_matches
    fields
    "acceptanceBarrier"
    (encoded_option acceptance_barrier_v14_to_yojson dto.acceptance_barrier)
  && field_matches
       fields
       "blockedPriorState"
       (optional_transport_state_to_yojson dto.blocked_prior_state)
  && field_matches
       fields
       "blockedReason"
       (optional_block_reason_to_yojson dto.blocked_reason)
  && field_matches
       fields
       "dependencyShadows"
       (dependency_shadows_v14_to_yojson dto.dependency_shadows)
  && field_matches fields "effectFootprint" (footprint_v14_to_yojson dto.effect_footprint)
  && field_matches
       fields
       "deleteArtifacts"
       (encoded_option delete_artifacts_v14_to_yojson dto.delete_artifacts)
  && field_matches fields "mutation" (mutation_to_yojson dto.mutation)
  && field_matches fields "state" (transport_state_to_yojson dto.state)
;;

let decode source =
  try
    let json = Yojson.Safe.from_string source in
    let* dto = outbox_record_v14_of_yojson json in
    let fields =
      match json with
      | `Assoc fields -> fields
      | _ -> []
    in
    if
      (not (nested_values_are_canonical fields dto))
      || dto.format_version <> 14
      || dto.attempt_count < 0
      || dto.planned_tx < 0
      || dto.sequence <= 0
      || dto.sync_revision < 0
      || String.length dto.fingerprint <> 64
      || String.length dto.normalized_transaction = 0
      || Option.fold ~none:false ~some:(fun value -> value < 0) dto.submission_ordinal
      || Option.fold ~none:false ~some:(fun value -> value < 0) dto.submission_count
    then Error "invalid overlay outbox record"
    else
      let* dependency_shadows = dependency_shadows_of_dto dto.dependency_shadows in
      let* effect_footprint = footprint_of_dto dto.effect_footprint in
      let* delete_artifacts =
        match dto.delete_artifacts with
        | None -> Ok None
        | Some value -> Result.map Option.some (delete_artifacts_of_dto value)
      in
      let* acceptance_barrier =
        match dto.acceptance_barrier with
        | None -> Ok None
        | Some value -> Result.map Option.some (acceptance_barrier_of_dto value)
      in
      let* submission_t_before =
        optional_token Types.Server_cursor.of_string dto.submission_t_before
      in
      let* observed_origin_cursor =
        optional_token Types.Server_cursor.of_string dto.observed_origin_cursor
      in
      let* stale_earliest_conflict_cursor =
        optional_token Types.Server_cursor.of_string dto.stale_earliest_conflict_cursor
      in
      let* stale_conflicts = decode_conflicts dto.stale_conflicts in
      Ok
        ( { mutation_id = mutation_id dto.mutation
          ; fingerprint = dto.fingerprint
          ; mutation = dto.mutation
          ; normalized_transaction = dto.normalized_transaction
          ; dependency_shadows
          ; effect_footprint
          ; delete_artifacts
          ; intent_time_ms = dto.intent_time_ms
          ; planned_tx = dto.planned_tx
          ; sequence = dto.sequence
          ; transport_state = dto.state
          ; protected_transaction = dto.protected_transaction
          ; attempt_count = dto.attempt_count
          ; blocked_prior_state = dto.blocked_prior_state
          ; blocked_reason = dto.blocked_reason
          ; same_id_retry_eligible = dto.same_id_retry_eligible
          ; acceptance_barrier
          ; submission_t_before
          ; submission_ordinal = dto.submission_ordinal
          ; submission_count = dto.submission_count
          ; observed_origin_cursor
          ; stale_earliest_conflict_cursor
          ; stale_conflicts
          }
        , dto.sync_revision )
  with
  | Yojson.Json_error _ | Invalid_argument _ | Failure _ ->
    Error "invalid overlay outbox record"
;;
