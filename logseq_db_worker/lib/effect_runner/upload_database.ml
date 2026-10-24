module U = Logseq_db_worker_pure_reducer.Asset_upload
module I = Logseq_db_types.Asset_upload_intent
module A = Logseq_db_types.Asset_descriptor
module D = Logseq_overlay_db.Database
module T = Logseq_overlay_db.Types
module Diagnostic = Logseq_db_types.Failure_diagnostic

let ( let* ) = Result.bind
let reject on_diagnostic reason source =
  let detail = match source with
    | None -> Diagnostic.create ~operation:"assetUpload" ~reason ()
    | Some source -> Diagnostic.of_source ~operation:"assetUpload" ~reason source in
  (* Secondary reporting cannot change the existing upload failure result. *)
  (try on_diagnostic detail with _ -> ());
  Error U.Invalid_content
;;

let map_error on_diagnostic classify = function
  | Ok value -> Ok value
  | Error error -> let reason, source = classify error in reject on_diagnostic reason source
;;

let read on_diagnostic = map_error on_diagnostic (function
  | T.Database_closed | Snapshot_released | Snapshot_generation_invalidated -> "databaseClosed", None
  | Read_limit_exceeded -> "limitExceeded", None
  | Stale_read_cursor -> "staleCommit", None
  | Invalid_read_request source -> "invalidRequest", Some source
  | Fatal_read_state source -> "fatalState", Some source)
;;

let local_result on_diagnostic = map_error on_diagnostic (function
  | T.Local_database_closed -> "databaseClosed", None
  | Invalid_local_mutation source -> "invalidMutation", Some source
  | Mutation_identity_conflict -> "identityConflict", None
  | Missing_precondition _ -> "missingPrecondition", None
  | Target_precondition_conflict -> "preconditionConflict", None
  | Planner_limit_exceeded -> "limitExceeded", None
  | Delete_unsupported_for_footprint -> "unsupportedFootprint", None
  | Local_commit_busy -> "busy", None
  | Local_commit_persistence_failed source -> "persistenceFailed", Some source
  | Local_commit_fatal_state source -> "fatalState", Some source)
;;

let sync_result on_diagnostic = map_error on_diagnostic (function
  | T.Sync_database_closed -> "databaseClosed", None
  | Sync_fatal_state source -> "fatalState", Some source)
;;

let precondition on_diagnostic = map_error on_diagnostic (function
  | T.Duplicate_block_precondition _ | Duplicate_page_precondition _
  | Duplicate_scope_precondition _ -> "preconditionConflict", None)
;;

let local (i : I.t) =
  T.Insert_blocks
    { mutation_id = i.local_mutation
    ; parent = i.target
    ; tree = { uuid = i.asset; title = i.title; children = [] }
    ; asset =
        Some
          { replace_reference = i.replace_reference; version = i.version; size = i.size }
    }
;;

let metadata (i : I.t) =
  T.Publish_asset
    { mutation_id = i.metadata_mutation; block = i.asset; version = i.version }
;;

let snapshot on_diagnostic db f =
  let* s = read on_diagnostic (D.current_snapshot db) in
  Fun.protect ~finally:(fun () -> D.release_snapshot s) (fun () -> f s)
;;

let applied = function
  | Some (T.Existing_applied _) -> true
  | _ -> false
;;

let rejected = function
  | Some (T.Existing_blocked _ | Existing_discarded _ | Existing_remote_won _) -> true
  | _ -> false
;;

let inspect ?(on_diagnostic = fun _ -> ()) db (i : I.t) =
  let* insertion = local_result on_diagnostic (D.inspect_local_mutation db (local i)) in
  let* publication = local_result on_diagnostic (D.inspect_local_mutation db (metadata i)) in
  if rejected insertion || rejected publication
  then Ok U.Entity_cancelled
  else
    let* assets = snapshot on_diagnostic db (fun s -> read on_diagnostic (D.get_asset_descriptors s [ i.asset ])) in
    match assets with
    | [] -> Ok (if applied insertion then U.Entity_cancelled else U.Absent)
    | [ asset ] when asset.current_checksum = Some i.version.checksum ->
      (match asset.source with
       | A.Managed (Some version) when A.equal_version version i.version ->
         let* sync = sync_result on_diagnostic (D.inspect_sync db) in
         let pending =
           List.exists
             (fun (s : T.submission_descriptor) -> s.mutation_id = i.metadata_mutation)
             (T.sync_view_submissions sync)
         in
         Ok
           (if not (applied publication)
            then U.Local_present
            else if not pending
            then U.Publication_acknowledged
            else U.Metadata_present)
       | A.Managed None -> Ok U.Local_present
       | _ -> Ok U.Entity_cancelled)
    | _ -> Ok U.Entity_cancelled
;;

let commit on_diagnostic db mutation expected =
  let* outcome = local_result on_diagnostic (D.commit_local db ~expected mutation) in
  match outcome with
  | T.Local_committed _ | Local_existing (Existing_applied _) -> Ok ()
  | Local_existing _ -> reject on_diagnostic "preconditionConflict" None
;;

let apply_local ?(on_diagnostic = fun _ -> ()) db (i : I.t) =
  let mutation = local i in
  let* receipt = local_result on_diagnostic (D.inspect_local_mutation db mutation) in
  if applied receipt
  then Ok ()
  else if rejected receipt
  then reject on_diagnostic "preconditionConflict" None
  else
    let* expected =
      snapshot on_diagnostic db (fun s ->
        let* pages = read on_diagnostic (D.get_pages s [ i.target ]) in
        let* blocks, pages =
          match pages with
          | [ T.Present_page { revision; _ } ] -> Ok ([], [ i.target, revision ])
          | _ ->
            let* blocks = read on_diagnostic (D.get_outline_blocks s [ i.target ]) in
            (match blocks with
             | [ T.Present_block { revision; _ } ] -> Ok ([ i.target, revision ], [])
             | _ -> reject on_diagnostic "missingPrecondition" None)
        in
        let* structure =
          read on_diagnostic
            (D.get_structure
               s
               (T.Children { parent = i.target; limit = 1; cursor = None }))
        in
        match structure with
        | T.Children_result { revision_scope; scope_revision; _ } ->
          precondition on_diagnostic
            (D.write_precondition
               ~blocks
               ~pages
               ~scopes:[ revision_scope, scope_revision ])
        | _ -> reject on_diagnostic "invalidContent" None)
    in
    commit on_diagnostic db mutation expected
;;

let apply_metadata ?(on_diagnostic = fun _ -> ()) db (i : I.t) =
  let* observation = inspect ~on_diagnostic db i in
  match observation with
  | U.Metadata_present | Publication_acknowledged -> Ok ()
  | Local_present ->
    let* expected =
      snapshot on_diagnostic db (fun s ->
        let* blocks = read on_diagnostic (D.get_outline_blocks s [ i.asset ]) in
        match blocks with
        | [ T.Present_block { revision; _ } ] ->
          precondition on_diagnostic (D.write_precondition ~blocks:[ i.asset, revision ] ~pages:[] ~scopes:[])
        | _ -> reject on_diagnostic "missingPrecondition" None)
    in
    commit on_diagnostic db (metadata i) expected
  | _ -> reject on_diagnostic "missingPrecondition" None
;;
