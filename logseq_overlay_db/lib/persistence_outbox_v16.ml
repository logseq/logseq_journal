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

type block_tree_v16 =
  { children : block_tree_v16 list
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

type save_block_v16 =
  { block : string
  ; mutation_id : string
  ; title : string
  }
[@@deriving yojson]

type asset_metadata_v16 =
  { replace_reference : string option
  ; checksum : string
  ; file_type : string
  ; size : int64
  }
[@@deriving yojson]

type insert_blocks_v16 =
  { mutation_id : string
  ; parent : string
  ; tree : block_tree_v16
  ; asset : asset_metadata_v16 option
  }
[@@deriving yojson]

type delete_blocks_v16 =
  { mutation_id : string
  ; root : string
  }
[@@deriving yojson]

type create_journal_page_v16 =
  { journal_day : int
  ; mutation_id : string
  ; page : string
  ; title : string
  }
[@@deriving yojson]

type set_task_status_v16 =
  { block : string
  ; mutation_id : string
  ; status : Json.task_status
  }
[@@deriving yojson]

type clear_task_status_v16 =
  { block : string
  ; mutation_id : string
  }
[@@deriving yojson]

type publish_asset_v16 =
  { mutation_id : string
  ; block : string
  ; checksum : string
  ; file_type : string
  }
[@@deriving yojson]

type asset_reference_v16 =
  { mutation_id : string
  ; block : string
  ; previous : string option
  ; asset : string
  }
[@@deriving yojson]

type mutation_wire =
  | Set_asset_reference of asset_reference_v16
  | Publish_asset of publish_asset_v16
  | Save_block of save_block_v16
  | Insert_blocks of insert_blocks_v16
  | Delete_blocks of delete_blocks_v16
  | Create_journal_page of create_journal_page_v16
  | Set_task_status of set_task_status_v16
  | Clear_task_status of clear_task_status_v16
[@@deriving yojson]

let mutation_to_wire = function
  | Types.Set_asset_reference { mutation_id; block; previous; asset } ->
    Set_asset_reference
      { mutation_id = Graph.Uuid.to_string mutation_id
      ; block = Graph.Uuid.to_string block
      ; previous = Option.map Graph.Uuid.to_string previous
      ; asset = Graph.Uuid.to_string asset
      }
  | Types.Publish_asset { mutation_id; block; version } ->
    Publish_asset
      { mutation_id = Graph.Uuid.to_string mutation_id
      ; block = Graph.Uuid.to_string block
      ; checksum = version.checksum
      ; file_type = version.file_type
      }
  | Types.Save_block { mutation_id; block; title } ->
    Save_block
      { block = Graph.Uuid.to_string block
      ; mutation_id = Graph.Uuid.to_string mutation_id
      ; title
      }
  | Insert_blocks { mutation_id; tree; parent; asset } ->
    Insert_blocks
      { mutation_id = Graph.Uuid.to_string mutation_id
      ; parent = Graph.Uuid.to_string parent
      ; tree = block_tree_to_dto tree
      ; asset =
          Option.map
            (fun (asset : Types.asset_metadata) ->
               { replace_reference =
                   Option.map Graph.Uuid.to_string asset.replace_reference
               ; checksum = asset.version.checksum
               ; file_type = asset.version.file_type
               ; size = asset.size
               })
            asset
      }
  | Delete_blocks { mutation_id; root } ->
    Delete_blocks
      { mutation_id = Graph.Uuid.to_string mutation_id; root = Graph.Uuid.to_string root }
  | Create_journal_page { mutation_id; page; title; journal_day } ->
    Create_journal_page
      { journal_day
      ; mutation_id = Graph.Uuid.to_string mutation_id
      ; page = Graph.Uuid.to_string page
      ; title
      }
  | Set_task_status { mutation_id; block; status } ->
    Set_task_status
      { block = Graph.Uuid.to_string block
      ; mutation_id = Graph.Uuid.to_string mutation_id
      ; status
      }
  | Clear_task_status { mutation_id; block } ->
    Clear_task_status
      { block = Graph.Uuid.to_string block
      ; mutation_id = Graph.Uuid.to_string mutation_id
      }
;;

let mutation_of_wire = function
  | Set_asset_reference value ->
    let* mutation_id = Graph.Uuid.of_string value.mutation_id in
    let* block = Graph.Uuid.of_string value.block in
    let* asset = Graph.Uuid.of_string value.asset in
    let* previous =
      match value.previous with
      | None -> Ok None
      | Some text -> Result.map Option.some (Graph.Uuid.of_string text)
    in
    Ok (Types.Set_asset_reference { mutation_id; block; previous; asset })
  | Publish_asset value ->
    let* mutation_id = Graph.Uuid.of_string value.mutation_id in
    let* block = Graph.Uuid.of_string value.block in
    let* version =
      Logseq_db_types.Asset_descriptor.version
        ~checksum:value.checksum
        ~file_type:value.file_type
    in
    Ok (Types.Publish_asset { mutation_id; block; version })
  | Save_block value ->
    let* mutation_id = Graph.Uuid.of_string value.mutation_id in
    let* block = Graph.Uuid.of_string value.block in
    Ok (Types.Save_block { mutation_id; block; title = value.title })
  | Insert_blocks value ->
    let* mutation_id = Graph.Uuid.of_string value.mutation_id in
    let* parent = Graph.Uuid.of_string value.parent in
    let* tree = block_tree_of_dto value.tree in
    let* asset =
      match value.asset with
      | None -> Ok None
      | Some asset ->
        let* version =
          Logseq_db_types.Asset_descriptor.version
            ~checksum:asset.checksum
            ~file_type:asset.file_type
        in
        let* replace_reference =
          match asset.replace_reference with
          | None -> Ok None
          | Some text -> Result.map Option.some (Graph.Uuid.of_string text)
        in
        if asset.size >= 0L && asset.size <= 104857600L
        then Ok (Some Types.{ replace_reference; version; size = asset.size })
        else Error "Invalid persisted asset size"
    in
    Ok (Types.Insert_blocks { mutation_id; tree; parent; asset })
  | Delete_blocks value ->
    let* mutation_id = Graph.Uuid.of_string value.mutation_id in
    let* root = Graph.Uuid.of_string value.root in
    Ok (Types.Delete_blocks { mutation_id; root })
  | Create_journal_page value ->
    let* mutation_id = Graph.Uuid.of_string value.mutation_id in
    let* page = Graph.Uuid.of_string value.page in
    Ok
      (Types.Create_journal_page
         { mutation_id; page; title = value.title; journal_day = value.journal_day })
  | Set_task_status value ->
    let* mutation_id = Graph.Uuid.of_string value.mutation_id in
    let* block = Graph.Uuid.of_string value.block in
    let status = value.status in
    Ok (Types.Set_task_status { mutation_id; block; status })
  | Clear_task_status value ->
    let* mutation_id = Graph.Uuid.of_string value.mutation_id in
    let* block = Graph.Uuid.of_string value.block in
    Ok (Types.Clear_task_status { mutation_id; block })
;;

let mutation_to_yojson value = mutation_wire_to_yojson (mutation_to_wire value)

let mutation_of_yojson json =
  let* value = mutation_wire_of_yojson json in
  mutation_of_wire value
;;

type structure_interest = Types.structure_interest =
  | Children_interest of Graph.block_uuid
  | Page_tree_interest of Graph.page_uuid
  | Journal_index_interest
[@@deriving yojson]

type structure_interests = structure_interest list [@@deriving yojson]

type footprint_v16 =
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

type dependency_block_shadow_v16 =
  { created_at_ms : int64
  ; order : string
  ; page : string
  ; parent : string
  ; task_status : Json.task_status option
  ; title : string
  ; updated_at_ms : int64
  ; uuid : string
  }
[@@deriving yojson]

type dependency_page_shadow_v16 =
  { created_at_ms : int64
  ; kind : Graph.page_kind
  ; name : string
  ; recycled : bool
  ; title : string
  ; updated_at_ms : int64
  ; uuid : string
  }
[@@deriving yojson]

type dependency_shadows_v16 =
  { blocks : dependency_block_shadow_v16 list
  ; pages : dependency_page_shadow_v16 list
  }
[@@deriving yojson]

let dependency_block_shadow_to_dto (shadow : dependency_block_shadow) =
  { created_at_ms = shadow.shadow_created_at_ms
  ; order = shadow.shadow_order
  ; page = Graph.Uuid.to_string shadow.shadow_page
  ; parent = Graph.Uuid.to_string shadow.shadow_parent
  ; task_status = shadow.shadow_task_status
  ; title = shadow.shadow_title
  ; updated_at_ms = shadow.shadow_updated_at_ms
  ; uuid = Graph.Uuid.to_string shadow.shadow_block_uuid
  }
;;

let dependency_block_shadow_of_dto (shadow : dependency_block_shadow_v16) =
  let* shadow_block_uuid = Graph.Uuid.of_string shadow.uuid in
  let* shadow_parent = Graph.Uuid.of_string shadow.parent in
  let* shadow_page = Graph.Uuid.of_string shadow.page in
  let shadow_task_status = shadow.task_status in
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

let dependency_page_shadow_of_dto (shadow : dependency_page_shadow_v16) =
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

let dependency_shadows_of_dto (shadows : dependency_shadows_v16) =
  let* shadow_blocks = list_map_result dependency_block_shadow_of_dto shadows.blocks in
  let* shadow_pages = list_map_result dependency_page_shadow_of_dto shadows.pages in
  Ok { shadow_blocks; shadow_pages }
;;

type delete_block_patch_v16 =
  { refs : string list
  ; title : string
  ; updated_at_ms : int64
  ; uuid : string
  }
[@@deriving yojson]

type delete_page_patch_v16 =
  { updated_at_ms : int64
  ; uuid : string
  }
[@@deriving yojson]

type delete_property_patch_v16 =
  { holder_uuid : string
  ; property_ident : string
  ; replacement_uuid : string
  ; updated_at_ms : int64
  }
[@@deriving yojson]

type delete_property_guard_v16 =
  { property_ident : string
  ; property_uuid : string
  ; replacement_uuid : string
  }
[@@deriving yojson]

type delete_artifacts_v16 =
  { block_patches : delete_block_patch_v16 list
  ; frontier : string list
  ; page_patches : delete_page_patch_v16 list
  ; property_guard : delete_property_guard_v16 option
  ; property_patches : delete_property_patch_v16 list
  }
[@@deriving yojson]

let delete_block_patch_to_dto (patch : delete_block_patch) =
  { refs = List.map Graph.Uuid.to_string patch.refs
  ; title = patch.title
  ; updated_at_ms = patch.updated_at_ms
  ; uuid = Graph.Uuid.to_string patch.block_uuid
  }
;;

let delete_block_patch_of_dto (patch : delete_block_patch_v16) =
  let* refs = list_map_result Graph.Uuid.of_string patch.refs in
  let* block_uuid = Graph.Uuid.of_string patch.uuid in
  Ok { block_uuid; title = patch.title; refs; updated_at_ms = patch.updated_at_ms }
;;

let delete_page_patch_to_dto (patch : delete_page_patch) =
  { updated_at_ms = patch.updated_at_ms; uuid = Graph.Uuid.to_string patch.page_uuid }
;;

let delete_page_patch_of_dto (patch : delete_page_patch_v16) =
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

let delete_property_patch_of_dto (patch : delete_property_patch_v16) =
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

let delete_property_guard_of_dto (guard : delete_property_guard_v16) =
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

let delete_artifacts_of_dto (artifacts : delete_artifacts_v16) =
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

type transport_state_wire =
  | Queued
  | Submitted of string
  | Accepted_pending_authoritative of string
  | Stale_rejected_pending_authoritative of
      { batch_id : string
      ; through : string
      }
  | Blocked
[@@deriving yojson]

let transport_state_to_wire = function
  | Types.Queued -> Queued
  | Submitted id -> Submitted (Types.Submission_batch_id.to_string id)
  | Accepted_pending_authoritative id ->
    Accepted_pending_authoritative (Types.Submission_batch_id.to_string id)
  | Stale_rejected_pending_authoritative { batch_id; through } ->
    Stale_rejected_pending_authoritative
      { batch_id = Types.Submission_batch_id.to_string batch_id
      ; through = Persistence_json.server_cursor_to_string through
      }
  | Blocked -> Blocked
;;

let transport_state_of_wire = function
  | Queued -> Ok Types.Queued
  | Submitted id ->
    Result.map (fun id -> Types.Submitted id) (Types.Submission_batch_id.of_string id)
  | Accepted_pending_authoritative id ->
    Result.map
      (fun id -> Types.Accepted_pending_authoritative id)
      (Types.Submission_batch_id.of_string id)
  | Stale_rejected_pending_authoritative { batch_id; through } ->
    let* batch_id = Types.Submission_batch_id.of_string batch_id in
    let* through = Persistence_json.server_cursor_of_string through in
    Ok (Types.Stale_rejected_pending_authoritative { batch_id; through })
  | Blocked -> Ok Types.Blocked
;;

type acceptance_barrier_v16 =
  { checksum : string
  ; through : string
  }
[@@deriving yojson]

let acceptance_barrier_to_dto (barrier : Types.acceptance_barrier) =
  { checksum = Types.Checksum.to_string barrier.checksum
  ; through = Persistence_json.server_cursor_to_string barrier.through
  }
;;

let acceptance_barrier_of_dto barrier =
  let* checksum = Types.Checksum.of_string barrier.checksum in
  let* through = Persistence_json.server_cursor_of_string barrier.through in
  Ok Types.{ through; checksum }
;;

type outbox_record_v16 =
  { acceptance_barrier : acceptance_barrier_v16 option
  ; attempt_count : int
  ; blocked_prior_state : transport_state_wire option
  ; blocked_reason : Json.block_reason option
  ; fingerprint : string
  ; format_version : int
  ; intent_time_ms : int64
  ; planned_tx : int
  ; sequence : int
  ; dependency_shadows : dependency_shadows_v16
  ; effect_footprint : footprint_v16
  ; delete_artifacts : delete_artifacts_v16 option
  ; mutation :
      (Types.local_mutation
      [@to_yojson mutation_to_yojson] [@of_yojson mutation_of_yojson])
  ; normalized_transaction : string
  ; protected_transaction : string option
  ; state : transport_state_wire
  ; same_id_retry_eligible : bool
  ; submission_t_before : string option
  ; submission_ordinal : int option
  ; submission_count : int option
  ; observed_origin_cursor : string option
  ; stale_earliest_conflict_cursor : string option
  ; stale_conflicts : Json.delete_conflict_kind list
  ; sync_revision : int
  }
[@@deriving yojson]

let mutation_id = function
  | Types.Save_block value -> value.mutation_id
  | Publish_asset value -> value.mutation_id
  | Set_asset_reference value -> value.mutation_id
  | Insert_blocks value -> value.mutation_id
  | Delete_blocks value -> value.mutation_id
  | Create_journal_page value -> value.mutation_id
  | Set_task_status value -> value.mutation_id
  | Clear_task_status value -> value.mutation_id
;;

let encode ~sync_revision (record : t) =
  ({ acceptance_barrier = Option.map acceptance_barrier_to_dto record.acceptance_barrier
   ; attempt_count = record.attempt_count
   ; blocked_prior_state = Option.map transport_state_to_wire record.blocked_prior_state
   ; blocked_reason = record.blocked_reason
   ; fingerprint = record.fingerprint
   ; format_version = 17
   ; intent_time_ms = record.intent_time_ms
   ; planned_tx = record.planned_tx
   ; sequence = record.sequence
   ; dependency_shadows = dependency_shadows_to_dto record.dependency_shadows
   ; effect_footprint = footprint_to_dto record.effect_footprint
   ; delete_artifacts = Option.map delete_artifacts_to_dto record.delete_artifacts
   ; mutation = record.mutation
   ; normalized_transaction = record.normalized_transaction
   ; protected_transaction = record.protected_transaction
   ; state = transport_state_to_wire record.transport_state
   ; same_id_retry_eligible = record.same_id_retry_eligible
   ; submission_t_before =
       Option.map Persistence_json.server_cursor_to_string record.submission_t_before
   ; submission_ordinal = record.submission_ordinal
   ; submission_count = record.submission_count
   ; observed_origin_cursor =
       Option.map Persistence_json.server_cursor_to_string record.observed_origin_cursor
   ; stale_earliest_conflict_cursor =
       Option.map
         Persistence_json.server_cursor_to_string
         record.stale_earliest_conflict_cursor
   ; stale_conflicts = record.stale_conflicts
   ; sync_revision
   }
   : outbox_record_v16)
  |> outbox_record_v16_to_yojson
  |> Yojson.Safe.to_string
;;

let optional_token parse = function
  | None -> Ok None
  | Some value -> Result.map Option.some (parse value)
;;

let decode source =
  try
    let json = Yojson.Safe.from_string source in
    let* dto =
      Logseq_db_types.Json_codec.decode outbox_record_v16_of_yojson json
      |> Result.map_error (fun error ->
        "unsupported or invalid overlay outbox format: " ^ error)
    in
    if dto.format_version <> 17
    then Error "unsupported overlay outbox JSON format"
    else if
      dto.attempt_count < 0
      || dto.planned_tx < 0
      || dto.sequence <= 0
      || dto.sync_revision < 0
      || String.length dto.fingerprint <> 64
      || String.length dto.normalized_transaction = 0
      || Option.fold ~none:false ~some:(fun value -> value < 0) dto.submission_ordinal
      || Option.fold ~none:false ~some:(fun value -> value < 0) dto.submission_count
    then Error "invalid overlay outbox record"
    else
      let* transport_state = transport_state_of_wire dto.state in
      let* blocked_prior_state =
        match dto.blocked_prior_state with
        | None -> Ok None
        | Some value -> Result.map Option.some (transport_state_of_wire value)
      in
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
        optional_token Persistence_json.server_cursor_of_string dto.submission_t_before
      in
      let* observed_origin_cursor =
        optional_token Persistence_json.server_cursor_of_string dto.observed_origin_cursor
      in
      let* stale_earliest_conflict_cursor =
        optional_token
          Persistence_json.server_cursor_of_string
          dto.stale_earliest_conflict_cursor
      in
      let stale_conflicts = List.sort_uniq compare dto.stale_conflicts in
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
          ; transport_state
          ; protected_transaction = dto.protected_transaction
          ; attempt_count = dto.attempt_count
          ; blocked_prior_state
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
