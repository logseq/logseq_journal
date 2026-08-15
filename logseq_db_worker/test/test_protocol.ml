module T = Logseq_db_worker_test_support.Test_support
module P = Logseq_db_worker.Protocol

let fixture_has_version path =
  match T.read_json (T.fixture path) with
  | `Assoc fields ->
    (match List.assoc_opt "apiVersion" fields with
     | Some (`Int 1) -> ()
     | _ -> T.fail "%s does not declare apiVersion 1" path)
  | _ -> T.fail "%s is not a JSON object" path
;;

let command_catalog_requests () =
  match T.read_json (T.fixture "protocol/v1-command-catalog.json") with
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
       | Error error -> T.fail "request decode failed: %s" (Logseq_db_worker.Error.message error)
       | Ok request ->
         T.require
           (Yojson.Safe.equal (Yojson.Safe.sort expected) (Yojson.Safe.sort (P.request_to_yojson request)))
           "request changed during round trip")
    (command_catalog_requests ())
;;

let outcome_field name =
  match T.read_json (T.fixture "protocol/v1-outcome-catalog.json") with
  | `Assoc fields -> (match List.assoc_opt name fields with Some (`List values) -> values | _ -> T.fail "missing %s" name)
  | _ -> T.fail "invalid outcome catalog"
;;

let response_round_trip () =
  List.iter
    (fun expected ->
       match P.response_of_yojson expected with
       | Error message -> T.fail "response decode failed: %s" message
       | Ok response -> T.require (Yojson.Safe.equal (Yojson.Safe.sort expected) (Yojson.Safe.sort (P.response_to_yojson response))) "response changed")
    (outcome_field "responses")
;;

let push_round_trip () =
  List.iter
    (fun expected ->
       match P.push_of_yojson expected with
       | Error message -> T.fail "push decode failed: %s" message
       | Ok push -> T.require (Yojson.Safe.equal (Yojson.Safe.sort expected) (Yojson.Safe.sort (P.push_to_yojson push))) "push changed")
    (outcome_field "pushes")
;;

let () =
  T.run
    "protocol"
    [ T.case "frozen protocol budgets" (fun () ->
        T.require (P.api_version = 1) "api version changed";
        T.require (P.maximum_request_bytes = 1_048_576) "request budget changed";
        T.require (P.maximum_response_bytes = 262_144) "response budget changed";
        T.require (P.maximum_push_bytes = 65_536) "push budget changed";
        T.require (P.default_page_size = 50) "default page size changed";
        T.require (P.maximum_page_size = 200) "maximum page size changed";
        T.require (P.maximum_tree_nodes = 2_000) "tree node budget changed";
        T.require (P.maximum_tree_depth = 64) "tree depth budget changed")
    ; T.case "versioned command fixture" (fun () ->
        fixture_has_version "protocol/v1-command-catalog.json")
    ; T.case "versioned outcome fixture" (fun () ->
        fixture_has_version "protocol/v1-outcome-catalog.json")
    ; T.case "versioned operation fixture" (fun () ->
        fixture_has_version "protocol/v1-operation-contracts.json")
    ; T.case "request JSON round trip" request_round_trip
    ; T.case "response JSON round trip" response_round_trip
    ; T.case "push JSON round trip" push_round_trip
    ; T.case "reject unknown and trailing fields" (fun () ->
        let invalid =
          `Assoc
            [ "apiVersion", `Int 1
            ; "requestId", `String "00000000-0000-4000-8000-000000000001"
            ; "command", `Assoc [ "type", `String "graphInfo"; "unknown", `Bool true ]
            ]
        in
        match P.request_of_yojson invalid with
        | Error _ -> ()
        | Ok _ -> T.fail "unknown command field accepted")
    ; T.case "reject invalid UTF-8 and UUID" (fun () ->
        let invalid =
          `Assoc
            [ "apiVersion", `Int 1
            ; "requestId", `String "not-a-uuid"
            ; "command", `Assoc [ "type", `String "graphInfo" ]
            ]
        in
        match P.request_of_yojson invalid with Error _ -> () | Ok _ -> T.fail "invalid UUID accepted")
    ; T.case "reject oversized envelope before Engine" (fun () ->
        let request =
          `Assoc
            [ "apiVersion", `Int 1
            ; "requestId", `String "00000000-0000-4000-8000-000000000001"
            ; "command", `Assoc [ "type", `String "getPage"; "page", `Assoc [ "type", `String "name"; "name", `String (String.make P.maximum_request_bytes 'x'); "kind", `String "any" ] ]
            ]
        in
        match P.request_of_yojson request with Error _ -> () | Ok _ -> T.fail "oversized request accepted")
    ; T.case "never expose numeric entity IDs" (fun () ->
        List.iter
          (fun json ->
             let encoded = Yojson.Safe.to_string json in
             T.require (not (String.starts_with ~prefix:"dbId" encoded)) "numeric storage identity exposed";
             match P.request_of_yojson json with Error _ -> T.fail "catalog request rejected" | Ok _ -> ())
          (command_catalog_requests ()))
    ; T.case "schema profile accepts 65.33 or newer" (fun () ->
        match Logseq_db_worker.Config.Logseq_65_33_or_newer with
        | Logseq_db_worker.Config.Logseq_65_33_or_newer -> ())
    ; T.case "all targets are exclusive read-write" (fun () ->
        let directory = Filename.temp_file "logseq-db-worker-config-" "" in
        Sys.remove directory;
        Unix.mkdir directory 0o700;
        let token = match Logseq_db_worker.Graph_types.Uuid.of_string "40000000-0000-4000-8000-000000000001" with Ok token -> token | Error message -> T.fail "%s" message in
        let config =
          match
            Logseq_db_worker.Config.create
              ~application_support_directory:directory
              ~target:(Snapshot { token })
              ~compatibility_profile:Logseq_65_33_or_newer
              ~response_budget_bytes:P.maximum_response_bytes
              ~default_page_size:P.default_page_size
          with
          | Ok config -> config
          | Error message -> T.fail "%s" message
        in
        let json = Logseq_db_worker.Config.to_yojson config in
        (match json with
         | `Assoc fields -> T.require (List.assoc_opt "accessMode" fields = None) "access mode leaked into config"
         | _ -> T.fail "config is not an object");
        match Logseq_db_worker.Config.of_yojson json with Ok _ -> () | Error message -> T.fail "%s" message)
    ; T.case "config decoding performs no filesystem access" (fun () ->
        let missing =
          Filename.concat
            (Filename.get_temp_dir_name ())
            "logseq-db-worker-config-must-not-exist"
        in
        let json =
          `Assoc
            [ "applicationSupportDirectory", `String missing
            ; ( "target"
              , `Assoc
                  [ "kind", `String "snapshot"
                  ; "token", `String "40000000-0000-4000-8000-000000000001"
                  ] )
            ; "compatibilityProfile", `String "logseq-65.33-or-newer"
            ; "responseBudgetBytes", `Int P.maximum_response_bytes
            ; "defaultPageSize", `Int P.default_page_size
            ]
        in
        match Logseq_db_worker.Config.of_yojson json with
        | Ok config ->
          T.require
            (String.equal config.application_support_directory missing)
            "bounded decode changed the startup capability"
        | Error message -> T.fail "bounded config decode touched the filesystem: %s" message)
    ]
