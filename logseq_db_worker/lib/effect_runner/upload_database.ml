module U = Logseq_db_worker_pure_reducer.Asset_upload
module I = Logseq_db_types.Asset_upload_intent
module A = Logseq_db_types.Asset_descriptor
module D = Logseq_overlay_db.Database
module T = Logseq_overlay_db.Types

let ( let* ) = Result.bind
let read result = Result.map_error (fun _ -> U.Invalid_content) result

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

let snapshot db f =
  let* s = read (D.current_snapshot db) in
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

let inspect db (i : I.t) =
  let* insertion = read (D.inspect_local_mutation db (local i)) in
  let* publication = read (D.inspect_local_mutation db (metadata i)) in
  if rejected insertion || rejected publication
  then Ok U.Entity_cancelled
  else
    let* assets = snapshot db (fun s -> read (D.get_asset_descriptors s [ i.asset ])) in
    match assets with
    | [] -> Ok (if applied insertion then U.Entity_cancelled else U.Absent)
    | [ asset ] when asset.current_checksum = Some i.version.checksum ->
      (match asset.source with
       | A.Managed (Some version) when A.equal_version version i.version ->
         let* sync = read (D.inspect_sync db) in
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

let commit db mutation expected =
  let* outcome = read (D.commit_local db ~expected mutation) in
  match outcome with
  | T.Local_committed _ | Local_existing (Existing_applied _) -> Ok ()
  | Local_existing _ -> Error U.Invalid_content
;;

let apply_local db (i : I.t) =
  let mutation = local i in
  let* receipt = read (D.inspect_local_mutation db mutation) in
  if applied receipt
  then Ok ()
  else if rejected receipt
  then Error U.Invalid_content
  else
    let* expected =
      snapshot db (fun s ->
        let* pages = read (D.get_pages s [ i.target ]) in
        let* blocks, pages =
          match pages with
          | [ T.Present_page { revision; _ } ] -> Ok ([], [ i.target, revision ])
          | _ ->
            let* blocks = read (D.get_blocks s [ i.target ]) in
            (match blocks with
             | [ T.Present_block { revision; _ } ] -> Ok ([ i.target, revision ], [])
             | _ -> Error U.Invalid_content)
        in
        let* structure =
          read
            (D.get_structure
               s
               (T.Children { parent = i.target; limit = 1; cursor = None }))
        in
        match structure with
        | T.Children_result { revision_scope; scope_revision; _ } ->
          read
            (D.write_precondition
               ~blocks
               ~pages
               ~scopes:[ revision_scope, scope_revision ])
        | _ -> Error U.Invalid_content)
    in
    commit db mutation expected
;;

let apply_metadata db (i : I.t) =
  let* observation = inspect db i in
  match observation with
  | U.Metadata_present | Publication_acknowledged -> Ok ()
  | Local_present ->
    let* expected =
      snapshot db (fun s ->
        let* blocks = read (D.get_blocks s [ i.asset ]) in
        match blocks with
        | [ T.Present_block { revision; _ } ] ->
          read (D.write_precondition ~blocks:[ i.asset, revision ] ~pages:[] ~scopes:[])
        | _ -> Error U.Invalid_content)
    in
    commit db (metadata i) expected
  | _ -> Error U.Invalid_content
;;
