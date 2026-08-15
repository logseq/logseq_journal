module T = Test_support
module Uuid = Logseq_db_worker.Graph_types.Uuid

let page_one = "10000000-0000-4000-8000-000000000001"
let page_two = "10000000-0000-4000-8000-000000000002"
let root_one = "20000000-0000-4000-8000-000000000001"
let root_two = "20000000-0000-4000-8000-000000000002"
let child_one = "30000000-0000-4000-8000-000000000001"
let child_two = "30000000-0000-4000-8000-000000000002"
let empty = "40000000-0000-4000-8000-000000000001"
let other_page_root = "50000000-0000-4000-8000-000000000001"
let built_in = "60000000-0000-4000-8000-000000000001"
let inserted_one = "70000000-0000-4000-8000-000000000001"
let inserted_two = "70000000-0000-4000-8000-000000000002"
let inserted_child = "70000000-0000-4000-8000-000000000003"
let missing_reference = "80000000-0000-4000-8000-000000000001"
let mutation = "90000000-0000-4000-8000-000000000001"
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
  ; "block/collapsed?", schema_attr ()
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
  ; ( "logseq.property.comments/blocks"
    , schema_attr
        ~cardinality:Datascript.Many
        ~indexed:true
        ~value_type:Datascript.RefType
        () )
  ; ( "logseq.property/created-from-property"
    , schema_attr ~indexed:true ~value_type:Datascript.RefType () )
  ; ( "logseq.property/default-value"
    , schema_attr ~indexed:true ~value_type:Datascript.RefType () )
  ; ( "block/closed-value-property"
    , schema_attr ~indexed:true ~value_type:Datascript.RefType () )
  ; ( "user.property/example"
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

let db () =
  let page_one_id = Datascript.Temp_id "page-one" in
  let page_two_id = Datascript.Temp_id "page-two" in
  let root_one_id = Datascript.Temp_id "root-one" in
  let root_two_id = Datascript.Temp_id "root-two" in
  let child_one_id = Datascript.Temp_id "child-one" in
  let child_two_id = Datascript.Temp_id "child-two" in
  let empty_id = Datascript.Temp_id "empty" in
  let other_page_root_id = Datascript.Temp_id "other-page-root" in
  let built_in_id = Datascript.Temp_id "built-in" in
  Datascript.empty_db ~schema ()
  |> Datascript.db_with
       (page page_one_id page_one "Page One" "page one"
        @ page page_two_id page_two "Page Two" "page two"
        @ block root_one_id root_one "Root one" page_one_id page_one_id "a0"
        @ block root_two_id root_two "Root two" page_one_id page_one_id "a1"
        @ block child_one_id child_one "Child one" root_one_id page_one_id "a0"
        @ block child_two_id child_two "Child two" root_one_id page_one_id "a1"
        @ block empty_id empty "" page_one_id page_one_id "a2"
        @ block
            other_page_root_id
            other_page_root
            "Other page root"
            page_two_id
            page_two_id
            "a0"
        @ block built_in_id built_in "Built in" page_one_id page_one_id "a3"
        @ [ Datascript.Add (built_in_id, "logseq.property/built-in?", Bool true) ])
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

let reference db entity attr =
  match one db entity attr with
  | Datascript.Ref value -> value
  | _ -> T.fail "%s is not a reference" attr
;;

let string db entity attr =
  match one db entity attr with
  | Datascript.String value -> value
  | _ -> T.fail "%s is not a string" attr
;;

let integer db entity attr =
  match one db entity attr with
  | Datascript.Int value -> value
  | _ -> T.fail "%s is not an integer" attr
;;

let context db =
  Logseq_db_worker.Protocol.
    { mutation_id = uuid mutation
    ; expected_basis =
        Int64.of_int (Datascript.serializable db).serializable_max_tx
    }
;;
