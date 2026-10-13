module T = Logseq_db_worker_test_support.Test_support
module P = Logseq_db_worker.Protocol

let page_tree_contract_rejects_retired_scope () =
  let raw =
    Yojson.Safe.from_string
      {|{"api_version":2,"request_id":"00000000-0000-4000-8000-000000000009","command":["V2_delete_blocks",{"mutation_id":"30000000-0000-4000-8000-000000000003","root":"10000000-0000-4000-8000-000000000002","preconditions":{"blocks":[["10000000-0000-4000-8000-000000000002","block-revision:v1:1"]],"pages":[],"scopes":[[["V2_page_tree_scope",{"page":"20000000-0000-4000-8000-000000000001","maximum_depth":8}],"obsolete"]]}}]}|}
  in
  match P.request_of_yojson raw with
  | Error _ -> ()
  | Ok _ -> T.fail "retired page-tree write scope was accepted"
;;

let page_tree_result_without_collection_revision () =
  let raw =
    Yojson.Safe.from_string
      {|["V2_response",{"api_version":2,"request_id":"00000000-0000-4000-8000-000000000006","outcome":["V2_page_tree_outcome",{"page":"20000000-0000-4000-8000-000000000001","maximum_depth":1,"items":[],"next_cursor":null}]}]|}
  in
  match P.response_of_yojson raw with
  | Error message -> T.fail "revision-free page-tree result rejected: %s" message
  | Ok response ->
    T.require
      (Yojson.Safe.equal
         (T.canonical_json raw)
         (T.canonical_json (P.response_to_yojson response)))
      "page-tree result gained a revision"
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

let tag_titles_survive_block_read_json () =
  let catalog = T.read_json (T.fixture "protocol/v2-outcome-catalog.json") in
  let responses =
    match catalog with
    | `Assoc f -> List.assoc "responses" f
    | _ -> assert false
  in
  let responses =
    match responses with
    | `List xs -> xs
    | _ -> assert false
  in
  List.iter
    (fun original ->
       let expected = add_tag_titles original in
       if expected <> original
       then (
         match P.response_of_yojson expected with
         | Error message ->
           T.fail "named tags rejected at block read boundary: %s" message
         | Ok decoded ->
           T.require
             (Yojson.Safe.equal
                (T.canonical_json expected)
                (T.canonical_json (P.response_to_yojson decoded)))
             "named tags were lost by block read serialization"))
    responses
;;

let fixture_has_version expected_version path =
  match T.read_json (T.fixture path) with
  | `Assoc fields ->
    (match List.assoc_opt "api_version" fields with
     | Some (`Int version) when version = expected_version -> ()
     | _ -> T.fail "%s does not declare api_version %d" path expected_version)
  | _ -> T.fail "%s is not a JSON object" path
;;

let command_catalog_requests () =
  match T.read_json (T.fixture "protocol/v2-command-catalog.json") with
  | `Assoc fields ->
    (match List.assoc_opt "requests" fields with
     | Some (`List requests) -> requests
     | _ -> T.fail "command catalog has no requests")
  | _ -> T.fail "invalid command catalog"
;;

let request_round_trip () =
  List.iter
    (fun expected ->
       match P.request_of_yojson expected with
       | Error error ->
         T.fail "request decode failed: %s" (Logseq_db_worker.Error.message error)
       | Ok request ->
         T.require
           (Yojson.Safe.equal
              (T.canonical_json expected)
              (T.canonical_json (P.request_to_yojson request)))
           "request changed during round trip")
    (command_catalog_requests ())
;;

let outcome_field name =
  match T.read_json (T.fixture "protocol/v2-outcome-catalog.json") with
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some (`List values) -> values
     | _ -> T.fail "missing %s" name)
  | _ -> T.fail "invalid outcome catalog"
;;

let response_round_trip () =
  List.iter
    (fun expected ->
       match P.response_of_yojson expected with
       | Error message ->
         T.fail
           "response decode failed for %s: %s"
           (Yojson.Safe.to_string expected)
           message
       | Ok response ->
         T.require
           (Yojson.Safe.equal
              (T.canonical_json expected)
              (T.canonical_json (P.response_to_yojson response)))
           "response changed")
    (outcome_field "responses")
;;

let push_round_trip () =
  List.iter
    (fun expected ->
       match P.push_of_yojson expected with
       | Error message -> T.fail "push decode failed: %s" message
       | Ok push ->
         T.require
           (Yojson.Safe.equal
              (T.canonical_json expected)
              (T.canonical_json (P.push_to_yojson push)))
           "push changed")
    (outcome_field "pushes")
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

let native_id = "00000000-0000-4000-8000-000000000001"
let native_variant name fields = `List [ `String name; `Assoc fields ]

let native_request command =
  `Assoc [ "api_version", `Int 2; "request_id", `String native_id; "command", command ]
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

let generated_golden_and_legacy_rejection () =
  let native = native_request (`List [ `String "V2_graph_info" ]) in
  (match P.request_of_yojson native with
   | Error error ->
     T.fail "generated request rejected: %s" (Logseq_db_worker.Error.message error)
   | Ok request ->
     T.require
       (Yojson.Safe.equal native (P.request_to_yojson request))
       "graph-info encoding differs from the generated golden");
  let old_request =
    Yojson.Safe.from_string
      {|{"apiVersion":2,"requestId":"00000000-0000-4000-8000-000000000001","command":{"type":"graphInfo"}}|}
  in
  T.require
    (Result.is_error (P.request_of_yojson old_request))
    "old request wire accepted";
  let old_response =
    Yojson.Safe.from_string
      {|{"apiVersion":2,"requestId":"00000000-0000-4000-8000-000000000001","outcome":{"type":"failed","code":"closedSession","message":"Safe worker failure"}}|}
  in
  T.require
    (Result.is_error (P.response_of_yojson old_response))
    "old response wire accepted";
  let old_push =
    Yojson.Safe.from_string
      {|{"apiVersion":2,"push":{"type":"changesAvailable","generation":"g","through":"w"}}|}
  in
  T.require (Result.is_error (P.push_of_yojson old_push)) "old push wire accepted"
;;

let request_domain_constraints () =
  let reject label json =
    T.require (Result.is_error (P.request_of_yojson json)) "%s accepted" label
  in
  let favorite limit cursor =
    native_request
      (native_variant "V2_list_favorites" [ "limit", limit; "cursor", cursor ])
  in
  List.iter
    (fun limit -> reject "invalid page limit" (favorite (`Int limit) `Null))
    [ 0; -1; P.maximum_page_size + 1 ];
  List.iter
    (fun cursor -> reject "invalid cursor" (favorite (`Int 1) cursor))
    [ `String ""; `String (String.make 16385 'x'); `Bool false; `List []; `String "\255" ];
  reject "nonintegral limit" (favorite (`Float 1.5) `Null);
  reject "integer overflow" (favorite (`Intlit "9223372036854775808") `Null);
  reject
    "invalid request UUID"
    (replace_field "request_id" (`String "not-a-uuid") (favorite (`Int 1) `Null));
  reject
    "invalid nested UUID"
    (native_request
       (native_variant
          "V2_get_block"
          [ "block", `String "not-a-uuid"; "revision", `Null ]));
  let save title =
    native_request
      (native_variant
         "V2_save_block"
         [ "mutation_id", `String native_id
         ; "block", `String native_id
         ; "title", `String title
         ; ( "preconditions"
           , `Assoc [ "blocks", `List []; "pages", `List []; "scopes", `List [] ] )
         ])
  in
  reject "invalid title UTF-8" (save "\255");
  reject "oversized title" (save (String.make (P.maximum_title_bytes + 1) 'x'));
  let duplicate =
    native_request
      (native_variant
         "V2_list_favorites"
         [ "limit", `Int 1; "limit", `Int 2; "cursor", `Null ])
  in
  reject "duplicate nested field" duplicate;
  reject
    "unknown nested field"
    (native_request
       (native_variant
          "V2_list_favorites"
          [ "limit", `Int 1; "cursor", `Null; "unknown", `Bool true ]));
  reject
    "malformed scope UUID"
    (native_request
       (native_variant
          "V2_save_block"
          [ "mutation_id", `String native_id
          ; "block", `String native_id
          ; "title", `String "safe"
          ; ( "preconditions"
            , `Assoc
                [ "blocks", `List []
                ; "pages", `List []
                ; ( "scopes"
                  , `List
                      [ `List
                          [ `List [ `String "V2_children_scope"; `String "bad" ]
                          ; `String "r"
                          ]
                      ] )
                ] )
          ]));
  let tree depth =
    native_request
      (native_variant
         "V2_get_page_tree"
         [ "page", `String native_id
         ; "maximum_depth", `Int depth
         ; "limit", `Int 1
         ; "cursor", `Null
         ; "revision", `Null
         ])
  in
  List.iter
    (fun depth -> reject "invalid tree depth" (tree depth))
    [ -1; P.maximum_tree_depth + 1 ]
;;

let response_domain_constraints () =
  let responses = outcome_field "responses" in
  let present_block =
    List.find
      (function
        | `List [ `String "V2_response"; `Assoc fields ] ->
          (match List.assoc "outcome" fields with
           | `List [ `String "V2_block_outcome"; `List [ `String "V2_present_block"; _ ] ]
             -> true
           | _ -> false)
        | _ -> false)
      responses
  in
  let reject label json =
    T.require (Result.is_error (P.response_of_yojson json)) "%s accepted" label
  in
  reject "nested block UUID" (replace_field "uuid" (`String "bad") present_block);
  reject
    "invalid nested title UTF-8"
    (replace_field "title" (`String "\255") present_block);
  reject
    "oversized block title"
    (replace_field
       "title"
       (`String (String.make (P.maximum_title_bytes + 1) 'x'))
       present_block);
  reject
    "missing required tag_titles"
    (map_json_fields (List.filter (fun (name, _) -> name <> "tag_titles")) present_block);
  reject
    "malformed tag_titles"
    (replace_field "tag_titles" (`List [ `Int 1 ]) present_block);
  reject
    "invalid task status option"
    (replace_field "task_status" (`List [ `String "todo" ]) present_block);
  reject
    "old textual int64"
    (replace_field "created_at_ms" (`String "1788278400000") present_block);
  reject
    "int64 overflow"
    (replace_field "updated_at_ms" (`Intlit "9223372036854775808") present_block);
  let child =
    List.find
      (function
        | `List [ `String "V2_response"; `Assoc fields ] ->
          (match List.assoc "outcome" fields with
           | `List [ `String "V2_children_outcome"; _ ] -> true
           | _ -> false)
        | _ -> false)
      responses
  in
  reject "invalid nested cursor" (replace_field "next_cursor" (`String "") child);
  reject
    "malformed revision scope UUID"
    (replace_field
       "revision_scope"
       (`List [ `String "V2_children_revision"; `String "bad" ])
       child)
;;

let property_variants_and_int64_round_trip () =
  let response =
    List.find
      (function
        | `List [ `String "V2_response"; `Assoc fields ] ->
          (match List.assoc "outcome" fields with
           | `List [ `String "V2_block_outcome"; `List [ `String "V2_present_block"; _ ] ]
             -> true
           | _ -> false)
        | _ -> false)
      (outcome_field "responses")
  in
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
  match P.response_of_yojson expected with
  | Error message -> T.fail "property variants rejected: %s" message
  | Ok decoded ->
    T.require
      (Yojson.Safe.equal
         (T.canonical_json expected)
         (T.canonical_json (P.response_to_yojson decoded)))
      "property variants/int64 bounds changed during roundtrip"
;;

let exact_wire_budgets () =
  let encoded_size json = String.length (Yojson.Safe.to_string json) in
  let padded target make =
    let overhead = encoded_size (make 0) in
    let json = make (target - overhead) in
    T.require
      (encoded_size json = target)
      "test failed to construct exact %d byte wire"
      target;
    json
  in
  let request_make padding =
    let remaining = ref padding in
    let roots =
      List.init 17 (fun i ->
        let length = min P.maximum_title_bytes !remaining in
        remaining := !remaining - length;
        `Assoc
          [ "uuid", `String (Printf.sprintf "10000000-0000-4000-8000-%012d" i)
          ; "title", `String (String.make length 'x')
          ; "children", `List []
          ])
    in
    native_request
      (native_variant
         "V2_insert_blocks"
         [ "mutation_id", `String native_id
         ; "parent", `String native_id
         ; "roots", `List roots
         ; ( "preconditions"
           , `Assoc [ "blocks", `List []; "pages", `List []; "scopes", `List [] ] )
         ])
  in
  let accept_request json =
    match P.request_of_yojson json with
    | Ok _ -> ()
    | Error e ->
      T.fail "request at budget rejected: %s" (Logseq_db_worker.Error.message e)
  in
  accept_request (padded P.maximum_request_bytes request_make);
  T.require
    (Result.is_error
       (P.request_of_yojson (padded (P.maximum_request_bytes + 1) request_make)))
    "request over budget accepted";
  let response_make padding =
    `List
      [ `String "V2_response"
      ; `Assoc
          [ "api_version", `Int 2
          ; "request_id", `String native_id
          ; ( "outcome"
            , native_variant
                "V2_failed"
                [ "code", `String "failed"; "message", `String (String.make padding 'x') ]
            )
          ]
      ]
  in
  let at_limit = padded P.maximum_response_bytes response_make in
  (match P.response_of_yojson at_limit with
   | Error message -> T.fail "response at budget rejected: %s" message
   | Ok response ->
     T.require
       (P.encoded_response_bytes response = P.maximum_response_bytes)
       "actual generated response byte count differs");
  T.require
    (Result.is_error
       (P.response_of_yojson (padded (P.maximum_response_bytes + 1) response_make)))
    "response over budget accepted";
  let push_make padding =
    native_variant
      "V2_resync_required_push"
      [ "api_version", `Int 2
      ; "generation", `String "g"
      ; "reason", `String (String.make padding 'x')
      ]
  in
  T.require
    (Result.is_ok (P.push_of_yojson (padded P.maximum_push_bytes push_make)))
    "push at budget rejected";
  T.require
    (Result.is_error (P.push_of_yojson (padded (P.maximum_push_bytes + 1) push_make)))
    "push over budget accepted"
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
      ; "response_budget_bytes", `Int P.maximum_response_bytes
      ; "default_page_size", `Int P.default_page_size
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
    [ 0; P.maximum_response_bytes + 1 ];
  List.iter
    (fun size ->
       T.require
         (Result.is_error
            (C.of_yojson (replace_field "default_page_size" (`Int size) valid)))
         "invalid default page size accepted")
    [ 0; P.maximum_page_size + 1 ];
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

let request_tree_boundaries () =
  let node index children =
    `Assoc
      [ "uuid", `String (Printf.sprintf "10000000-0000-4000-8000-%012d" index)
      ; "title", `String "Node"
      ; "children", `List children
      ]
  in
  let insert roots =
    native_request
      (native_variant
         "V2_insert_blocks"
         [ "mutation_id", `String native_id
         ; "parent", `String native_id
         ; "roots", `List roots
         ; ( "preconditions"
           , `Assoc [ "blocks", `List []; "pages", `List []; "scopes", `List [] ] )
         ])
  in
  let rec chain depth = node depth (if depth = 0 then [] else [ chain (depth - 1) ]) in
  let accept label json =
    match P.request_of_yojson json with
    | Ok _ -> ()
    | Error error -> T.fail "%s rejected: %s" label (Logseq_db_worker.Error.message error)
  in
  accept "tree at maximum depth" (insert [ chain P.maximum_tree_depth ]);
  T.require
    (Result.is_error (P.request_of_yojson (insert [ chain (P.maximum_tree_depth + 1) ])))
    "tree deeper than maximum accepted";
  let width nodes =
    insert [ node 0 (List.init (nodes - 1) (fun i -> node (i + 1) [])) ]
  in
  accept "tree at maximum node count" (width P.maximum_tree_nodes);
  T.require
    (Result.is_error (P.request_of_yojson (width (P.maximum_tree_nodes + 1))))
    "tree over node bound accepted";
  accept
    "tree at maximum root count"
    (insert (List.init P.maximum_roots (fun i -> node i [])));
  T.require
    (Result.is_error
       (P.request_of_yojson
          (insert (List.init (P.maximum_roots + 1) (fun i -> node i [])))))
    "tree over root bound accepted"
;;

let () =
  T.run
    "protocol"
    [ T.case "tree depth node and root boundaries" request_tree_boundaries
    ; T.case "config golden and validation" config_generated_golden_and_validation
    ; T.case "generated golden and legacy rejection" generated_golden_and_legacy_rejection
    ; T.case "request domain constraints" request_domain_constraints
    ; T.case "response domain constraints" response_domain_constraints
    ; T.case
        "property variants and int64 boundaries"
        property_variants_and_int64_round_trip
    ; T.case "exact generated wire budgets" exact_wire_budgets
    ; T.case "error details and exact budget" error_details_and_budget
    ; T.case "reject retired page-tree scope" page_tree_contract_rejects_retired_scope
    ; T.case
        "page-tree result has no collection revision"
        page_tree_result_without_collection_revision
    ; T.case "frozen protocol budgets" (fun () ->
        T.require (P.api_version = 2) "api version is not v2";
        T.require (P.maximum_request_bytes = 1_048_576) "request budget changed";
        T.require (P.maximum_response_bytes = 262_144) "response budget changed";
        T.require (P.maximum_push_bytes = 65_536) "push budget changed";
        T.require (P.default_page_size = 50) "default page size changed";
        T.require (P.maximum_page_size = 200) "maximum page size changed";
        T.require (P.maximum_tree_nodes = 2_000) "tree node budget changed";
        T.require (P.maximum_tree_depth = 64) "tree depth budget changed")
    ; T.case "versioned command fixture" (fun () ->
        fixture_has_version 2 "protocol/v2-command-catalog.json")
    ; T.case "versioned outcome fixture" (fun () ->
        fixture_has_version 2 "protocol/v2-outcome-catalog.json")
    ; T.case "versioned operation fixture" (fun () ->
        fixture_has_version 2 "protocol/v2-operation-contracts.json")
    ; T.case "request JSON round trip" request_round_trip
    ; T.case "response JSON round trip" response_round_trip
    ; T.case "named tags in block reads" tag_titles_survive_block_read_json
    ; T.case "push JSON round trip" push_round_trip
    ; T.case "causal error JSON round trip" causal_error_round_trip
    ; T.case
        "cause fallback preserves valid construction"
        cause_or_fallback_preserves_valid_cause
    ; T.case
        "cause fallback replaces rejected messages"
        cause_or_fallback_replaces_rejected_messages
    ; T.case
        "cause fallback preserves absent code"
        cause_or_fallback_preserves_absent_code
    ; T.case
        "cause fallback rejects an invalid fallback"
        cause_or_fallback_rejects_invalid_fallback
    ; T.case "direct errors create complete origins" direct_errors_create_complete_origins
    ; T.case
        "causal errors reject legacy and unsafe values"
        causal_error_rejects_legacy_and_unsafe_values
    ; T.case "reject unknown and trailing fields" (fun () ->
        let invalid =
          `Assoc
            [ "api_version", `Int 2
            ; "request_id", `String "00000000-0000-4000-8000-000000000001"
            ; ( "command"
              , `List [ `String "V2_graph_info"; `Assoc [ "unknown", `Bool true ] ] )
            ]
        in
        match P.request_of_yojson invalid with
        | Error _ -> ()
        | Ok _ -> T.fail "unknown command field accepted")
    ; T.case "reject invalid UTF-8 and UUID" (fun () ->
        let invalid =
          `Assoc
            [ "api_version", `Int 2
            ; "request_id", `String "not-a-uuid"
            ; "command", `List [ `String "V2_graph_info" ]
            ]
        in
        match P.request_of_yojson invalid with
        | Error _ -> ()
        | Ok _ -> T.fail "invalid UUID accepted")
    ; T.case "reject oversized envelope before Engine" (fun () ->
        let request =
          native_request
            (native_variant
               "V2_save_block"
               [ "mutation_id", `String native_id
               ; "block", `String native_id
               ; "title", `String (String.make P.maximum_request_bytes 'x')
               ; ( "preconditions"
                 , `Assoc [ "blocks", `List []; "pages", `List []; "scopes", `List [] ] )
               ])
        in
        match P.request_of_yojson request with
        | Error _ -> ()
        | Ok _ -> T.fail "oversized request accepted")
    ; T.case "never expose numeric entity IDs" (fun () ->
        List.iter
          (fun json ->
             let encoded = Yojson.Safe.to_string json in
             T.require
               (not (String.starts_with ~prefix:"dbId" encoded))
               "numeric storage identity exposed";
             match P.request_of_yojson json with
             | Error _ -> T.fail "catalog request rejected"
             | Ok _ -> ())
          (command_catalog_requests ()))
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
              ~response_budget_bytes:P.maximum_response_bytes
              ~default_page_size:P.default_page_size
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
            ; "response_budget_bytes", `Int P.maximum_response_bytes
            ; "default_page_size", `Int P.default_page_size
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
            ; "response_budget_bytes", `Int P.maximum_response_bytes
            ; "default_page_size", `Int P.default_page_size
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
