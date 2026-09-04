module Database = Logseq_overlay_db.Database
module Graph = Logseq_db_types.Graph_types
module Oracle = Naive_projection_oracle
module T = Test_support
module Types = Logseq_overlay_db.Types
open Types

let current_snapshot database behavior f =
  let snapshot = Database.current_snapshot database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot snapshot)
    (fun () -> f snapshot)
;;

let page_precondition database page behavior =
  current_snapshot database behavior (fun snapshot ->
    let page_revision =
      match Database.get_pages snapshot [ page ] |> T.require_ok ~behavior with
      | [ Present_page { revision; _ } ] | [ Missing_page { revision; _ } ] -> revision
      | _ -> Alcotest.fail "page precondition lookup returned the wrong cardinality"
    in
    Database.write_precondition ~blocks:[] ~pages:[ page, page_revision ] ~scopes:[]
    |> T.require_ok ~behavior)
;;

let journal_precondition database page behavior =
  current_snapshot database behavior (fun snapshot ->
    let page_revision =
      match Database.get_pages snapshot [ page ] |> T.require_ok ~behavior with
      | [ Missing_page { revision; _ } ] -> revision
      | _ -> Alcotest.fail "journal page UUID is already present"
    in
    let journals =
      Database.get_journals snapshot ~limit:1 ~cursor:None |> T.require_ok ~behavior
    in
    Database.write_precondition
      ~blocks:[]
      ~pages:[ page, page_revision ]
      ~scopes:[ journals.revision_scope, journals.scope_revision ]
    |> T.require_ok ~behavior)
;;

let block_precondition database block behavior =
  current_snapshot database behavior (fun snapshot ->
    let block_revision =
      match Database.get_blocks snapshot [ block ] |> T.require_ok ~behavior with
      | [ Present_block { revision; _ } ] | [ Missing_block { revision; _ } ] -> revision
      | _ -> Alcotest.fail "block precondition lookup returned the wrong cardinality"
    in
    Database.write_precondition ~blocks:[ block, block_revision ] ~pages:[] ~scopes:[]
    |> T.require_ok ~behavior)
;;

let delete_precondition database block behavior =
  current_snapshot database behavior (fun snapshot ->
    let value, block_revision =
      match Database.get_blocks snapshot [ block ] |> T.require_ok ~behavior with
      | [ Present_block { value; revision } ] -> value, revision
      | _ -> Alcotest.fail "delete target block is missing"
    in
    let scope, scope_revision =
      match
        Database.get_structure
          snapshot
          (Page_tree
             { page = value.block.page; maximum_depth = 256; limit = 200; cursor = None })
        |> T.require_ok ~behavior
      with
      | Page_tree_result { revision_scope; scope_revision; _ } ->
        revision_scope, scope_revision
      | Children_result _ -> Alcotest.fail "page-tree request returned children"
    in
    Database.write_precondition
      ~blocks:[ block, block_revision ]
      ~pages:[]
      ~scopes:[ scope, scope_revision ]
    |> T.require_ok ~behavior)
;;

let insert_precondition database parent behavior =
  current_snapshot database behavior (fun snapshot ->
    let parent_revision =
      match Database.get_pages snapshot [ parent ] |> T.require_ok ~behavior with
      | [ Present_page { revision; _ } ] -> revision
      | _ -> Alcotest.fail "insert parent page is missing"
    in
    let scope, scope_revision =
      match
        Database.get_structure snapshot (Children { parent; limit = 200; cursor = None })
        |> T.require_ok ~behavior
      with
      | Children_result { revision_scope; scope_revision; _ } ->
        revision_scope, scope_revision
      | Page_tree_result _ -> Alcotest.fail "children request returned a page tree"
    in
    Database.write_precondition
      ~blocks:[]
      ~pages:[ parent, parent_revision ]
      ~scopes:[ scope, scope_revision ]
    |> T.require_ok ~behavior)
;;

let block_insert_precondition database parent behavior =
  current_snapshot database behavior (fun snapshot ->
    let parent_revision =
      match Database.get_blocks snapshot [ parent ] |> T.require_ok ~behavior with
      | [ Present_block { revision; _ } ] -> revision
      | _ -> Alcotest.fail "insert parent block is missing"
    in
    let scope, scope_revision =
      match
        Database.get_structure snapshot (Children { parent; limit = 200; cursor = None })
        |> T.require_ok ~behavior
      with
      | Children_result { revision_scope; scope_revision; _ } ->
        revision_scope, scope_revision
      | Page_tree_result _ -> Alcotest.fail "children request returned a page tree"
    in
    Database.write_precondition
      ~blocks:[ parent, parent_revision ]
      ~pages:[]
      ~scopes:[ scope, scope_revision ]
    |> T.require_ok ~behavior)
;;

let commit database expected mutation behavior =
  Database.commit_local database ~expected mutation |> T.require_ok ~behavior
;;

let require_new_commit behavior = function
  | Local_committed commit -> commit
  | Local_existing _ ->
    Alcotest.failf "%s unexpectedly reused an existing mutation" behavior
;;

let insert_is_immediately_readable database =
  let behavior = "pending insert is immediately readable" in
  let expected = insert_precondition database T.page_uuid behavior in
  let commit =
    commit database expected (T.insert_blocks ()) behavior |> require_new_commit behavior
  in
  T.require (commit.status = Applied) "pending insert did not report Applied";
  current_snapshot database behavior (fun snapshot ->
    match Database.get_blocks snapshot [ T.block_uuid ] |> T.require_ok ~behavior with
    | [ Present_block { value; _ } ] ->
      T.require (value.block.title = "Inserted") "pending insert title is not visible"
    | _ -> Alcotest.fail "pending inserted block is not visible")
;;

let duplicate_insert_tree_is_rejected database =
  let behavior = "duplicate insert tree UUID is rejected" in
  let duplicate = T.mutation_uuid 9_001 in
  let mutation =
    Types.Insert_blocks
      { mutation_id = T.mutation_uuid 9_002
      ; parent = T.page_uuid
      ; tree =
          { uuid = duplicate
          ; title = "Root"
          ; children = [ { uuid = duplicate; title = "Duplicate"; children = [] } ]
          }
      }
  in
  match
    Database.commit_local
      database
      ~expected:(insert_precondition database T.page_uuid behavior)
      mutation
  with
  | Error (Types.Invalid_local_mutation message) ->
    T.require
      (String.equal message "insert tree contains duplicate block UUIDs")
      "duplicate tree rejection changed"
  | Error _ | Ok _ -> Alcotest.fail "duplicate insert tree passed planner validation"
;;

let pending_insert_can_be_saved database =
  let behavior = "pending insert can be edited" in
  ignore
    (commit
       database
       (insert_precondition database T.page_uuid behavior)
       (T.insert_blocks ~ordinal:10 ())
       behavior
     |> require_new_commit behavior);
  let expected = block_precondition database T.block_uuid behavior in
  ignore
    (commit
       database
       expected
       (T.save_block ~ordinal:11 ~title:"Edited pending" ())
       behavior
     |> require_new_commit behavior);
  current_snapshot database behavior (fun snapshot ->
    match Database.get_blocks snapshot [ T.block_uuid ] |> T.require_ok ~behavior with
    | [ Present_block { value; _ } ] ->
      T.require
        (value.block.title = "Edited pending")
        "field-level save did not override the pending title"
    | _ -> Alcotest.fail "edited pending block disappeared")
;;

let pending_block_can_receive_an_inserted_child database =
  let behavior = "pending block can receive an inserted child" in
  ignore
    (commit
       database
       (insert_precondition database T.page_uuid behavior)
       (T.insert_blocks ~ordinal:12 ())
       behavior
     |> require_new_commit behavior);
  let mutation =
    Types.Insert_blocks
      { mutation_id = T.mutation_uuid 13
      ; parent = T.block_uuid
      ; tree = { uuid = T.child_uuid; title = "Nested"; children = [] }
      }
  in
  ignore
    (commit
       database
       (block_insert_precondition database T.block_uuid behavior)
       mutation
       behavior
     |> require_new_commit behavior);
  current_snapshot database behavior (fun snapshot ->
    match Database.get_blocks snapshot [ T.child_uuid ] |> T.require_ok ~behavior with
    | [ Present_block { value; _ } ] ->
      T.require
        (Graph.Uuid.equal value.block.parent T.block_uuid)
        "nested block has the wrong parent";
      T.require
        (Graph.Uuid.equal value.block.page T.page_uuid)
        "nested block inherited its parent UUID instead of its page UUID"
    | _ -> Alcotest.fail "nested pending block is not visible")
;;

let pending_insert_can_receive_task_status database =
  let behavior = "pending insert can receive task status" in
  ignore
    (commit
       database
       (insert_precondition database T.page_uuid behavior)
       (T.insert_blocks ~ordinal:20 ())
       behavior
     |> require_new_commit behavior);
  ignore
    (commit
       database
       (block_precondition database T.block_uuid behavior)
       (T.set_task_status ~ordinal:21 ())
       behavior
     |> require_new_commit behavior);
  ignore
    (commit
       database
       (block_precondition database T.block_uuid behavior)
       (T.clear_task_status ~ordinal:22 ())
       behavior
     |> require_new_commit behavior)
;;

let pending_insert_can_be_deleted database =
  let behavior = "pending insert can be deleted" in
  ignore
    (commit
       database
       (insert_precondition database T.page_uuid behavior)
       (T.insert_blocks ~ordinal:30 ())
       behavior
     |> require_new_commit behavior);
  ignore
    (commit
       database
       (delete_precondition database T.block_uuid behavior)
       (T.delete_blocks ~ordinal:31 ())
       behavior
     |> require_new_commit behavior);
  current_snapshot database behavior (fun snapshot ->
    match Database.get_blocks snapshot [ T.block_uuid ] |> T.require_ok ~behavior with
    | [ Missing_block _ ] -> ()
    | _ -> Alcotest.fail "delete tombstone did not hide the pending block")
;;

let journal_creation_uses_missing_page_revision database =
  let behavior = "journal creation requires and uses Missing page revision" in
  let expected = journal_precondition database T.missing_page_uuid behavior in
  ignore
    (commit database expected (T.create_journal_page ()) behavior
     |> require_new_commit behavior);
  current_snapshot database behavior (fun snapshot ->
    match
      Database.get_pages snapshot [ T.missing_page_uuid ] |> T.require_ok ~behavior
    with
    | [ Present_page { value; _ } ] ->
      T.require (value.page.title = "2026-09-02") "journal title is wrong"
    | _ -> Alcotest.fail "created journal is not visible by explicit UUID")
;;

let journal_creation_does_not_require_index_precondition database =
  let behavior = "journal creation uses only its missing-page precondition" in
  let page_only = page_precondition database T.missing_page_uuid behavior in
  ignore
    (commit database page_only (T.create_journal_page ~ordinal:41 ()) behavior
     |> require_new_commit behavior)
;;

let delete_requires_observed_structure_scope database =
  let behavior = "delete requires an observed page-tree or parent scope" in
  ignore
    (commit
       database
       (insert_precondition database T.page_uuid behavior)
       (T.insert_blocks ~ordinal:42 ())
       behavior
     |> require_new_commit behavior);
  match
    Database.commit_local
      database
      ~expected:(block_precondition database T.block_uuid behavior)
      (T.delete_blocks ~ordinal:43 ())
  with
  | Error (Missing_precondition (Some (Page_tree_revision _))) -> ()
  | Error _ -> Alcotest.fail "missing delete scope returned the wrong typed error"
  | Ok _ -> Alcotest.fail "delete accepted only the root block revision"
;;

let missing_preconditions_are_constructor_specific database =
  let behavior = "fresh mutation rejects missing caller-observed preconditions" in
  let empty = T.empty_precondition ~behavior in
  match Database.commit_local database ~expected:empty (T.save_block ~ordinal:40 ()) with
  | Error (Missing_precondition _) -> ()
  | Error _ -> Alcotest.fail "missing precondition returned the wrong typed error"
  | Ok _ -> Alcotest.fail "save without block revision was accepted"
;;

let same_id_same_payload_is_idempotent database =
  let behavior = "same mutation ID and fingerprint is idempotent" in
  let mutation = T.insert_blocks ~ordinal:50 () in
  let first =
    commit database (insert_precondition database T.page_uuid behavior) mutation behavior
    |> require_new_commit behavior
  in
  let duplicate = commit database (T.empty_precondition ~behavior) mutation behavior in
  match duplicate with
  | Local_existing (Existing_applied commit) ->
    T.require (commit.status = Already_applied) "duplicate did not report Already_applied";
    T.require
      (Types.Projection_revision.equal
         commit.before_projection_revision
         commit.after_projection_revision)
      "duplicate advanced projection revision";
    T.require
      (Graph.Uuid.equal first.mutation_id commit.mutation_id)
      "duplicate returned a different mutation ID"
  | _ -> Alcotest.fail "duplicate did not return Existing_applied"
;;

let same_id_different_payload_conflicts database =
  let behavior = "same mutation ID with different payload conflicts" in
  let first = T.insert_blocks ~ordinal:60 () in
  ignore
    (commit database (insert_precondition database T.page_uuid behavior) first behavior
     |> require_new_commit behavior);
  let different =
    Types.Insert_blocks
      { mutation_id = T.mutation_uuid 60
      ; parent = T.page_uuid
      ; tree = { uuid = T.child_uuid; title = "Different"; children = [] }
      }
  in
  match
    Database.commit_local database ~expected:(T.empty_precondition ~behavior) different
  with
  | Error Mutation_identity_conflict -> ()
  | Error _ -> Alcotest.fail "identity conflict returned the wrong typed error"
  | Ok _ -> Alcotest.fail "different payload reused an existing mutation ID"
;;

let semantic_no_op_is_durable_without_advancing_projection database =
  let behavior = "semantic no-op keeps projection stable and is idempotent" in
  let mutation =
    Types.Save_block
      { mutation_id = T.mutation_uuid 70
      ; block = T.missing_block_uuid
      ; title = "Still missing"
      }
  in
  let before =
    current_snapshot database behavior (fun snapshot ->
      Database.snapshot_version snapshot)
  in
  let committed =
    commit
      database
      (block_precondition database T.missing_block_uuid behavior)
      mutation
      behavior
    |> require_new_commit behavior
  in
  T.require (committed.status = No_change) "missing target did not produce No_change";
  T.require
    (Projection_revision.equal
       committed.before_projection_revision
       committed.after_projection_revision)
    "No_change advanced its commit projection revision";
  let after =
    current_snapshot database behavior (fun snapshot ->
      Database.snapshot_version snapshot)
  in
  T.require
    (Projection_revision.equal before.projection_revision after.projection_revision)
    "No_change advanced the database projection revision";
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  T.require (sync_view_submissions view = []) "No_change created an active outbox record";
  match commit database (T.empty_precondition ~behavior) mutation behavior with
  | Local_existing (Existing_applied duplicate) ->
    T.require
      (duplicate.status = Already_applied)
      "No_change duplicate was not idempotent"
  | _ -> Alcotest.fail "No_change receipt was not reused"
;;

let delete_rewrites_external_reference_source database =
  let behavior = "delete applies its complete frozen write footprint" in
  let mutation =
    Types.Delete_blocks
      { mutation_id = T.mutation_uuid 71; root = T.authoritative_block_uuid }
  in
  ignore
    (commit
       database
       (delete_precondition database T.authoritative_block_uuid behavior)
       mutation
       behavior
     |> require_new_commit behavior);
  current_snapshot database behavior (fun snapshot ->
    match
      Database.get_blocks snapshot [ T.authoritative_block_uuid; T.reference_source_uuid ]
      |> T.require_ok ~behavior
    with
    | [ Missing_block _; Present_block { value = source; _ } ] ->
      T.require (source.block.refs = []) "delete left the incoming block/refs fact active";
      T.require
        (String.equal source.block.title "Reference Authoritative block")
        "delete did not freeze and apply the reference-title rewrite"
    | _ -> Alcotest.fail "delete returned the wrong root/source logical records")
;;

let delete_default_property_value_replaces_holders database =
  let behavior = "delete replaces a default-property holder without deleting the value" in
  let mutation =
    Types.Delete_blocks { mutation_id = T.mutation_uuid 72; root = T.default_value_uuid }
  in
  ignore
    (commit
       database
       (delete_precondition database T.default_value_uuid behavior)
       mutation
       behavior
     |> require_new_commit behavior);
  current_snapshot database behavior (fun snapshot ->
    match
      Database.get_blocks snapshot [ T.default_value_uuid; T.property_holder_uuid ]
      |> T.require_ok ~behavior
    with
    | [ Present_block _; Present_block { value = holder; _ } ] ->
      let replacement =
        holder.block.properties
        |> List.find_opt (fun (property : Graph.property_summary) ->
          String.equal property.Graph.ident "test.property/default")
        |> Option.to_list
        |> List.concat_map (fun property -> property.Graph.values)
      in
      T.require
        (replacement = [ Graph.Default_value "00000004-1595-0218-3700-000000000000" ])
        "default-property holder did not receive the empty placeholder"
    | _ ->
      Alcotest.fail
        "default-property delete removed its value or failed to retain its holder")
;;

let malformed_default_property_delete_fails_before_publish database =
  let behavior = "malformed default-property delete fails before publish" in
  let mutation =
    Types.Delete_blocks
      { mutation_id = T.mutation_uuid 73; root = T.malformed_default_value_uuid }
  in
  match
    Database.commit_local
      database
      ~expected:(delete_precondition database T.malformed_default_value_uuid behavior)
      mutation
  with
  | Error Delete_unsupported_for_footprint -> ()
  | Ok _ | Error _ -> Alcotest.fail "malformed default-property delete was admitted"
;;

let deterministic_model_projection_matches_naive_oracle database =
  let behavior = "indexed projection matches the naive model" in
  let random = Random.State.make [| 0x51A7; 0x0DB |] in
  let model = ref Oracle.empty in
  let next_uuid ordinal =
    T.uuid (Printf.sprintf "30000000-0000-4000-8000-%012d" ordinal)
  in
  let apply ordinal mutation expected =
    ignore (commit database expected mutation behavior |> require_new_commit behavior);
    model := Oracle.apply_local !model mutation;
    let expected_blocks =
      !model.Oracle.blocks
      |> List.sort (fun (left : Oracle.block) right ->
        Graph.Uuid.compare left.Oracle.uuid right.Oracle.uuid)
    in
    current_snapshot database behavior (fun snapshot ->
      let actual =
        Database.get_blocks
          snapshot
          (List.map (fun (block : Oracle.block) -> block.Oracle.uuid) expected_blocks)
        |> T.require_ok ~behavior
      in
      List.iter2
        (fun (expected : Oracle.block) actual ->
           match expected.Oracle.deleted, actual with
           | true, Missing_block _ -> ()
           | false, Present_block { value; _ } ->
             T.require
               (String.equal value.block.title expected.title)
               "model title diverged at step %d"
               ordinal;
             T.require
               (Graph.Uuid.equal value.block.parent expected.parent)
               "model parent diverged at step %d"
               ordinal;
             T.require
               (value.task_status = expected.task_status)
               "model task status diverged at step %d"
               ordinal
           | true, Present_block _ | false, Missing_block _ ->
             Alcotest.failf "model visibility diverged at step %d" ordinal)
        expected_blocks
        actual)
  in
  for ordinal = 0 to 15 do
    let uuid = next_uuid ordinal in
    let mutation =
      Types.Insert_blocks
        { mutation_id = T.mutation_uuid (1_000 + ordinal)
        ; parent = T.page_uuid
        ; tree = { uuid; title = Printf.sprintf "Model block %d" ordinal; children = [] }
        }
    in
    apply ordinal mutation (insert_precondition database T.page_uuid behavior)
  done;
  for ordinal = 16 to 79 do
    let visible = Oracle.visible_blocks !model in
    let target : Oracle.block =
      List.nth visible (Random.State.int random (List.length visible))
    in
    let mutation, expected =
      match Random.State.int random 5 with
      | 0 ->
        ( Types.Save_block
            { mutation_id = T.mutation_uuid (1_000 + ordinal)
            ; block = target.uuid
            ; title = Printf.sprintf "Edited model block %d" ordinal
            }
        , block_precondition database target.uuid behavior )
      | 1 ->
        ( Types.Set_task_status
            { mutation_id = T.mutation_uuid (1_000 + ordinal)
            ; block = target.uuid
            ; status = Types.Todo
            }
        , block_precondition database target.uuid behavior )
      | 2 ->
        ( Types.Clear_task_status
            { mutation_id = T.mutation_uuid (1_000 + ordinal); block = target.uuid }
        , block_precondition database target.uuid behavior )
      | 3 ->
        let uuid = next_uuid ordinal in
        ( Types.Insert_blocks
            { mutation_id = T.mutation_uuid (1_000 + ordinal)
            ; parent = target.uuid
            ; tree =
                { uuid; title = Printf.sprintf "Model child %d" ordinal; children = [] }
            }
        , block_insert_precondition database target.uuid behavior )
      | _ ->
        ( Types.Delete_blocks
            { mutation_id = T.mutation_uuid (1_000 + ordinal); root = target.uuid }
        , delete_precondition database target.uuid behavior )
    in
    apply ordinal mutation expected
  done
;;

let cases =
  [ T.database_case "local insert is immediately readable" insert_is_immediately_readable
  ; T.database_case "duplicate insert tree is rejected" duplicate_insert_tree_is_rejected
  ; T.database_case
      "pending insert followed by field-level edit"
      pending_insert_can_be_saved
  ; T.database_case
      "pending block can receive an inserted child"
      pending_block_can_receive_an_inserted_child
  ; T.database_case
      "pending insert supports set and clear task status"
      pending_insert_can_receive_task_status
  ; T.database_case "pending insert can be subtree-deleted" pending_insert_can_be_deleted
  ; T.database_case
      "journal creation uses explicit Missing page revision"
      journal_creation_uses_missing_page_revision
  ; T.database_case
      "journal creation does not require Journal_index revision"
      journal_creation_does_not_require_index_precondition
  ; T.database_case
      "delete requires a structure precondition"
      delete_requires_observed_structure_scope
  ; T.database_case
      "constructor-specific missing preconditions are rejected"
      missing_preconditions_are_constructor_specific
  ; T.database_case
      "same ID and fingerprint bypass stale preconditions"
      same_id_same_payload_is_idempotent
  ; T.database_case
      "same ID with different payload conflicts"
      same_id_different_payload_conflicts
  ; T.database_case
      "semantic no-op is durable without advancing projection"
      semantic_no_op_is_durable_without_advancing_projection
  ; T.database_case
      "delete rewrites external reference source"
      delete_rewrites_external_reference_source
  ; T.database_case
      "delete replaces default-property holders"
      delete_default_property_value_replaces_holders
  ; T.database_case
      "malformed default-property delete fails closed"
      malformed_default_property_delete_fails_before_publish
  ; T.database_case
      "indexed projection matches a deterministic model"
      deterministic_model_projection_matches_naive_oracle
  ]
;;

let () = Alcotest.run "logseq_overlay_db mutations" [ "local planning and commit", cases ]
