module T = Logseq_db_worker_test_support.Test_support
module Plan = Logseq_db_worker__Mutation_plan
module Protocol = Logseq_db_worker.Protocol
module Uuid = Logseq_db_worker.Graph_types.Uuid
open Logseq_db_worker.Graph_types

let now_ms = 1_704_067_299_999L
let target_uuid = "71000000-0000-4000-8000-000000000001"
let second_uuid = "71000000-0000-4000-8000-000000000002"
let page_uuid = "71000000-0000-4000-8000-000000000003"
let class_uuid = "71000000-0000-4000-8000-000000000004"
let node_uuid = "71000000-0000-4000-8000-000000000005"
let asset_uuid = "71000000-0000-4000-8000-000000000006"
let journal_uuid = "00000001-2024-0101-0000-000000000000"
let default_property_uuid = "72000000-0000-4000-8000-000000000001"
let many_property_uuid = "72000000-0000-4000-8000-000000000002"
let checkbox_property_uuid = "72000000-0000-4000-8000-000000000003"
let status_property_uuid = "72000000-0000-4000-8000-000000000004"
let closed_value_uuid = "73000000-0000-4000-8000-000000000001"
let associated_value_uuid = "73000000-0000-4000-8000-000000000002"
let mutation_uuid = "74000000-0000-4000-8000-000000000001"

let uuid value =
  match Uuid.of_string value with
  | Ok value -> value
  | Error message -> T.fail "invalid fixture UUID %s: %s" value message
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
  ; "block/title", schema_attr ~value_type:Datascript.StringType ()
  ; "block/name", schema_attr ~indexed:true ~value_type:Datascript.StringType ()
  ; "block/order", schema_attr ~value_type:Datascript.StringType ()
  ; "block/parent", schema_attr ~indexed:true ~value_type:Datascript.RefType ()
  ; "block/page", schema_attr ~indexed:true ~value_type:Datascript.RefType ()
  ; ( "block/tags"
    , schema_attr
        ~cardinality:Datascript.Many
        ~indexed:true
        ~value_type:Datascript.RefType
        () )
  ; ( "block/refs"
    , schema_attr
        ~cardinality:Datascript.Many
        ~indexed:true
        ~value_type:Datascript.RefType
        () )
  ; ( "block/closed-value-property"
    , schema_attr ~indexed:true ~value_type:Datascript.RefType () )
  ; ( "logseq.property.class/properties"
    , schema_attr
        ~cardinality:Datascript.Many
        ~indexed:true
        ~value_type:Datascript.RefType
        () )
  ; ( "logseq.property.class/extends"
    , schema_attr
        ~cardinality:Datascript.Many
        ~indexed:true
        ~value_type:Datascript.RefType
        () )
  ; ( "logseq.property/default-value"
    , schema_attr ~indexed:true ~value_type:Datascript.RefType () )
  ; ( "logseq.property/created-from-property"
    , schema_attr ~indexed:true ~value_type:Datascript.RefType () )
  ; "logseq.property/value", schema_attr ()
  ; "logseq.property/type", schema_attr ~value_type:Datascript.KeywordType ()
  ; "logseq.property/hide?", schema_attr ()
  ; "logseq.property/public?", schema_attr ()
  ; "logseq.property/built-in?", schema_attr ()
  ; "logseq.property/icon", schema_attr ~value_type:Datascript.StringType ()
  ; "block/journal-day", schema_attr ~indexed:true ~value_type:Datascript.NumberType ()
  ]
;;

let entity_tx id uuid title =
  [ Datascript.Add (id, "block/uuid", Uuid uuid)
  ; Add (id, "block/title", String title)
  ; Add (id, "block/name", String (String.lowercase_ascii title))
  ; Add (id, "block/created-at", Int 1_704_067_200_000)
  ; Add (id, "block/updated-at", Int 1_704_067_200_000)
  ]
;;

let property_tx id uuid ident title property_type cardinality property_class =
  entity_tx id uuid title
  @ [ Datascript.Add (id, "db/ident", Keyword ident)
    ; Add (id, "block/tags", Ref_to property_class)
    ; Add (id, "logseq.property/type", Keyword property_type)
    ; Add
        ( id
        , "db/cardinality"
        , Keyword
            (match cardinality with
             | One -> "db.cardinality/one"
             | Many -> "db.cardinality/many") )
    ; Add (id, "db/index", Bool true)
    ]
  @
  if
    List.mem
      property_type
      [ "default"
      ; "number"
      ; "url"
      ; "date"
      ; "node"
      ; "asset"
      ; "entity"
      ; "class"
      ; "page"
      ; "property"
      ]
  then [ Datascript.Add (id, "db/valueType", Keyword "db.type/ref") ]
  else []
;;

let fixture () =
  let page_class = Datascript.Temp_id "page-class" in
  let tag_class = Datascript.Temp_id "tag-class" in
  let property_class = Datascript.Temp_id "builtin-property-class" in
  let root_class = Datascript.Temp_id "root-class" in
  let task_class = Datascript.Temp_id "task-class" in
  let journal_class = Datascript.Temp_id "journal-class" in
  let asset_class = Datascript.Temp_id "asset-class" in
  let empty_placeholder = Datascript.Temp_id "empty-placeholder" in
  let status_todo = Datascript.Temp_id "status-todo" in
  let target = Datascript.Temp_id "target" in
  let second = Datascript.Temp_id "second" in
  let page = Datascript.Temp_id "page" in
  let class_ = Datascript.Temp_id "class" in
  let node = Datascript.Temp_id "node" in
  let asset = Datascript.Temp_id "asset" in
  let journal = Datascript.Temp_id "journal" in
  let default_property = Datascript.Temp_id "default-property" in
  let many_property = Datascript.Temp_id "many-property" in
  let checkbox_property = Datascript.Temp_id "checkbox-property" in
  let status_property = Datascript.Temp_id "status-property" in
  let internal_types =
    [ "date"
    ; "datetime"
    ; "url"
    ; "node"
    ; "asset"
    ; "keyword"
    ; "map"
    ; "coll"
    ; "any"
    ; "entity"
    ; "class"
    ; "page"
    ; "property"
    ; "string"
    ; "json"
    ; "raw-number"
    ]
  in
  let internal_properties =
    List.mapi
      (fun index property_type ->
         let ident = "user.property/" ^ property_type in
         let id = Datascript.Temp_id ("property-" ^ property_type) in
         let property_uuid =
           Printf.sprintf "72000000-0000-4000-8000-%012d" (index + 100)
         in
         property_tx id property_uuid ident property_type property_type One property_class)
      internal_types
    |> List.concat
  in
  Datascript.empty_db ~schema ()
  |> Datascript.db_with
       (entity_tx page_class "70000000-0000-4000-8000-000000000001" "Page"
        @ entity_tx tag_class "70000000-0000-4000-8000-000000000002" "Tag"
        @ entity_tx property_class "70000000-0000-4000-8000-000000000003" "Property"
        @ entity_tx root_class "70000000-0000-4000-8000-000000000004" "Root"
        @ entity_tx task_class "70000000-0000-4000-8000-000000000005" "Task"
        @ entity_tx journal_class "70000000-0000-4000-8000-000000000006" "Journal"
        @ entity_tx asset_class "70000000-0000-4000-8000-000000000007" "Asset"
        @ entity_tx empty_placeholder "70000000-0000-4000-8000-000000000008" "Empty"
        @ entity_tx status_todo "70000000-0000-4000-8000-000000000009" "Todo"
        @ [ Datascript.Add (page_class, "db/ident", Keyword "logseq.class/Page")
          ; Add (tag_class, "db/ident", Keyword "logseq.class/Tag")
          ; Add (property_class, "db/ident", Keyword "logseq.class/Property")
          ; Add (root_class, "db/ident", Keyword "logseq.class/Root")
          ; Add (task_class, "db/ident", Keyword "logseq.class/Task")
          ; Add (journal_class, "db/ident", Keyword "logseq.class/Journal")
          ; Add (asset_class, "db/ident", Keyword "logseq.class/Asset")
          ; Add
              (empty_placeholder, "db/ident", Keyword "logseq.property/empty-placeholder")
          ; Add (status_todo, "db/ident", Keyword "logseq.property/status.todo")
          ]
        @ entity_tx target target_uuid "Target"
        @ entity_tx second second_uuid "Second"
        @ entity_tx page page_uuid "Page value"
        @ entity_tx class_ class_uuid "Class value"
        @ entity_tx node node_uuid "Node value"
        @ entity_tx asset asset_uuid "Asset value"
        @ entity_tx journal journal_uuid "Jan 1st, 2024"
        @ [ Datascript.Add (target, "block/parent", Ref_to page)
          ; Add (target, "block/page", Ref_to page)
          ; Add (target, "block/order", String "a0")
          ; Add (second, "block/parent", Ref_to page)
          ; Add (second, "block/page", Ref_to page)
          ; Add (second, "block/order", String "a1")
          ; Add (page, "block/tags", Ref_to page_class)
          ; Add (class_, "block/tags", Ref_to tag_class)
          ; Add (class_, "db/ident", Keyword "user.class/example")
          ; Add (class_, "logseq.property.class/extends", Ref_to root_class)
          ; Add (node, "block/parent", Ref_to page)
          ; Add (node, "block/page", Ref_to page)
          ; Add (node, "block/order", String "a2")
          ; Add (asset, "block/parent", Ref_to page)
          ; Add (asset, "block/page", Ref_to page)
          ; Add (asset, "block/order", String "a3")
          ; Add (asset, "block/tags", Ref_to asset_class)
          ; Add (journal, "block/tags", Ref_to journal_class)
          ; Add (journal, "block/journal-day", Int 20240101)
          ]
        @ property_tx
            default_property
            default_property_uuid
            "user.property/default"
            "Default"
            "default"
            One
            property_class
        @ property_tx
            many_property
            many_property_uuid
            "user.property/many"
            "Many"
            "number"
            Many
            property_class
        @ property_tx
            checkbox_property
            checkbox_property_uuid
            "user.property/checkbox"
            "Checkbox"
            "checkbox"
            One
            property_class
        @ property_tx
            status_property
            status_property_uuid
            "logseq.property/status"
            "Status"
            "default"
            One
            property_class
        @ internal_properties)
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

let entity_of_ident db ident =
  match
    Datascript.datoms db Datascript.Avet ~a:"db/ident" ~v:(Datascript.Keyword ident) ()
    |> List.of_seq
  with
  | [ datom ] -> datom.Datascript.e
  | _ -> T.fail "unable to resolve fixture ident %s" ident
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
  | _ -> T.fail "ambiguous fixture UUID"
;;

let values db entity attr =
  Datascript.datoms db Datascript.Eavt ~e:entity ~a:attr ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.v)
;;

let has_value db entity attr value = List.mem value (values db entity attr)

let context db =
  Protocol.
    { mutation_id = uuid mutation_uuid
    ; expected_basis = Int64.of_int (Datascript.serializable db).serializable_max_tx
    }
;;

let selector ident = Property_by_ident ident
let plan db mutation = Plan.plan ~now_ms db (Protocol.Property mutation)

let require_plan (result : (Plan.t, Plan.error) result) =
  match result with
  | Ok plan -> plan
  | Error (Unsupported_semantics message) ->
    T.fail "valid property mutation was unsupported: %s" message
  | Error (Invalid_selection message) ->
    T.fail "valid property mutation had invalid selection: %s" message
  | Error (Invalid_tree message) ->
    T.fail "valid property mutation had invalid tree: %s" message
  | Error (Invalid_order message) ->
    T.fail "valid property mutation had invalid order: %s" message
  | Error (Invalid_position message) ->
    T.fail "valid property mutation had invalid position: %s" message
  | Error (Conflict message) -> T.fail "valid property mutation conflicted: %s" message
  | Error Plan.Built_in_protected ->
    T.fail "valid property mutation was built-in protected"
;;

let apply db plan = Datascript.with_tx ~tx_meta:plan.Plan.tx_meta db plan.tx_ops

let mutate db mutation =
  let plan = require_plan (plan db mutation) in
  apply db plan
;;

let set db ?(property = selector "user.property/default") value =
  mutate
    db
    (Protocol.Set_property
       { block = uuid target_uuid; property; value; context = context db })
;;

let () =
  T.run
    "properties"
    [ T.case "qualified identifier is required" (fun () ->
        let db = fixture () in
        match
          plan
            db
            (Upsert_property
               { property = New_property { ident = "priority"; title = "Priority" }
               ; schema =
                   { property_type = Number
                   ; cardinality = One
                   ; hidden = false
                   ; public = true
                   }
               ; context = context db
               })
        with
        | Error (Plan.Invalid_selection _ | Unsupported_semantics _) -> ()
        | _ -> T.fail "unqualified property ident was accepted")
    ; T.case "new property UUID matches Logseq keyword hashing" (fun () ->
        let db = fixture () in
        let report =
          mutate
            db
            (Upsert_property
               { property =
                   New_property
                     { ident = "user.property/priority"; title = "Priority" }
               ; schema =
                   { property_type = Number
                   ; cardinality = One
                   ; hidden = false
                   ; public = true
                   }
               ; context = context db
               })
        in
        let property = entity_of_ident report.db_after "user.property/priority" in
        T.require
          (values report.db_after property "block/uuid"
           = [ Datascript.Uuid "00000002-1232-8114-1300-000000000000" ])
          "new property UUID diverged from pinned Logseq")
    ; T.case "property UUID selector resolves" (fun () ->
        let db = fixture () in
        let report =
          set
            db
            ~property:(Property_by_uuid (uuid checkbox_property_uuid))
            (Checkbox_value true)
        in
        let target = entity report.db_after (uuid target_uuid) in
        T.require
          (has_value
             report.db_after
             target
             "user.property/checkbox"
             (Datascript.Bool true))
          "UUID selector did not set the property")
    ; T.case "same-title ambiguity rejects" (fun () ->
        let db = fixture () in
        match
          plan
            db
            (Upsert_property
               { property =
                   New_property { ident = "user.property/another"; title = "Default" }
               ; schema =
                   { property_type = Default
                   ; cardinality = One
                   ; hidden = false
                   ; public = true
                   }
               ; context = context db
               })
        with
        | Error (Plan.Conflict _ | Invalid_selection _) -> ()
        | _ -> T.fail "duplicate property title was accepted")
    ; T.case "all frozen property types validate" (fun () ->
        let db = fixture () in
        let cases =
          [ "user.property/default", Default_value "text"
          ; "user.property/many", Number_value "12.5"
          ; "user.property/date", Date_value { journal_day = 20240101 }
          ; "user.property/datetime", Datetime_value { unix_ms = 1_704_067_200_000L }
          ; "user.property/checkbox", Checkbox_value true
          ; "user.property/url", Url_value "https://logseq.com"
          ; "user.property/node", Node_value (uuid node_uuid)
          ; "user.property/asset", Asset_value (uuid asset_uuid)
          ; "user.property/keyword", Keyword_value "example/value"
          ; ( "user.property/map"
            , Map_value [ Internal_keyword "example/key", Internal_string "value" ] )
          ; ( "user.property/coll"
            , Collection_value [ Internal_string "one"; Internal_number "2" ] )
          ; "user.property/any", Any_value (Internal_bool true)
          ; "user.property/entity", Entity_value (uuid node_uuid)
          ; "user.property/class", Class_value (uuid class_uuid)
          ; "user.property/page", Page_value (uuid page_uuid)
          ; "user.property/property", Property_value "user.property/default"
          ; "user.property/string", String_value "string"
          ; "user.property/json", Json_value "{\"ok\":true}"
          ; "user.property/raw-number", Raw_number_value "3.5"
          ]
        in
        List.iter
          (fun (ident, value) ->
             ignore
               (require_plan
                  (plan
                     db
                     (Set_property
                        { block = uuid target_uuid
                        ; property = selector ident
                        ; value
                        ; context = context db
                        }))))
          cases)
    ; T.case "generated value uses the target page" (fun () ->
        let db = fixture () in
        let report = set db (Default_value "Generated") in
        let target = entity report.db_after (uuid target_uuid) in
        let page = entity report.db_after (uuid page_uuid) in
        match values report.db_after target "user.property/default" with
        | [ Datascript.Ref generated ] ->
          T.require
            (values report.db_after generated "block/parent" = [ Datascript.Ref target ])
            "generated property value has the wrong parent";
          T.require
            (values report.db_after generated "block/page" = [ Datascript.Ref page ])
            "generated property value has the wrong page"
        | _ -> T.fail "default property did not create one value entity")
    ; T.case "closed values constrain only their own property" (fun () ->
        let db = fixture () in
        let with_choice =
          mutate
            db
            (Manage_closed_values
               { property = selector "user.property/default"
               ; action =
                   Add_closed_value
                     { value_uuid = uuid closed_value_uuid
                     ; value = Default_value "Choice"
                     ; icon = None
                     }
               ; context = context db
               })
        in
        let property_plan =
          plan
            with_choice.db_after
            (Set_property
               { block = uuid target_uuid
               ; property = selector "user.property/many"
               ; value = Number_value "1"
               ; context = context with_choice.db_after
               })
        in
        ignore (require_plan property_plan))
    ; T.case "cardinality validates existing values" (fun () ->
        let db = fixture () in
        let target = entity db (uuid target_uuid) in
        let property = entity_of_ident db "user.property/many" in
        let db =
          Datascript.db_with
            [ Datascript.Add
                (Entity_id target, "user.property/many", Ref_to (Entity_id target))
            ; Add
                ( Entity_id (entity db (uuid second_uuid))
                , "user.property/many"
                , Ref_to (Entity_id target) )
            ]
            db
        in
        match
          plan
            db
            (Upsert_property
               { property = Existing_property (selector "user.property/many")
               ; schema =
                   { property_type = Number
                   ; cardinality = One
                   ; hidden = false
                   ; public = true
                   }
               ; context = context db
               })
        with
        | Error (Plan.Conflict _ | Unsupported_semantics _) -> ignore property
        | _ -> T.fail "many-to-one conversion with existing values was accepted")
    ; T.case "self reference is rejected" (fun () ->
        let db = fixture () in
        match
          plan
            db
            (Set_property
               { block = uuid target_uuid
               ; property = selector "user.property/node"
               ; value = Node_value (uuid target_uuid)
               ; context = context db
               })
        with
        | Error (Plan.Conflict _ | Invalid_selection _) -> ()
        | _ -> T.fail "self reference was accepted")
    ; T.case "single value set and remove" (fun () ->
        let db = fixture () in
        let set_report =
          set db ~property:(selector "user.property/checkbox") (Checkbox_value true)
        in
        let target = entity set_report.db_after (uuid target_uuid) in
        T.require
          (values set_report.db_after target "user.property/checkbox"
           = [ Datascript.Bool true ])
          "single value was not set";
        let remove_report =
          mutate
            set_report.db_after
            (Remove_property
               { block = uuid target_uuid
               ; property = selector "user.property/checkbox"
               ; context = context set_report.db_after
               })
        in
        T.require
          (values remove_report.db_after target "user.property/checkbox" = [])
          "single value was not removed")
    ; T.case "many value set and remove" (fun () ->
        let db = fixture () in
        let first = set db ~property:(selector "user.property/many") (Number_value "1") in
        let second =
          set first.db_after ~property:(selector "user.property/many") (Number_value "2")
        in
        let target = entity second.db_after (uuid target_uuid) in
        T.require
          (List.length (values second.db_after target "user.property/many") = 2)
          "many property did not append";
        let removed =
          mutate
            second.db_after
            (Remove_property
               { block = uuid target_uuid
               ; property = selector "user.property/many"
               ; context = context second.db_after
               })
        in
        T.require
          (values removed.db_after target "user.property/many" = [])
          "many property was not removed")
    ; T.case "batch append is explicit" (fun () ->
        let db = fixture () in
        let report =
          mutate
            db
            (Batch_set_property
               { blocks = [ uuid target_uuid; uuid second_uuid ]
               ; property = selector "user.property/many"
               ; mode = Append (Number_value "1")
               ; context = context db
               })
        in
        List.iter
          (fun block ->
             T.require
               (List.length
                  (values
                     report.db_after
                     (entity report.db_after (uuid block))
                     "user.property/many")
                = 1)
               "batch append skipped a target")
          [ target_uuid; second_uuid ])
    ; T.case "batch replace is explicit" (fun () ->
        let db = fixture () in
        let report =
          mutate
            db
            (Batch_set_property
               { blocks = [ uuid target_uuid; uuid second_uuid ]
               ; property = selector "user.property/many"
               ; mode = Replace [ Number_value "2"; Number_value "3" ]
               ; context = context db
               })
        in
        List.iter
          (fun block ->
             T.require
               (List.length
                  (values
                     report.db_after
                     (entity report.db_after (uuid block))
                     "user.property/many")
                = 2)
               "batch replace did not install the complete value set")
          [ target_uuid; second_uuid ])
    ; T.case "batch resolves all targets before mutation" (fun () ->
        let db = fixture () in
        match
          plan
            db
            (Batch_set_property
               { blocks =
                   [ uuid target_uuid; uuid "79999999-0000-4000-8000-000000000001" ]
               ; property = selector "user.property/many"
               ; mode = Append (Number_value "1")
               ; context = context db
               })
        with
        | Error (Plan.Invalid_selection _) -> ()
        | _ -> T.fail "batch accepted a missing target")
    ; T.case "status default extends and alias rules" (fun () ->
        let db = fixture () in
        let target = entity db (uuid target_uuid) in
        let task = entity_of_ident db "logseq.class/Task" in
        let status = entity_of_ident db "logseq.property/status.todo" in
        let db =
          Datascript.db_with
            [ Datascript.Add (Entity_id target, "block/tags", Ref_to (Entity_id task))
            ; Add (Entity_id target, "logseq.property/status", Ref_to (Entity_id status))
            ]
            db
        in
        let report =
          mutate
            db
            (Remove_property
               { block = uuid target_uuid
               ; property = selector "logseq.property/status"
               ; context = context db
               })
        in
        T.require
          (values report.db_after target "logseq.property/status" = [])
          "status survived removal";
        T.require
          (not (has_value report.db_after target "block/tags" (Datascript.Ref task)))
          "orphan Task tag survived status removal")
    ; T.case "class property add and remove" (fun () ->
        let db = fixture () in
        let added =
          mutate
            db
            (Manage_class_property
               { class_ = uuid class_uuid
               ; property = selector "user.property/checkbox"
               ; action =
                   Add_class_property { default_value = Some (Checkbox_value true) }
               ; context = context db
               })
        in
        let class_ = entity added.db_after (uuid class_uuid) in
        let property = entity_of_ident added.db_after "user.property/checkbox" in
        T.require
          (has_value
             added.db_after
             class_
             "logseq.property.class/properties"
             (Datascript.Ref property))
          "class property relation is missing";
        let removed =
          mutate
            added.db_after
            (Manage_class_property
               { class_ = uuid class_uuid
               ; property = selector "user.property/checkbox"
               ; action = Remove_class_property
               ; context = context added.db_after
               })
        in
        T.require
          (values removed.db_after class_ "logseq.property.class/properties" = [])
          "class property relation survived removal")
    ; T.case "closed value add update associate and delete" (fun () ->
        let db = fixture () in
        let added =
          mutate
            db
            (Manage_closed_values
               { property = selector "user.property/default"
               ; action =
                   Add_closed_value
                     { value_uuid = uuid closed_value_uuid
                     ; value = Default_value "One"
                     ; icon = Some "1️⃣"
                     }
               ; context = context db
               })
        in
        let closed = entity added.db_after (uuid closed_value_uuid) in
        let property = entity_of_ident added.db_after "user.property/default" in
        T.require
          (has_value
             added.db_after
             closed
             "block/closed-value-property"
             (Datascript.Ref property))
          "closed value association is missing";
        let updated =
          mutate
            added.db_after
            (Manage_closed_values
               { property = selector "user.property/default"
               ; action =
                   Update_closed_value
                     { value_uuid = uuid closed_value_uuid
                     ; value = Default_value "Updated"
                     ; icon = None
                     }
               ; context = context added.db_after
               })
        in
        T.require
          (values updated.db_after closed "block/title" = [ Datascript.String "Updated" ])
          "closed value was not updated";
        let associated_seed =
          Datascript.db_with
            (entity_tx (Temp_id "associated") associated_value_uuid "Associated")
            updated.db_after
        in
        let associated =
          mutate
            associated_seed
            (Manage_closed_values
               { property = selector "user.property/default"
               ; action =
                   Associate_closed_value { value_uuid = uuid associated_value_uuid }
               ; context = context associated_seed
               })
        in
        let associated_entity = entity associated.db_after (uuid associated_value_uuid) in
        T.require
          (has_value
             associated.db_after
             associated_entity
             "block/closed-value-property"
             (Datascript.Ref property))
          "existing value was not associated";
        let deleted =
          mutate
            associated.db_after
            (Manage_closed_values
               { property = selector "user.property/default"
               ; action = Delete_closed_value { value_uuid = uuid closed_value_uuid }
               ; context = context associated.db_after
               })
        in
        T.require
          (Option.is_none (entity_opt deleted.db_after (uuid closed_value_uuid)))
          "closed value survived deletion")
    ; T.case "default placeholder lifecycle" (fun () ->
        let db = fixture () in
        let target = entity db (uuid target_uuid) in
        let property = entity_of_ident db "user.property/default" in
        let placeholder = entity_of_ident db "logseq.property/empty-placeholder" in
        let db =
          Datascript.db_with
            [ Datascript.Add
                ( Entity_id property
                , "logseq.property/default-value"
                , Ref_to (Entity_id target) )
            ; Add (Entity_id target, "user.property/default", Ref_to (Entity_id target))
            ]
            db
        in
        let report =
          mutate
            db
            (Remove_property
               { block = uuid target_uuid
               ; property = selector "user.property/default"
               ; context = context db
               })
        in
        T.require
          (values report.db_after target "user.property/default"
           = [ Datascript.Ref placeholder ])
          "default value was not replaced by the empty placeholder")
    ; T.case "idempotent set returns No_change" (fun () ->
        let db = fixture () in
        let target = entity db (uuid target_uuid) in
        let db =
          Datascript.db_with
            [ Datascript.Add (Entity_id target, "user.property/checkbox", Bool true) ]
            db
        in
        let property_plan =
          require_plan
            (plan
               db
               (Set_property
                  { block = uuid target_uuid
                  ; property = selector "user.property/checkbox"
                  ; value = Checkbox_value true
                  ; context = context db
                  }))
        in
        T.require (property_plan.status = Protocol.No_change) "idempotent set was applied";
        T.require (property_plan.tx_ops = []) "idempotent set produced datoms")
    ; T.case "orphan generated values are cleaned" (fun () ->
        let db = fixture () in
        let generated_uuid = "73000000-0000-4000-8000-000000000099" in
        let target = entity db (uuid target_uuid) in
        let property = entity_of_ident db "user.property/default" in
        let generated = Datascript.Temp_id "generated" in
        let db =
          Datascript.db_with
            (entity_tx generated generated_uuid "Generated"
             @ [ Datascript.Add
                   ( generated
                   , "logseq.property/created-from-property"
                   , Ref_to (Entity_id property) )
               ; Add (Entity_id target, "user.property/default", Ref_to generated)
               ])
            db
        in
        let report =
          mutate
            db
            (Remove_property
               { block = uuid target_uuid
               ; property = selector "user.property/default"
               ; context = context db
               })
        in
        T.require
          (Option.is_none (entity_opt report.db_after (uuid generated_uuid)))
          "orphan generated value survived")
    ; T.case "unsupported internal user type rejects pre-stage" (fun () ->
        let db = fixture () in
        match
          plan
            db
            (Upsert_property
               { property =
                   New_property { ident = "user.property/internal"; title = "Internal" }
               ; schema =
                   { property_type = Keyword
                   ; cardinality = One
                   ; hidden = false
                   ; public = true
                   }
               ; context = context db
               })
        with
        | Error (Plan.Unsupported_semantics _) -> ()
        | _ -> T.fail "unsupported user property type was accepted")
    ; T.case "built-in protected relations reject" (fun () ->
        let db = fixture () in
        let class_ = entity db (uuid class_uuid) in
        let db =
          Datascript.db_with
            [ Datascript.Add (Entity_id class_, "logseq.property/built-in?", Bool true) ]
            db
        in
        match
          plan
            db
            (Manage_class_property
               { class_ = uuid class_uuid
               ; property = selector "user.property/checkbox"
               ; action = Add_class_property { default_value = None }
               ; context = context db
               })
        with
        | Error Plan.Built_in_protected -> ()
        | _ -> T.fail "built-in class relation was editable")
    ; T.case "transaction metadata matches oracle" (fun () ->
        let db = fixture () in
        let property_plan =
          require_plan
            (plan
               db
               (Set_property
                  { block = uuid target_uuid
                  ; property = selector "user.property/checkbox"
                  ; value = Checkbox_value true
                  ; context = context db
                  }))
        in
        T.require
          (List.mem
             ("outliner-op", Datascript.Keyword "set-block-property")
             property_plan.tx_meta)
          "property tx metadata has the wrong outliner operation";
        T.require
          (List.mem
             ("db-sync/tx-id", Datascript.Uuid mutation_uuid)
             property_plan.tx_meta)
          "property tx metadata has no mutation UUID")
    ]
;;
