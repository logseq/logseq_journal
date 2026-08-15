module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Structural_fixture
module Plan = Logseq_db_worker__Mutation_plan
module Protocol = Logseq_db_worker.Protocol
module Uuid = Logseq_db_worker.Graph_types.Uuid

open Protocol

let move db roots position =
  Plan.plan
    ~now_ms:F.now_ms
    db
    (Protocol.Structural
       (Move_blocks
          { roots = List.map F.uuid roots
          ; position
          ; context = F.context db
          }))
;;

let move_up_down db roots direction =
  Plan.plan
    ~now_ms:F.now_ms
    db
    (Protocol.Structural
       (Move_up_down
          { roots = List.map F.uuid roots
          ; direction
          ; context = F.context db
          }))
;;

let require_plan = function
  | Ok plan -> plan
  | Error _ -> T.fail "valid move did not plan"
;;

let apply db plan = Datascript.with_tx ~tx_meta:plan.Plan.tx_meta db plan.tx_ops

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

let require_children db parent expected message =
  T.require
    (child_uuids db (F.entity db (F.uuid parent)) = expected)
    "%s"
    message
;;

let contains_ref db source attr target =
  F.values db source attr
  |> List.exists (function
    | Datascript.Ref entity -> entity = target
    | _ -> false)
;;

let with_ops db ops = Datascript.db_with ops db

let with_comment_tag db block_uuid ident tag_uuid =
  let tag = Datascript.Temp_id ("tag:" ^ tag_uuid) in
  let block = F.entity db (F.uuid block_uuid) in
  with_ops
    db
    [ Datascript.Add (tag, "block/uuid", Uuid tag_uuid)
    ; Add (tag, "block/title", String ident)
    ; Add (tag, "block/name", String ident)
    ; Add (tag, "db/ident", Keyword ident)
    ; Add (Entity_id block, "block/tags", Ref_to tag)
    ]
;;

let () =
  T.run
    "move blocks"
    [ T.case "ordered multi-root selection" (fun () ->
        let db = F.db () in
        let after =
          apply
            db
            (require_plan
               (move
                  db
                  [ F.root_two; F.root_one ]
                  (After (F.uuid F.empty))))
          |> fun report -> report.db_after
        in
        require_children
          after
          F.page_one
          [ F.empty; F.root_one; F.root_two; F.built_in ]
          "caller order changed canonical multi-root order")
    ; T.case "selected descendants are deduplicated" (fun () ->
        let db = F.db () in
        let plan =
          require_plan
            (move
               db
               [ F.child_one; F.root_one ]
               (After (F.uuid F.other_page_root)))
        in
        let after = (apply db plan).db_after in
        let root = F.entity after (F.uuid F.root_one) in
        let child = F.entity after (F.uuid F.child_one) in
        T.require (F.reference after child "block/parent" = root) "selected descendant detached";
        T.require
          (List.length plan.changed_uuids = List.length (List.sort_uniq Uuid.compare plan.changed_uuids))
          "selected descendant was planned twice")
    ; T.case "same-parent move" (fun () ->
        let db = F.db () in
        let after =
          apply
            db
            (require_plan
               (move db [ F.root_two ] (Before (F.uuid F.root_one))))
          |> fun report -> report.db_after
        in
        require_children
          after
          F.page_one
          [ F.root_two; F.root_one; F.empty; F.built_in ]
          "same-parent move failed")
    ; T.case "cross-parent move" (fun () ->
        let db = F.db () in
        let after =
          apply
            db
            (require_plan
               (move db [ F.root_two ] (Last_child (F.uuid F.root_one))))
          |> fun report -> report.db_after
        in
        require_children
          after
          F.root_one
          [ F.child_one; F.child_two; F.root_two ]
          "cross-parent move failed")
    ; T.case "cross-page subtree rewrites page" (fun () ->
        let db = F.db () in
        let after =
          apply
            db
            (require_plan
               (move db [ F.root_one ] (Last_child (F.uuid F.other_page_root))))
          |> fun report -> report.db_after
        in
        let page = F.entity after (F.uuid F.page_two) in
        List.iter
          (fun uuid ->
             T.require
               (F.reference after (F.entity after (F.uuid uuid)) "block/page" = page)
               "cross-page move left a descendant on the source page")
          [ F.root_one; F.child_one; F.child_two ])
    ; T.case "move before after first-child and last-child" (fun () ->
        let cases =
          [ Before (F.uuid F.root_one), F.page_one, [ F.root_two; F.root_one; F.empty; F.built_in ]
          ; After (F.uuid F.empty), F.page_one, [ F.root_one; F.empty; F.root_two; F.built_in ]
          ; First_child (F.uuid F.root_one), F.root_one, [ F.root_two; F.child_one; F.child_two ]
          ; Last_child (F.uuid F.root_one), F.root_one, [ F.child_one; F.child_two; F.root_two ]
          ]
        in
        List.iter
          (fun (position, parent, expected) ->
             let db = F.db () in
             let after = (apply db (require_plan (move db [ F.root_two ] position))).db_after in
             require_children after parent expected "relative move position failed")
          cases)
    ; T.case "original position is rejected" (fun () ->
        match move (F.db ()) [ F.root_two ] (After (F.uuid F.root_one)) with
        | Error (Plan.Invalid_position _) -> ()
        | _ -> T.fail "move to original position was accepted")
    ; T.case "page target semantics" (fun () ->
        let db = F.db () in
        let after =
          (apply
             db
             (require_plan
                (move db [ F.root_two ] (First_child (F.uuid F.page_two))))).db_after
        in
        require_children
          after
          F.page_two
          [ F.root_two; F.other_page_root ]
          "page first-child target failed";
        match move (F.db ()) [ F.root_two ] (Before (F.uuid F.page_two)) with
        | Error (Plan.Invalid_position _) -> ()
        | _ -> T.fail "page was accepted as a sibling target")
    ; T.case "self move is rejected" (fun () ->
        match move (F.db ()) [ F.root_one ] (Before (F.uuid F.root_one)) with
        | Error (Plan.Invalid_position _) -> ()
        | _ -> T.fail "self move was accepted")
    ; T.case "cycle is rejected" (fun () ->
        match move (F.db ()) [ F.root_one ] (Last_child (F.uuid F.child_one)) with
        | Error (Plan.Invalid_position _ | Invalid_tree _) -> ()
        | _ -> T.fail "move beneath a descendant was accepted")
    ; T.case "built-in source and target are rejected" (fun () ->
        List.iter
          (fun (roots, position) ->
             match move (F.db ()) roots position with
             | Error Plan.Built_in_protected -> ()
             | _ -> T.fail "built-in move was accepted")
          [ [ F.built_in ], Before (F.uuid F.root_one)
          ; [ F.root_one ], Last_child (F.uuid F.built_in)
          ])
    ; T.case "range comment relationships remain valid" (fun () ->
        let db = F.db () in
        let comments = F.entity db (F.uuid F.empty) in
        let target = F.entity db (F.uuid F.root_two) in
        let db =
          with_ops
            db
            [ Datascript.Add
                ( Entity_id comments
                , "logseq.property.comments/blocks"
                , Ref_to (Entity_id target) )
            ]
        in
        let after =
          (apply
             db
             (require_plan
                (move db [ F.root_two ] (Last_child (F.uuid F.root_one))))).db_after
        in
        T.require
          (contains_ref
             after
             (F.entity after (F.uuid F.empty))
             "logseq.property.comments/blocks"
             (F.entity after (F.uuid F.root_two)))
          "range comment relation was damaged")
    ; T.case "property-value membership rejects pre-stage" (fun () ->
        let db = F.db () in
        let block = F.entity db (F.uuid F.root_two) in
        let property = F.entity db (F.uuid F.page_two) in
        let db =
          with_ops
            db
            [ Datascript.Add
                ( Entity_id block
                , "logseq.property/created-from-property"
                , Ref_to (Entity_id property) )
            ]
        in
        (match move db [ F.root_two ] (Last_child (F.uuid F.root_one)) with
         | Error (Plan.Unsupported_semantics _) -> ()
         | _ -> T.fail "property-value source move was accepted");
        let db = F.db () in
        let target = F.entity db (F.uuid F.child_one) in
        let property = F.entity db (F.uuid F.page_two) in
        let db =
          with_ops
            db
            [ Datascript.Add
                ( Entity_id target
                , "logseq.property/created-from-property"
                , Ref_to (Entity_id property) )
            ]
        in
        match move db [ F.root_two ] (Before (F.uuid F.child_one)) with
        | Error (Plan.Unsupported_semantics _) -> ()
        | _ -> T.fail "property-value target move was accepted")
    ; T.case "move-up top boundary returns No_change" (fun () ->
        let plan = require_plan (move_up_down (F.db ()) [ F.root_one ] Up) in
        T.require (plan.status = Protocol.No_change && plan.tx_ops = []) "top boundary changed")
    ; T.case "move-down bottom boundary returns No_change" (fun () ->
        let plan = require_plan (move_up_down (F.db ()) [ F.other_page_root ] Down) in
        T.require (plan.status = Protocol.No_change && plan.tx_ops = []) "bottom boundary changed")
    ; T.case "move-up/down preserves multi-root order" (fun () ->
        let db = F.db () in
        let after =
          (apply
             db
             (require_plan
                (move_up_down db [ F.root_two; F.root_one ] Down))).db_after
        in
        require_children
          after
          F.page_one
          [ F.empty; F.root_one; F.root_two; F.built_in ]
          "move-down reversed multi-root selection")
    ; T.case "move-up/down uses nested context" (fun () ->
        let db = F.db () in
        let after =
          (apply
             db
             (require_plan
                (move_up_down db [ F.child_two ] Down))).db_after
        in
        require_children
          after
          F.root_two
          [ F.child_two ]
          "nested move-down did not enter the parent's right sibling")
    ; T.case "move metadata touches source and target pages" (fun () ->
        let db = F.db () in
        let plan =
          require_plan
            (move db [ F.root_one ] (After (F.uuid F.other_page_root)))
        in
        let lookup attr = List.assoc_opt attr plan.Plan.tx_meta in
        T.require
          (lookup "outliner-op" = Some (Datascript.Keyword "move-blocks"))
          "move transaction metadata is missing";
        let after = (apply db plan).db_after in
        List.iter
          (fun page ->
             T.require
               (F.integer after (F.entity after (F.uuid page)) "block/updated-at"
                = Int64.to_int F.now_ms)
               "move did not touch a page timestamp")
          [ F.page_one; F.page_two ])
    ; T.case "protected comment sources and targets reject pre-stage" (fun () ->
        let comments_uuid = "a1000000-0000-4000-8000-000000000001" in
        let comment_uuid = "a1000000-0000-4000-8000-000000000002" in
        let source_db =
          with_comment_tag
            (F.db ())
            F.root_two
            "logseq.class/Comment"
            comment_uuid
        in
        (match move source_db [ F.root_two ] (Before (F.uuid F.root_one)) with
         | Error (Plan.Unsupported_semantics _) -> ()
         | _ -> T.fail "protected comment source was accepted");
        let target_db =
          with_comment_tag
            (F.db ())
            F.root_one
            "logseq.class/Comments"
            comments_uuid
        in
        match move target_db [ F.root_two ] (Last_child (F.uuid F.root_one)) with
        | Error (Plan.Unsupported_semantics _) -> ()
        | _ -> T.fail "protected comments-area target was accepted")
    ; T.case "selection bounds and continuity are enforced" (fun () ->
        let db = F.db () in
        List.iter
          (fun roots ->
             match move db roots (After (F.uuid F.other_page_root)) with
             | Error (Plan.Invalid_tree _) -> ()
             | _ -> T.fail "invalid move root selection was accepted")
          [ []; [ F.root_one; F.root_one ]; [ F.root_one; F.empty ] ];
        match move db [ F.missing_reference ] (After (F.uuid F.root_one)) with
        | Error (Plan.Invalid_selection _) -> ()
        | _ -> T.fail "missing move root was accepted")
    ]
