module T = Logseq_db_worker_test_support.Test_support
module S = Managed_sync_e2e_support

let require_error context = function
  | Ok _ -> T.fail "%s unexpectedly succeeded" context
  | Error message ->
    T.require
      (String.length message > 0 && String.length message <= 160)
      "%s returned an unsafe diagnostic"
      context
;;

let credentials_reject_invalid_environment () =
  let missing _ = None in
  require_error "missing credentials" (S.credentials_from_environment missing);
  let empty = function
    | "LOGSEQ_DB_WORKER_E2E_USERNAME" -> Some ""
    | "LOGSEQ_DB_WORKER_E2E_PASSWORD" -> Some "password"
    | "LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD" -> Some "graph-password"
    | "LOGSEQ_DB_WORKER_E2E_GRAPH_NAME" -> Some "Dedicated test graph"
    | _ -> None
  in
  require_error "empty username" (S.credentials_from_environment empty);
  let nul = function
    | "LOGSEQ_DB_WORKER_E2E_USERNAME" -> Some "account"
    | "LOGSEQ_DB_WORKER_E2E_PASSWORD" -> Some "pass\000word"
    | "LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD" -> Some "graph-password"
    | "LOGSEQ_DB_WORKER_E2E_GRAPH_NAME" -> Some "Dedicated test graph"
    | _ -> None
  in
  require_error "NUL password" (S.credentials_from_environment nul);
  let oversized = function
    | "LOGSEQ_DB_WORKER_E2E_USERNAME" -> Some (String.make 4_097 'u')
    | "LOGSEQ_DB_WORKER_E2E_PASSWORD" -> Some "password"
    | "LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD" -> Some "graph-password"
    | "LOGSEQ_DB_WORKER_E2E_GRAPH_NAME" -> Some "Dedicated test graph"
    | _ -> None
  in
  require_error "oversized username" (S.credentials_from_environment oversized);
  let invalid_graph_name value = function
    | "LOGSEQ_DB_WORKER_E2E_USERNAME" -> Some "account"
    | "LOGSEQ_DB_WORKER_E2E_PASSWORD" -> Some "password"
    | "LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD" -> Some "graph-password"
    | "LOGSEQ_DB_WORKER_E2E_GRAPH_NAME" -> value
    | _ -> None
  in
  require_error
    "missing graph name"
    (S.credentials_from_environment (invalid_graph_name None));
  require_error
    "empty graph name"
    (S.credentials_from_environment (invalid_graph_name (Some "")));
  require_error
    "NUL graph name"
    (S.credentials_from_environment (invalid_graph_name (Some "graph\000name")));
  require_error
    "oversized graph name"
    (S.credentials_from_environment (invalid_graph_name (Some (String.make 4_097 'g'))));
  let invalid_e2ee_password value = function
    | "LOGSEQ_DB_WORKER_E2E_USERNAME" -> Some "account"
    | "LOGSEQ_DB_WORKER_E2E_PASSWORD" -> Some "password"
    | "LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD" -> value
    | "LOGSEQ_DB_WORKER_E2E_GRAPH_NAME" -> Some "Dedicated test graph"
    | _ -> None
  in
  require_error
    "missing E2EE password"
    (S.credentials_from_environment (invalid_e2ee_password None));
  require_error
    "empty E2EE password"
    (S.credentials_from_environment (invalid_e2ee_password (Some "")));
  require_error
    "NUL E2EE password"
    (S.credentials_from_environment (invalid_e2ee_password (Some "graph\000password")));
  require_error
    "oversized E2EE password"
    (S.credentials_from_environment
       (invalid_e2ee_password (Some (String.make 4_097 'p'))))
;;

let credentials_accept_bounded_environment () =
  let lookup = function
    | "LOGSEQ_DB_WORKER_E2E_USERNAME" -> Some "dedicated-account"
    | "LOGSEQ_DB_WORKER_E2E_PASSWORD" -> Some "dedicated-password"
    | "LOGSEQ_DB_WORKER_E2E_E2EE_PASSWORD" -> Some "dedicated-graph-password"
    | "LOGSEQ_DB_WORKER_E2E_GRAPH_NAME" -> Some "Dedicated test graph"
    | _ -> None
  in
  match S.credentials_from_environment lookup with
  | Ok credentials ->
    T.require
      (String.equal credentials.graph_name "Dedicated test graph")
      "configured graph name changed";
    T.require
      (String.equal credentials.e2ee_password "dedicated-graph-password")
      "configured E2EE password changed"
  | Error message -> T.fail "bounded credentials were rejected: %s" message
;;

let cognito_response_yields_token_and_subject () =
  let response =
    {|{"AuthenticationResult":{"IdToken":"header.eyJzdWIiOiJkZWRpY2F0ZWQtdXNlciJ9.signature"}}|}
  in
  match S.cognito_session_of_response response with
  | Ok session ->
    T.require
      (String.equal session.user_id "dedicated-user")
      "Cognito subject was not extracted";
    T.require
      (String.equal session.id_token "header.eyJzdWIiOiJkZWRpY2F0ZWQtdXNlciJ9.signature")
      "Cognito ID token changed"
  | Error message -> T.fail "valid Cognito response was rejected: %s" message
;;

let cognito_response_rejects_challenges_and_malformed_tokens () =
  require_error
    "Cognito challenge"
    (S.cognito_session_of_response
       {|{"ChallengeName":"NEW_PASSWORD_REQUIRED","Session":"secret"}|});
  require_error
    "malformed ID token"
    (S.cognito_session_of_response {|{"AuthenticationResult":{"IdToken":"not-a-jwt"}}|});
  require_error
    "missing subject"
    (S.cognito_session_of_response
       {|{"AuthenticationResult":{"IdToken":"header.e30.signature"}}|})
;;

let graph id name encrypted =
  Logseq_db_types.Managed_graph.
    { graph_id = Logseq_db_types.Graph_types.Uuid.of_string id |> Result.get_ok
    ; name
    ; schema = { major = 65; minor = 33; exact = true }
    ; encrypted
    }
;;

let catalog_requires_exactly_one_named_encrypted_graph () =
  let target = graph "60000000-0000-4000-8000-000000000001" "Target graph" true in
  let unrelated = graph "60000000-0000-4000-8000-000000000002" "Unrelated graph" true in
  (match S.named_encrypted_graph ~name:"Target graph" [ unrelated; target ] with
   | Ok selected ->
     T.require
       (Logseq_db_types.Graph_types.Uuid.equal selected.graph_id target.graph_id)
       "named encrypted graph selection changed the graph"
   | Error message -> T.fail "valid named graph was rejected: %s" message);
  require_error "empty catalog" (S.named_encrypted_graph ~name:"Target graph" []);
  require_error
    "missing named graph"
    (S.named_encrypted_graph ~name:"Target graph" [ unrelated ]);
  require_error
    "case-mismatched graph"
    (S.named_encrypted_graph
       ~name:"Target graph"
       [ graph "60000000-0000-4000-8000-000000000003" "target graph" true ]);
  require_error
    "named unencrypted graph"
    (S.named_encrypted_graph
       ~name:"Target graph"
       [ graph "60000000-0000-4000-8000-000000000004" "Target graph" false ]);
  require_error
    "duplicate named graph"
    (S.named_encrypted_graph
       ~name:"Target graph"
       [ target; graph "60000000-0000-4000-8000-000000000005" "Target graph" true ])
;;

let catalog_selection_waits_for_remote_catalog () =
  match S.catalog_graph ~name:"Target graph" [] with
  | Ok None -> ()
  | Ok (Some _) -> T.fail "empty catalog unexpectedly selected a graph"
  | Error message ->
    T.fail "empty catalog was rejected before remote discovery: %s" message
;;

let () =
  T.run
    "managed sync deployed e2e support"
    [ T.case
        "credentials reject invalid environment"
        credentials_reject_invalid_environment
    ; T.case
        "credentials accept bounded environment"
        credentials_accept_bounded_environment
    ; T.case
        "Cognito response yields token and subject"
        cognito_response_yields_token_and_subject
    ; T.case
        "Cognito response rejects challenges and malformed tokens"
        cognito_response_rejects_challenges_and_malformed_tokens
    ; T.case
        "catalog requires exactly one named encrypted graph"
        catalog_requires_exactly_one_named_encrypted_graph
    ; T.case
        "catalog selection waits for remote catalog"
        catalog_selection_waits_for_remote_catalog
    ]
;;
