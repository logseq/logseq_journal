module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Structural_fixture
module Plan = Logseq_db_worker__Mutation_plan
module Protocol = Logseq_db_worker.Protocol

open Protocol

let mutate db roots direction =
  Plan.plan
    ~now_ms:F.now_ms
    db
    (Protocol.Structural
       (Indent_outdent
          { roots = List.map F.uuid roots
          ; direction
          ; context = F.context db
          }))
;;

let require_plan = function
  | Ok plan -> plan
  | Error _ -> T.fail "valid indent/outdent did not plan"
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

let with_ops db ops = Datascript.db_with ops db

let has_true db entity attr =
  match F.values db entity attr with
  | [ Datascript.Bool true ] -> true
  | [] | [ _ ] -> false
  | _ -> T.fail "multiple values for %s" attr
;;

let () =
  T.run
    "indent outdent"
    [ T.case "indent requires a left sibling" (fun () ->
        match mutate (F.db ()) [ F.root_one ] Indent with
        | Error (Plan.Invalid_position _) -> ()
        | _ -> T.fail "indent without a left sibling was accepted")
    ; T.case "indent accepts multiple continuous roots" (fun () ->
        let db = F.db () in
        let after =
          (apply
             db
             (require_plan
                (mutate db [ F.root_two; F.empty ] Indent))).db_after
        in
        require_children
          after
          F.root_one
          [ F.child_one; F.child_two; F.root_two; F.empty ]
          "continuous roots were not indented in canonical order")
    ; T.case "indent rejects discontinuous selection" (fun () ->
        match mutate (F.db ()) [ F.root_one; F.empty ] Indent with
        | Error (Plan.Invalid_tree _) -> ()
        | _ -> T.fail "discontinuous indent roots were accepted")
    ; T.case "collapsed left sibling with children is expanded" (fun () ->
        let db = F.db () in
        let left = F.entity db (F.uuid F.root_one) in
        let db = with_ops db [ Datascript.Add (Entity_id left, "block/collapsed?", Bool true) ] in
        let after =
          (apply db (require_plan (mutate db [ F.root_two ] Indent))).db_after
        in
        let left = F.entity after (F.uuid F.root_one) in
        T.require
          (not (has_true after left "block/collapsed?"))
          "collapsed target with children was not expanded";
        require_children
          after
          F.root_one
          [ F.child_one; F.child_two; F.root_two ]
          "collapsed left sibling was not the indent target")
    ; T.case "collapsed left sibling without children remains collapsed" (fun () ->
        let db = F.db () in
        let left = F.entity db (F.uuid F.root_two) in
        let db = with_ops db [ Datascript.Add (Entity_id left, "block/collapsed?", Bool true) ] in
        let after = (apply db (require_plan (mutate db [ F.empty ] Indent))).db_after in
        let left = F.entity after (F.uuid F.root_two) in
        T.require
          (has_true after left "block/collapsed?")
          "no-child indent unexpectedly expanded its target";
        require_children after F.root_two [ F.empty ] "no-child indent used the wrong target")
    ; T.case "indent generates last-child orders" (fun () ->
        let db = F.db () in
        let after = (apply db (require_plan (mutate db [ F.root_two ] Indent))).db_after in
        let moved = F.entity after (F.uuid F.root_two) in
        T.require
          (String.compare (F.string after moved "block/order") "a1" > 0)
          "indent did not append after the last existing child")
    ; T.case "direct outdent rejects page roots" (fun () ->
        match mutate (F.db ()) [ F.root_one ] Direct_outdent with
        | Error (Plan.Invalid_position _) -> ()
        | _ -> T.fail "a page-root block was outdented")
    ; T.case "direct outdent rejects property values" (fun () ->
        let db = F.db () in
        let block = F.entity db (F.uuid F.child_one) in
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
        match mutate db [ F.child_one ] Direct_outdent with
        | Error (Plan.Unsupported_semantics _) -> ()
        | _ -> T.fail "a property-value block was outdented")
    ; T.case "direct outdent reparents right siblings" (fun () ->
        let db = F.db () in
        let after =
          (apply db (require_plan (mutate db [ F.child_one ] Direct_outdent))).db_after
        in
        require_children
          after
          F.page_one
          [ F.root_one; F.child_one; F.root_two; F.empty; F.built_in ]
          "outdented root did not follow its old parent";
        require_children
          after
          F.root_one
          []
          "right siblings remained under the old parent";
        require_children
          after
          F.child_one
          [ F.child_two ]
          "right siblings were not reparented beneath the outdented root")
    ; T.case "direct outdent preserves right-sibling order" (fun () ->
        let db = F.db () in
        let parent = F.entity db (F.uuid F.root_one) in
        let page = F.entity db (F.uuid F.page_one) in
        let db =
          with_ops
            db
            [ Datascript.Add (Temp_id "third", "block/uuid", Uuid F.inserted_one)
            ; Add (Temp_id "third", "block/title", String "Third")
            ; Add (Temp_id "third", "block/parent", Ref_to (Entity_id parent))
            ; Add (Temp_id "third", "block/page", Ref_to (Entity_id page))
            ; Add (Temp_id "third", "block/order", String "a2")
            ; Add (Temp_id "third", "block/created-at", Int 1_704_067_200_000)
            ; Add (Temp_id "third", "block/updated-at", Int 1_704_067_200_000)
            ]
        in
        let after =
          (apply db (require_plan (mutate db [ F.child_one ] Direct_outdent))).db_after
        in
        require_children
          after
          F.child_one
          [ F.child_two; F.inserted_one ]
          "outdent reversed right-sibling order")
    ; T.case "direct outdent preserves page invariants" (fun () ->
        let db = F.db () in
        let after =
          (apply db (require_plan (mutate db [ F.child_one ] Direct_outdent))).db_after
        in
        let page = F.entity after (F.uuid F.page_one) in
        List.iter
          (fun uuid ->
             T.require
               (F.reference after (F.entity after (F.uuid uuid)) "block/page" = page)
               "direct outdent changed a subtree page")
          [ F.child_one; F.child_two ])
    ; T.case "direct outdent leaves an acyclic tree" (fun () ->
        let db = F.db () in
        let after =
          (apply db (require_plan (mutate db [ F.child_one ] Direct_outdent))).db_after
        in
        let rec walk seen entity =
          T.require (not (List.mem entity seen)) "direct outdent introduced a cycle";
          match F.values after entity "block/parent" with
          | [ Datascript.Ref parent ] -> walk (entity :: seen) parent
          | [] -> ()
          | _ -> T.fail "malformed parent relation"
        in
        walk [] (F.entity after (F.uuid F.child_two)))
    ; T.case "transaction metadata and block tx-id match oracle" (fun () ->
        let db = F.db () in
        let plan = require_plan (mutate db [ F.root_two ] Indent) in
        T.require
          (List.assoc_opt "outliner-op" plan.tx_meta
           = Some (Datascript.Keyword "indent-outdent-blocks"))
          "indent transaction metadata is missing";
        let report = apply db plan in
        let current_tx =
          match List.assoc_opt "db/current-tx" report.tempids with
          | Some tx -> tx
          | None -> T.fail "transaction has no current tx tempid"
        in
        List.iter
          (fun uuid ->
             T.require
               (F.integer report.db_after (F.entity report.db_after (F.uuid uuid)) "block/tx-id"
                = current_tx)
               "indent tx-id does not match the current transaction")
          [ F.root_two; F.page_one ])
    ]
