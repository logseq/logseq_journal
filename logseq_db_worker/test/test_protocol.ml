module T=Logseq_db_worker_test_support.Test_support
module M=Logseq_db_worker_contract.Worker_pure_mutation
module Data=Worker_pure_data
module Uuid=Logseq_db_types.Graph_types.Uuid
let uuid value=Uuid.of_string value |> Result.get_ok
let native_id="00000000-0000-4000-8000-000000000001"
let native_variant name fields=`List[`String name;`Assoc fields]
let block_records ()=match T.read_json(T.fixture "worker-data/block-records.json")with
  |`List values->values|_->T.fail "Expected actual Data record fixtures"

let closed_internal_config_fields () =
  let base =
    `Assoc
      [ "application_support_directory", `String "/tmp/synthetic-support"
      ; ( "target"
        , `List
            [ `String "Managed_sync"
            ; `Assoc [ "base_url", `String "https://example.invalid" ]
            ] )
      ; "compatibility_profile", `List [ `String "Logseq_65_33_or_newer" ]
      ; "response_budget_bytes", `Int Worker_pure_data.maximum_response_bytes
      ; "default_page_size", `Int Worker_pure_data.default_page_size
      ]
  in
  T.require
    (Result.is_ok (Logseq_db_worker.Config.of_yojson base))
    "valid owned Config control was rejected";
  let outer =
    match base with
    | `Assoc fields -> `Assoc (("future", `Bool true) :: fields)
    | _ -> assert false
  in
  let nested =
    match base with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
              if key = "target"
              then
                ( key
                , `List
                    [ `String "Managed_sync"
                    ; `Assoc
                        [ "base_url", `String "https://example.invalid"
                        ; "future", `Bool true
                        ]
                    ] )
              else key, value)
           fields)
    | _ -> assert false
  in
  List.iter
    (fun json ->
       T.require
         (Result.is_error (Logseq_db_worker.Config.of_yojson json))
         "owned internal Config accepted an extra field")
    [ outer; nested ]
;;

let rec map_json_fields update = function
  | `Assoc fields ->
    `Assoc
      (update (List.map (fun (key, value) -> key, map_json_fields update value) fields))
  | `List values -> `List (List.map (map_json_fields update) values)
  | json -> json
;;

let replace_field name value =
  map_json_fields (List.map (fun (key, old) -> key, if key = name then value else old))
;;

let causal_error_json ~contexts ~origin ~truncated =
  `Assoc
    [ "code", `List [ `String "Corrupt_storage" ]
    ; "message", `String "The graph storage is corrupt or incomplete."
    ; "details", `List []
    ; ( "trace"
      , `Assoc
          [ "contexts", `List contexts; "origin", origin; "truncated", `Bool truncated ] )
    ]
;;

let cause_json ~component ~operation ~code ~message =
  `Assoc
    [ "component", `List [ `String component ]
    ; "operation", `String operation
    ; "code", Option.fold ~none:`Null ~some:(fun value -> `String value) code
    ; "message", `String message
    ]
;;

let causal_error_round_trip () =
  let json =
    causal_error_json
      ~contexts:
        [ cause_json
            ~component:"Engine"
            ~operation:"openGraph"
            ~code:(Some "corruptStorage")
            ~message:"The graph storage is corrupt or incomplete."
        ; cause_json
            ~component:"Storage"
            ~operation:"restoreDatabase"
            ~code:(Some "SQLITE_CORRUPT")
            ~message:"SQLite rejected the database image."
        ]
      ~origin:
        (cause_json
           ~component:"Sqlite"
           ~operation:"readPage"
           ~code:(Some "SQLITE_CORRUPT")
           ~message:"Database page validation failed.")
      ~truncated:false
  in
  match Logseq_db_worker.Error.of_yojson json with
  | Error message -> T.fail "causal error decode failed: %s" message
  | Ok error ->
    T.require
      (Yojson.Safe.equal
         (T.canonical_json json)
         (T.canonical_json (Logseq_db_worker.Error.to_yojson error)))
      "causal error changed during round trip"
;;

let cause_or_fallback_preserves_valid_cause () =
  let expected =
    Logseq_db_worker.Error.create_cause
      ~component:Logseq_db_worker.Error.Storage
      ~operation:"restoreDatabase"
      ~code:(Some "SQLITE_CORRUPT")
      ~message:"SQLite rejected the database image."
    |> Result.get_ok
  in
  let actual =
    Logseq_db_worker.Error.create_cause_or_fallback
      ~component:Logseq_db_worker.Error.Storage
      ~operation:"restoreDatabase"
      ~code:(Some "SQLITE_CORRUPT")
      ~message:"SQLite rejected the database image."
      ~fallback_message:"The storage operation returned an unsafe failure."
  in
  T.require (actual = expected) "valid cause construction changed"
;;

let cause_or_fallback_replaces_rejected_messages () =
  let fallback_message = "The storage operation returned an unsafe failure." in
  let rejected_messages =
    [ ""
    ; String.make (Logseq_db_worker.Error.maximum_message_bytes + 1) 'x'
    ; "cannot open /Users/alice/private-graph/logseq.sqlite"
    ]
  in
  List.iter
    (fun message ->
       let cause =
         Logseq_db_worker.Error.create_cause_or_fallback
           ~component:Logseq_db_worker.Error.Storage
           ~operation:"openDatabase"
           ~code:(Some "SQLITE_CANTOPEN")
           ~message
           ~fallback_message
       in
       T.require
         (cause.component = Logseq_db_worker.Error.Storage)
         "fallback cause component changed";
       T.require
         (String.equal cause.operation "openDatabase")
         "fallback cause operation changed";
       T.require (cause.code = Some "SQLITE_CANTOPEN") "fallback cause code changed";
       T.require
         (String.equal cause.message fallback_message)
         "fallback cause message changed")
    rejected_messages
;;

let cause_or_fallback_preserves_absent_code () =
  let cause =
    Logseq_db_worker.Error.create_cause_or_fallback
      ~component:Logseq_db_worker.Error.Dependency
      ~operation:"loadDependency"
      ~code:None
      ~message:"Bearer secret"
      ~fallback_message:"The dependency returned an unsafe failure."
  in
  T.require (cause.code = None) "fallback cause introduced a code"
;;

let cause_or_fallback_rejects_invalid_fallback () =
  match
    Logseq_db_worker.Error.create_cause_or_fallback
      ~component:Logseq_db_worker.Error.Operating_system
      ~operation:"openFile"
      ~code:(Some "openFailed")
      ~message:"password=secret"
      ~fallback_message:""
  with
  | _ -> T.fail "invalid fallback did not raise an invariant failure"
  | exception Invalid_argument _ -> ()
;;

let direct_errors_create_complete_origins () =
  let codes =
    Logseq_db_worker.Error.
      [ Invalid_request
      ; Stale_read_cursor
      ; Unsupported_api_version
      ; Graph_not_found
      ; Graph_locked
      ; Ownership_recovery
      ; Unsupported_schema
      ; Remote_graph
      ; Ambiguous_sync_state
      ; Unsupported_value
      ; Unsupported_semantics
      ; Corrupt_storage
      ; Not_found
      ; Ambiguous_selector
      ; Duplicate_selector
      ; Built_in_protected
      ; Invalid_tree
      ; Invalid_order
      ; Invalid_position
      ; Conflict
      ; Response_too_large
      ; Storage_busy
      ; Closed_session
      ]
  in
  List.iter
    (fun code ->
       let code_string = Logseq_db_worker.Error.code_string code in
       let message = "Safe direct worker error" in
       let error =
         Logseq_db_worker.Error.create ~code ~message ~details:[] |> Result.get_ok
       in
       match Logseq_db_worker.Error.to_yojson error with
       | `Assoc fields ->
         (match List.assoc_opt "trace" fields with
          | Some
              (`Assoc
                 [ ("contexts", `List [])
                 ; ( "origin"
                   , `Assoc
                       [ ("component", `List [ `String "Logseq_db_worker" ])
                       ; ("operation", `String operation)
                       ; ("code", `String origin_code)
                       ; ("message", `String origin_message)
                       ] )
                 ; ("truncated", `Bool false)
                 ]) ->
            T.require
              (String.equal operation code_string)
              "direct origin operation changed";
            T.require (String.equal origin_code code_string) "direct origin code changed";
            T.require
              (String.equal origin_message message)
              "direct origin message changed"
          | _ -> T.fail "%s has no complete direct causal origin" code_string)
       | _ -> T.fail "%s did not encode as an object" code_string)
    codes
;;

let causal_error_rejects_legacy_and_unsafe_values () =
  let legacy =
    `Assoc
      [ "code", `List [ `String "Corrupt_storage" ]
      ; "message", `String "Legacy flat error"
      ; "details", `List []
      ]
  in
  (match Logseq_db_worker.Error.of_yojson legacy with
   | Error _ -> ()
   | Ok _ -> T.fail "legacy string-only error envelope was accepted");
  let unsafe =
    causal_error_json
      ~contexts:[]
      ~origin:
        (cause_json
           ~component:"Sqlite"
           ~operation:"openDatabase"
           ~code:(Some "SQLITE_CANTOPEN")
           ~message:"cannot open /Users/alice/private-graph/logseq.sqlite")
      ~truncated:false
  in
  match Logseq_db_worker.Error.of_yojson unsafe with
  | Error _ -> ()
  | Ok _ -> T.fail "unsafe complete home-directory path was accepted"
;;

let error_details_and_budget () =
  let module E = Logseq_db_worker.Error in
  let safe =
    causal_error_json
      ~contexts:[]
      ~origin:
        (cause_json
           ~component:"Storage"
           ~operation:"read"
           ~code:None
           ~message:"Safe storage failure")
      ~truncated:false
  in
  let detail_values =
    [ `List [ `String "Detail_string"; `String "Safe detail" ]
    ; `List [ `String "Detail_int"; `Intlit "-9223372036854775808" ]
    ; `List [ `String "Detail_int"; `Intlit "9223372036854775807" ]
    ; `List [ `String "Detail_bool"; `Bool true ]
    ; `List [ `String "Detail_uuid"; `String native_id ]
    ; `List [ `String "Detail_strings"; `List [ `String "Safe one"; `String "Safe two" ] ]
    ; `List [ `String "Detail_uuids"; `List [ `String native_id ] ]
    ]
  in
  let json =
    replace_field
      "details"
      (`List
          (List.mapi
             (fun i value ->
                `Assoc [ "name", `String ("detail" ^ string_of_int i); "value", value ])
             detail_values))
      safe
  in
  (match E.of_yojson json with
   | Error message -> T.fail "generated error details rejected: %s" message
   | Ok error ->
     T.require
       (Yojson.Safe.equal (T.canonical_json json) (T.canonical_json (E.to_yojson error)))
       "error details changed");
  T.require
    (Result.is_error
       (E.of_yojson
          (replace_field "value" (`List [ `String "Detail_uuid"; `String "bad" ]) json)))
    "invalid detail UUID accepted";
  T.require
    (Result.is_error
       (E.of_yojson (replace_field "message" (`String "Bearer secret") safe)))
    "unsafe error accepted";
  let slots =
    (E.maximum_encoded_bytes + E.maximum_message_bytes - 1) / E.maximum_message_bytes
  in
  let make padding =
    let remaining = ref (padding - slots) in
    let strings =
      List.init slots (fun _ ->
        let n = min (E.maximum_message_bytes - 1) !remaining in
        remaining := !remaining - n;
        `String (String.make (n + 1) 'x'))
    in
    replace_field
      "details"
      (`List
          [ `Assoc
              [ "name", `String "detail"
              ; "value", `List [ `String "Detail_strings"; `List strings ]
              ]
          ])
      safe
  in
  let capacity = slots * E.maximum_message_bytes in
  let base = String.length (Yojson.Safe.to_string (make capacity)) - capacity in
  let exact = make (E.maximum_encoded_bytes - base) in
  T.require
    (String.length (Yojson.Safe.to_string exact) = E.maximum_encoded_bytes)
    "error budget fixture size incorrect";
  T.require (Result.is_ok (E.of_yojson exact)) "error at exact generated budget rejected";
  T.require
    (Result.is_error (E.of_yojson (make (E.maximum_encoded_bytes - base + 1))))
    "error over generated budget accepted"
;;

let config_generated_golden_and_validation () =
  let module C = Logseq_db_worker.Config in
  let valid =
    `Assoc
      [ "application_support_directory", `String "/tmp/logseq-journal-config"
      ; ( "target"
        , native_variant "Managed_sync" [ "base_url", `String "https://api.logseq.io" ] )
      ; "compatibility_profile", `List [ `String "Logseq_65_33_or_newer" ]
      ; "response_budget_bytes", `Int Worker_pure_data.maximum_response_bytes
      ; "default_page_size", `Int Worker_pure_data.default_page_size
      ]
  in
  (match C.of_yojson valid with
   | Error message -> T.fail "generated config rejected: %s" message
   | Ok config ->
     T.require
       (Yojson.Safe.equal valid (C.to_yojson config))
       "config generated golden changed");
  List.iter
    (fun url ->
       T.require
         (Result.is_error (C.of_yojson (replace_field "base_url" (`String url) valid)))
         "invalid origin accepted: %s"
         url)
    [ "http://api.logseq.io"
    ; "https://user:secret@api.logseq.io"
    ; "https://api.logseq.io/path"
    ; "https://api.logseq.io?key=value"
    ; "https://api.logseq.io#fragment"
    ];
  List.iter
    (fun path ->
       T.require
         (Result.is_error
            (C.of_yojson
               (replace_field "application_support_directory" (`String path) valid)))
         "invalid config path accepted")
    [ "relative"; "/tmp/../graph"; "/tmp//graph"; "/tmp/\255"; "/tmp/\000" ];
  List.iter
    (fun budget ->
       T.require
         (Result.is_error
            (C.of_yojson (replace_field "response_budget_bytes" (`Int budget) valid)))
         "invalid config response budget accepted")
    [ 0; Worker_pure_data.maximum_response_bytes + 1 ];
  List.iter
    (fun size ->
       T.require
         (Result.is_error
            (C.of_yojson (replace_field "default_page_size" (`Int size) valid)))
         "invalid default page size accepted")
    [ 0; Worker_pure_data.maximum_page_size + 1 ];
  T.require
    (Result.is_error
       (C.of_yojson
          (map_json_fields
             (fun fields ->
                match List.assoc_opt "default_page_size" fields with
                | None -> fields
                | Some v -> ("default_page_size", v) :: fields)
             valid)))
    "duplicate config field accepted";
  let legacy =
    Yojson.Safe.from_string
      {|{"applicationSupportDirectory":"/tmp/logseq-journal-config","target":{"kind":"managedSync","baseUrl":"https://api.logseq.io"},"compatibilityProfile":"logseq-65.33-or-newer","responseBudgetBytes":262144,"defaultPageSize":50}|}
  in
  T.require (Result.is_error (C.of_yojson legacy)) "legacy config accepted"
;;

let rec add_tag_titles = function
  | `Assoc fields ->
    let fields = List.map (fun (k, v) -> k, add_tag_titles v) fields in
    if List.mem_assoc "rendered_page_title" fields && List.mem_assoc "block" fields
    then
      `Assoc
        (List.map
           (fun (name, value) ->
              if name = "tag_titles"
              then name, `List [ `String "户外"; `String "周末计划" ]
              else name, value)
           fields)
    else `Assoc fields
  | `List xs -> `List (List.map add_tag_titles xs)
  | x -> x
;;

let arbitrary_status_uuid_wire ()=
  let status=uuid "b1000000-0000-4000-8000-000000000099" in
  let origin=Uri.of_string "https://example.invalid" and graph=uuid native_id in
  let intent=M.create_mutation ~origin ~user:"synthetic" ~graph
    ~mutation_id:(uuid "30000000-0000-4000-8000-000000000003")
    (M.Set_task_status{block=uuid "10000000-0000-4000-8000-000000000002";status;
      preconditions={blocks=[];pages=[];scopes=[]}}) |> Result.get_ok |>fun intent->M.Mutation_intent intent in
  let encoded=M.encode intent in
  match M.restore ~origin ~user:"synthetic" ~graph encoded with
  |Ok(M.Mutation_intent restored)->
    T.require(M.encode(M.Mutation_intent restored)=encoded) "status storage bytes changed";
    (match M.mutation_command restored with M.Set_task_status value->
      T.require(value.status=status) "custom status UUID changed"|_->T.fail "status command changed")
  |_->T.fail "custom status UUID rejected"
;;

let page_tree_contract_rejects_retired_scope ()=
  let raw=Yojson.Safe.from_string {|{"blocks":[["10000000-0000-4000-8000-000000000002","block-revision:v1:1"]],"pages":[],"scopes":[[["V2_page_tree_scope",{"page":"20000000-0000-4000-8000-000000000001","maximum_depth":8}],"obsolete"]]}|}in
  T.require(Result.is_error(Data.preconditions_of_yojson raw)) "retired page-tree write scope was accepted"
;;

let tag_titles_survive_block_read_json ()=
  List.iter(fun original->
    let expected=add_tag_titles original in
    let decoded=Data.block_record_of_yojson expected |> Result.get_ok in
    T.require(Yojson.Safe.equal(T.canonical_json expected)(T.canonical_json(Data.block_record_to_yojson decoded)))
      "named tags were lost by Data record serialization")(block_records())
;;

let property_variants_and_int64_round_trip () =
  let response=List.hd(block_records())in
  let internal_values =
    [ `List [ `String "Internal_null" ]
    ; `List [ `String "Internal_bool"; `Bool true ]
    ; `List [ `String "Internal_number"; `String "1.25" ]
    ; `List [ `String "Internal_string"; `String "文本" ]
    ; `List [ `String "Internal_keyword"; `String "kind/value" ]
    ; `List [ `String "Internal_uuid"; `String native_id ]
    ; `List [ `String "Internal_list"; `List [ `List [ `String "Internal_null" ] ] ]
    ; `List
        [ `String "Internal_map"
        ; `List
            [ `List
                [ `List [ `String "Internal_keyword"; `String "key" ]
                ; `List [ `String "Internal_bool"; `Bool false ]
                ]
            ]
        ]
    ]
  in
  let value name json = `List [ `String name; json ] in
  let values =
    [ value "Default_value" (`String "Text")
    ; value "Number_value" (`String "12345678901234567890.125")
    ; value "Date_value" (`Assoc [ "journal_day", `Int 20261012 ])
    ; value "Datetime_value" (`Assoc [ "unix_ms", `Intlit "-9223372036854775808" ])
    ; value "Datetime_value" (`Assoc [ "unix_ms", `Intlit "9223372036854775807" ])
    ; value "Checkbox_value" (`Bool true)
    ; value "Url_value" (`String "https://example.org")
    ; value "Node_value" (`String native_id)
    ; value "Asset_value" (`String native_id)
    ; value "Keyword_value" (`String "kind/value")
    ; value
        "Map_value"
        (`List [ `List [ List.nth internal_values 4; List.nth internal_values 6 ] ])
    ; value "Collection_value" (`List internal_values)
    ; value "Any_value" (List.nth internal_values 7)
    ; value "Entity_value" (`String native_id)
    ; value "Class_value" (`String native_id)
    ; value "Page_value" (`String native_id)
    ; value "Property_value" (`String "user/property")
    ; value "String_value" (`String "Text")
    ; value "Json_value" (`String "{\"key\":true}")
    ; value "Raw_number_value" (`String "-9007199254740993")
    ]
  in
  let property =
    `Assoc
      [ "ident", `String "user/property"
      ; "uuid", `String native_id
      ; "title", `String "Property"
      ; ( "schema"
        , `Assoc
            [ "property_type", `List [ `String "Any" ]
            ; "cardinality", `List [ `String "Many" ]
            ; "hidden", `Bool false
            ; "public", `Bool true
            ] )
      ; "values", `List values
      ; "values_truncated", `Bool false
      ]
  in
  let expected =
    response
    |> replace_field "properties" (`List [ property ])
    |> replace_field "created_at_ms" (`Intlit "-9223372036854775808")
    |> replace_field "updated_at_ms" (`Intlit "9223372036854775807")
  in
  match Data.block_record_of_yojson expected with
  | Error message -> T.fail "property variants rejected: %s" message
  | Ok decoded ->
    T.require
      (Yojson.Safe.equal
         (T.canonical_json expected)
         (T.canonical_json (Data.block_record_to_yojson decoded)))
      "property variants/int64 bounds changed during roundtrip"
;;

let request_tree_boundaries ()=
  let node index children:Data.block_tree={uuid=uuid(Printf.sprintf "10000000-0000-4000-8000-%012d"index);title="Node";children}in
  let origin=Uri.of_string "https://example.invalid"and graph=uuid native_id in
  let insert roots=M.create_mutation ~origin ~user:"synthetic" ~graph ~mutation_id:graph
    (M.Insert_blocks{parent=graph;roots;preconditions={blocks=[];pages=[];scopes=[]}})in
  let rec chain depth=node depth(if depth=0 then []else[chain(depth-1)])in
  T.require(Result.is_ok(insert[chain Data.maximum_tree_depth])) "maximum-depth tree rejected";
  T.require(Result.is_error(insert[chain(Data.maximum_tree_depth+1)])) "over-depth tree accepted";
  let width nodes=insert[node 0(List.init(nodes-1)(fun n->node(n+1)[]))]in
  T.require(Result.is_ok(width Data.maximum_tree_nodes)) "maximum-node tree rejected";
  T.require(Result.is_error(width(Data.maximum_tree_nodes+1))) "over-node tree accepted";
  T.require(Result.is_error(insert[node 0[];node 1[]])) "multiple insertion trees bypassed sealed intent admission"
;;

let durable_wire_preserves_logical_identity () =
  let module W = Logseq_db_worker_contract.Worker_pure_mutation in
  let uuid text = Logseq_db_types.Graph_types.Uuid.of_string text |> Result.get_ok in
  let graph = uuid "40000000-0000-4000-8000-000000000001" in
  let id = uuid "30000000-0000-4000-8000-000000000003" in
  let block = uuid "10000000-0000-4000-8000-000000000002" in
  let origin = Uri.of_string "https://example.invalid" in
  let command =
    W.Save_block
      { block
      ; title = "complete durable payload"
      ; preconditions =
          { blocks = [ block, "block-state:v1:synthetic" ]; pages = []; scopes = [] }
      }
  in
  let first = W.create_mutation ~origin ~user:"synthetic-user" ~graph ~mutation_id:id command |> Result.get_ok in
  let first=W.Mutation_intent first in
  let encoded = W.encode first in
  T.require(encoded={golden|{"owner":{"graph":"40000000-0000-4000-8000-000000000001","origin":"https://example.invalid","user":"synthetic-user"},"request":{"api_version":2,"command":["V2_save_block",{"block":"10000000-0000-4000-8000-000000000002","mutation_id":"30000000-0000-4000-8000-000000000003","preconditions":{"blocks":[["10000000-0000-4000-8000-000000000002","block-state:v1:synthetic"]],"pages":[],"scopes":[]},"title":"complete durable payload"}],"request_id":"30000000-0000-4000-8000-000000000003"},"version":1}|golden}) "original v1 immutable bytes changed";
  T.require(W.namespace first="a8f4253d6166747cfe8e9d812c2f9f4a4fd24173cf78e3cc3957f5b0dfde5930") "original logical namespace changed";
  let restored =
    W.restore ~origin ~user:"synthetic-user" ~graph encoded |> Result.get_ok
  in
  T.require
    (W.encode restored = encoded && (match restored with W.Mutation_intent value->W.mutation_command value=command|_->false))
    "durable payload changed on restore";
  T.require (W.mutation_id restored = id) "durable mutation ID changed";
  T.require
    (Result.is_error (W.restore ~origin ~user:"different-user" ~graph encoded))
    "cross-user intent restored";
  T.require
    (Result.is_error
       (W.restore
          ~origin:(Uri.of_string "https://other.invalid")
          ~user:"synthetic-user"
          ~graph
          encoded))
    "cross-origin intent restored";
  T.require
    (Result.is_error (W.restore ~origin ~user:"synthetic-user" ~graph (encoded ^ " ")))
    "noncanonical intent accepted";
  T.require (Rrbvec.to_list (W.targets restored) = [ block ]) "canonical target missing";
  let response status generation before after=W.For_worker.commit ~mutation_id:id ~status ~generation ~before ~after in
  T.require (Result.is_ok(W.committed_point restored
    (response Worker_pure_data.V2_applied "generation:v1:1:1" "projection:v1:0" "projection:v1:1")))
    "valid original commit point rejected";
  List.iter(fun invalid ->
    T.require(Result.is_error(W.committed_point restored invalid))
      "invalid original commit evidence accepted")
    [response Worker_pure_data.V2_already_applied "generation:v1:1:1" "projection:v1:0" "projection:v1:0";
     response Worker_pure_data.V2_applied "generation:v1:1:1" "projection:v1:1" "projection:v1:1";
     response Worker_pure_data.V2_no_change "generation:v1:1:1" "projection:v1:0" "projection:v1:1";
     response Worker_pure_data.V2_applied "futureGeneration:v2:1" "projection:v1:0" "projection:v1:1"]
;;

let ()=T.run "Worker pure contracts"
  [T.case "durable storage logical identity" durable_wire_preserves_logical_identity
  ;T.case "arbitrary task status UUID storage" arbitrary_status_uuid_wire
  ;T.case "closed internal Config root and nested fields" closed_internal_config_fields
  ;T.case "tree depth node and root boundaries" request_tree_boundaries
  ;T.case "config golden and validation" config_generated_golden_and_validation
  ;T.case "property variants and int64 boundaries" property_variants_and_int64_round_trip
  ;T.case "error details and exact budget" error_details_and_budget
  ;T.case "reject retired page-tree scope" page_tree_contract_rejects_retired_scope
  ;T.case "named tags in Data records" tag_titles_survive_block_read_json
  ;T.case "causal error JSON round trip" causal_error_round_trip
  ;T.case "cause fallback preserves valid construction" cause_or_fallback_preserves_valid_cause
  ;T.case "cause fallback replaces rejected messages" cause_or_fallback_replaces_rejected_messages
  ;T.case "cause fallback preserves absent code" cause_or_fallback_preserves_absent_code
  ;T.case "cause fallback rejects an invalid fallback" cause_or_fallback_rejects_invalid_fallback
  ;T.case "direct errors create complete origins" direct_errors_create_complete_origins
  ;T.case "causal errors reject legacy and unsafe values" causal_error_rejects_legacy_and_unsafe_values
    ; T.case "frozen Data budgets" (fun () ->
        T.require (Worker_pure_data.maximum_request_bytes = 1_048_576) "request budget changed";
        T.require (Worker_pure_data.maximum_response_bytes = 262_144) "response budget changed";
        T.require (Worker_pure_data.maximum_push_bytes = 65_536) "push budget changed";
        T.require (Worker_pure_data.default_page_size = 50) "default page size changed";
        T.require (Worker_pure_data.maximum_page_size = 200) "maximum page size changed";
        T.require (Worker_pure_data.maximum_tree_nodes = 2_000) "tree node budget changed";
        T.require (Worker_pure_data.maximum_tree_depth = 64) "tree depth budget changed")
    ; T.case "schema profile accepts 65.33 or newer" (fun () ->
        match Logseq_db_worker.Config.Logseq_65_33_or_newer with
        | Logseq_db_worker.Config.Logseq_65_33_or_newer -> ())
    ; T.case "managed sync is the only startup target" (fun () ->
        let directory = Filename.temp_file "logseq-db-worker-config-" "" in
        Sys.remove directory;
        Unix.mkdir directory 0o700;
        let config =
          match
            Logseq_db_worker.Config.create
              ~application_support_directory:directory
              ~target:(Managed_sync { base_url = "https://api.logseq.io" })
              ~compatibility_profile:Logseq_65_33_or_newer
              ~response_budget_bytes:Worker_pure_data.maximum_response_bytes
              ~default_page_size:Worker_pure_data.default_page_size
          with
          | Ok config -> config
          | Error message -> T.fail "%s" message
        in
        let json = Logseq_db_worker.Config.to_yojson config in
        (match json with
         | `Assoc fields ->
           T.require
             (List.assoc_opt "accessMode" fields = None)
             "access mode leaked into config"
         | _ -> T.fail "config is not an object");
        match Logseq_db_worker.Config.of_yojson json with
        | Ok _ -> ()
        | Error message -> T.fail "%s" message)
    ; T.case "config decoding performs no filesystem access" (fun () ->
        let missing =
          Filename.concat
            (Filename.get_temp_dir_name ())
            "logseq-db-worker-config-must-not-exist"
        in
        let json =
          `Assoc
            [ "application_support_directory", `String missing
            ; ( "target"
              , `List
                  [ `String "Managed_sync"
                  ; `Assoc [ "base_url", `String "https://api.logseq.io" ]
                  ] )
            ; "compatibility_profile", `List [ `String "Logseq_65_33_or_newer" ]
            ; "response_budget_bytes", `Int Worker_pure_data.maximum_response_bytes
            ; "default_page_size", `Int Worker_pure_data.default_page_size
            ]
        in
        match Logseq_db_worker.Config.of_yojson json with
        | Ok config ->
          T.require
            (String.equal config.application_support_directory missing)
            "bounded decode changed the startup capability"
        | Error message ->
          T.fail "bounded config decode touched the filesystem: %s" message)
    ; T.case "reject retired startup target wire values" (fun () ->
        let envelope target =
          `Assoc
            [ "application_support_directory", `String "/tmp/logseq-journal-support"
            ; "target", target
            ; "compatibility_profile", `List [ `String "Logseq_65_33_or_newer" ]
            ; "response_budget_bytes", `Int Worker_pure_data.maximum_response_bytes
            ; "default_page_size", `Int Worker_pure_data.default_page_size
            ]
        in
        let reject kind fields =
          let target = `Assoc (("kind", `String kind) :: fields) in
          match Logseq_db_worker.Config.of_yojson (envelope target) with
          | Error _ -> ()
          | Ok _ -> T.fail "retired %s target was accepted" kind
        in
        reject
          ("snap" ^ "shot")
          [ "token", `String "40000000-0000-4000-8000-000000000001" ];
        reject ("import" ^ "Snapshot") [ "inbox" ^ "Entry", `String "incoming" ];
        reject
          ("nativeLocal" ^ "Graph")
          [ "graphName", `String "Journal"; "graphDir", `String "/tmp/Journal" ];
        reject
          ("synced" ^ "Mirror")
          [ "graphId", `String "40000000-0000-4000-8000-000000000001"
          ; "graphName", `String "Journal"
          ; "graphDir", `String "/tmp/Journal"
          ; "databasePath", `String "/tmp/Journal/db.sqlite"
          ; ( "checkpoint"
            , `Assoc
                [ "appliedServerT", `Int 0
                ; "checksum", `String "0000000000000000"
                ; "schemaMajor", `Int 65
                ; "schemaMinor", `Int 33
                ; "status", `String "active"
                ; "lastError", `Null
                ] )
          ])
    ]
;;
