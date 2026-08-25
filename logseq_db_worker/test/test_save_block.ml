module T = Logseq_db_worker_test_support.Test_support
module Plan = Logseq_db_worker__Mutation_plan
module Graph_read = Logseq_db_worker__Outliner__Graph_read
module Protocol = Logseq_db_worker.Protocol
module Uuid = Logseq_db_worker.Graph_types.Uuid

let page_uuid_text = "11111111-1111-4111-8111-111111111111"
let block_uuid_text = "22222222-2222-4222-8222-222222222222"
let target_uuid_text = "33333333-3333-4333-8333-333333333333"
let reference_uuid_text = "44444444-4444-4444-8444-444444444444"
let tag_uuid_text = "55555555-5555-4555-8555-555555555555"
let journal_uuid_text = "66666666-6666-4666-8666-666666666666"
let old_stub_uuid_text = "77777777-7777-4777-8777-777777777777"
let built_in_uuid_text = "88888888-8888-4888-8888-888888888888"
let scheduled_property_uuid_text = "99999999-9999-4999-8999-999999999999"
let deadline_property_uuid_text = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
let mutation_uuid_text = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
let missing_uuid_text = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
let now_ms = 1_704_067_299_999L

let uuid value =
  match Uuid.of_string value with
  | Ok uuid -> uuid
  | Error message -> T.fail "%s" message
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
  ; ( "logseq.property/scheduled"
    , schema_attr ~indexed:true ~value_type:Datascript.RefType () )
  ; ( "logseq.property/deadline"
    , schema_attr ~indexed:true ~value_type:Datascript.RefType () )
  ]
;;

let page id uuid title name =
  [ Datascript.Add (id, "block/uuid", Uuid uuid)
  ; Add (id, "block/title", String title)
  ; Add (id, "block/name", String name)
  ; Add (id, "block/created-at", Int 1_704_067_200_000)
  ; Add (id, "block/updated-at", Int 1_704_067_200_000)
  ]
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
  let page_id = Datascript.Temp_id "page" in
  let block_id = Datascript.Temp_id "block" in
  let target_id = Datascript.Temp_id "target" in
  let reference_id = Datascript.Temp_id "reference" in
  let tag_id = Datascript.Temp_id "tag" in
  let journal_id = Datascript.Temp_id "journal" in
  let old_stub_id = Datascript.Temp_id "old-stub" in
  let built_in_id = Datascript.Temp_id "built-in" in
  let scheduled_property_id = Datascript.Temp_id "scheduled-property" in
  let deadline_property_id = Datascript.Temp_id "deadline-property" in
  Datascript.empty_db ~schema ()
  |> Datascript.db_with
       (page page_id page_uuid_text "Page" "page"
        @ block
            block_id
            block_uuid_text
            ("Old [[" ^ old_stub_uuid_text ^ "]] title")
            page_id
            page_id
            "a0"
        @ block target_id target_uuid_text "Target" page_id page_id "a1"
        @ page reference_id reference_uuid_text "Reference Page" "reference page"
        @ page tag_id tag_uuid_text "Tag" "tag"
        @ page journal_id journal_uuid_text "Jan 2nd, 2024" "jan 2nd, 2024"
        @ page old_stub_id old_stub_uuid_text "Old Stub" "old stub"
        @ block built_in_id built_in_uuid_text "Built in" page_id page_id "a2"
        @ page scheduled_property_id scheduled_property_uuid_text "Scheduled" "scheduled"
        @ page deadline_property_id deadline_property_uuid_text "Deadline" "deadline"
        @ [ Datascript.Add (tag_id, "db/ident", Keyword "user.class/tag")
          ; Add (scheduled_property_id, "db/ident", Keyword "logseq.property/scheduled")
          ; Add (deadline_property_id, "db/ident", Keyword "logseq.property/deadline")
          ; Add (scheduled_property_id, "logseq.property/type", Keyword "datetime")
          ; Add (deadline_property_id, "logseq.property/type", Keyword "datetime")
          ; Add (journal_id, "block/journal-day", Int 20240102)
          ; Add (block_id, "block/refs", Ref_to old_stub_id)
          ; Add (block_id, "logseq.property/scheduled", Ref_to journal_id)
          ; Add (block_id, "logseq.property/deadline", Ref_to journal_id)
          ; Add (built_in_id, "logseq.property/built-in?", Bool true)
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

let ref_entities db entity attr =
  values db entity attr
  |> List.map (function
    | Datascript.Ref entity -> entity
    | _ -> T.fail "%s contains a non-reference" attr)
  |> List.sort_uniq Int.compare
;;

let context db mutation_id =
  Protocol.
    { mutation_id
    ; expected_basis = Int64.of_int (Datascript.serializable db).serializable_max_tx
    }
;;

let save ?(block = uuid block_uuid_text) ?(mutation_id = uuid mutation_uuid_text) db title
  =
  Plan.plan
    ~now_ms
    db
    (Protocol.Structural (Save_block { block; title; context = context db mutation_id }))
;;

let require_plan = function
  | Ok plan -> plan
  | Error _ -> T.fail "valid Save_block did not plan"
;;

let apply db plan = Datascript.with_tx ~tx_meta:plan.Plan.tx_meta db plan.tx_ops

let require_string expected = function
  | Datascript.String actual ->
    T.require (String.equal actual expected) "expected %S, got %S" expected actual
  | _ -> T.fail "expected string value"
;;

let require_int expected = function
  | Datascript.Int actual ->
    T.require (actual = expected) "expected %d, got %d" expected actual
  | _ -> T.fail "expected integer value"
;;

let contains_uuid values expected = List.exists (Uuid.equal expected) values
let changed_uuids plan = plan.Plan.changed_uuids

let graph_read_schema =
  [ "block/uuid", schema_attr ~indexed:true ()
  ; "block/parent", schema_attr ~indexed:true ()
  ; "test/many", schema_attr ~cardinality:Datascript.Many ()
  ]
;;

let graph_read_fixture () =
  let parent = Datascript.Temp_id "graph-read-parent" in
  let child = Datascript.Temp_id "graph-read-child" in
  let uuid_entity = Datascript.Temp_id "graph-read-uuid" in
  let string_entity = Datascript.Temp_id "graph-read-string" in
  Datascript.empty_db ~schema:graph_read_schema ()
  |> Datascript.db_with
       [ Datascript.Add (parent, "block/uuid", Uuid block_uuid_text)
       ; Add (parent, "block/name", String "parent")
       ; Add (parent, "test/many", String "first")
       ; Add (parent, "test/many", String "second")
       ; Add (parent, "test/ref", Ref_to child)
       ; Add (parent, "test/enabled", Bool true)
       ; Add (parent, "block/parent", Ref_to parent)
       ; Add (child, "block/parent", Ref_to parent)
       ; Add (uuid_entity, "block/uuid", Uuid target_uuid_text)
       ; Add (string_entity, "block/uuid", String target_uuid_text)
       ]
;;

let () =
  T.run
    "save block"
    [ T.case "built-in block is rejected" (fun () ->
        match save ~block:(uuid built_in_uuid_text) (fixture ()) "Hacked" with
        | Error Plan.Built_in_protected -> ()
        | _ -> T.fail "built-in block was mutable")
    ; T.case "missing selector rejects the complete request" (fun () ->
        match save ~block:(uuid missing_uuid_text) (fixture ()) "Missing" with
        | Error (Plan.Invalid_selection _) -> ()
        | _ -> T.fail "missing block selector was accepted")
    ; T.case "UUID is immutable" (fun () ->
        let db = fixture () in
        let report = apply db (require_plan (save db "Changed")) in
        let block = entity report.db_after (uuid block_uuid_text) in
        match one report.db_after block "block/uuid" with
        | Datascript.Uuid actual ->
          T.require (String.equal actual block_uuid_text) "Save_block changed UUID"
        | _ -> T.fail "Save_block changed UUID value type")
    ; T.case "title changes through canonical pipeline" (fun () ->
        let db = fixture () in
        let report = apply db (require_plan (save db "Changed title")) in
        require_string
          "Changed title"
          (one
             report.db_after
             (entity report.db_after (uuid block_uuid_text))
             "block/title"))
    ; T.case "unchanged save returns No_change" (fun () ->
        let db = fixture () in
        let title = "Old [[" ^ old_stub_uuid_text ^ "]] title" in
        let plan = require_plan (save db title) in
        T.require (plan.Plan.tx_ops = []) "unchanged save staged a transaction";
        T.require (plan.changed_uuids = []) "unchanged save reported changes";
        T.require (plan.status = Protocol.No_change) "unchanged save was not No_change")
    ; T.case "shared graph reads preserve raw storage invariants" (fun () ->
        let db = graph_read_fixture () in
        let parent =
          match Graph_read.entities_by_uuid db (uuid block_uuid_text) with
          | [ entity ] -> entity
          | _ -> T.fail "UUID lookup did not resolve the graph-read parent"
        in
        let matching = Graph_read.entities_by_uuid db (uuid target_uuid_text) in
        T.require (List.length matching = 2) "dual UUID encodings were not both resolved";
        T.require
          (matching = List.sort_uniq Int.compare matching)
          "dual UUID lookup was not sorted and deduplicated";
        List.iter
          (fun entity ->
             match Graph_read.uuid_of_entity db entity with
             | Ok actual ->
               T.require (Uuid.equal actual (uuid target_uuid_text)) "entity UUID changed"
             | Error message -> T.fail "entity UUID was not decoded: %s" message)
          matching;
        T.require
          (Graph_read.one db parent "test/many" = None)
          "ambiguous cardinality selected a value";
        T.require
          (Graph_read.string_value db parent "block/name" = Some "parent")
          "string selector changed";
        T.require
          (Option.is_some (Graph_read.reference_value db parent "test/ref"))
          "reference selector changed";
        T.require (Graph_read.has_true db parent "test/enabled") "true selector changed";
        T.require (Graph_read.is_page db parent) "page detection changed";
        let children = Graph_read.children db parent in
        T.require (List.length children = 1) "self-parent datom was returned as a child";
        T.require (List.hd children <> parent) "child lookup retained its parent")
    ; T.case "updated-at uses injected epoch milliseconds" (fun () ->
        let db = fixture () in
        let report = apply db (require_plan (save db "Changed")) in
        require_int
          (Int64.to_int now_ms)
          (one
             report.db_after
             (entity report.db_after (uuid block_uuid_text))
             "block/updated-at"))
    ; T.case "page updated-at follows block save" (fun () ->
        let db = fixture () in
        let report = apply db (require_plan (save db "Changed")) in
        require_int
          (Int64.to_int now_ms)
          (one
             report.db_after
             (entity report.db_after (uuid page_uuid_text))
             "block/updated-at"))
    ; T.case "page name is normalized" (fun () ->
        let db = fixture () in
        let plan = require_plan (save ~block:(uuid page_uuid_text) db "RENAMED PAGE") in
        let report = apply db plan in
        require_string
          "renamed page"
          (one
             report.db_after
             (entity report.db_after (uuid page_uuid_text))
             "block/name"))
    ; T.case "block and page references are derived" (fun () ->
        let db = fixture () in
        let title = "See [[Reference Page]] and ((" ^ target_uuid_text ^ "))" in
        let report = apply db (require_plan (save db title)) in
        let block = entity report.db_after (uuid block_uuid_text) in
        let refs = ref_entities report.db_after block "block/refs" in
        T.require
          (List.mem (entity report.db_after (uuid reference_uuid_text)) refs)
          "page reference was not derived";
        T.require
          (List.mem (entity report.db_after (uuid target_uuid_text)) refs)
          "block reference was not derived";
        require_string
          ("See [[" ^ reference_uuid_text ^ "]] and [[" ^ target_uuid_text ^ "]]")
          (one report.db_after block "block/title"))
    ; T.case "tags are derived" (fun () ->
        let db = fixture () in
        let report = apply db (require_plan (save db "Tagged #Tag")) in
        let block = entity report.db_after (uuid block_uuid_text) in
        let tag = entity report.db_after (uuid tag_uuid_text) in
        T.require
          (List.mem tag (ref_entities report.db_after block "block/tags"))
          "inline tag relation was not derived";
        T.require
          (List.mem tag (ref_entities report.db_after block "block/refs"))
          "inline tag reference was not derived";
        require_string
          ("Tagged [[" ^ tag_uuid_text ^ "]]")
          (one report.db_after block "block/title"))
    ; T.case "scheduled and deadline references are derived" (fun () ->
        let db = fixture () in
        let report = apply db (require_plan (save db "Keep task dates")) in
        let block = entity report.db_after (uuid block_uuid_text) in
        let refs = ref_entities report.db_after block "block/refs" in
        List.iter
          (fun expected ->
             T.require
               (List.mem (entity report.db_after (uuid expected)) refs)
               "missing derived property reference %s"
               expected)
          [ scheduled_property_uuid_text; deadline_property_uuid_text; journal_uuid_text ])
    ; T.case "orphan reference stubs are cleaned" (fun () ->
        let db = fixture () in
        let report = apply db (require_plan (save db "No references")) in
        match
          Datascript.datoms
            report.db_after
            Datascript.Avet
            ~a:"block/uuid"
            ~v:(Datascript.Uuid old_stub_uuid_text)
            ()
          |> Seq.uncons
        with
        | None -> ()
        | Some _ -> T.fail "orphan page-reference stub was retained")
    ; T.case "Unicode title round trips" (fun () ->
        let db = fixture () in
        let title = "你好，Logseq 👋" in
        let report = apply db (require_plan (save db title)) in
        require_string
          title
          (one
             report.db_after
             (entity report.db_after (uuid block_uuid_text))
             "block/title"))
    ; T.case "missing literal Unicode tag is rejected" (fun () ->
        let db = fixture () in
        let title = "中文 👩🏽‍💻 e\204\129 #literal @mention" in
        match save db title with
        | Error
            (Plan.Unsupported_semantics "The title references a missing entity: literal")
          -> ()
        | _ -> T.fail "missing inline tag was not rejected explicitly")
    ; T.case "title size limit is enforced" (fun () ->
        let title = String.make (Protocol.maximum_title_bytes + 1) 'x' in
        match save (fixture ()) title with
        | Error (Plan.Unsupported_semantics _) -> ()
        | _ -> T.fail "oversized title was accepted")
    ; T.case "commands templates and unsupported assets reject pre-stage" (fun () ->
        List.iter
          (fun title ->
             match save (fixture ()) title with
             | Error (Plan.Unsupported_semantics _) -> ()
             | _ -> T.fail "unsupported automatic effect was accepted: %s" title)
          [ "{{renderer :command}}"
          ; "{{template Daily}}"
          ; "![asset](../assets/file.png)"
          ])
    ; T.case "transaction metadata and block tx-id match oracle" (fun () ->
        let db = fixture () in
        let mutation_id = uuid mutation_uuid_text in
        let plan = require_plan (save ~mutation_id db "Changed") in
        let lookup attr = List.assoc_opt attr plan.Plan.tx_meta in
        T.require
          (lookup "db-sync/tx-id" = Some (Datascript.Uuid mutation_uuid_text))
          "transaction UUID metadata is missing";
        T.require
          (lookup "outliner-op" = Some (Datascript.Keyword "save-block"))
          "outliner operation metadata is missing";
        T.require
          (lookup "local-tx?" = Some (Datascript.Bool true))
          "local transaction metadata is missing";
        let report = apply db plan in
        let current_tx =
          match List.assoc_opt "db/current-tx" report.tempids with
          | Some tx -> tx
          | None -> T.fail "transaction has no current tx tempid"
        in
        List.iter
          (fun expected_uuid ->
             require_int
               current_tx
               (one report.db_after (entity report.db_after expected_uuid) "block/tx-id"))
          [ uuid block_uuid_text; uuid page_uuid_text ];
        T.require
          (contains_uuid (changed_uuids plan) (uuid block_uuid_text))
          "changed UUIDs omit block";
        T.require
          (contains_uuid (changed_uuids plan) (uuid page_uuid_text))
          "changed UUIDs omit page")
    ]
;;
