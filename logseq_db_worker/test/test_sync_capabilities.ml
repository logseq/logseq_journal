module T = Logseq_db_worker_test_support.Test_support
module Phase = Sync_startup_phase
module Action = Sync_action

let scope ?(graph_id = "10000000-0000-4000-8000-000000000001") permit_id =
  let account =
    Phase.account_scope
      ~managed_sync_origin:(Uri.of_string "https://api.logseq.io")
      ~user_id:"user-1"
      ~account_generation:3
      ~presentation_generation:5
      ~permit_id
    |> Option.get
  in
  Phase.graph_scope account ~graph_id ~graph_generation:7 |> Option.get
;;

let account_scope permit_id =
  Phase.account_scope
    ~managed_sync_origin:(Uri.of_string "https://api.logseq.io")
    ~user_id:"user-1"
    ~account_generation:3
    ~presentation_generation:5
    ~permit_id
  |> Option.get
;;

let graph graph_id =
  Action.
    { graph_id
    ; name = "Encrypted"
    ; schema_major = 65
    ; schema_minor = 33
    ; schema_exact = true
    ; encrypted = true
    }
;;

let test_stale_timeline_ack_cannot_mint_a_permit () =
  let restoring = scope 11L |> Phase.begin_restore in
  let stale =
    Phase.acknowledge_timeline
      restoring
      { account_generation = 3; graph_generation = 7; presentation_generation = 4 }
  in
  T.require (stale = None) "stale Timeline acknowledgement produced a witness";
  let presented =
    Phase.acknowledge_timeline
      restoring
      { account_generation = 3; graph_generation = 7; presentation_generation = 5 }
  in
  T.require (Option.is_some presented) "current Timeline acknowledgement was rejected"
;;

let test_recovery_receipts_are_scope_sealed_and_one_shot () =
  let restoring = scope 12L |> Phase.begin_restore in
  let other =
    scope ~graph_id:"10000000-0000-4000-8000-000000000002" 13L
    |> Phase.begin_restore
  in
  let receipt =
    Phase.request_wrapped_graph_key restoring
    |> Phase.Local_completion.wrapped_graph_key_failed ~diagnostic:"cache miss"
  in
  T.require
    (Phase.recover other receipt = None)
    "a failure receipt authorized another restore scope";
  let recovery = Phase.recover restoring receipt |> Option.get in
  T.require
    (Phase.recover restoring receipt = None)
    "a consumed failure receipt minted a second recovery ticket";
  T.require
    (Phase.recovery_reason recovery = Wrapped_graph_key_unavailable)
    "recovery lost the local failure reason";
  ignore (Phase.permit_recovery recovery |> Result.get_ok);
  T.require
    (Phase.permit_recovery recovery = Error `Already_consumed)
    "a recovery ticket was reusable"
;;

let test_account_recovery_is_one_shot_and_authorizes_catalog_only () =
  let recovery = account_scope 17L |> Phase.begin_account_recovery in
  let permit = Phase.permit_account_recovery recovery |> Result.get_ok in
  T.require
    (Result.is_ok (Action.fetch_catalog permit ~token:"token"))
    "account recovery could not authorize catalog discovery";
  T.require
    (Phase.permit_account_recovery recovery = Error `Already_consumed)
    "an account recovery ticket was reusable"
;;

let test_actions_require_matching_scopes_and_valid_payloads () =
  let restoring = scope 14L |> Phase.begin_restore in
  let request = Phase.request_graph_open restoring in
  let matching = graph "10000000-0000-4000-8000-000000000001" in
  let mismatched = graph "10000000-0000-4000-8000-000000000002" in
  T.require
    (Result.is_ok (Action.open_graph request matching ~encrypted_graph_key:None))
    "matching local graph action was rejected";
  T.require
    (Action.open_graph request mismatched ~encrypted_graph_key:None = Error `Scope_mismatch)
    "mismatched local graph action was constructible";
  T.require
    (Action.wrapped_graph_key_of_string {|["~#'","~bYWJj"]|} |> Option.is_some)
    "valid wrapped ciphertext was rejected";
  T.require
    (Action.wrapped_graph_key_of_string "plaintext" = None)
    "arbitrary plaintext was accepted as a wrapped graph key"
;;

let test_connection_permit_requires_the_presented_graph_scope () =
  let graph_scope = scope 15L in
  let restoring = Phase.begin_restore graph_scope in
  let presented =
    Phase.acknowledge_timeline
      restoring
      { account_generation = 3; graph_generation = 7; presentation_generation = 5 }
    |> Option.get
  in
  let permit = Phase.permit_reconciliation presented in
  let connection =
    Phase.connection_scope graph_scope ~connection_generation:9 ~lifecycle_generation:2L
    |> Option.get
  in
  let connection_permit = Phase.connection_permit permit connection |> Option.get in
  T.require
    (Result.is_ok (Action.connect_websocket connection_permit ~token:"token"))
    "presented graph permit could not authorize its connection";
  let other_connection =
    Phase.connection_scope
      (scope ~graph_id:"10000000-0000-4000-8000-000000000002" 16L)
      ~connection_generation:9
      ~lifecycle_generation:2L
    |> Option.get
  in
  T.require
    (Phase.connection_permit permit other_connection = None)
    "a graph permit authorized another connection scope"
;;

let () =
  test_stale_timeline_ack_cannot_mint_a_permit ();
  test_recovery_receipts_are_scope_sealed_and_one_shot ();
  test_account_recovery_is_one_shot_and_authorizes_catalog_only ();
  test_actions_require_matching_scopes_and_valid_payloads ();
  test_connection_permit_requires_the_presented_graph_scope ()
;;
