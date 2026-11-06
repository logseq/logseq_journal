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
    Database.write_precondition ~blocks:[] ~pages:[ page, page_revision ] ~scopes:[]
    |> T.require_ok ~behavior)
;;

let block_precondition database block behavior =
  current_snapshot database behavior (fun snapshot ->
    let block_revision =
      match Database.get_outline_blocks snapshot [ block ] |> T.require_ok ~behavior with
      | [ Present_block { revision; _ } ] | [ Missing_block { revision; _ } ] -> revision
      | _ -> Alcotest.fail "block precondition lookup returned the wrong cardinality"
    in
    Database.write_precondition ~blocks:[ block, block_revision ] ~pages:[] ~scopes:[]
    |> T.require_ok ~behavior)
;;

let delete_precondition database block behavior =
  current_snapshot database behavior (fun snapshot ->
    let block_revision =
      match Database.get_outline_blocks snapshot [ block ] |> T.require_ok ~behavior with
      | [ Present_block { revision; _ } ] -> revision
      | _ -> Alcotest.fail "delete target block is missing"
    in
    Database.write_precondition ~blocks:[ block, block_revision ] ~pages:[] ~scopes:[]
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
      match Database.get_outline_blocks snapshot [ parent ] |> T.require_ok ~behavior with
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
    match Database.get_outline_blocks snapshot [ T.block_uuid ] |> T.require_ok ~behavior with
    | [ Present_block { value; _ } ] ->
      T.require (value.block.title = "Inserted") "pending insert title is not visible"
    | _ -> Alcotest.fail "pending inserted block is not visible")
;;

let duplicate_insert_tree_is_rejected database =
  let behavior = "duplicate insert tree UUID is rejected" in
  let duplicate = T.mutation_uuid 9_001 in
  let mutation =
    Types.Insert_blocks
      { asset = None
      ; mutation_id = T.mutation_uuid 9_002
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
    match Database.get_outline_blocks snapshot [ T.block_uuid ] |> T.require_ok ~behavior with
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
      { asset = None
      ; mutation_id = T.mutation_uuid 13
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
    match Database.get_outline_blocks snapshot [ T.child_uuid ] |> T.require_ok ~behavior with
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
    match Database.get_outline_blocks snapshot [ T.block_uuid ] |> T.require_ok ~behavior with
    | [ Missing_block _ ] -> ()
    | _ -> Alcotest.fail "delete tombstone did not hide the pending block")
;;

let journal_creation_uses_missing_page_revision database =
  let behavior = "journal creation requires and uses Missing page revision" in
  let expected = journal_precondition database T.missing_page_uuid behavior in
  let committed =
    commit database expected (T.create_journal_page ()) behavior
    |> require_new_commit behavior
  in
  let sync = Database.inspect_sync database |> T.require_ok ~behavior in
  let prepared, protection =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token sync)
      (Submit_group [ committed.mutation_id ])
    |> T.require_ok ~behavior
  in
  let encrypted =
    Option.map
      (fun request ->
         ( request
         , List.map
             (fun (id, value) -> id, "encrypted:" ^ value)
             (Database.protection_plaintexts request) ))
      protection
  in
  let submitted =
    Database.apply_outbox_transition database prepared ~encrypted
    |> T.require_ok ~behavior
  in
  let wire = submission_batch_wires (Option.get submitted.submission_batch) |> List.hd in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let has_journal_class =
    match Codec.of_string (submission_wire_protected_transaction wire) with
    | Transit.Array operations ->
      List.exists
        (function
          | Transit.Array
              [ Keyword "db/add"
              ; _
              ; Keyword "block/tags"
              ; Keyword "logseq.class/Journal"
              ] -> true
          | _ -> false)
        operations
    | _ -> false
  in
  T.require
    has_journal_class
    "submitted journal lacks its required Journal classification";
  current_snapshot database behavior (fun snapshot ->
    match
      Database.get_pages snapshot [ T.missing_page_uuid ] |> T.require_ok ~behavior
    with
    | [ Present_page { value; _ } ] ->
      T.require (value.page.title = "2026-09-02") "journal title is wrong";
      (* The imported Logseq schema assigns this stable UUID to Journal. *)
      let journal_class = T.uuid "00000002-1979-7410-8100-000000000000" in
      T.require
        (List.exists (Graph.Uuid.equal journal_class) value.page.tags)
        "created journal lacks the Journal class required by Logseq validation"
    | _ -> Alcotest.fail "created journal is not visible by explicit UUID")
;;

let journal_creation_does_not_require_index_precondition database =
  let behavior = "journal creation uses only its missing-page precondition" in
  let page_only = page_precondition database T.missing_page_uuid behavior in
  ignore
    (commit database page_only (T.create_journal_page ~ordinal:41 ()) behavior
     |> require_new_commit behavior)
;;

let delete_uses_root_revision_and_latest_local_subtree database =
  let behavior = "delete freezes latest local subtree with only root revision" in
  ignore
    (commit
       database
       (insert_precondition database T.page_uuid behavior)
       (Insert_blocks
          { asset = None
          ; mutation_id = T.mutation_uuid 42
          ; parent = T.page_uuid
          ; tree =
              { uuid = T.block_uuid
              ; title = "Root"
              ; children = [ { uuid = T.child_uuid; title = "Child"; children = [] } ]
              }
          })
       behavior
     |> require_new_commit behavior);
  let expected = block_precondition database T.block_uuid behavior in
  let pinned = Database.current_snapshot database |> T.require_ok ~behavior in
  Fun.protect
    ~finally:(fun () -> Database.release_snapshot pinned)
    (fun () ->
       let newer = T.uuid "72000000-0000-4000-8000-000000000001" in
       let grandchild = T.uuid "72000000-0000-4000-8000-000000000002" in
       ignore
         (commit
            database
            (block_insert_precondition database T.child_uuid behavior)
            (Insert_blocks
               { asset = None
               ; mutation_id = T.mutation_uuid 44
               ; parent = T.child_uuid
               ; tree =
                   { uuid = newer
                   ; title = "Later child"
                   ; children =
                       [ { uuid = grandchild; title = "Later grandchild"; children = [] }
                       ]
                   }
               })
            behavior
          |> require_new_commit behavior);
       ignore
         (commit database expected (T.delete_blocks ~ordinal:43 ()) behavior
          |> require_new_commit behavior);
       current_snapshot database behavior (fun snapshot ->
         Database.get_outline_blocks snapshot [ T.block_uuid; T.child_uuid; newer; grandchild ]
         |> T.require_ok ~behavior
         |> List.iter (function
           | Missing_block _ -> ()
           | Present_block _ ->
             Alcotest.fail "latest local descendant survived delete admission"));
       match
         Database.get_outline_blocks pinned [ T.block_uuid; newer ] |> T.require_ok ~behavior
       with
       | [ Present_block _; Missing_block _ ] -> ()
       | _ -> Alcotest.fail "delete changed the earlier snapshot")
;;

let delete_rejects_a_changed_root_revision database =
  let behavior = "delete rejects changed root revision" in
  let expected = block_precondition database T.authoritative_block_uuid behavior in
  ignore
    (commit
       database
       expected
       (Save_block
          { mutation_id = T.mutation_uuid 45
          ; block = T.authoritative_block_uuid
          ; title = "Root changed after observation"
          })
       behavior
     |> require_new_commit behavior);
  match
    Database.commit_local
      database
      ~expected
      (Delete_blocks
         { mutation_id = T.mutation_uuid 46; root = T.authoritative_block_uuid })
  with
  | Error Target_precondition_conflict -> ()
  | Error _ -> Alcotest.fail "changed root returned the wrong conflict"
  | Ok _ -> Alcotest.fail "delete accepted a stale root revision"
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
      { asset = None
      ; mutation_id = T.mutation_uuid 60
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
      Database.get_outline_blocks snapshot [ T.authoritative_block_uuid; T.reference_source_uuid ]
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
      Database.get_outline_blocks snapshot [ T.default_value_uuid; T.property_holder_uuid ]
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
        Database.get_outline_blocks
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
        { asset = None
        ; mutation_id = T.mutation_uuid (1_000 + ordinal)
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
            ; status = Status_uuid T.builtin_todo_uuid
            }
        , block_precondition database target.uuid behavior )
      | 2 ->
        ( Types.Clear_task_status
            { mutation_id = T.mutation_uuid (1_000 + ordinal); block = target.uuid }
        , block_precondition database target.uuid behavior )
      | 3 ->
        let uuid = next_uuid ordinal in
        ( Types.Insert_blocks
            { asset = None
            ; mutation_id = T.mutation_uuid (1_000 + ordinal)
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

let order_of database uuid =
  current_snapshot database "read assigned order" (fun snapshot ->
    match
      Database.get_outline_blocks snapshot [ uuid ] |> T.require_ok ~behavior:"read order"
    with
    | [ Present_block { value; _ } ] -> value.block.order
    | _ -> Alcotest.fail "ordered block is missing")
;;

let append_tree database ~parent ~ordinal tree =
  let behavior = "append ordered tree" in
  let expected =
    current_snapshot database behavior (fun snapshot ->
      match Database.get_pages snapshot [ parent ] |> T.require_ok ~behavior with
      | [ Present_page _ ] -> insert_precondition database parent behavior
      | _ -> block_insert_precondition database parent behavior)
  in
  commit
    database
    expected
    (Insert_blocks { mutation_id = T.mutation_uuid ordinal; parent; tree; asset = None })
    behavior
  |> require_new_commit behavior
;;

let order_uuid index = T.uuid (Printf.sprintf "71000000-0000-4000-8000-%012d" index)

let order_leaf index =
  Types.{ uuid = order_uuid index; title = "Ordered block"; children = [] }
;;

let check_child_orders database parent expected =
  current_snapshot database "read ordered children" (fun snapshot ->
    let rec read cursor acc =
      match
        Database.get_structure snapshot (Children { parent; limit = 1; cursor })
        |> T.require_ok ~behavior:"read paginated sibling orders"
      with
      | Children_result { items; next_cursor; _ } ->
        let acc =
          acc
          @ List.map
              (fun (item : child_member) -> item.block.block.uuid, item.block.block.order)
              items
        in
        (match next_cursor with
         | None -> acc
         | Some _ -> read next_cursor acc)
      | _ -> Alcotest.fail "children returned wrong result"
    in
    let actual = read None [] in
    Alcotest.(check (list (pair string string)))
      "sibling order and pagination"
      (List.map (fun (uuid, order) -> Graph.Uuid.to_string uuid, order) expected)
      (List.map (fun (uuid, order) -> Graph.Uuid.to_string uuid, order) actual);
    List.iter
      (fun (uuid, order) ->
         Alcotest.(check string)
           "block and structure agree"
           order
           (order_of database uuid))
      actual)
;;

let append_orders_follow_existing_tail database =
  let behavior = "append follows authoritative and local tails" in
  (* Update two existing children through the public authoritative boundary. *)
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Codec.to_string
      (Transit.Array
         (List.map
            (fun (uuid, order) ->
               Transit.Array
                 [ Keyword "db/add"
                 ; Array [ Keyword "block/uuid"; Uuid (Graph.Uuid.to_string uuid) ]
                 ; Keyword "block/order"
                 ; String order
                 ])
            [ T.authoritative_block_uuid, "a0"; T.reference_source_uuid, "a1" ]))
  in
  let cursor =
    Server_cursor.of_int64 1L
    |> Result.map_error (fun `Negative_cursor -> "negative cursor")
    |> T.require_ok ~behavior
  in
  let transaction =
    encoded_transaction_of_string ~maximum_bytes:4096 wire |> T.require_ok ~behavior
  in
  let batch =
    authoritative_batch
      ~maximum_count:1
      ~maximum_bytes:4096
      ~transactions:[ authoritative_transaction ~cursor ~transaction ]
      ~through:cursor
      ~checksum:None
    |> T.require_ok ~behavior
  in
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let prepared, crypto =
    Database.begin_authoritative database ~expected:(sync_view_token view) batch
    |> T.require_ok ~behavior
  in
  T.require (crypto = None) "order-only transaction requested decryption";
  ignore
    (Database.apply_authoritative database prepared ~decrypted:None
     |> T.require_ok ~behavior);
  ignore (append_tree database ~parent:T.page_uuid ~ordinal:9001 (order_leaf 1));
  Alcotest.(check string)
    "append after actual authoritative tail"
    "a2"
    (order_of database (order_uuid 1));
  ignore (append_tree database ~parent:T.page_uuid ~ordinal:9002 (order_leaf 2));
  Alcotest.(check string)
    "append includes preceding local insert"
    "a3"
    (order_of database (order_uuid 2));
  ignore
    (commit
       database
       (delete_precondition database (order_uuid 2) behavior)
       (Delete_blocks { mutation_id = T.mutation_uuid 9003; root = order_uuid 2 })
       behavior);
  ignore (append_tree database ~parent:T.page_uuid ~ordinal:9004 (order_leaf 3));
  Alcotest.(check string)
    "deleted local tail is excluded"
    "a3"
    (order_of database (order_uuid 3));
  Alcotest.(check string)
    "existing first order preserved"
    "a0"
    (order_of database T.authoritative_block_uuid);
  Alcotest.(check string)
    "existing second order preserved"
    "a1"
    (order_of database T.reference_source_uuid)
;;

let nested_orders_are_assigned_once database =
  let behavior = "nested order allocation agrees across reads and transaction" in
  let tree =
    Types.
      { (order_leaf 10) with
        children =
          [ { (order_leaf 11) with children = [ order_leaf 14; order_leaf 15 ] }
          ; order_leaf 12
          ; order_leaf 13
          ]
      }
  in
  let first = append_tree database ~parent:T.page_uuid ~ordinal:9010 tree in
  check_child_orders
    database
    (order_uuid 10)
    [ order_uuid 11, "a0"; order_uuid 12, "a1"; order_uuid 13, "a2" ];
  check_child_orders database (order_uuid 11) [ order_uuid 14, "a0"; order_uuid 15, "a1" ];
  let second =
    append_tree database ~parent:(order_uuid 11) ~ordinal:9011 (order_leaf 16)
  in
  check_child_orders
    database
    (order_uuid 11)
    [ order_uuid 14, "a0"; order_uuid 15, "a1"; order_uuid 16, "a2" ];
  let third =
    append_tree database ~parent:(order_uuid 12) ~ordinal:9012 (order_leaf 17)
  in
  check_child_orders database (order_uuid 12) [ order_uuid 17, "a0" ];
  current_snapshot database behavior (fun snapshot ->
    match
      Database.get_structure
        snapshot
        (Page_tree { page = T.page_uuid; maximum_depth = 10; limit = 200; cursor = None })
      |> T.require_ok ~behavior
    with
    | Page_tree_result { items; _ } ->
      List.iter
        (fun index ->
           T.require
             (List.exists
                (fun (item : tree_member) ->
                   Graph.Uuid.equal item.block.block.uuid (order_uuid index))
                items)
             "nested child omitted from page tree")
        [ 10; 11; 12; 13; 14; 15; 16; 17 ]
    | _ -> Alcotest.fail "page tree returned children");
  let view = Database.inspect_sync database |> T.require_ok ~behavior in
  let prepared, request =
    Database.begin_outbox_transition
      database
      ~expected:(sync_view_token view)
      (Submit_group [ first.mutation_id; second.mutation_id; third.mutation_id ])
    |> T.require_ok ~behavior
  in
  let request = Option.get request in
  let encrypted =
    Database.protection_plaintexts request
    |> List.map (fun (id, value) -> id, "encrypted:" ^ value)
  in
  let result =
    Database.apply_outbox_transition
      database
      prepared
      ~encrypted:(Some (request, encrypted))
    |> T.require_ok ~behavior
  in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let orders =
    submission_batch_wires (Option.get result.submission_batch)
    |> List.concat_map (fun wire ->
      match Codec.of_string (submission_wire_protected_transaction wire) with
      | Transit.Array ops ->
        List.filter_map
          (function
            | Transit.Array [ Keyword "db/add"; _; Keyword "block/order"; String order ]
              -> Some order
            | _ -> None)
          ops
      | _ -> Alcotest.fail "transaction is not an array")
  in
  Alcotest.(check (list string))
    "transaction reuses every assigned order"
    (List.map
       (fun index -> order_of database (order_uuid index))
       [ 10; 11; 14; 15; 12; 13; 16; 17 ])
    orders
;;

let append_uses_tail_beyond_first_page database =
  let parent = order_uuid 100 in
  ignore
    (append_tree
       database
       ~parent:T.page_uuid
       ~ordinal:9100
       Types.
         { (order_leaf 100) with
           children = List.init 230 (fun index -> order_leaf (200 + index))
         });
  current_snapshot database "read first sibling page" (fun snapshot ->
    match
      Database.get_structure snapshot (Children { parent; limit = 200; cursor = None })
      |> T.require_ok ~behavior:"read first sibling page"
    with
    | Children_result { items; next_cursor; _ } ->
      T.require
        (List.length items = 200 && Option.is_some next_cursor)
        "wide parent did not paginate"
    | _ -> Alcotest.fail "unexpected structure result");
  ignore (append_tree database ~parent ~ordinal:9101 (order_leaf 500));
  (* Generated directly by the pinned reference for an unbounded batch of 231. *)
  Alcotest.(check string)
    "append uses child 230, not child 200"
    "b2i"
    (order_of database (order_uuid 500))
;;

let orders_survive_reopen_and_outbox_drain () =
  let behavior = "assigned orders survive reopen and outbox drain" in
  T.with_temp_directory "block-order-reopen-" (fun support ->
    ignore (T.seed_mirror support);
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let use f =
          let inspection =
            Database.inspect_mirror
              ~application_support_directory:support
              ~graph_id:T.graph_uuid
            |> T.require_ok ~behavior
          in
          let database =
            Database.open_
              ~sw
              (T.dependencies ~behavior)
              inspection
              ~graph_name:"order-reopen"
            |> T.require_ok ~behavior
          in
          Fun.protect
            ~finally:(fun () ->
              ignore (Database.close database |> T.require_ok ~behavior))
            (fun () -> f database)
        in
        use (fun database ->
          ignore
            (append_tree
               database
               ~parent:T.page_uuid
               ~ordinal:9200
               Types.
                 { (order_leaf 600) with children = [ order_leaf 601; order_leaf 602 ] }));
        use (fun database ->
          check_child_orders
            database
            (order_uuid 600)
            [ order_uuid 601, "a0"; order_uuid 602, "a1" ];
          let module Transit = Transit_core.Json in
          let module Codec = Transit_native.Transit.Json in
          let records =
            current_snapshot database behavior (fun snapshot ->
              Database.get_outline_blocks snapshot (List.map order_uuid [ 600; 601; 602 ])
              |> T.require_ok ~behavior
              |> List.map (function
                | Present_block { value; _ } -> value.block
                | _ -> Alcotest.fail "reopened block missing"))
          in
          let operations =
            records
            |> List.concat_map (fun (block : Graph.block) ->
              let entity = Transit.String (Graph.Uuid.to_string block.uuid) in
              let lookup uuid =
                if
                  List.exists
                    (fun (record : Graph.block) -> Graph.Uuid.equal record.uuid uuid)
                    records
                then Transit.String (Graph.Uuid.to_string uuid)
                else
                  Transit.Array [ Keyword "block/uuid"; Uuid (Graph.Uuid.to_string uuid) ]
              in
              let add attr value =
                Transit.Array [ Keyword "db/add"; entity; Keyword attr; value ]
              in
              [ add "block/uuid" (Uuid (Graph.Uuid.to_string block.uuid))
              ; add "block/title" (String block.title)
              ; add "block/parent" (lookup block.parent)
              ; add "block/page" (lookup block.page)
              ; add "block/order" (String block.order)
              ; add "block/created-at" (Int (Int64.to_int block.created_at_ms))
              ; add "block/updated-at" (Int (Int64.to_int block.updated_at_ms))
              ])
          in
          let transaction =
            Codec.to_string (Transit.Array operations)
            |> encoded_transaction_of_string ~maximum_bytes:16384
            |> T.require_ok ~behavior
          in
          let cursor =
            Server_cursor.of_int64 1L
            |> Result.map_error (fun `Negative_cursor -> "negative cursor")
            |> T.require_ok ~behavior
          in
          let batch =
            authoritative_batch
              ~maximum_count:1
              ~maximum_bytes:16384
              ~transactions:[ authoritative_transaction ~cursor ~transaction ]
              ~through:cursor
              ~checksum:None
            |> T.require_ok ~behavior
          in
          let sync = Database.inspect_sync database |> T.require_ok ~behavior in
          let prepared, request =
            Database.begin_authoritative database ~expected:(sync_view_token sync) batch
            |> T.require_ok ~behavior
          in
          let decrypted =
            Option.map
              (fun request -> request, Database.unprotection_ciphertexts request)
              request
          in
          ignore
            (match Database.apply_authoritative database prepared ~decrypted with
             | Error
                 ( Authoritative_decode_failed message
                 | Authoritative_integrity_failure message
                 | Authoritative_commit_fatal_state message ) -> Alcotest.fail message
             | result -> T.require_ok ~behavior result);
          let sync = Database.inspect_sync database |> T.require_ok ~behavior in
          T.require
            (sync_view_submissions sync = [])
            "equivalent authoritative tree did not drain queued insert";
          check_child_orders
            database
            (order_uuid 600)
            [ order_uuid 601, "a0"; order_uuid 602, "a1" ];
          ignore
            (append_tree database ~parent:(order_uuid 600) ~ordinal:9201 (order_leaf 603));
          Alcotest.(check string)
            "outbox sequence restart cannot reset order"
            "a2"
            (order_of database (order_uuid 603))))))
;;

let custom_status_writes_exact_reference database =
  let behavior = "custom status writes exact UUID and preserves properties" in
  T.seed_task_statuses database;
  let command n status =
    Set_task_status
      { mutation_id = T.mutation_uuid n
      ; block = T.authoritative_block_uuid
      ; status = Status_uuid status
      }
  in
  let expected = block_precondition database T.authoritative_block_uuid behavior in
  List.iter
    (fun status ->
       match Database.commit_local database ~expected (command 890 status) with
       | Error (Invalid_local_mutation _) -> ()
       | _ -> Alcotest.fail "missing or wrong-property status was selectable")
    [ T.missing_block_uuid; T.default_value_uuid; T.page_uuid ];
  let mutation = command 891 (T.status_uuid 1) in
  ignore (T.commit_mutation database ~expected mutation ~behavior);
  (match T.commit_mutation database ~expected mutation ~behavior with
   | Local_existing _ -> ()
   | _ -> Alcotest.fail "status same-id retry changed identity");
  current_snapshot database behavior (fun snapshot ->
    match
      Database.get_outline_blocks snapshot [ T.authoritative_block_uuid ]
      |> T.require_ok ~behavior
    with
    | [ Present_block { value; _ } ] ->
      T.require
        (value.task_status = Some (Status_uuid (T.status_uuid 1)))
        "custom status not retained";
      let property =
        List.find
          (fun (p : Graph.property_summary) -> p.ident = "logseq.property/status")
          value.block.properties
      in
      T.require
        (property.values = [ Default_value (Graph.Uuid.to_string (T.status_uuid 1)) ])
        "saved property reference differs from chosen UUID";
      T.require (value.block.title = "Authoritative block") "status changed block source"
    | _ -> Alcotest.fail "status mutation removed block");
  let expected = block_precondition database T.authoritative_block_uuid behavior in
  ignore
    (T.commit_mutation
       database
       ~expected
       (Clear_task_status
          { mutation_id = T.mutation_uuid 892; block = T.authoritative_block_uuid })
       ~behavior);
  current_snapshot database behavior (fun snapshot ->
    match
      Database.get_outline_blocks snapshot [ T.authoritative_block_uuid ]
      |> T.require_ok ~behavior
    with
    | [ Present_block { value; _ } ] ->
      T.require (value.task_status = None) "explicit clear failed"
    | _ -> Alcotest.fail "cleared block missing");
  T.apply_test_transaction
    database
    ~cursor:2
    [ T.status_add
        (T.status_lookup (T.status_uuid 2))
        "block/closed-value-property"
        (Transit_core.Json.Keyword "logseq.property/status")
    ];
  ignore
    (T.commit_mutation
       database
       ~expected:(delete_precondition database (T.status_uuid 2) behavior)
       (Delete_blocks { mutation_id = T.mutation_uuid 893; root = T.status_uuid 2 })
       ~behavior);
  match
    Database.commit_local
      database
      ~expected:(block_precondition database T.authoritative_block_uuid behavior)
      (command 894 (T.status_uuid 2))
  with
  | Error (Invalid_local_mutation _) -> ()
  | _ -> Alcotest.fail "locally deleted status remained selectable"
;;

let atomic_append_reuses_day_and_full_tree ?(remote=false) database =
  T.seed_task_statuses database;
  let behavior="atomic append resolves day and complete status tree" in
  let page=T.page_uuid and candidate=T.mutation_uuid 7701 in
  let day=20260902 in
  let existing=T.create_journal_page ~ordinal:7700 () in
  let existing_page=match existing with Create_journal_page{page;_}->page|_->assert false in
  if remote then (
    let module J=Transit_core.Json in
    let page=J.String "web-created-day" in
    let add attribute value=T.status_add page attribute value in
    T.apply_test_transaction database ~cursor:2
      [add "block/uuid" (J.Uuid(Graph.Uuid.to_string existing_page));
       add "block/title" (J.String "Web journal");add "block/name" (J.String "web-journal");
       add "block/journal-day" (J.Int day)])
  else ignore(Database.commit_local database ~expected:(journal_precondition database existing_page behavior)
    existing |> T.require_ok ~behavior);
  let root:Types.append_node={uuid=T.mutation_uuid 7702;title="Atomic root";
    task_status=Some(T.status_uuid 2);children=Rrbvec.singleton
      {uuid=T.mutation_uuid 7703;title="Nested status";task_status=Some(T.status_uuid 3);children=Rrbvec.empty}} in
  let mutation=Types.Append_journal{mutation_id=T.mutation_uuid 7704;page=candidate;title="Fallback journal";journal_day=day;root} in
  let expected=Database.write_precondition ~blocks:[] ~pages:[] ~scopes:[] |> T.require_ok ~behavior in
  let intent=Database.persist_local_intent database ~namespace:(String.make 64 'a') ~payload:"atomic append complete payload"
    ~expected mutation |> T.require_ok ~behavior in
  let proof=match Database.commit_local_intent database intent with
    | Ok proof->proof
    | Error(Types.Invalid_local_mutation message|Local_commit_persistence_failed message)->Alcotest.fail message
    | Error Planner_limit_exceeded->Alcotest.fail "Append exceeded planner bounds"
    | Error _->Alcotest.fail "Append failed before atomic commit" in
  let original=Database.intent_commit_outcome proof in
  if not remote then (
    let sync=Database.inspect_sync database |> T.require_ok ~behavior in
    match Database.begin_outbox_transition database ~expected:(Types.sync_view_token sync)
      (Types.Submit_group [original.mutation_id]) with
    | Error(Types.Outbox_dependency_ineligible id) when id=original.mutation_id->()
    | _->Alcotest.fail "append submitted before the unresolved local day owner");
  (* The public immutable-snapshot query owns journal candidate hydration;
     checking mutation receipts alone misses the ordinary Timeline read. *)
  current_snapshot database behavior(fun snapshot->
    let journals=Database.get_journals snapshot ~from_day:day ~through_day:day ~limit:1 ~cursor:None
      |> T.require_ok ~behavior in
    T.require(List.length journals.items=1 && (List.hd journals.items).page.page.uuid=existing_page)
      "Append lost the existing day's journal catalog entry";
    (match Database.get_pages snapshot [candidate;existing_page;page] |> T.require_ok ~behavior with
     | Missing_page _::Present_page _::_->()|_->Alcotest.fail "append created a second journal page");
    match Database.get_outline_blocks snapshot [root.uuid;T.mutation_uuid 7703] |> T.require_ok ~behavior with
    | [Present_block{value=root_value;_};Present_block{value=child;_}]->
      T.require(root_value.block.parent=existing_page && root_value.block.page=existing_page)
        "append did not reuse the existing day owner";
      T.require(root_value.block.title=root.title && root_value.task_status=Some(Status_uuid(T.status_uuid 2)))
        "append root status/source was not atomic";
      T.require(child.block.parent=root.uuid && child.block.page=existing_page
        && child.task_status=Some(Status_uuid(T.status_uuid 3))) "append nested status/tree was incomplete"
    | _->Alcotest.fail "append lost its complete tree");
  Database.acknowledge_local_intent database proof |> T.require_ok ~behavior;
  let again=Database.commit_local_intent database intent |> T.require_ok ~behavior in
  T.require(Database.intent_commit_outcome again=original) "append retry changed original evidence"
;;

let atomic_append_rejects_sparse_identity ~candidate database =
  let behavior="append never upserts a sparse existing identity" in
  let occupied=T.mutation_uuid 7784 in
  let module J=Transit_core.Json in
  let entity=J.String "existing-sparse-entity" in
  T.apply_test_transaction database ~cursor:1
    [T.status_add entity "block/uuid" (J.Uuid(Graph.Uuid.to_string occupied));
     T.status_add entity "block/title" (J.String "Existing sparse")];
  let expected=Database.write_precondition ~blocks:[] ~pages:[] ~scopes:[] |> T.require_ok ~behavior in
  let root:Types.append_node={uuid=(if candidate then T.mutation_uuid 7785 else occupied);title="Must not upsert";
    task_status=None;children=Rrbvec.empty} in
  let mutation=Types.Append_journal{mutation_id=T.mutation_uuid 7786;
    page=(if candidate then occupied else T.mutation_uuid 7785);title="Must not replace";journal_day=20261102;root} in
  let before=Database.inspect_sync database |> T.require_ok ~behavior in
  (match Database.commit_local database ~expected mutation with
   | Error(Types.Invalid_local_mutation _)->()
   | _->Alcotest.fail "append admitted an existing sparse UUID");
  let after=Database.inspect_sync database |> T.require_ok ~behavior in
  T.require(Types.sync_view_submissions before=Types.sync_view_submissions after)
    "rejected sparse identity changed durable outbox"
;;

let atomic_append_rejects_invalid_day database =
  let behavior="append validates a real Gregorian day" in
  let expected=Database.write_precondition ~blocks:[] ~pages:[] ~scopes:[] |> T.require_ok ~behavior in
  let root:Types.append_node={uuid=T.mutation_uuid 7781;title="Invalid day";task_status=None;children=Rrbvec.empty} in
  let mutation=Types.Append_journal{mutation_id=T.mutation_uuid 7782;page=T.mutation_uuid 7783;title="Invalid day";
    journal_day=20260230;root} in
  T.require(Result.is_error(Database.persist_local_intent database ~namespace:(String.make 64 'e')
    ~payload:"invalid append day" ~expected mutation)) "append admitted February 30"
;;

let atomic_append_keeps_existing_tree_budget database =
  let behavior="atomic append preserves the existing 2000-node protocol budget" in
  let root:Types.append_node={uuid=T.mutation_uuid 30000;title="Large append";task_status=None;
    children=Rrbvec.init 1999(fun index->{uuid=T.mutation_uuid(30001+index);title="Child";
      task_status=None;children=Rrbvec.empty})} in
  let mutation=Types.Append_journal{mutation_id=T.mutation_uuid 33000;page=T.mutation_uuid 33001;
    title="Large day";journal_day=20261102;root} in
  let expected=Database.write_precondition ~blocks:[] ~pages:[] ~scopes:[] |> T.require_ok ~behavior in
  let intent=Database.persist_local_intent database ~namespace:(String.make 64 'd') ~payload:"complete large append"
    ~expected mutation |> T.require_ok ~behavior in
  let proof=Database.commit_local_intent database intent |> T.require_ok ~behavior in
  T.require(Rrbvec.length(Database.intent_commit_targets proof)=2000) "append truncated its durable target tree";
  current_snapshot database behavior(fun snapshot->
    let selected=Rrbvec.to_seq root.children |> Seq.take 64 |> Seq.map(fun(node:Types.append_node)->node.uuid) |> List.of_seq in
    Gc.full_major();
    let allocated_before=Gc.allocated_bytes() in
    let values=Database.get_outline_blocks snapshot selected |> T.require_ok ~behavior in
    let allocated=Gc.allocated_bytes()-.allocated_before in
    T.require(List.length values=64) "large append lost bounded point reads";
    T.require(allocated<64.*.1024.*.1024.) "bounded Append hydration repeatedly decoded the entire transaction";
    match Database.get_structure snapshot(Children{parent=root.uuid;limit=200;cursor=None}) |> T.require_ok ~behavior with
    | Children_result{items;next_cursor=Some _;_}->
      T.require(List.length items=200) "large append did not preserve a bounded Partial child page"
    | _->Alcotest.fail "large append pretended its first child page was complete")
;;

let cases =
  [ T.database_case "atomic append preserves tree node budget" atomic_append_keeps_existing_tree_budget
    ; T.database_case "atomic append rejects sparse root identity" (atomic_append_rejects_sparse_identity ~candidate:false)
    ; T.database_case "atomic append rejects sparse page identity" (atomic_append_rejects_sparse_identity ~candidate:true)
    ; T.database_case "atomic append validates Gregorian day" atomic_append_rejects_invalid_day
    ; T.database_case "atomic append resolves existing day and full tree" (atomic_append_reuses_day_and_full_tree ~remote:false)
    ; T.database_case "atomic append resolves Web-created day" (atomic_append_reuses_day_and_full_tree ~remote:true)
    ; T.database_case
      "custom status UUID mutation and explicit clear"
      custom_status_writes_exact_reference
  ; T.database_case
      "delete rejects changed root revision"
      delete_rejects_a_changed_root_revision
  ; T.database_case
      "append uses tail beyond first page"
      append_uses_tail_beyond_first_page
  ; Alcotest.test_case
      "orders survive reopen and outbox drain"
      `Quick
      orders_survive_reopen_and_outbox_drain
  ; T.database_case
      "append orders follow existing tail"
      append_orders_follow_existing_tail
  ; T.database_case "nested orders are assigned once" nested_orders_are_assigned_once
  ; T.database_case "local insert is immediately readable" insert_is_immediately_readable
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
      "delete uses root revision and latest local subtree"
      delete_uses_root_revision_and_latest_local_subtree
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

let durable_intent_keeps_original_commit database =
  let behavior = "durable intent preserves original commit point" in
  let expected = block_precondition database T.authoritative_block_uuid behavior in
  let mutation =
    Types.Save_block
      { mutation_id = T.mutation_uuid 7601
      ; block = T.authoritative_block_uuid
      ; title = "Durable original edit"
      }
  in
  let namespace = String.make 64 'a' in
  let intent =
    Database.persist_local_intent
      database
      ~namespace
      ~payload:"complete stable wire payload"
      ~expected
      mutation
    |> T.require_ok ~behavior
  in
  Alcotest.(check bool)
    "prepared intent has no invented receipt"
    true
    (Database.inspect_local_intent database intent
     |> T.require_ok ~behavior
     = Database.Intent_pending);
  let committed =
    Database.commit_local_intent database intent |> T.require_ok ~behavior
  in
  let original = Database.intent_commit_outcome committed in
  let fresh = block_precondition database T.authoritative_block_uuid behavior in
  ignore
    (Database.commit_local
       database
       ~expected:fresh
       (Types.Save_block
          { mutation_id = T.mutation_uuid 7602
          ; block = T.authoritative_block_uuid
          ; title = "Later independent edit"
          })
     |> T.require_ok ~behavior);
  let repeated = Database.commit_local_intent database intent |> T.require_ok ~behavior in
  Alcotest.(check bool)
    "retry retains exact original outcome"
    true
    (Database.intent_commit_outcome repeated = original);
  Alcotest.(check bool)
    "preconditions are part of durable identity"
    true
    (Result.is_error
       (Database.persist_local_intent
          database
          ~namespace
          ~payload:"complete stable wire payload"
          ~expected:fresh
          mutation));
  Alcotest.(check bool)
    "wire payload is part of durable identity"
    true
    (Result.is_error
       (Database.persist_local_intent
          database
          ~namespace
          ~payload:"changed wire payload"
          ~expected
          mutation));
  let targets = Database.intent_commit_targets committed |> Rrbvec.to_list in
  Alcotest.(check bool)
    "receipt names its actual canonical target"
    true
    (targets = [ T.authoritative_block_uuid ]);
  let pending =
    Database.pending_local_intents database ~namespace ~after:None ~limit:1
    |> T.require_ok ~behavior
  in
  Alcotest.(check int)
    "prepared or committed unacknowledged intent remains recoverable"
    1
    (List.length pending.items);
  Database.acknowledge_local_intent database committed |> T.require_ok ~behavior;
  let pending =
    Database.pending_local_intents database ~namespace ~after:None ~limit:1
    |> T.require_ok ~behavior
  in
  Alcotest.(check int)
    "ack settles recovery without erasing proof"
    0
    (List.length pending.items);
  let stored =
    match Database.inspect_local_intent database intent |> T.require_ok ~behavior with
    | Database.Intent_committed proof -> proof
    | _ -> Alcotest.fail "committed evidence missing"
  in
  Alcotest.(check bool)
    "ack cannot erase original proof"
    true
    (Database.intent_commit_outcome stored = original)
;;

let durable_intent_survives_restart_and_rollback ?(append=false) () =
  let behavior = "durable intent atomicity and restart" in
  T.with_temp_directory "durable-intent-reopen-" (fun support ->
    let path = T.seed_mirror support in
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let use f =
          let inspection =
            Database.inspect_mirror
              ~application_support_directory:support
              ~graph_id:T.graph_uuid
            |> T.require_ok ~behavior
          in
          let database =
            Database.open_
              ~sw
              (T.dependencies ~behavior)
              inspection
              ~graph_name:"durable-intent"
            |> T.require_ok ~behavior
          in
          Fun.protect
            ~finally:(fun () ->
              ignore (Database.close database |> T.require_ok ~behavior))
            (fun () -> f database)
        in
        let sql command =
          let sqlite = Sqlite3.db_open ~mode:`NO_CREATE path in
          Fun.protect
            ~finally:(fun () -> ignore (Sqlite3.db_close sqlite))
            (fun () -> Sqlite3.Rc.check (Sqlite3.exec sqlite command))
        in
        let namespace = String.make 64 'b' in
        let original =
          use (fun database ->
            let expected =
              block_precondition database T.authoritative_block_uuid behavior
            in
            let intent =
              Database.persist_local_intent
                database
                ~namespace
                ~payload:"stable restart payload"
                ~expected
                (if append then Types.Append_journal
                   {mutation_id=T.mutation_uuid 7610;page=T.mutation_uuid 7720;title="New atomic day";journal_day=20261102;
                    root={uuid=T.mutation_uuid 7721;title="New atomic root";task_status=None;children=Rrbvec.singleton
                      {uuid=T.mutation_uuid 7722;title="New atomic child";task_status=None;children=Rrbvec.empty}}}
                 else Save_block {mutation_id=T.mutation_uuid 7610;block=T.authoritative_block_uuid;title="Atomic restart edit"})
              |> T.require_ok ~behavior
            in
            let before =
              current_snapshot database behavior (fun snapshot ->
                Database.graph_info snapshot |> T.require_ok ~behavior)
            in
            sql
              "CREATE TRIGGER reject_intent_commit BEFORE UPDATE OF evidence ON \
               overlay_intents_v1 BEGIN SELECT RAISE(ABORT, 'synthetic evidence write \
               failure'); END";
            (match Database.commit_local_intent database intent with
             | Error (Local_commit_persistence_failed _) -> ()
             | _ -> Alcotest.fail "evidence failure did not fail the logical write");
            Alcotest.(check bool)
              "failed transaction has no commit evidence"
              true
              (Database.inspect_local_intent database intent
               |> T.require_ok ~behavior
               = Database.Intent_pending);
            let after =
              current_snapshot database behavior (fun snapshot ->
                Database.graph_info snapshot |> T.require_ok ~behavior)
            in
            Alcotest.(check bool)
              "failed transaction restores projection"
              true
              (before = after);
            if append then current_snapshot database behavior(fun snapshot->
              T.require(match Database.get_pages snapshot [T.mutation_uuid 7720] |> T.require_ok ~behavior with
                |[Missing_page _]->true|_->false) "failed append left an empty journal page";
              T.require(match Database.get_outline_blocks snapshot [T.mutation_uuid 7721;T.mutation_uuid 7722]
                |> T.require_ok ~behavior with [Missing_block _;Missing_block _]->true|_->false)
                "failed append left a partial tree");
            sql "DROP TRIGGER reject_intent_commit";
            Database.commit_local_intent database intent
            |> T.require_ok ~behavior
            |> Database.intent_commit_outcome)
        in
        use (fun database ->
          let pending =
            Database.pending_local_intents database ~namespace ~after:None ~limit:1
            |> T.require_ok ~behavior
          in
          Alcotest.(check int)
            "restart recovers exactly one intent"
            1
            (List.length pending.items);
          let intent = List.hd pending.items in
          Alcotest.(check string)
            "restart restores complete wire payload"
            "stable restart payload"
            (Database.local_intent_payload intent);
          let proof =
            Database.commit_local_intent database intent |> T.require_ok ~behavior
          in
          Alcotest.(check bool)
            "restart preserves original commit point"
            true
            (Database.intent_commit_outcome proof = original);
          if append then current_snapshot database behavior(fun snapshot->
            T.require(match Database.get_pages snapshot [T.mutation_uuid 7720] |> T.require_ok ~behavior with
              |[Present_page{value;_}]->value.page.kind=Graph.Journal_page{journal_day=20261102}
              |_->false) "reopen lost the atomically created day";
            T.require(match Database.get_outline_blocks snapshot [T.mutation_uuid 7721;T.mutation_uuid 7722]
              |> T.require_ok ~behavior with
              |[Present_block{value=root;_};Present_block{value=child;_}]->
                root.block.page=T.mutation_uuid 7720 && child.block.parent=root.block.uuid
              |_->false) "reopen lost the complete atomic tree");
          let fresh = block_precondition database T.authoritative_block_uuid behavior in
          ignore
            (Database.commit_local
               database
               ~expected:fresh
               (Save_block
                  { mutation_id = T.mutation_uuid 7611
                  ; block = T.authoritative_block_uuid
                  ; title = "Later post-restart edit"
                  })
             |> T.require_ok ~behavior);
          let again =
            Database.commit_local_intent database intent |> T.require_ok ~behavior
          in
          Alcotest.(check bool)
            "later write cannot replace recovered evidence"
            true
            (Database.intent_commit_outcome again = original)))))
;;

let durable_rejection_is_final database =
  let behavior = "durable rejection cannot later apply" in
  let namespace = String.make 64 'c' in
  let stale = block_precondition database T.authoritative_block_uuid behavior in
  let intent =
    Database.persist_local_intent
      database
      ~namespace
      ~payload:"rejected complete intent"
      ~expected:stale
      (Save_block
         { mutation_id = T.mutation_uuid 7620
         ; block = T.authoritative_block_uuid
         ; title = "Must not apply later"
         })
    |> T.require_ok ~behavior
  in
  ignore
    (Database.commit_local
       database
       ~expected:stale
       (Save_block
          { mutation_id = T.mutation_uuid 7621
          ; block = T.authoritative_block_uuid
          ; title = "Changes target revision"
          })
     |> T.require_ok ~behavior);
  Alcotest.(check bool)
    "stale intent is deterministically rejected"
    true
    (Database.commit_local_intent database intent = Error Target_precondition_conflict);
  (match Database.inspect_local_intent database intent |> T.require_ok ~behavior with
   | Database.Intent_rejected Target_precondition_conflict -> ()
   | _ -> Alcotest.fail "known rejection was not durable");
  Database.acknowledge_rejected_local_intent database intent |> T.require_ok ~behavior;
  let pending =
    Database.pending_local_intents database ~namespace ~after:None ~limit:1
    |> T.require_ok ~behavior
  in
  Alcotest.(check int) "rejected ACK settles recovery" 0 (List.length pending.items);
  Alcotest.(check bool)
    "ACK retains exact rejection for retry"
    true
    (Database.commit_local_intent database intent = Error Target_precondition_conflict)
;;

let legacy_receipt_cannot_prove_rejection database =
  let behavior = "legacy proof stays uncertain" in
  let expected = block_precondition database T.authoritative_block_uuid behavior in
  let mutation =
    Save_block
      { mutation_id = T.mutation_uuid 7631
      ; block = T.authoritative_block_uuid
      ; title = "Legacy accepted write"
      }
  in
  ignore (Database.commit_local database ~expected mutation |> T.require_ok ~behavior);
  let intent =
    Database.persist_local_intent
      database
      ~namespace:(String.make 64 'd')
      ~payload:"complete newer durable encoding"
      ~expected
      mutation
    |> T.require_ok ~behavior
  in
  ignore (Database.commit_local_intent database intent);
  Alcotest.(check bool)
    "legacy applied write is neither a new original point nor known rejection"
    true
    (Database.inspect_local_intent database intent
     |> T.require_ok ~behavior
     = Database.Intent_pending);
  Alcotest.(check bool)
    "uncertain legacy evidence cannot be acknowledged as rejected"
    true
    (Result.is_error (Database.acknowledge_rejected_local_intent database intent))
;;

let durable_rejection_survives_restart () =
  let behavior = "durable rejection survives restart" in
  T.with_temp_directory "durable-rejection-reopen-" (fun support ->
    ignore (T.seed_mirror support);
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let namespace = String.make 64 'e'
        and mutation_id = T.mutation_uuid 7640 in
        let use f =
          let inspection =
            Database.inspect_mirror
              ~application_support_directory:support
              ~graph_id:T.graph_uuid
            |> T.require_ok ~behavior
          in
          let database =
            Database.open_
              ~sw
              (T.dependencies ~behavior)
              inspection
              ~graph_name:"rejection-reopen"
            |> T.require_ok ~behavior
          in
          Fun.protect
            ~finally:(fun () ->
              ignore (Database.close database |> T.require_ok ~behavior))
            (fun () -> f database)
        in
        use (fun database ->
          let expected =
            block_precondition database T.authoritative_block_uuid behavior
          in
          let intent =
            Database.persist_local_intent
              database
              ~namespace
              ~payload:"rejected restart payload"
              ~expected
              (Save_block
                 { mutation_id
                 ; block = T.authoritative_block_uuid
                 ; title = "Never apply"
                 })
            |> T.require_ok ~behavior
          in
          ignore
            (Database.commit_local
               database
               ~expected
               (Save_block
                  { mutation_id = T.mutation_uuid 7641
                  ; block = T.authoritative_block_uuid
                  ; title = "New target revision"
                  })
             |> T.require_ok ~behavior);
          Alcotest.(check bool)
            "initial stale intent rejected"
            true
            (Database.commit_local_intent database intent
             = Error Target_precondition_conflict));
        use (fun database ->
          let intent =
            Database.find_local_intent database ~namespace ~mutation_id
            |> T.require_ok ~behavior
            |> Option.get
          in
          Alcotest.(check bool)
            "restart retains exact rejection"
            true
            (Database.inspect_local_intent database intent
             |> T.require_ok ~behavior
             = Database.Intent_rejected Target_precondition_conflict);
          Alcotest.(check bool)
            "restart cannot replay rejection as write"
            true
            (Database.commit_local_intent database intent
             = Error Target_precondition_conflict);
          Database.acknowledge_rejected_local_intent database intent
          |> T.require_ok ~behavior);
        use (fun database ->
          let pending =
            Database.pending_local_intents database ~namespace ~after:None ~limit:1
            |> T.require_ok ~behavior
          in
          Alcotest.(check int)
            "acknowledged rejection stays out of recovery after restart"
            0
            (List.length pending.items);
          let intent =
            Database.find_local_intent database ~namespace ~mutation_id
            |> T.require_ok ~behavior
            |> Option.get
          in
          Alcotest.(check bool)
            "settlement retains proof after restart"
            true
            (Database.inspect_local_intent database intent
             |> T.require_ok ~behavior
             = Database.Intent_rejected Target_precondition_conflict)))))
;;

let cases =
  cases
  @ [ Alcotest.test_case
        "rejection survives restart"
        `Quick
        durable_rejection_survives_restart
    ; T.database_case
        "legacy receipt cannot prove rejection"
        legacy_receipt_cannot_prove_rejection
    ; T.database_case "durable rejection is final" durable_rejection_is_final
    ; T.database_case
        "durable intent keeps original commit point"
        durable_intent_keeps_original_commit
    ; Alcotest.test_case
        "durable intent survives restart and rollback"
        `Quick
        (durable_intent_survives_restart_and_rollback ~append:false)
    ; Alcotest.test_case "atomic append rollback and restart" `Quick
        (durable_intent_survives_restart_and_rollback ~append:true)
    ]
;;

let () = Alcotest.run "logseq_overlay_db mutations" [ "local planning and commit", cases ]
