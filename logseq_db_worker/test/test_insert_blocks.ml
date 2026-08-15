module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Structural_fixture
module Plan = Logseq_db_worker__Mutation_plan
module Protocol = Logseq_db_worker.Protocol
module Uuid = Logseq_db_worker.Graph_types.Uuid

let tree ?(children = []) uuid title = Protocol.{ uuid = F.uuid uuid; title; children }

let insert db roots position =
  Plan.plan
    ~now_ms:F.now_ms
    db
    (Protocol.Structural
       (Insert_blocks { roots; position; context = F.context db }))
;;

let require_plan = function
  | Ok plan -> plan
  | Error _ -> T.fail "valid Insert_blocks did not plan"
;;

let apply db plan = Datascript.with_tx ~tx_meta:plan.Plan.tx_meta db plan.tx_ops

let optional_entity db uuid =
  match
    Datascript.datoms
      db
      Datascript.Avet
      ~a:"block/uuid"
      ~v:(Datascript.Uuid (Uuid.to_string uuid))
      ()
    |> List.of_seq
  with
  | [ datom ] -> Some datom.Datascript.e
  | [] -> None
  | _ -> T.fail "fixture contains an ambiguous UUID"
;;

let uuid_text db entity =
  match F.one db entity "block/uuid" with
  | Datascript.Uuid value | String value -> value
  | _ -> T.fail "block/uuid is not a UUID"
;;

let children db parent =
  Datascript.datoms
    db
    Datascript.Avet
    ~a:"block/parent"
    ~v:(Datascript.Ref parent)
    ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.sort (fun left right ->
    String.compare (F.string db left "block/order") (F.string db right "block/order"))
;;

let child_uuids db parent = List.map (uuid_text db) (children db parent)

let require_ref db source target =
  let refs = F.values db source "block/refs" in
  T.require
    (List.exists
       (function
         | Datascript.Ref entity -> entity = target
         | _ -> false)
       refs)
    "expected block/refs relation is missing"
;;

let require_string expected = function
  | Datascript.String actual ->
    T.require (String.equal expected actual) "expected %S, got %S" expected actual
  | _ -> T.fail "expected string value"
;;

let require_int expected = function
  | Datascript.Int actual ->
    T.require (actual = expected) "expected %d, got %d" expected actual
  | _ -> T.fail "expected integer value"
;;

let generated_uuid index =
  F.uuid (Printf.sprintf "71000000-0000-4000-8000-%012x" index)
;;

let generated_tree index = Protocol.{ uuid = generated_uuid index; title = "Generated"; children = [] }

let rec deep_tree index depth =
  Protocol.
    { uuid = generated_uuid index
    ; title = "Depth"
    ; children = if depth = 1 then [] else [ deep_tree (index + 1) (depth - 1) ]
    }
;;

let () =
  T.run
    "insert blocks"
    [ T.case "insert before" (fun () ->
        let db = F.db () in
        let plan =
          require_plan
            (insert
               db
               [ tree F.inserted_one "Before" ]
               (Relative (Before (F.uuid F.root_two))))
        in
        let after = (apply db plan).db_after in
        let page = F.entity after (F.uuid F.page_one) in
        T.require
          (child_uuids after page = [ F.root_one; F.inserted_one; F.root_two; F.empty; F.built_in ])
          "insert-before did not preserve sibling order";
        let inserted = F.entity after (F.uuid F.inserted_one) in
        T.require
          (String.compare "a0" (F.string after inserted "block/order") < 0
           && String.compare (F.string after inserted "block/order") "a1" < 0)
          "insert-before order is outside its bounds")
    ; T.case "insert after" (fun () ->
        let db = F.db () in
        let after =
          apply
            db
            (require_plan
               (insert
                  db
                  [ tree F.inserted_one "After" ]
                  (Relative (After (F.uuid F.root_one)))))
          |> fun report -> report.db_after
        in
        let page = F.entity after (F.uuid F.page_one) in
        T.require
          (child_uuids after page = [ F.root_one; F.inserted_one; F.root_two; F.empty; F.built_in ])
          "insert-after did not preserve sibling order")
    ; T.case "insert first child" (fun () ->
        let db = F.db () in
        let after =
          apply
            db
            (require_plan
               (insert
                  db
                  [ tree F.inserted_one "First child" ]
                  (Relative (First_child (F.uuid F.root_one)))))
          |> fun report -> report.db_after
        in
        let parent = F.entity after (F.uuid F.root_one) in
        T.require
          (child_uuids after parent = [ F.inserted_one; F.child_one; F.child_two ])
          "first-child insertion was not first")
    ; T.case "insert last child" (fun () ->
        let db = F.db () in
        let after =
          apply
            db
            (require_plan
               (insert
                  db
                  [ tree F.inserted_one "Last child" ]
                  (Relative (Last_child (F.uuid F.root_one)))))
          |> fun report -> report.db_after
        in
        let parent = F.entity after (F.uuid F.root_one) in
        T.require
          (child_uuids after parent = [ F.child_one; F.child_two; F.inserted_one ])
          "last-child insertion was not last")
    ; T.case "nested preorder input" (fun () ->
        let db = F.db () in
        let roots =
          [ tree
              ~children:[ tree F.inserted_child "Nested child" ]
              F.inserted_one
              "Nested parent"
          ; tree F.inserted_two "Second root"
          ]
        in
        let after =
          apply
            db
            (require_plan
               (insert db roots (Relative (After (F.uuid F.root_one)))))
          |> fun report -> report.db_after
        in
        let parent = F.entity after (F.uuid F.inserted_one) in
        let child = F.entity after (F.uuid F.inserted_child) in
        T.require (F.reference after child "block/parent" = parent) "nested parent was lost";
        T.require
          (child_uuids after parent = [ F.inserted_child ])
          "nested preorder was not preserved")
    ; T.case "caller supplied UUIDs are preserved" (fun () ->
        let db = F.db () in
        let after =
          apply
            db
            (require_plan
               (insert
                  db
                  [ tree F.inserted_one "Preserved" ]
                  (Relative (After (F.uuid F.root_one)))))
          |> fun report -> report.db_after
        in
        T.require
          (Option.is_some (optional_entity after (F.uuid F.inserted_one)))
          "caller UUID was replaced")
    ; T.case "blank target replacement" (fun () ->
        let db = F.db () in
        let roots =
          [ tree
              ~children:[ tree F.inserted_child "Replacement child" ]
              F.empty
              "Replacement"
          ]
        in
        let after =
          apply db (require_plan (insert db roots (Replace_empty (F.uuid F.empty))))
          |> fun report -> report.db_after
        in
        let replaced = F.entity after (F.uuid F.empty) in
        require_string "Replacement" (F.one after replaced "block/title");
        T.require
          (String.equal (F.string after replaced "block/order") "a2")
          "blank replacement changed the target order";
        T.require
          (child_uuids after replaced = [ F.inserted_child ])
          "blank replacement did not remap its child parent")
    ; T.case "cross-page insertion rewrites page" (fun () ->
        let db = F.db () in
        let roots =
          [ tree
              ~children:[ tree F.inserted_child "Cross-page child" ]
              F.inserted_one
              "Cross-page root"
          ]
        in
        let after =
          apply
            db
            (require_plan
               (insert db roots (Relative (After (F.uuid F.other_page_root)))))
          |> fun report -> report.db_after
        in
        let page = F.entity after (F.uuid F.page_two) in
        List.iter
          (fun value ->
             let entity = F.entity after (F.uuid value) in
             T.require (F.reference after entity "block/page" = page) "cross-page rewrite was incomplete")
          [ F.inserted_one; F.inserted_child ])
    ; T.case "internal references remap to inserted UUIDs" (fun () ->
        let db = F.db () in
        let roots =
          [ tree
              ~children:[ tree F.inserted_child "Reference target" ]
              F.inserted_one
              ("See ((" ^ F.inserted_child ^ "))")
          ]
        in
        let after =
          apply
            db
            (require_plan
               (insert db roots (Relative (After (F.uuid F.root_one)))))
          |> fun report -> report.db_after
        in
        let source = F.entity after (F.uuid F.inserted_one) in
        let target = F.entity after (F.uuid F.inserted_child) in
        require_string
          ("See [[" ^ F.inserted_child ^ "]]" )
          (F.one after source "block/title");
        require_ref after source target)
    ; T.case "missing external references create canonical stubs" (fun () ->
        let db = F.db () in
        let after =
          apply
            db
            (require_plan
               (insert
                  db
                  [ tree F.inserted_one ("External [[" ^ F.missing_reference ^ "]]") ]
                  (Relative (After (F.uuid F.root_one)))))
          |> fun report -> report.db_after
        in
        let source = F.entity after (F.uuid F.inserted_one) in
        let stub = F.entity after (F.uuid F.missing_reference) in
        require_string F.missing_reference (F.one after stub "block/title");
        require_string F.missing_reference (F.one after stub "block/name");
        require_ref after source stub)
    ; T.case "invalid parent rejects entire mutation" (fun () ->
        let db = F.db () in
        match
          insert
            db
            [ tree F.inserted_one "Unplaced" ]
            (Relative (First_child (F.uuid F.missing_reference)))
        with
        | Error (Plan.Invalid_selection _) ->
          T.require
            (Option.is_none (optional_entity db (F.uuid F.inserted_one)))
            "failed planning mutated the source database"
        | _ -> T.fail "missing insertion parent was accepted")
    ; T.case "invalid order rejects entire mutation" (fun () ->
        let db = F.db () in
        let root = F.entity db (F.uuid F.root_one) in
        let db =
          Datascript.db_with
            [ Datascript.Add (Entity_id root, "block/order", String "a00") ]
            db
        in
        match
          insert
            db
            [ tree F.inserted_one "Invalid order" ]
            (Relative (After (F.uuid F.root_one)))
        with
        | Error (Plan.Invalid_order _) -> ()
        | _ -> T.fail "invalid anchor order was accepted")
    ; T.case "empty roots are rejected" (fun () ->
        match
          insert
            (F.db ())
            []
            (Relative (After (F.uuid F.root_one)))
        with
        | Error (Plan.Invalid_tree _) -> ()
        | _ -> T.fail "empty roots were accepted")
    ; T.case "root depth and node limits are enforced" (fun () ->
        let db = F.db () in
        let position = Protocol.Relative (After (F.uuid F.root_one)) in
        let too_many_roots = List.init (Protocol.maximum_roots + 1) generated_tree in
        (match insert db too_many_roots position with
         | Error (Plan.Invalid_tree _) -> ()
         | _ -> T.fail "root-count limit was not enforced");
        let too_deep = [ deep_tree 0 (Protocol.maximum_tree_depth + 1) ] in
        (match insert db too_deep position with
         | Error (Plan.Invalid_tree _) -> ()
         | _ -> T.fail "tree-depth limit was not enforced");
        let too_many_nodes =
          [ Protocol.
              { uuid = generated_uuid 0
              ; title = "Root"
              ; children =
                  List.init Protocol.maximum_tree_nodes (fun index -> generated_tree (index + 1))
              }
          ]
        in
        match insert db too_many_nodes position with
        | Error (Plan.Invalid_tree _) -> ()
        | _ -> T.fail "tree-node limit was not enforced")
    ; T.case "timestamps and transaction metadata match oracle" (fun () ->
        let db = F.db () in
        let plan =
          require_plan
            (insert
               db
               [ tree F.inserted_one "Timestamped" ]
               (Relative (After (F.uuid F.root_one))))
        in
        let lookup attr = List.assoc_opt attr plan.Plan.tx_meta in
        T.require
          (lookup "db-sync/tx-id" = Some (Datascript.Uuid F.mutation))
          "transaction UUID metadata is missing";
        T.require
          (lookup "outliner-op" = Some (Datascript.Keyword "insert-blocks"))
          "outliner operation metadata is missing";
        T.require
          (lookup "local-tx?" = Some (Datascript.Bool true))
          "local transaction metadata is missing";
        let report = apply db plan in
        let inserted = F.entity report.db_after (F.uuid F.inserted_one) in
        let page = F.entity report.db_after (F.uuid F.page_one) in
        List.iter
          (fun attr -> require_int (Int64.to_int F.now_ms) (F.one report.db_after inserted attr))
          [ "block/created-at"; "block/updated-at" ];
        require_int (Int64.to_int F.now_ms) (F.one report.db_after page "block/updated-at");
        let current_tx =
          match List.assoc_opt "db/current-tx" report.tempids with
          | Some tx -> tx
          | None -> T.fail "transaction has no current tx tempid"
        in
        List.iter
          (fun entity -> require_int current_tx (F.one report.db_after entity "block/tx-id"))
          [ inserted; page ])
    ; T.case "unsupported asset relations reject pre-stage" (fun () ->
        match
          insert
            (F.db ())
            [ tree F.inserted_one "![asset](../assets/file.png)" ]
            (Relative (After (F.uuid F.root_one)))
        with
        | Error (Plan.Unsupported_semantics _) -> ()
        | _ -> T.fail "unsupported asset effect was accepted")
    ; T.case "duplicate caller UUIDs reject the whole tree" (fun () ->
        match
          insert
            (F.db ())
            [ tree
                ~children:[ tree F.inserted_one "Duplicate child" ]
                F.inserted_one
                "Duplicate root"
            ]
            (Relative (After (F.uuid F.root_one)))
        with
        | Error (Plan.Invalid_tree _) -> ()
        | _ -> T.fail "duplicate caller UUIDs were accepted")
    ; T.case "title and UTF-8 limits are enforced before planning" (fun () ->
        let db = F.db () in
        let position = Protocol.Relative (After (F.uuid F.root_one)) in
        List.iter
          (fun title ->
             match insert db [ tree F.inserted_one title ] position with
             | Error (Plan.Unsupported_semantics _) -> ()
             | _ -> T.fail "invalid inserted title was accepted")
          [ String.make (Protocol.maximum_title_bytes + 1) 'x'; "\255" ])
    ; T.case "wrong-kind position anchors are rejected" (fun () ->
        match
          insert
            (F.db ())
            [ tree F.inserted_one "Invalid anchor" ]
            (Relative (Before (F.uuid F.page_one)))
        with
        | Error (Plan.Invalid_position _) -> ()
        | _ -> T.fail "page was accepted as a before anchor")
    ; T.case "exact replay is Already_applied and partial reuse conflicts" (fun () ->
        let db = F.db () in
        let position = Protocol.Relative (After (F.uuid F.root_one)) in
        let roots = [ tree F.inserted_one "Idempotent insert" ] in
        let first = require_plan (insert db roots position) in
        let after = (apply db first).db_after in
        let replay = require_plan (insert after roots position) in
        T.require (replay.Plan.status = Protocol.Already_applied) "exact replay was not idempotent";
        T.require (replay.tx_ops = []) "exact replay staged a transaction";
        match insert after [ tree F.inserted_one "Different title" ] position with
        | Error (Plan.Conflict _) -> ()
        | _ -> T.fail "partial UUID reuse did not conflict")
    ; T.case "Replace_empty requires one matching blank root" (fun () ->
        let db = F.db () in
        List.iter
          (fun roots ->
             match insert db roots (Replace_empty (F.uuid F.empty)) with
             | Error (Plan.Invalid_position _ | Invalid_tree _) -> ()
             | _ -> T.fail "invalid replacement tree was accepted")
          [ [ tree F.inserted_one "Wrong UUID" ]
          ; [ tree F.empty "One"; tree F.inserted_two "Two" ]
          ];
        match
          insert
            db
            [ tree F.root_one "Not blank" ]
            (Replace_empty (F.uuid F.root_one))
        with
        | Error (Plan.Invalid_position _) -> ()
        | _ -> T.fail "non-blank replacement target was accepted")
    ; T.case "canonicalized title replay is Already_applied" (fun () ->
        let db = F.db () in
        let roots =
          [ tree
              ~children:[ tree F.inserted_child "Target" ]
              F.inserted_one
              ("See ((" ^ F.inserted_child ^ "))")
          ]
        in
        let position = Protocol.Relative (After (F.uuid F.root_one)) in
        let after = (apply db (require_plan (insert db roots position))).db_after in
        let replay = require_plan (insert after roots position) in
        T.require
          (replay.Plan.status = Protocol.Already_applied && replay.tx_ops = [])
          "canonicalized title replay was not idempotent")
    ; T.case "completed blank replacement replay is Already_applied" (fun () ->
        let db = F.db () in
        let roots =
          [ tree
              ~children:[ tree F.inserted_child "Replacement child" ]
              F.empty
              "Replacement"
          ]
        in
        let position = Protocol.Replace_empty (F.uuid F.empty) in
        let after = (apply db (require_plan (insert db roots position))).db_after in
        let replay = require_plan (insert after roots position) in
        T.require
          (replay.Plan.status = Protocol.Already_applied && replay.tx_ops = [])
          "completed blank replacement replay was not idempotent")
    ]
