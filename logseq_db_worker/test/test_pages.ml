module T = Logseq_db_worker_test_support.Test_support
module Plan = Logseq_db_worker__Mutation_plan
module Protocol = Logseq_db_worker.Protocol
module Uuid = Logseq_db_worker.Graph_types.Uuid

let now_ms = 1_704_067_299_999L
let ordinary_uuid = "10000000-0000-4000-8000-000000000001"
let namespace_uuid = "10000000-0000-4000-8000-000000000002"
let class_uuid = "10000000-0000-4000-8000-000000000003"
let property_uuid = "10000000-0000-4000-8000-000000000004"
let journal_uuid = "00000001-2024-0101-0000-000000000000"
let built_in_uuid = "10000000-0000-4000-8000-000000000006"
let hidden_uuid = "10000000-0000-4000-8000-000000000007"
let recycle_uuid = "10000000-0000-4000-8000-000000000008"
let referring_page_uuid = "10000000-0000-4000-8000-000000000009"
let root_uuid = "20000000-0000-4000-8000-000000000001"
let child_uuid = "20000000-0000-4000-8000-000000000002"
let referring_block_uuid = "20000000-0000-4000-8000-000000000003"
let page_class_uuid = "30000000-0000-4000-8000-000000000001"
let tag_class_uuid = "30000000-0000-4000-8000-000000000002"
let property_class_uuid = "30000000-0000-4000-8000-000000000003"
let journal_class_uuid = "30000000-0000-4000-8000-000000000004"
let root_class_uuid = "30000000-0000-4000-8000-000000000005"
let block_tags_property_uuid = "30000000-0000-4000-8000-000000000006"
let class_extends_property_uuid = "30000000-0000-4000-8000-000000000007"
let created_uuid = "40000000-0000-4000-8000-000000000001"
let created_class_uuid = "40000000-0000-4000-8000-000000000002"
let mutation_uuid = "50000000-0000-4000-8000-000000000001"

let uuid value =
  match Uuid.of_string value with
  | Ok value -> value
  | Error message -> T.fail "invalid fixture UUID: %s" message
;;

let schema_attr ?(cardinality = Datascript.One) ?unique ?(indexed = false) ?value_type () =
  Datascript.
    { cardinality
    ; unique
    ; indexed
    ; is_component = false
    ; no_history = false
    ; doc = None
    ; value_type
    ; tuple_attrs = None
    ; tuple_types = None
    }
;;

let schema =
  [ ( "block/uuid"
    , schema_attr
        ~unique:Datascript.Identity
        ~indexed:true
        ~value_type:Datascript.UuidType
        () )
  ; ( "db/ident"
    , schema_attr
        ~unique:Datascript.Identity
        ~indexed:true
        ~value_type:Datascript.KeywordType
        () )
  ; "block/name", schema_attr ~indexed:true ~value_type:Datascript.StringType ()
  ; "block/title", schema_attr ~value_type:Datascript.StringType ()
  ; "block/order", schema_attr ~value_type:Datascript.StringType ()
  ; "block/parent", schema_attr ~indexed:true ~value_type:Datascript.RefType ()
  ; "block/page", schema_attr ~indexed:true ~value_type:Datascript.RefType ()
  ; "block/journal-day", schema_attr ~indexed:true ~value_type:Datascript.NumberType ()
  ; ( "block/refs"
    , schema_attr
        ~cardinality:Datascript.Many
        ~indexed:true
        ~value_type:Datascript.RefType
        () )
  ; ( "block/tags"
    , schema_attr
        ~cardinality:Datascript.Many
        ~indexed:true
        ~value_type:Datascript.RefType
        () )
  ; ( "block/alias"
    , schema_attr
        ~cardinality:Datascript.Many
        ~indexed:true
        ~value_type:Datascript.RefType
        () )
  ; "logseq.property/built-in?", schema_attr ()
  ; "logseq.property/hide?", schema_attr ()
  ; "logseq.property/deleted-at", schema_attr ~value_type:Datascript.NumberType ()
  ; ( "logseq.property.recycle/original-parent"
    , schema_attr ~indexed:true ~value_type:Datascript.RefType () )
  ; ( "logseq.property.recycle/original-page"
    , schema_attr ~indexed:true ~value_type:Datascript.RefType () )
  ; ( "logseq.property.recycle/original-order"
    , schema_attr ~value_type:Datascript.StringType () )
  ]
;;

let page ?parent ?order ?journal_day ?(tags = []) id uuid title name =
  let optional =
    Option.to_list
      (Option.map (fun value -> Datascript.Add (id, "block/parent", Ref_to value)) parent)
    @ Option.to_list
        (Option.map (fun value -> Datascript.Add (id, "block/order", String value)) order)
    @ Option.to_list
        (Option.map
           (fun value -> Datascript.Add (id, "block/journal-day", Int value))
           journal_day)
  in
  [ Datascript.Add (id, "block/uuid", Uuid uuid)
  ; Add (id, "block/title", String title)
  ; Add (id, "block/name", String name)
  ; Add (id, "block/created-at", Int 1_704_067_200_000)
  ; Add (id, "block/updated-at", Int 1_704_067_200_000)
  ]
  @ optional
  @ List.map (fun tag -> Datascript.Add (id, "block/tags", Ref_to tag)) tags
;;

let block id uuid title parent page order =
  [ Datascript.Add (id, "block/uuid", Uuid uuid)
  ; Add (id, "block/title", String title)
  ; Add (id, "block/parent", Ref_to parent)
  ; Add (id, "block/page", Ref_to page)
  ; Add (id, "block/order", String order)
  ; Add (id, "block/created-at", Int 1_704_067_200_000)
  ; Add (id, "block/updated-at", Int 1_704_067_200_000)
  ]
;;

let fixture () =
  let ordinary = Datascript.Temp_id "ordinary" in
  let namespaced = Datascript.Temp_id "namespaced" in
  let class_page = Datascript.Temp_id "class-page" in
  let property_page = Datascript.Temp_id "property-page" in
  let journal = Datascript.Temp_id "journal" in
  let built_in = Datascript.Temp_id "built-in" in
  let hidden = Datascript.Temp_id "hidden" in
  let recycle = Datascript.Temp_id "recycle" in
  let referring_page = Datascript.Temp_id "referring-page" in
  let root = Datascript.Temp_id "root" in
  let child = Datascript.Temp_id "child" in
  let referring_block = Datascript.Temp_id "referring-block" in
  let page_class = Datascript.Temp_id "page-class" in
  let tag_class = Datascript.Temp_id "tag-class" in
  let property_class = Datascript.Temp_id "property-class" in
  let journal_class = Datascript.Temp_id "journal-class" in
  let root_class = Datascript.Temp_id "root-class" in
  let block_tags_property = Datascript.Temp_id "block-tags-property" in
  let class_extends_property = Datascript.Temp_id "class-extends-property" in
  Datascript.empty_db ~schema ()
  |> Datascript.db_with
       (page page_class page_class_uuid "Page" "page"
        @ page tag_class tag_class_uuid "Tag" "tag"
        @ page property_class property_class_uuid "Property" "property"
        @ page journal_class journal_class_uuid "Journal" "journal"
        @ page root_class root_class_uuid "Root" "root"
        @ page
            block_tags_property
            block_tags_property_uuid
            "Tags"
            "tags"
        @ page
            class_extends_property
            class_extends_property_uuid
            "Extends"
            "extends"
        @ [ Datascript.Add (page_class, "db/ident", Keyword "logseq.class/Page")
          ; Add (tag_class, "db/ident", Keyword "logseq.class/Tag")
          ; Add (property_class, "db/ident", Keyword "logseq.class/Property")
          ; Add (journal_class, "db/ident", Keyword "logseq.class/Journal")
          ; Add (root_class, "db/ident", Keyword "logseq.class/Root")
          ; Add (block_tags_property, "db/ident", Keyword "block/tags")
          ; Add
              ( class_extends_property
              , "db/ident"
              , Keyword "logseq.property.class/extends" )
          ]
        @ page ~tags:[ page_class ] ordinary ordinary_uuid "Old Page" "old page"
        @ page
            ~parent:ordinary
            ~order:"a1"
            ~tags:[ page_class ]
            namespaced
            namespace_uuid
            "Child Page"
            "child page"
        @ page ~tags:[ tag_class ] class_page class_uuid "Class Page" "class page"
        @ page
            ~tags:[ property_class ]
            property_page
            property_uuid
            "Property Page"
            "property page"
        @ page
            ~journal_day:20240101
            ~tags:[ journal_class ]
            journal
            journal_uuid
            "Jan 1st, 2024"
            "jan 1st, 2024"
        @ page ~tags:[ page_class ] built_in built_in_uuid "Built In" "built in"
        @ page ~tags:[ page_class ] hidden hidden_uuid "Hidden" "hidden"
        @ page ~tags:[ page_class ] recycle recycle_uuid "Recycle" "recycle"
        @ page
            ~tags:[ page_class ]
            referring_page
            referring_page_uuid
            "Referring"
            "referring"
        @ block root root_uuid "Root" ordinary ordinary "a0"
        @ block child child_uuid "Child" root ordinary "a0"
        @ block
            referring_block
            referring_block_uuid
            "See [[Old Page]]"
            referring_page
            referring_page
            "a0"
        @ [ Datascript.Add (referring_block, "block/refs", Ref_to ordinary)
          ; Add (referring_page, "block/alias", Ref_to ordinary)
          ; Add (built_in, "logseq.property/built-in?", Bool true)
          ; Add (hidden, "logseq.property/hide?", Bool true)
          ; Add (recycle, "logseq.property/built-in?", Bool true)
          ; Add (recycle, "logseq.property/hide?", Bool true)
          ])
;;

let entity db uuid =
  match
    Datascript.datoms
      db
      Datascript.Avet
      ~a:"block/uuid"
      ~v:(Datascript.Uuid (Uuid.to_string uuid))
      ()
    |> List.of_seq
  with
  | [ datom ] -> datom.Datascript.e
  | _ -> T.fail "unable to resolve fixture UUID %s" (Uuid.to_string uuid)
;;

let entity_opt db uuid =
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
  | _ -> T.fail "ambiguous fixture UUID %s" (Uuid.to_string uuid)
;;

let values db entity attr =
  Datascript.datoms db Datascript.Eavt ~e:entity ~a:attr ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.v)
;;

let one db entity attr =
  match values db entity attr with
  | [ value ] -> value
  | [] -> T.fail "missing %s" attr
  | _ -> T.fail "multiple %s values" attr
;;

let string db entity attr =
  match one db entity attr with
  | Datascript.String value -> value
  | _ -> T.fail "%s is not a string" attr
;;

let reference db entity attr =
  match one db entity attr with
  | Datascript.Ref value -> value
  | _ -> T.fail "%s is not a reference" attr
;;

let has_value db entity attr value = List.mem value (values db entity attr)

let context db =
  Protocol.
    { mutation_id = uuid mutation_uuid
    ; expected_basis = Int64.of_int (Datascript.serializable db).serializable_max_tx
    }
;;

let plan db mutation = Plan.plan ~now_ms db (Protocol.Page mutation)

let require_plan = function
  | Ok plan -> plan
  | Error _ -> T.fail "valid page mutation did not plan"
;;

let apply db plan = Datascript.with_tx ~tx_meta:plan.Plan.tx_meta db plan.tx_ops

let create ?(title = "Created Page") db kind =
  plan db (Protocol.Create_page { title; kind; context = context db })
;;

let mutate db mutation = apply db (require_plan (plan db mutation))

let delete db page =
  mutate db (Protocol.Delete_page { page; context = context db })
  |> fun report -> report.db_after
;;

let () =
  T.run
    "pages"
    [ T.case "create ordinary page with caller UUID" (fun () ->
        let db = fixture () in
        let report =
          apply
            db
            (require_plan (create db (Create_ordinary_page { uuid = uuid created_uuid })))
        in
        let page = entity report.db_after (uuid created_uuid) in
        T.require
          (String.equal (string report.db_after page "block/title") "Created Page")
          "wrong title";
        T.require
          (String.equal (string report.db_after page "block/name") "created page")
          "wrong name";
        T.require
          (has_value
             report.db_after
             page
             "block/tags"
             (Datascript.Ref (entity report.db_after (uuid page_class_uuid))))
          "ordinary page tag is missing")
    ; T.case "create journal page derives canonical UUID" (fun () ->
        let db = fixture () in
        let expected = uuid "00000001-2024-0102-0000-000000000000" in
        let report =
          apply
            db
            (require_plan
               (create
                  ~title:"Jan 2nd, 2024"
                  db
                  (Create_journal_page { journal_day = 20240102; supplied_uuid = None })))
        in
        let page = entity report.db_after expected in
        T.require
          (one report.db_after page "block/journal-day" = Datascript.Int 20240102)
          "journal day is missing")
    ; T.case "create class page" (fun () ->
        let db = fixture () in
        let report =
          apply
            db
            (require_plan
               (create db (Create_class_page { uuid = uuid created_class_uuid })))
        in
        let page = entity report.db_after (uuid created_class_uuid) in
        T.require
          (has_value
             report.db_after
             page
             "block/tags"
             (Datascript.Ref (entity report.db_after (uuid tag_class_uuid))))
          "class page tag is missing")
    ; T.case "create collision policy" (fun () ->
        let db = fixture () in
        (match
           create ~title:"Old Page" db (Create_ordinary_page { uuid = uuid created_uuid })
         with
         | Error (Plan.Conflict _) -> ()
         | _ -> T.fail "existing page title was accepted");
        match create db (Create_ordinary_page { uuid = uuid ordinary_uuid }) with
        | Error (Plan.Conflict _) -> ()
        | _ -> T.fail "existing page UUID was accepted")
    ; T.case "create rejects namespace parent creation" (fun () ->
        match
          create
            ~title:"Missing Parent/Child"
            (fixture ())
            (Create_ordinary_page { uuid = uuid created_uuid })
        with
        | Error (Plan.Unsupported_semantics _) -> ()
        | _ -> T.fail "implicit namespace parent creation was accepted")
    ; T.case "create rejects restore and kind conversion" (fun () ->
        let recycled = delete (fixture ()) (uuid ordinary_uuid) in
        (match
           create
             ~title:"Old Page"
             recycled
             (Create_ordinary_page { uuid = uuid ordinary_uuid })
         with
         | Error (Plan.Conflict _) -> ()
         | _ -> T.fail "create restored a recycled identity");
        match
          create
            ~title:"Class Page"
            (fixture ())
            (Create_ordinary_page { uuid = uuid created_uuid })
        with
        | Error (Plan.Conflict _) -> ()
        | _ -> T.fail "create converted an existing class page")
    ; T.case "rename normalizes page name" (fun () ->
        let db = fixture () in
        let report =
          mutate
            db
            (Rename_page
               { page = uuid ordinary_uuid
               ; title = "  RENAMED PAGE  "
               ; context = context db
               })
        in
        let page = entity report.db_after (uuid ordinary_uuid) in
        T.require
          (String.equal (string report.db_after page "block/title") "RENAMED PAGE")
          "wrong title";
        T.require
          (String.equal (string report.db_after page "block/name") "renamed page")
          "wrong normalized name")
    ; T.case "rename rewrites references and aliases" (fun () ->
        let db = fixture () in
        let report =
          mutate
            db
            (Rename_page
               { page = uuid ordinary_uuid; title = "Renamed"; context = context db })
        in
        let referring = entity report.db_after (uuid referring_block_uuid) in
        T.require
          (String.equal
             (string report.db_after referring "block/title")
             ("See [[" ^ ordinary_uuid ^ "]]"))
          "inbound page title was not canonicalized";
        let alias_page = entity report.db_after (uuid referring_page_uuid) in
        T.require
          (has_value
             report.db_after
             alias_page
             "block/alias"
             (Datascript.Ref (entity report.db_after (uuid ordinary_uuid))))
          "UUID-backed alias was not preserved")
    ; T.case "rename cleans orphan references" (fun () ->
        let db = fixture () in
        let page = entity db (uuid ordinary_uuid) in
        let db =
          Datascript.db_with
            [ Datascript.Add
                ( Entity_id page
                , "block/refs"
                , Ref_to (Entity_id (entity db (uuid class_uuid))) )
            ]
            db
        in
        let report =
          mutate
            db
            (Rename_page
               { page = uuid ordinary_uuid
               ; title = "No references"
               ; context = context db
               })
        in
        T.require
          (not
             (has_value
                report.db_after
                (entity report.db_after (uuid ordinary_uuid))
                "block/refs"
                (Datascript.Ref (entity report.db_after (uuid class_uuid)))))
          "orphan page references survived rename")
    ; T.case "ordinary delete creates recycle metadata" (fun () ->
        let db = delete (fixture ()) (uuid namespace_uuid) in
        let page = entity db (uuid namespace_uuid) in
        T.require
          (reference db page "block/parent" = entity db (uuid recycle_uuid))
          "wrong recycle parent";
        T.require
          (reference db page "logseq.property.recycle/original-parent"
           = entity db (uuid ordinary_uuid))
          "original parent was not recorded";
        T.require
          (String.equal (string db page "logseq.property.recycle/original-order") "a1")
          "original order was not recorded")
    ; T.case "today journal delete clears instead of recycling" (fun () ->
        let db = fixture () in
        let journal = entity db (uuid journal_uuid) in
        let db =
          Datascript.db_with
            (block
               (Temp_id "journal-block")
               created_uuid
               "Today"
               (Entity_id journal)
               (Entity_id journal)
               "a0")
            db
        in
        let report =
          mutate db (Delete_page { page = uuid journal_uuid; context = context db })
        in
        T.require
          (Option.is_some (entity_opt report.db_after (uuid journal_uuid)))
          "today journal was deleted";
        T.require
          (Option.is_none (entity_opt report.db_after (uuid created_uuid)))
          "today journal block survived";
        let page = entity report.db_after (uuid journal_uuid) in
        T.require
          (values report.db_after page "logseq.property/deleted-at" = [])
          "today journal was recycled")
    ; T.case "built-in and hidden pages reject delete" (fun () ->
        let db = fixture () in
        List.iter
          (fun page ->
             match plan db (Delete_page { page; context = context db }) with
             | Error Plan.Built_in_protected -> ()
             | _ -> T.fail "protected page was deletable")
          [ uuid built_in_uuid; uuid hidden_uuid ])
    ; T.case "class and property delete rules" (fun () ->
        let class_deleted = delete (fixture ()) (uuid class_uuid) in
        T.require
          (Option.is_none (entity_opt class_deleted (uuid class_uuid)))
          "class was recycled";
        let property_deleted = delete (fixture ()) (uuid property_uuid) in
        T.require
          (Option.is_none (entity_opt property_deleted (uuid property_uuid)))
          "property was recycled")
    ; T.case "restore uses recorded parent and order" (fun () ->
        let recycled = delete (fixture ()) (uuid namespace_uuid) in
        let report =
          mutate
            recycled
            (Restore_recycled_page
               { page = uuid namespace_uuid; context = context recycled })
        in
        let page = entity report.db_after (uuid namespace_uuid) in
        T.require
          (reference report.db_after page "block/parent"
           = entity report.db_after (uuid ordinary_uuid))
          "restore did not reuse original parent";
        T.require
          (String.equal (string report.db_after page "block/order") "a1")
          "restore changed order";
        T.require
          (values report.db_after page "logseq.property/deleted-at" = [])
          "restore metadata survived")
    ; T.case "top-level restore" (fun () ->
        let recycled = delete (fixture ()) (uuid ordinary_uuid) in
        let report =
          mutate
            recycled
            (Restore_recycled_page
               { page = uuid ordinary_uuid; context = context recycled })
        in
        let page = entity report.db_after (uuid ordinary_uuid) in
        T.require
          (values report.db_after page "block/parent" = [])
          "top-level page gained a parent";
        T.require
          (values report.db_after page "block/order" = [])
          "top-level page gained an order")
    ; T.case "restore rejects order repair" (fun () ->
        let recycled = delete (fixture ()) (uuid namespace_uuid) in
        let parent = entity recycled (uuid ordinary_uuid) in
        let db =
          Datascript.db_with
            (page
               ~parent:(Entity_id parent)
               ~order:"a1"
               ~tags:[ Entity_id (entity recycled (uuid page_class_uuid)) ]
               (Temp_id "collision")
               created_uuid
               "Collision"
               "collision")
            recycled
        in
        match
          plan
            db
            (Restore_recycled_page { page = uuid namespace_uuid; context = context db })
        with
        | Error (Plan.Invalid_order _) -> ()
        | _ -> T.fail "restore silently repaired an order collision")
    ; T.case "permanent delete requires recycled page" (fun () ->
        let db = fixture () in
        match
          plan
            db
            (Permanently_delete_recycled_page
               { page = uuid ordinary_uuid; context = context db })
        with
        | Error (Plan.Invalid_selection _) -> ()
        | _ -> T.fail "active page was permanently deleted")
    ; T.case "permanent delete removes subtree and relations" (fun () ->
        let recycled = delete (fixture ()) (uuid ordinary_uuid) in
        let report =
          mutate
            recycled
            (Permanently_delete_recycled_page
               { page = uuid ordinary_uuid; context = context recycled })
        in
        List.iter
          (fun value ->
             T.require
               (Option.is_none (entity_opt report.db_after (uuid value)))
               "deleted subtree survived")
          [ ordinary_uuid; namespace_uuid; root_uuid; child_uuid ];
        let referring = entity report.db_after (uuid referring_block_uuid) in
        T.require
          (values report.db_after referring "block/refs" = [])
          "inbound relation survived")
    ; T.case "ambiguous title returns Ambiguous_selector" (fun () ->
        let db = fixture () in
        let db =
          Datascript.db_with
            (page
               ~tags:[ Entity_id (entity db (uuid page_class_uuid)) ]
               (Temp_id "duplicate-a")
               created_uuid
               "Duplicate"
               "duplicate"
             @ page
                 ~tags:[ Entity_id (entity db (uuid page_class_uuid)) ]
                 (Temp_id "duplicate-b")
                 created_class_uuid
                 "DUPLICATE"
                 "duplicate")
            db
        in
        match
          create
            ~title:"duplicate"
            db
            (Create_ordinary_page { uuid = uuid "40000000-0000-4000-8000-000000000003" })
        with
        | Error (Plan.Invalid_selection message) ->
          T.require
            (String.equal message "ambiguous page selector")
            "wrong ambiguity diagnostic"
        | _ -> T.fail "ambiguous page title was not rejected")
    ; T.case "UUID identity remains stable" (fun () ->
        let db = fixture () in
        let renamed =
          mutate
            db
            (Rename_page
               { page = uuid ordinary_uuid
               ; title = "Stable Identity"
               ; context = context db
               })
          |> fun report -> report.db_after
        in
        let recycled = delete renamed (uuid ordinary_uuid) in
        let restored =
          mutate
            recycled
            (Restore_recycled_page
               { page = uuid ordinary_uuid; context = context recycled })
          |> fun report -> report.db_after
        in
        T.require
          (Option.is_some (entity_opt restored (uuid ordinary_uuid)))
          "page UUID changed")
    ]
;;
