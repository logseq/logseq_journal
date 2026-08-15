module T = Logseq_db_worker_test_support.Test_support
module F = Logseq_db_worker_test_support.Structural_fixture
module Plan = Logseq_db_worker__Mutation_plan
module Protocol = Logseq_db_worker.Protocol
module Uuid = Logseq_db_worker.Graph_types.Uuid

let delete db roots =
  Plan.plan
    ~now_ms:F.now_ms
    db
    (Protocol.Structural
       (Delete_blocks
          { roots = List.map F.uuid roots
          ; context = F.context db
          }))
;;

let require_plan = function
  | Ok plan -> plan
  | Error _ -> T.fail "valid Delete_blocks did not plan"
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
  | _ -> T.fail "ambiguous fixture UUID"
;;

let with_ops db ops = Datascript.db_with ops db

let comments_area db area_uuid target_uuid =
  let area = F.entity db (F.uuid area_uuid) in
  let target = F.entity db (F.uuid target_uuid) in
  let tag = Datascript.Temp_id "comments-tag" in
  with_ops
    db
    [ Datascript.Add (tag, "block/uuid", Uuid F.inserted_one)
    ; Add (tag, "block/title", String "Comments")
    ; Add (tag, "block/name", String "comments")
    ; Add (tag, "db/ident", Keyword "logseq.class/Comments")
    ; Add (Entity_id area, "block/tags", Ref_to tag)
    ; Add
        ( Entity_id area
        , "logseq.property.comments/blocks"
        , Ref_to (Entity_id target) )
    ]
;;

let () =
  T.run
    "delete blocks"
    [ T.case "hard subtree delete" (fun () ->
        let db = F.db () in
        let after = (apply db (require_plan (delete db [ F.root_one ]))).db_after in
        List.iter
          (fun uuid ->
             T.require
               (Option.is_none (optional_entity after (F.uuid uuid)))
               "hard delete retained %s"
               uuid)
          [ F.root_one; F.child_one; F.child_two ])
    ; T.case "selected ancestor deduplication" (fun () ->
        let db = F.db () in
        let plan = require_plan (delete db [ F.child_one; F.root_one ]) in
        T.require
          (List.length plan.changed_uuids
           = List.length (List.sort_uniq Uuid.compare plan.changed_uuids))
          "ancestor selection planned a descendant twice";
        let after = (apply db plan).db_after in
        T.require
          (Option.is_none (optional_entity after (F.uuid F.child_one)))
          "selected descendant survived ancestor deletion")
    ; T.case "built-in rejection" (fun () ->
        match delete (F.db ()) [ F.root_one; F.built_in ] with
        | Error Plan.Built_in_protected -> ()
        | _ -> T.fail "built-in delete was accepted")
    ; T.case "reference cleanup" (fun () ->
        let db = F.db () in
        let source = F.entity db (F.uuid F.root_two) in
        let target = F.entity db (F.uuid F.child_one) in
        let db =
          with_ops
            db
            [ Datascript.Add
                ( Entity_id source
                , "block/title"
                , String ("See [[" ^ F.child_one ^ "]] now") )
            ; Add (Entity_id source, "block/refs", Ref_to (Entity_id target))
            ]
        in
        let after = (apply db (require_plan (delete db [ F.child_one ]))).db_after in
        let source = F.entity after (F.uuid F.root_two) in
        T.require
          (F.values after source "block/refs" = [])
          "incoming block/refs relation survived delete";
        T.require
          (F.string after source "block/title" = "See Child one now")
          "deleted reference was not replaced with its title")
    ; T.case "range-comment cleanup" (fun () ->
        let db = comments_area (F.db ()) F.empty F.root_one in
        let after = (apply db (require_plan (delete db [ F.root_one ]))).db_after in
        T.require
          (Option.is_none (optional_entity after (F.uuid F.empty)))
          "orphaned range-comments area survived delete")
    ; T.case "default property value replacement" (fun () ->
        let db = F.db () in
        let property = F.entity db (F.uuid F.page_two) in
        let holder = F.entity db (F.uuid F.root_one) in
        let value = F.entity db (F.uuid F.root_two) in
        let default = F.entity db (F.uuid F.child_two) in
        let placeholder = Datascript.Temp_id "empty-placeholder" in
        let db =
          with_ops
            db
            [ Datascript.Add (Entity_id property, "db/ident", Keyword "user.property/example")
            ; Add
                ( Entity_id property
                , "logseq.property/default-value"
                , Ref_to (Entity_id default) )
            ; Add
                ( Entity_id value
                , "logseq.property/created-from-property"
                , Ref_to (Entity_id property) )
            ; Add
                ( Entity_id holder
                , "user.property/example"
                , Ref_to (Entity_id value) )
            ; Add (placeholder, "block/uuid", Uuid F.inserted_two)
            ; Add (placeholder, "block/title", String "Empty placeholder")
            ; Add (placeholder, "block/name", String "empty placeholder")
            ; Add
                ( placeholder
                , "db/ident"
                , Keyword "logseq.property/empty-placeholder" )
            ]
        in
        let after = (apply db (require_plan (delete db [ F.root_two ]))).db_after in
        let holder = F.entity after (F.uuid F.root_one) in
        let placeholder = F.entity after (F.uuid F.inserted_two) in
        T.require
          (F.reference after holder "user.property/example" = placeholder)
          "default property value was not replaced with the empty placeholder";
        T.require
          (Option.is_some (optional_entity after (F.uuid F.root_two)))
          "default property value block should remain available")
    ; T.case "empty roots are rejected" (fun () ->
        match delete (F.db ()) [] with
        | Error (Plan.Invalid_tree _) -> ()
        | _ -> T.fail "empty delete roots were accepted")
    ; T.case "missing UUID rejects whole mutation" (fun () ->
        let db = F.db () in
        match delete db [ F.root_one; F.missing_reference ] with
        | Error (Plan.Invalid_selection _) ->
          T.require
            (Option.is_some (optional_entity db (F.uuid F.root_one)))
            "failed delete planning changed the source db"
        | _ -> T.fail "partially resolvable delete was accepted")
    ; T.case "duplicate UUIDs are rejected" (fun () ->
        match delete (F.db ()) [ F.root_one; F.root_one ] with
        | Error (Plan.Invalid_tree _) -> ()
        | _ -> T.fail "duplicate delete roots were accepted")
    ; T.case "no recycle metadata remains for block delete" (fun () ->
        let db = F.db () in
        let after = (apply db (require_plan (delete db [ F.root_two ]))).db_after in
        T.require
          (Option.is_none (optional_entity after (F.uuid F.root_two)))
          "block delete recycled instead of hard-deleting";
        T.require
          (Datascript.datoms after Datascript.Aevt ~a:"logseq.property/deleted-at" ()
           |> Seq.uncons
           |> Option.is_none)
          "block delete wrote recycle metadata")
    ; T.case "transaction metadata and page tx-id match oracle" (fun () ->
        let db = F.db () in
        let plan = require_plan (delete db [ F.root_two ]) in
        T.require
          (List.assoc_opt "outliner-op" plan.tx_meta
           = Some (Datascript.Keyword "delete-blocks"))
          "delete transaction metadata is missing";
        let report = apply db plan in
        let current_tx =
          match List.assoc_opt "db/current-tx" report.tempids with
          | Some tx -> tx
          | None -> T.fail "transaction has no current tx tempid"
        in
        let page = F.entity report.db_after (F.uuid F.page_one) in
        T.require
          (F.integer report.db_after page "block/tx-id" = current_tx)
          "delete page tx-id does not match the transaction";
        T.require
          (F.integer report.db_after page "block/updated-at" = Int64.to_int F.now_ms)
          "delete did not touch the containing page")
    ]
