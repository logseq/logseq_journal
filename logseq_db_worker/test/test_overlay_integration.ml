module T = Logseq_db_worker_test_support.Test_support

let assoc name = function
  | `Assoc fields ->
    (match List.assoc_opt name fields with
     | Some value -> value
     | None -> T.fail "missing %s" name)
  | _ -> T.fail "expected an object while reading %s" name
;;

let strings name json =
  match assoc name json with
  | `List values ->
    List.map
      (function
        | `String value -> value
        | _ -> T.fail "%s contains a non-string value" name)
      values
  | _ -> T.fail "%s is not a list" name
;;

let constructor = function
  | `List (`String name :: _) -> name
  | _ -> T.fail "expected a generated variant"
;;

let command_types json =
  match assoc "requests" json with
  | `List requests ->
    List.map (fun request -> constructor (assoc "command" request)) requests
  | _ -> T.fail "requests is not a list"
;;

let outcome_types json =
  match assoc "responses" json with
  | `List responses ->
    List.map
      (function
        | `List [ `String "V2_response"; fields ] -> constructor (assoc "outcome" fields)
        | _ -> T.fail "expected a generated response")
      responses
  | _ -> T.fail "responses is not a list"
;;

let rec object_contains_key key = function
  | `Assoc fields ->
    List.exists
      (fun (name, value) -> String.equal name key || object_contains_key key value)
      fields
  | `List values -> List.exists (object_contains_key key) values
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `Tuple _ | `Variant _ ->
    false
;;

let require_exact label expected actual =
  T.require
    (List.sort String.compare expected = List.sort String.compare actual)
    "%s changed: expected [%s], got [%s]"
    label
    (String.concat ", " expected)
    (String.concat ", " actual)
;;

let contains_substring haystack needle =
  let haystack_length = String.length haystack in
  let needle_length = String.length needle in
  let rec search offset =
    if offset + needle_length > haystack_length
    then false
    else if String.sub haystack offset needle_length = needle
    then true
    else search (offset + 1)
  in
  search 0
;;

let () =
  let commands = T.read_json (T.fixture "protocol/v2-command-catalog.json") in
  let contracts = T.read_json (T.fixture "protocol/v2-operation-contracts.json") in
  let outcomes = T.read_json (T.fixture "protocol/v2-outcome-catalog.json") in
  T.run
    "overlay integration"
    [ T.case "worker exposes protocol v2" (fun () ->
        T.require (Logseq_db_worker.Protocol.api_version = 2) "Worker is not v2")
    ; T.case "v2 catalog contains only the current App surface" (fun () ->
        require_exact
          "read operations"
          [ "V2_get_outline_block"
          ; "V2_get_children"
          ; "V2_get_page"
          ; "V2_get_page_tree"
          ; "V2_graph_info"
          ; "V2_inspect_admission"
          ; "V2_list_favorites"
          ; "V2_list_journals"
          ; "V2_get_asset_descriptors"
          ; "V2_list_assets"
          ; "V2_get_outline_block_summary"
          ; "V2_list_task_statuses"
          ; "V2_get_task_status_definitions"
          ]
          (strings "read_operations" commands);
        require_exact
          "mutation operations"
          [ "V2_clear_task_status"
          ; "V2_create_journal_page"
          ; "V2_delete_blocks"
          ; "V2_insert_blocks"
          ; "V2_save_block"
          ; "V2_set_task_status"
          ; "V2_set_asset_reference"
          ]
          (strings "mutation_operations" commands);
        require_exact
          "change operations"
          [ "V2_ack_changes"; "V2_pull_changes" ]
          (strings "change_operations" commands))
    ; T.case "v2 requests contain no basis or generic selector shapes" (fun () ->
        List.iter
          (fun key ->
             T.require
               (not (object_contains_key key commands))
               "v2 catalog contains retired field %s"
               key)
          [ "expectedBasis"
          ; "kind"
          ; "position"
          ; "property"
          ; "propertySelector"
          ; "propertyValue"
          ])
    ; T.case "v2 operations use constructor-specific contracts" (fun () ->
        T.require
          (not (object_contains_key "expectedBasis" contracts))
          "v2 identity retained expectedBasis";
        T.require
          (object_contains_key "requiredPreconditions" contracts)
          "v2 mutations have no target-local preconditions")
    ; T.case "v2 outcomes include cumulative windows, ACK, and resync" (fun () ->
        let encoded = Yojson.Safe.to_string outcomes in
        List.iter
          (fun expected ->
             T.require
               (contains_substring encoded expected)
               "v2 outcomes omit %s"
               expected)
          [ "V2_changes_available"
          ; "V2_changes_acknowledged"
          ; "V2_resync_required"
          ; "predecessor"
          ; "successor"
          ])
    ; T.case "v2 outcomes cover every retained App read" (fun () ->
        let actual = outcome_types outcomes |> List.sort_uniq String.compare in
        List.iter
          (fun expected ->
             T.require
               (List.mem expected actual)
               "v2 outcomes omit retained App read %s"
               expected)
          [ "V2_graph_info_outcome"
          ; "V2_admission_outcome"
          ; "V2_journals_outcome"
          ; "V2_page_outcome"
          ; "V2_block_outcome"
          ; "V2_children_outcome"
          ; "V2_page_tree_outcome"
          ])
    ; T.case "v2 command catalog is the executable protocol catalog" (fun () ->
        let expected = command_types commands in
        T.require (List.length expected = 22) "unexpected v2 request count";
        List.iter
          (fun request ->
             match Logseq_db_worker.Protocol.request_of_yojson request with
             | Ok _ -> ()
             | Error error ->
               T.fail
                 "Worker rejected v2 request: %s"
                 (Logseq_db_worker.Error.message error))
          (match assoc "requests" commands with
           | `List values -> values
           | _ -> assert false))
    ]
;;
