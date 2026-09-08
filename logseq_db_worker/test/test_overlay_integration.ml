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

let command_types json =
  match assoc "requests" json with
  | `List requests ->
    List.map
      (fun request ->
         match assoc "type" (assoc "command" request) with
         | `String value -> value
         | _ -> T.fail "command type is not a string")
      requests
  | _ -> T.fail "requests is not a list"
;;

let outcome_types json =
  match assoc "responses" json with
  | `List responses ->
    List.map
      (fun response ->
         match assoc "type" (assoc "outcome" response) with
         | `String value -> value
         | _ -> T.fail "outcome type is not a string")
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
          [ "getBlock"
          ; "getChildren"
          ; "getPage"
          ; "getPageTree"
          ; "graphInfo"
          ; "inspectAdmission"
          ; "listFavorites"
          ; "listJournals"
          ]
          (strings "readOperations" commands);
        require_exact
          "mutation operations"
          [ "clearTaskStatus"
          ; "createJournalPage"
          ; "deleteBlocks"
          ; "insertBlocks"
          ; "saveBlock"
          ; "setTaskStatus"
          ]
          (strings "mutationOperations" commands);
        require_exact
          "change operations"
          [ "ackChanges"; "pullChanges" ]
          (strings "changeOperations" commands))
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
          [ "changesAvailable"
          ; "changesAcknowledged"
          ; "resyncRequired"
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
          [ "graphInfo"
          ; "admission"
          ; "journals"
          ; "page"
          ; "block"
          ; "children"
          ; "pageTree"
          ])
    ; T.case "v2 command catalog is the executable protocol catalog" (fun () ->
        let expected = command_types commands in
        T.require (List.length expected = 16) "unexpected v2 request count";
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
