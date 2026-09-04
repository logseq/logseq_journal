module Core = Logseq_sync_pure_reducer.Core

type observed =
  { state : Core.state
  ; admitted_graph_scope : Core.graph_scope option
  }

let observe core =
  { state = Core.state core; admitted_graph_scope = Core.admitted_graph_scope core }
;;

let check_observed test_id message expected actual =
  Alcotest.(check bool) (test_id ^ " " ^ message) true (expected = actual)
;;

let check_instructions test_id expected actual =
  Alcotest.(check bool)
    (test_id ^ " ordered instructions")
    true
    (Core.equal_instructions expected actual)
;;

let preview_step test_id origin event =
  let origin_observed = observe origin in
  let transition = Core.step origin event in
  check_observed test_id "preview preserves origin" origin_observed (observe origin);
  transition
;;

let check_replay test_id origin event (first : Core.transition) =
  let origin_observed = observe origin in
  check_observed test_id "origin remains immutable" origin_observed (observe origin);
  let replay = Core.step origin event in
  check_observed test_id "replay observation" (observe first.next) (observe replay.next);
  check_instructions test_id first.effects replay.effects;
  first
;;

let check_step test_id origin event expected effects =
  let origin_observed = observe origin in
  let first = Core.step origin event in
  check_observed test_id "public observation" expected (observe first.next);
  check_instructions test_id effects first.effects;
  check_observed test_id "origin remains immutable" origin_observed (observe origin);
  check_replay test_id origin event first
;;

let limits () =
  Core.limits
    ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
    ~maximum_artifact_bytes:(1024 * 1024)
    ~submission_batch_size:32
  |> Result.get_ok
;;

let initial () =
  Core.config
    ~managed_sync_origin:(Uri.of_string "https://api.logseq.io")
    ~limits:(limits ())
  |> Result.get_ok
  |> Core.initial
  |> Result.get_ok
;;

let token_request effects =
  List.find_map
    (function
      | Core.Publish (Core.Token_requested request) -> Some request
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> Option.get
;;

let graph_id =
  Logseq_db_types.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111"
  |> Result.get_ok
;;

let graph : Core.graph =
  { graph_id
  ; name = "Journal"
  ; schema = { major = 1; minor = 0; exact = true }
  ; encrypted = false
  }
;;

let encrypted_graph = { graph with encrypted = true }

let selected_graph selected_graph =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let catalog_token = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Core.Token_provided (catalog_token, "catalog-token"))
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authorized.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ selected_graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authorized.effects
    |> Option.get
  in
  let selected = Core.step catalog.next (Core.Graph_selected selected_graph.graph_id) in
  selected, Core.admitted_graph_scope selected.next |> Option.get
;;

let warm_encrypted_graph_loads_key_before_attach_and_protects_outbox () =
  let selected, scope = selected_graph encrypted_graph in
  let mirror = Core.{ graph = encrypted_graph; scope } in
  let inspected =
    Core.step selected.next (Core.Mirror_inspected (Mirror_available mirror))
  in
  let key = Core.graph_key_handle ~id:"warm-graph-key" ~scope in
  let key_request =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key requested_scope))
          ->
          Some
            ( requested_scope
            , Core.step
                inspected.next
                (Core.Runner_completed (Core.Completion (ticket, Ok key))) )
        | Run _ | Delegate _ | Publish _ -> None)
      inspected.effects
  in
  Alcotest.(check bool)
    "encrypted warm mirror requests its cached key"
    true
    (Option.is_some key_request);
  Alcotest.(check bool)
    "encrypted warm mirror is not attached before key recovery"
    false
    (List.exists
       (function
         | Core.Delegate (Core.Attach_graph _) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       inspected.effects);
  match key_request with
  | None -> ()
  | Some (requested_scope, unlocked) ->
    Alcotest.(check bool)
      "cached-key request retains the selected scope"
      true
      (requested_scope = scope);
    let attached_request =
      List.find_map
        (function
          | Core.Delegate (Core.Attach_graph request) -> Some request
          | Run _ | Delegate _ | Publish _ -> None)
        unlocked.effects
    in
    Alcotest.(check bool)
      "warm mirror attaches after cached-key recovery"
      true
      (Option.is_some attached_request);
    (match attached_request with
     | None -> ()
     | Some request ->
       Alcotest.(check bool)
         "attachment retains selected scope"
         true
         (request.scope = scope));
    let sync_token =
      Logseq_overlay_db.Types.sync_token_of_string "sync-token:v1:warm" |> Result.get_ok
    in
    let checkpoint =
      Logseq_overlay_db.Types.Server_cursor.of_string "server-cursor:v1:0"
      |> Result.get_ok
    in
    let sync =
      Logseq_overlay_db.Types.sync_view ~token:sync_token ~checkpoint ~submissions:[]
    in
    let attached = Core.step unlocked.next (Core.Graph_attached { scope; sync }) in
    let websocket_token = token_request attached.effects in
    let connecting =
      Core.step attached.next (Core.Token_provided (websocket_token, "websocket-token"))
    in
    let connection =
      List.find_map
        (function
          | Core.Run (Core.Start_websocket request) -> Some request.scope
          | Run _ | Delegate _ | Publish _ -> None)
        connecting.effects
      |> Option.get
    in
    let opened = Core.step connecting.next (Core.Websocket_opened connection) in
    let mutation_id =
      Logseq_db_types.Graph_types.Uuid.of_string "22222222-2222-4222-8222-222222222220"
      |> Result.get_ok
    in
    let fingerprint =
      Logseq_overlay_db.Types.Mutation_fingerprint.of_string
        "mutation-fingerprint:v1:warm"
      |> Result.get_ok
    in
    let pending : Logseq_overlay_db.Types.submission_descriptor =
      { mutation_id
      ; fingerprint
      ; state = Logseq_overlay_db.Types.Queued
      ; dependency_eligible = true
      ; attempt_count = 0
      ; plaintext_bytes = 16
      ; protected_bytes = None
      }
    in
    let pending_sync =
      Logseq_overlay_db.Types.sync_view
        ~token:sync_token
        ~checkpoint
        ~submissions:[ pending ]
    in
    let changed = Core.step opened.next Core.Local_outbox_changed in
    let inspection_scope =
      List.find_map
        (function
          | Core.Delegate (Core.Inspect_sync requested_scope) -> Some requested_scope
          | Run _ | Delegate _ | Publish _ -> None)
        changed.effects
      |> Option.get
    in
    let planned =
      Core.step
        changed.next
        (Core.Sync_inspected { scope = inspection_scope; sync = pending_sync })
    in
    let transition_key =
      List.find_map
        (function
          | Core.Delegate (Core.Apply_outbox_transition request) -> request.key
          | Run _ | Delegate _ | Publish _ -> None)
        planned.effects
    in
    Alcotest.(check (option string))
      "outbox protection retains the recovered key"
      (Some "warm-graph-key")
      (Option.map Core.graph_key_handle_id transition_key)
;;

let graph_picker_clears_terminal_graph_failure () =
  let selected, scope = selected_graph encrypted_graph in
  let missing =
    Core.step selected.next (Core.Mirror_inspected (Core.Mirror_absent scope))
  in
  let failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
          Some
            (Core.step
               missing.next
               (Core.Runner_completed
                  (Core.Completion
                     (ticket, Error (Core.Effect_failed "cached key unavailable")))))
        | Run _ | Delegate _ | Publish _ -> None)
      missing.effects
    |> Option.get
  in
  let picker = Core.step failed.next Core.Graph_picker_requested in
  let snapshot = (Core.state picker.next).snapshot in
  Alcotest.(check bool)
    "graph picker clears the terminal failure"
    true
    (snapshot.startup.awaiting_selection
     && snapshot.startup.failure = None
     && snapshot.last_error = None
     && snapshot.sync_phase = Core.Offline
     && snapshot.selected_graph = None)
;;

let graph_picker_fences_late_warm_key_completion () =
  let selected, scope = selected_graph encrypted_graph in
  let mirror = Core.{ graph = encrypted_graph; scope } in
  let inspected =
    Core.step selected.next (Core.Mirror_inspected (Mirror_available mirror))
  in
  let key_completion =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
          let picker = Core.step inspected.next Core.Graph_picker_requested in
          let key = Core.graph_key_handle ~id:"stale-warm-key" ~scope in
          Some
            (Core.step
               picker.next
               (Core.Runner_completed (Core.Completion (ticket, Ok key))))
        | Run _ | Delegate _ | Publish _ -> None)
      inspected.effects
  in
  Alcotest.(check bool)
    "warm encrypted mirror has a pending key request"
    true
    (Option.is_some key_completion);
  match key_completion with
  | None -> ()
  | Some completed ->
    Alcotest.(check int)
      "late key completion emits no graph or token work"
      0
      (List.length completed.effects)
;;

let warm_encrypted_graph_online_recovery_attaches_existing_mirror () =
  let selected, scope = selected_graph encrypted_graph in
  let mirror = Core.{ graph = encrypted_graph; scope } in
  let inspected =
    Core.step selected.next (Core.Mirror_inspected (Mirror_available mirror))
  in
  let failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
          Some
            (Core.step
               inspected.next
               (Core.Runner_completed
                  (Core.Completion
                     (ticket, Error (Core.Effect_failed "cached key unavailable")))))
        | Run _ | Delegate _ | Publish _ -> None)
      inspected.effects
    |> Option.get
  in
  let recovery = Core.step failed.next Core.Online_recovery_requested in
  let recovery_token = token_request recovery.effects in
  let graph_key_fetch =
    Core.step recovery.next (Core.Token_provided (recovery_token, "e2ee-token"))
  in
  let user_key_fetch =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_graph_key _)) ->
          Some
            (Core.step
               graph_key_fetch.next
               (Core.Runner_completed (Core.Completion (ticket, Ok "encrypted-graph-key"))))
        | Run _ | Delegate _ | Publish _ -> None)
      graph_key_fetch.effects
    |> Option.get
  in
  let password_prompt =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_user_keys _)) ->
          Some
            (Core.step
               user_key_fetch.next
               (Core.Runner_completed (Core.Completion (ticket, Ok "private-key-package"))))
        | Run _ | Delegate _ | Publish _ -> None)
      user_key_fetch.effects
    |> Option.get
  in
  let private_key_unlock =
    Core.step password_prompt.next (Core.E2ee_password_submitted "password")
  in
  let graph_key_unlock =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Unlock_private_key _)) ->
          Some
            (Core.step
               private_key_unlock.next
               (Core.Runner_completed (Core.Completion (ticket, Ok ()))))
        | Run _ | Delegate _ | Publish _ -> None)
      private_key_unlock.effects
    |> Option.get
  in
  let recovered =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_and_unlock_graph_key request)) ->
          let key =
            Core.graph_key_handle ~id:"online-warm-key" ~scope:request.scope.graph
          in
          Some
            (Core.step
               graph_key_unlock.next
               (Core.Runner_completed (Core.Completion (ticket, Ok key))))
        | Run _ | Delegate _ | Publish _ -> None)
      graph_key_unlock.effects
    |> Option.get
  in
  Alcotest.(check bool)
    "online key recovery attaches the existing mirror"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Attach_graph request) -> request.scope = scope
         | Run _ | Delegate _ | Publish _ -> false)
       recovered.effects);
  Alcotest.(check bool)
    "online warm recovery does not replace the existing mirror"
    false
    (List.exists
       (function
         | Core.Publish (Core.Token_requested request) ->
           Core.token_request_purpose request = Core.Snapshot_bootstrap
         | Run _ | Delegate _ | Publish _ -> false)
       recovered.effects)
;;

let encrypted_graph_recovery_fetches_and_unlocks_key_before_bootstrap () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let catalog_token = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Core.Token_provided (catalog_token, "catalog-token"))
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authorized.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ encrypted_graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authorized.effects
    |> Option.get
  in
  let selected = Core.step catalog.next (Core.Graph_selected graph_id) in
  let scope = Core.admitted_graph_scope selected.next |> Option.get in
  let missing =
    Core.step selected.next (Core.Mirror_inspected (Core.Mirror_absent scope))
  in
  let failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
          Some
            (Core.step
               missing.next
               (Core.Runner_completed
                  (Core.Completion (ticket, Error (Core.Effect_failed "missing key")))))
        | Run _ | Delegate _ | Publish _ -> None)
      missing.effects
    |> Option.get
  in
  let recovery = Core.step failed.next Core.Online_recovery_requested in
  let recovery_token = token_request recovery.effects in
  let graph_key_fetch =
    Core.step recovery.next (Core.Token_provided (recovery_token, "e2ee-token"))
  in
  let user_key_fetch =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_graph_key _)) ->
          Some
            (Core.step
               graph_key_fetch.next
               (Core.Runner_completed (Core.Completion (ticket, Ok "encrypted-graph-key"))))
        | Run _ | Delegate _ | Publish _ -> None)
      graph_key_fetch.effects
    |> Option.get
  in
  let password_prompt =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_user_keys _)) ->
          Some
            (Core.step
               user_key_fetch.next
               (Core.Runner_completed (Core.Completion (ticket, Ok "private-key-package"))))
        | Run _ | Delegate _ | Publish _ -> None)
      user_key_fetch.effects
    |> Option.get
  in
  Alcotest.(check bool)
    "private key package prompts for the E2EE password"
    true
    (Core.state password_prompt.next).snapshot.startup.awaiting_e2ee_password;
  let private_key_unlock =
    Core.step password_prompt.next (Core.E2ee_password_submitted "password")
  in
  let graph_key_unlock =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Unlock_private_key request)) ->
          Alcotest.(check string) "password is forwarded once" "password" request.password;
          Alcotest.(check string)
            "private key package is forwarded"
            "private-key-package"
            request.private_key_package;
          Some
            (Core.step
               private_key_unlock.next
               (Core.Runner_completed (Core.Completion (ticket, Ok ()))))
        | Run _ | Delegate _ | Publish _ -> None)
      private_key_unlock.effects
    |> Option.get
  in
  let bootstrapping =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_and_unlock_graph_key request)) ->
          Alcotest.(check string)
            "encrypted graph key is forwarded"
            "encrypted-graph-key"
            request.encrypted_graph_key;
          let handle = Core.graph_key_handle ~id:"graph-key" ~scope:request.scope.graph in
          Some
            (Core.step
               graph_key_unlock.next
               (Core.Runner_completed (Core.Completion (ticket, Ok handle))))
        | Run _ | Delegate _ | Publish _ -> None)
      graph_key_unlock.effects
    |> Option.get
  in
  let bootstrap_token = token_request bootstrapping.effects in
  Alcotest.(check bool)
    "unlocked graph key resumes snapshot bootstrap"
    true
    (Core.token_request_purpose bootstrap_token = Core.Snapshot_bootstrap)
;;

let begin_snapshot_bootstrap () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let catalog_token = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Core.Token_provided (catalog_token, "catalog-token"))
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authorized.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authorized.effects
    |> Option.get
  in
  let selected = Core.step catalog.next (Core.Graph_selected graph_id) in
  let scope =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_mirror request) -> Some request.scope
        | Run _ | Delegate _ | Publish _ -> None)
      selected.effects
    |> Option.get
  in
  let missing =
    Core.step selected.next (Core.Mirror_inspected (Core.Mirror_absent scope))
  in
  let snapshot_token = token_request missing.effects in
  let requested =
    Core.step missing.next (Core.Token_provided (snapshot_token, "snapshot-token"))
  in
  requested, scope
;;

let snapshot_bootstrap_preserves_server_cursor () =
  let requested, scope = begin_snapshot_bootstrap () in
  let metadata =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_baseline _)) ->
          Some
            (Core.step
               requested.next
               (Core.Runner_completed
                  (Core.Completion (ticket, Ok {|{"type":"pull/ok","t":42}|}))))
        | Run _ | Delegate _ | Publish _ -> None)
      requested.effects
    |> Option.get
  in
  let download =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
          Some
            (Core.step
               metadata.next
               (Core.Runner_completed
                  (Core.Completion
                     ( ticket
                     , Ok {|{"ok":true,"url":"https://example.com/snapshot.sqlite"}|} ))))
        | Run _ | Delegate _ | Publish _ -> None)
      metadata.effects
    |> Option.get
  in
  let activated =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Download_snapshot request)) ->
          Alcotest.(check int)
            "download retains configured bound"
            (1024 * 1024)
            request.maximum_bytes;
          let artifact =
            Core.staged_artifact
              ~id:"snapshot"
              ~scope
              ~path:"/tmp/snapshot.sqlite"
              ~expected_rows:10
          in
          Some
            (Core.step
               download.next
               (Core.Runner_completed (Core.Completion (ticket, Ok artifact))))
        | Run _ | Delegate _ | Publish _ -> None)
      download.effects
    |> Option.get
  in
  let activation =
    List.find_map
      (function
        | Core.Delegate (Core.Activate_snapshot request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      activated.effects
    |> Option.get
  in
  Alcotest.(check int) "activation uses baseline cursor" 42 activation.applied_server_t;
  Alcotest.(check bool)
    "plain snapshot has no graph key"
    true
    (Option.is_none activation.key)
;;

let invalid_snapshot_baseline_fails_bootstrap () =
  let requested, _scope = begin_snapshot_bootstrap () in
  let failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_baseline _)) ->
          Some
            (Core.step
               requested.next
               (Core.Runner_completed
                  (Core.Completion (ticket, Ok {|{"type":"pull/ok","t":-1}|}))))
        | Run _ | Delegate _ | Publish _ -> None)
      requested.effects
    |> Option.get
  in
  let snapshot = (Core.state failed.next).snapshot in
  Alcotest.(check bool)
    "invalid baseline enters failed state"
    true
    (snapshot.sync_phase = Core.Failed
     && snapshot.startup.failure = Some Core.During_bootstrap)
;;

module Overlay = Logseq_overlay_db.Types
module Protocol = Logseq_sync_pure_reducer.Sync_protocol

let token module_of_string value = module_of_string value |> Result.get_ok

let mutation_ids =
  [ "22222222-2222-4222-8222-222222222221"
  ; "22222222-2222-4222-8222-222222222222"
  ; "22222222-2222-4222-8222-222222222223"
  ]
  |> List.map (fun value ->
    Logseq_db_types.Graph_types.Uuid.of_string value |> Result.get_ok)
;;

let submitted_core () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let catalog_token = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Core.Token_provided (catalog_token, "catalog-token"))
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authorized.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authorized.effects
    |> Option.get
  in
  let selected = Core.step catalog.next (Core.Graph_selected graph_id) in
  let mirror_request =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_mirror request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      selected.effects
    |> Option.get
  in
  let inspected =
    Core.step selected.next (Core.Mirror_inspected (Core.Mirror_available mirror_request))
  in
  let attach_request =
    List.find_map
      (function
        | Core.Delegate (Core.Attach_graph request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      inspected.effects
    |> Option.get
  in
  let scope = attach_request.scope in
  let sync_token = Overlay.sync_token_of_string "sync-token:v1:1" |> Result.get_ok in
  let checkpoint =
    Overlay.Server_cursor.of_string "server-cursor:v1:0" |> Result.get_ok
  in
  let sync = Overlay.sync_view ~token:sync_token ~checkpoint ~submissions:[] in
  let attached = Core.step inspected.next (Core.Graph_attached { scope; sync }) in
  let websocket_token = token_request attached.effects in
  let connecting =
    Core.step attached.next (Core.Token_provided (websocket_token, "websocket-token"))
  in
  let connection =
    List.find_map
      (function
        | Core.Run (Core.Start_websocket request) -> Some request.scope
        | Run _ | Delegate _ | Publish _ -> None)
      connecting.effects
    |> Option.get
  in
  let opened = Core.step connecting.next (Core.Websocket_opened connection) in
  let batch_id =
    Overlay.Submission_batch_id.of_string "submission-batch:v1:test" |> Result.get_ok
  in
  let wires =
    List.map
      (fun mutation_id ->
         Overlay.submission_wire
           ~maximum_bytes:1024
           ~mutation_id
           ~operation:Overlay.Save_block_operation
           ~protected_transaction:"protected"
         |> Result.get_ok)
      mutation_ids
  in
  let batch =
    Overlay.submission_batch
      ~maximum_wires:3
      ~maximum_bytes:4096
      ~batch_id
      ~t_before:checkpoint
      ~wires
    |> Result.get_ok
  in
  let queued_submissions =
    List.map2
      (fun mutation_id wire ->
         { Overlay.mutation_id
         ; fingerprint =
             Overlay.Mutation_fingerprint.of_string
               ("mutation-fingerprint:v1:"
                ^ Logseq_db_types.Graph_types.Uuid.to_string mutation_id)
             |> Result.get_ok
         ; state = Overlay.Queued
         ; dependency_eligible = true
         ; attempt_count = 0
         ; plaintext_bytes = 16
         ; protected_bytes = Some (Overlay.submission_wire_byte_length wire)
         })
      mutation_ids
      wires
  in
  let queued_sync =
    Overlay.sync_view ~token:sync_token ~checkpoint ~submissions:queued_submissions
  in
  let inspect = Core.step opened.next Core.Local_outbox_changed in
  let inspected_scope =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_sync requested_scope) -> Some requested_scope
        | Run _ | Delegate _ | Publish _ -> None)
      inspect.effects
    |> Option.get
  in
  let planned =
    Core.step
      inspect.next
      (Core.Sync_inspected { scope = inspected_scope; sync = queued_sync })
  in
  let transition_request =
    List.find_map
      (function
        | Core.Delegate (Core.Apply_outbox_transition request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      planned.effects
    |> Option.get
  in
  let generation = Overlay.Generation.of_string "generation:v1:1" |> Result.get_ok in
  let projection =
    Overlay.Projection_revision.of_string "projection:v1:1" |> Result.get_ok
  in
  let commit : Overlay.outbox_commit =
    { generation
    ; before_projection_revision = projection
    ; after_projection_revision = projection
    ; sync_token
    ; transition = transition_request.transition
    ; activity = Overlay.Logically_active
    ; logical_change_summary = Overlay.No_logical_change
    ; submission_batch = Some batch
    }
  in
  let submitted =
    Core.step
      planned.next
      (Core.Outbox_transition_applied { scope = transition_request.scope; commit; sync })
  in
  submitted.next, connection
;;

let rejection_transition effects =
  List.find_map
    (function
      | Core.Delegate
          (Core.Apply_outbox_transition
             { transition = Overlay.Reject_group { resolution; _ }; _ }) ->
        Some resolution
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> Option.get
;;

let partial_rejection_is_normalized_exactly () =
  let core, connection = submitted_core () in
  let first, second, third =
    match mutation_ids with
    | [ first; second; third ] -> first, second, third
    | _ -> assert false
  in
  let detail_suffix =
    [ "cannot"
    ; "store"
    ; "value"
    ; "as"
    ; "expected"
    ; "uuid"
    ; "type"
    ; "block"
    ; "order"
    ; "should"
    ; "be"
    ; "a"
    ; "valid"
    ; "fractional"
    ; "index"
    ; "invalid"
    ; "type"
    ]
  in
  let repeated_prefix = List.init 80 (fun _ -> "data") in
  let rejection : Logseq_sync_pure_reducer.Sync_protocol.rejection =
    { reason = Db_transact_failed
    ; t = Some 1
    ; checksum = Some "0123456789abcdef"
    ; success_tx_ids = [ first ]
    ; failed_tx_id = Some second
    ; missing_block_uuids = [ graph_id ]
    ; error_detail = Some (String.concat " " (repeated_prefix @ detail_suffix))
    ; data = None
    }
  in
  let rejected =
    Core.step
      core
      (Core.Websocket_message
         (connection, Logseq_sync_pure_reducer.Sync_protocol.Server.Tx_reject rejection))
  in
  Alcotest.(check bool)
    "rejection reason is retained in sanitized diagnostics"
    true
    (let retained_prefix = List.init (64 - List.length detail_suffix) (fun _ -> "data") in
     let expected =
       "tx-reject:db-transact-failed:missing-dependencies:detail-"
       ^ String.concat "-" (retained_prefix @ detail_suffix)
     in
     List.mem expected (Core.state rejected.next).diagnostics.history);
  match rejection_transition rejected.effects with
  | Overlay.Definitive { reason = Missing_dependencies; partition } ->
    Alcotest.(check bool)
      "accepted prefix retained"
      true
      (partition.accepted_prefix = [ first ]);
    Alcotest.(check bool)
      "failed member retained"
      true
      (partition.failed_member = Some second);
    Alcotest.(check bool) "suffix inferred" true (partition.unexecuted_suffix = [ third ]);
    Alcotest.(check bool)
      "prefix barrier required"
      true
      (Option.is_some partition.acceptance_barrier)
  | _ -> Alcotest.fail "partial rejection was not normalized as missing dependencies"
;;

let local_outbox_change_requests_sync_inspection () =
  let core, _connection = submitted_core () in
  let transition = Core.step core Core.Local_outbox_changed in
  Alcotest.(check bool)
    "local outbox change delegates one fresh sync inspection"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Inspect_sync _) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       transition.effects)
;;

let accepted_submission_pulls_its_authoritative_transaction () =
  let core, connection = submitted_core () in
  let acknowledged =
    Core.step
      core
      (Core.Websocket_message
         ( connection
         , Logseq_sync_pure_reducer.Sync_protocol.Server.Tx_batch_ok
             { t = 1; checksum = Some "0123456789abcdef" } ))
  in
  let request =
    List.find_map
      (function
        | Core.Delegate
            (Core.Apply_outbox_transition
               ({ transition = Overlay.Accept_group _; _ } as request)) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      acknowledged.effects
    |> Option.get
  in
  let sync_token = Overlay.sync_token_of_string "sync-token:v1:2" |> Result.get_ok in
  let checkpoint =
    Overlay.Server_cursor.of_string "server-cursor:v1:0" |> Result.get_ok
  in
  let sync = Overlay.sync_view ~token:sync_token ~checkpoint ~submissions:[] in
  let generation = Overlay.Generation.of_string "generation:v1:2" |> Result.get_ok in
  let projection =
    Overlay.Projection_revision.of_string "projection:v1:1" |> Result.get_ok
  in
  let commit : Overlay.outbox_commit =
    { generation
    ; before_projection_revision = projection
    ; after_projection_revision = projection
    ; sync_token
    ; transition = request.transition
    ; activity = Overlay.Logically_inactive
    ; logical_change_summary = Overlay.No_logical_change
    ; submission_batch = None
    }
  in
  let completed =
    Core.step
      acknowledged.next
      (Core.Outbox_transition_applied { scope = request.scope; commit; sync })
  in
  Alcotest.(check bool)
    "accepted submission pulls from the durable cursor"
    true
    (List.exists
       (function
         | Core.Run
             (Core.Send_websocket
                { message = Logseq_sync_pure_reducer.Sync_protocol.Client.Pull { since }
                ; _
                }) -> since = Some 0
         | Run _ | Delegate _ | Publish _ -> false)
       completed.effects)
;;

let whole_batch_invalid_tx_partitions_every_member () =
  let core, connection = submitted_core () in
  let rejection : Logseq_sync_pure_reducer.Sync_protocol.rejection =
    { reason = Invalid_tx
    ; t = None
    ; checksum = None
    ; success_tx_ids = []
    ; failed_tx_id = None
    ; missing_block_uuids = []
    ; error_detail = None
    ; data = None
    }
  in
  let rejected =
    Core.step
      core
      (Core.Websocket_message
         (connection, Logseq_sync_pure_reducer.Sync_protocol.Server.Tx_reject rejection))
  in
  match rejection_transition rejected.effects, mutation_ids with
  | ( Overlay.Definitive
        { reason = Invalid_request
        ; partition =
            { accepted_prefix = []; failed_member = Some failed; unexecuted_suffix; _ }
        }
    , expected_failed :: expected_suffix ) ->
    Alcotest.(check bool)
      "first member failed"
      true
      (Logseq_db_types.Graph_types.Uuid.equal failed expected_failed);
    Alcotest.(check bool)
      "remaining members are unexecuted"
      true
      (unexecuted_suffix = expected_suffix)
  | _ -> Alcotest.fail "invalid tx did not produce a complete batch partition"
;;

let canonical_overlay_happy_path () =
  let origin = initial () in
  let initial_state = Core.state origin in
  let authenticated_startup =
    { initial_state.snapshot.startup with
      authenticated = true
    ; catalog_loading = true
    ; account_generation = 1
    ; presentation_generation = 1
    }
  in
  let authenticated_state =
    { initial_state with
      snapshot = { initial_state.snapshot with startup = authenticated_startup }
    }
  in
  let authenticated_observed =
    { state = authenticated_state; admitted_graph_scope = None }
  in
  let hp01_event = Core.Account_authenticated { user_id = Some "user" } in
  let hp01_preview = preview_step "HP01" origin hp01_event in
  let catalog_token =
    match hp01_preview.effects with
    | [ Core.Publish (Core.State_changed state)
      ; Core.Publish (Core.Token_requested request)
      ]
      when state = authenticated_state
           && Core.token_request_purpose request = Core.Catalog_discovery -> request
    | _ -> Alcotest.fail "HP01 unexpected instruction shape"
  in
  let hp01 =
    check_step
      "HP01"
      origin
      hp01_event
      authenticated_observed
      [ Core.Publish (Core.State_changed authenticated_state)
      ; Core.Publish (Core.Token_requested catalog_token)
      ]
  in
  let account_scope : Core.account_scope =
    { managed_sync_origin = Uri.of_string "https://api.logseq.io"
    ; user_id = "user"
    ; account_generation = 1
    ; presentation_generation = 1
    ; lifecycle_generation = 0L
    }
  in
  let authorized_scope : Core.authenticated_account_scope =
    { account = account_scope; token = "catalog-token" }
  in
  let hp02_event = Core.Token_provided (catalog_token, "catalog-token") in
  let hp02_preview = preview_step "HP02" hp01.next hp02_event in
  let catalog_ticket : Core.graph list Core.effect_ticket =
    match hp02_preview.effects with
    | [ Core.Run (Core.Request (ticket, Core.Fetch_catalog scope)) ]
      when scope = authorized_scope -> ticket
    | _ -> Alcotest.fail "HP02 unexpected instruction shape"
  in
  let hp02 =
    check_step
      "HP02"
      hp01.next
      hp02_event
      authenticated_observed
      [ Core.Run (Core.Request (catalog_ticket, Core.Fetch_catalog authorized_scope)) ]
  in
  let catalogued_startup =
    { authenticated_startup with catalog_loading = false; awaiting_selection = true }
  in
  let catalogued_state =
    { authenticated_state with
      snapshot =
        { authenticated_state.snapshot with
          catalog = [ graph ]
        ; startup = catalogued_startup
        }
    }
  in
  let catalogued_observed = { state = catalogued_state; admitted_graph_scope = None } in
  let hp03_event =
    Core.Runner_completed (Core.Completion (catalog_ticket, Ok [ graph ]))
  in
  let hp03_preview = preview_step "HP03" hp02.next hp03_event in
  let save_catalog_effect =
    match hp03_preview.effects with
    | [ Core.Publish (Core.State_changed state)
      ; Core.Run (Core.Request (ticket, Core.Save_catalog { account; cache }))
      ]
      when state = catalogued_state
           && account = account_scope
           && Core.catalog_cache_user_id cache = "user"
           && Core.catalog_cache_graphs cache = [ graph ]
           && Core.catalog_cache_selected_graph cache = None ->
      Core.Run
        (Core.Request (ticket, Core.Save_catalog { account = account_scope; cache }))
    | _ -> Alcotest.fail "HP03 unexpected instruction shape"
  in
  let hp03 =
    check_step
      "HP03"
      hp02.next
      hp03_event
      catalogued_observed
      [ Core.Publish (Core.State_changed catalogued_state); save_catalog_effect ]
  in
  let graph_scope : Core.graph_scope =
    { account = account_scope; graph_id; graph_generation = 1 }
  in
  let selected_startup =
    { catalogued_startup with
      awaiting_selection = false
    ; restoring_local = true
    ; graph_generation = 1
    }
  in
  let selected_state =
    { catalogued_state with
      snapshot =
        { catalogued_state.snapshot with
          selected_graph = Some graph_id
        ; startup = selected_startup
        }
    }
  in
  let selected_observed =
    { state = selected_state; admitted_graph_scope = Some graph_scope }
  in
  let hp04_event = Core.Graph_selected graph_id in
  let hp04_preview = preview_step "HP04" hp03.next hp04_event in
  let mirror_request, selected_save_effect =
    match hp04_preview.effects with
    | [ Core.Delegate (Core.Inspect_mirror request)
      ; Core.Publish (Core.State_changed state)
      ; Core.Run (Core.Request (ticket, Core.Save_catalog { account; cache }))
      ]
      when (request = Core.{ graph; scope = graph_scope })
           && state = selected_state
           && account = account_scope
           && Core.catalog_cache_user_id cache = "user"
           && Core.catalog_cache_graphs cache = [ graph ]
           && Core.catalog_cache_selected_graph cache = Some graph_id ->
      ( request
      , Core.Run
          (Core.Request (ticket, Core.Save_catalog { account = account_scope; cache })) )
    | _ -> Alcotest.fail "HP04 unexpected instruction shape"
  in
  let hp04 =
    check_step
      "HP04"
      hp03.next
      hp04_event
      selected_observed
      [ Core.Delegate (Core.Inspect_mirror mirror_request)
      ; Core.Publish (Core.State_changed selected_state)
      ; selected_save_effect
      ]
  in
  let hp05_event = Core.Mirror_inspected (Core.Mirror_available mirror_request) in
  let hp05 =
    check_step
      "HP05"
      hp04.next
      hp05_event
      selected_observed
      [ Core.Delegate (Core.Attach_graph mirror_request) ]
  in
  let cursor0 = token Overlay.Server_cursor.of_string "server-cursor:v1:0" in
  let sync_token0 = token Overlay.sync_token_of_string "sync-token:v1:hp-0" in
  let empty_sync0 =
    Overlay.sync_view ~token:sync_token0 ~checkpoint:cursor0 ~submissions:[]
  in
  let attached_startup =
    { selected_startup with restoring_local = false; bootstrapping = false }
  in
  let attached_state =
    { selected_state with
      snapshot =
        { selected_state.snapshot with
          sync_phase = Core.Current
        ; applied_server_t = Some 0
        ; timeline_presentation_pending = true
        ; startup = attached_startup
        }
    }
  in
  let attached_observed =
    { state = attached_state; admitted_graph_scope = Some graph_scope }
  in
  let hp06_event =
    Core.Graph_attached { scope = mirror_request.scope; sync = empty_sync0 }
  in
  let hp06_preview = preview_step "HP06" hp05.next hp06_event in
  let websocket_token =
    match hp06_preview.effects with
    | [ Core.Publish (Core.State_changed state)
      ; Core.Publish (Core.Token_requested request)
      ]
      when state = attached_state
           && Core.token_request_purpose request = Core.Websocket_connect -> request
    | _ -> Alcotest.fail "HP06 unexpected instruction shape"
  in
  let hp06 =
    check_step
      "HP06"
      hp05.next
      hp06_event
      attached_observed
      [ Core.Publish (Core.State_changed attached_state)
      ; Core.Publish (Core.Token_requested websocket_token)
      ]
  in
  let connecting_state =
    { attached_state with
      snapshot = { attached_state.snapshot with sync_phase = Core.Connecting }
    }
  in
  let connecting_observed =
    { state = connecting_state; admitted_graph_scope = Some graph_scope }
  in
  let connection : Core.connection_scope =
    { graph = graph_scope; connection_generation = 1 }
  in
  let websocket_request : Core.websocket_request =
    { scope = connection
    ; uri = Uri.of_string "wss://api.logseq.io/sync/11111111-1111-4111-8111-111111111111"
    ; token = "websocket-token"
    }
  in
  let hp07_event = Core.Token_provided (websocket_token, "websocket-token") in
  let hp07 =
    check_step
      "HP07"
      hp06.next
      hp07_event
      connecting_observed
      [ Core.Publish (Core.State_changed connecting_state)
      ; Core.Run (Core.Start_websocket websocket_request)
      ]
  in
  let pulling0_state =
    { connecting_state with
      snapshot = { connecting_state.snapshot with sync_phase = Core.Pulling }
    }
  in
  let pulling0_observed =
    { state = pulling0_state; admitted_graph_scope = Some graph_scope }
  in
  let pull0 =
    Core.Run
      (Core.Send_websocket
         { scope = connection; message = Protocol.Client.Pull { since = Some 0 } })
  in
  let hp08_event = Core.Websocket_opened connection in
  let hp08 =
    check_step
      "HP08"
      hp07.next
      hp08_event
      pulling0_observed
      [ Core.Publish (Core.State_changed pulling0_state); pull0 ]
  in
  let remote_tx : Protocol.Server.pull_transaction =
    { t = 1; tx = "[]"; outliner_op = Some "save-block" }
  in
  let opening_message =
    Protocol.Server.Pull_ok
      { t = 1; checksum = Some "0123456789abcdef"; txs = [ remote_tx ] }
  in
  let hp09_event = Core.Websocket_message (connection, opening_message) in
  let hp09_preview = preview_step "HP09" hp08.next hp09_event in
  let opening_batch =
    match hp09_preview.effects with
    | [ Core.Delegate (Core.Apply_authoritative_batch request) ]
      when request.scope = connection
           && request.presentation_generation = 1
           && request.lifecycle_generation = 0L
           && request.key = None
           && Overlay.Server_cursor.to_string
                (Overlay.authoritative_batch_through request.input)
              = "server-cursor:v1:1"
           && List.length (Overlay.authoritative_batch_transactions request.input) = 1 ->
      request
    | _ -> Alcotest.fail "HP09 unexpected instruction shape"
  in
  let hp09 =
    check_step
      "HP09"
      hp08.next
      hp09_event
      pulling0_observed
      [ Core.Delegate (Core.Apply_authoritative_batch opening_batch) ]
  in
  let generation1 = token Overlay.Generation.of_string "generation:v1:hp-1" in
  let projection1 = token Overlay.Projection_revision.of_string "projection:v1:1" in
  let cursor1 = token Overlay.Server_cursor.of_string "server-cursor:v1:1" in
  let sync_token1 = token Overlay.sync_token_of_string "sync-token:v1:hp-1" in
  let sync1 = Overlay.sync_view ~token:sync_token1 ~checkpoint:cursor1 ~submissions:[] in
  let authoritative_commit1 : Overlay.authoritative_commit =
    { generation = generation1
    ; before_projection_revision = projection1
    ; after_projection_revision = projection1
    ; checkpoint = cursor1
    ; sync_token = sync_token1
    ; terminal_receipts = []
    ; replanned_queued_ids = []
    ; blocked_ids = []
    ; logical_change_summary = Overlay.No_logical_change
    }
  in
  let current1_state =
    { pulling0_state with
      snapshot =
        { pulling0_state.snapshot with
          sync_phase = Core.Current
        ; applied_server_t = Some 1
        }
    }
  in
  let current1_observed =
    { state = current1_state; admitted_graph_scope = Some graph_scope }
  in
  let hp10_event =
    Core.Authoritative_batch_applied
      { scope = opening_batch.scope.graph; commit = authoritative_commit1; sync = sync1 }
  in
  let hp10 =
    check_step
      "HP10"
      hp09.next
      hp10_event
      current1_observed
      [ Core.Publish (Core.State_changed current1_state) ]
  in
  let hp11_event = Core.Local_outbox_changed in
  let hp11 =
    check_step
      "HP11"
      hp10.next
      hp11_event
      current1_observed
      [ Core.Delegate (Core.Inspect_sync graph_scope) ]
  in
  let mutation_id = List.hd mutation_ids in
  let fingerprint =
    token Overlay.Mutation_fingerprint.of_string "mutation-fingerprint:v1:hp"
  in
  let queued : Overlay.submission_descriptor =
    { mutation_id
    ; fingerprint
    ; state = Overlay.Queued
    ; dependency_eligible = true
    ; attempt_count = 0
    ; plaintext_bytes = 16
    ; protected_bytes = Some 16
    }
  in
  let queued_sync =
    Overlay.sync_view ~token:sync_token1 ~checkpoint:cursor1 ~submissions:[ queued ]
  in
  let submitting_state =
    { current1_state with
      snapshot = { current1_state.snapshot with sync_phase = Core.Submitting }
    }
  in
  let submitting_observed =
    { state = submitting_state; admitted_graph_scope = Some graph_scope }
  in
  let hp12_event = Core.Sync_inspected { scope = graph_scope; sync = queued_sync } in
  let hp12_preview = preview_step "HP12" hp11.next hp12_event in
  let submit_request =
    match hp12_preview.effects with
    | [ Core.Publish (Core.State_changed state)
      ; Core.Delegate (Core.Apply_outbox_transition request)
      ]
      when state = submitting_state
           && request.scope = graph_scope
           && request.key = None
           && Overlay.sync_token_equal request.expected sync_token1
           && request.transition = Overlay.Submit_group [ mutation_id ] -> request
    | _ -> Alcotest.fail "HP12 unexpected instruction shape"
  in
  let hp12 =
    check_step
      "HP12"
      hp11.next
      hp12_event
      submitting_observed
      [ Core.Publish (Core.State_changed submitting_state)
      ; Core.Delegate (Core.Apply_outbox_transition submit_request)
      ]
  in
  let batch_id = token Overlay.Submission_batch_id.of_string "submission-batch:v1:hp" in
  let wire =
    Overlay.submission_wire
      ~maximum_bytes:1024
      ~mutation_id
      ~operation:Overlay.Save_block_operation
      ~protected_transaction:"protected-hp-transaction"
    |> Result.get_ok
  in
  let submission_batch =
    Overlay.submission_batch
      ~maximum_wires:1
      ~maximum_bytes:4096
      ~batch_id
      ~t_before:cursor1
      ~wires:[ wire ]
    |> Result.get_ok
  in
  let sync_token2 = token Overlay.sync_token_of_string "sync-token:v1:hp-2" in
  let submitted_descriptor = { queued with state = Overlay.Submitted batch_id } in
  let submitted_sync =
    Overlay.sync_view
      ~token:sync_token2
      ~checkpoint:cursor1
      ~submissions:[ submitted_descriptor ]
  in
  let submit_commit : Overlay.outbox_commit =
    { generation = generation1
    ; before_projection_revision = projection1
    ; after_projection_revision = projection1
    ; sync_token = sync_token2
    ; transition = submit_request.transition
    ; activity = Overlay.Logically_active
    ; logical_change_summary = Overlay.No_logical_change
    ; submission_batch = Some submission_batch
    }
  in
  let tx_message =
    Protocol.Client.Tx_batch
      { client_revision = Some (Overlay.Submission_batch_id.to_string batch_id)
      ; t_before = 1
      ; txs =
          [ { Protocol.Client.tx = "protected-hp-transaction"
            ; tx_id = Some mutation_id
            ; outliner_op = Some "save-block"
            }
          ]
      }
  in
  let hp13_event =
    Core.Outbox_transition_applied
      { scope = submit_request.scope; commit = submit_commit; sync = submitted_sync }
  in
  let hp13 =
    check_step
      "HP13"
      hp12.next
      hp13_event
      submitting_observed
      [ Core.Run (Core.Send_websocket { scope = connection; message = tx_message }) ]
  in
  let hp14_event =
    Core.Websocket_message
      ( connection
      , Protocol.Server.Tx_batch_ok { t = 2; checksum = Some "fedcba9876543210" } )
  in
  let hp14_preview = preview_step "HP14" hp13.next hp14_event in
  let accept_request =
    match hp14_preview.effects with
    | [ Core.Delegate (Core.Apply_outbox_transition request) ]
      when request.scope = graph_scope
           && request.key = None
           && Overlay.sync_token_equal request.expected sync_token2
           && request.transition
              = Overlay.Accept_group
                  { batch_id
                  ; barrier =
                      { through =
                          token Overlay.Server_cursor.of_string "server-cursor:v1:2"
                      ; checksum =
                          token Overlay.Checksum.of_string "checksum:v1:fedcba9876543210"
                      }
                  } -> request
    | _ -> Alcotest.fail "HP14 unexpected instruction shape"
  in
  let hp14 =
    check_step
      "HP14"
      hp13.next
      hp14_event
      submitting_observed
      [ Core.Delegate (Core.Apply_outbox_transition accept_request) ]
  in
  let sync_token3 = token Overlay.sync_token_of_string "sync-token:v1:hp-3" in
  let accepted_descriptor =
    { queued with state = Overlay.Accepted_pending_authoritative batch_id }
  in
  let accepted_sync =
    Overlay.sync_view
      ~token:sync_token3
      ~checkpoint:cursor1
      ~submissions:[ accepted_descriptor ]
  in
  let accept_commit : Overlay.outbox_commit =
    { generation = generation1
    ; before_projection_revision = projection1
    ; after_projection_revision = projection1
    ; sync_token = sync_token3
    ; transition = accept_request.transition
    ; activity = Overlay.Logically_active
    ; logical_change_summary = Overlay.No_logical_change
    ; submission_batch = None
    }
  in
  let pulling1_state =
    { submitting_state with
      snapshot = { submitting_state.snapshot with sync_phase = Core.Pulling }
    }
  in
  let pulling1_observed =
    { state = pulling1_state; admitted_graph_scope = Some graph_scope }
  in
  let hp15_event =
    Core.Outbox_transition_applied
      { scope = accept_request.scope; commit = accept_commit; sync = accepted_sync }
  in
  let hp15 =
    check_step
      "HP15"
      hp14.next
      hp15_event
      pulling1_observed
      [ Core.Publish (Core.State_changed pulling1_state)
      ; Core.Run
          (Core.Send_websocket
             { scope = connection; message = Protocol.Client.Pull { since = Some 1 } })
      ]
  in
  let incorporated_tx : Protocol.Server.pull_transaction =
    { t = 2; tx = "[]"; outliner_op = Some "save-block" }
  in
  let confirmation_message =
    Protocol.Server.Pull_ok
      { t = 2; checksum = Some "fedcba9876543210"; txs = [ incorporated_tx ] }
  in
  let hp16_event = Core.Websocket_message (connection, confirmation_message) in
  let hp16_preview = preview_step "HP16" hp15.next hp16_event in
  let confirmation_batch =
    match hp16_preview.effects with
    | [ Core.Delegate (Core.Apply_authoritative_batch request) ]
      when request.scope = connection
           && request.presentation_generation = 1
           && request.lifecycle_generation = 0L
           && request.key = None
           && Overlay.Server_cursor.to_string
                (Overlay.authoritative_batch_through request.input)
              = "server-cursor:v1:2"
           && List.length (Overlay.authoritative_batch_transactions request.input) = 1 ->
      request
    | _ -> Alcotest.fail "HP16 unexpected instruction shape"
  in
  let hp16 =
    check_step
      "HP16"
      hp15.next
      hp16_event
      pulling1_observed
      [ Core.Delegate (Core.Apply_authoritative_batch confirmation_batch) ]
  in
  let cursor2 = token Overlay.Server_cursor.of_string "server-cursor:v1:2" in
  let sync_token4 = token Overlay.sync_token_of_string "sync-token:v1:hp-4" in
  let sync2 = Overlay.sync_view ~token:sync_token4 ~checkpoint:cursor2 ~submissions:[] in
  let authoritative_commit2 : Overlay.authoritative_commit =
    { generation = generation1
    ; before_projection_revision = projection1
    ; after_projection_revision = projection1
    ; checkpoint = cursor2
    ; sync_token = sync_token4
    ; terminal_receipts = []
    ; replanned_queued_ids = []
    ; blocked_ids = []
    ; logical_change_summary = Overlay.No_logical_change
    }
  in
  let current2_state =
    { pulling1_state with
      snapshot =
        { pulling1_state.snapshot with
          sync_phase = Core.Current
        ; applied_server_t = Some 2
        }
    }
  in
  let current2_observed =
    { state = current2_state; admitted_graph_scope = Some graph_scope }
  in
  let hp17_event =
    Core.Authoritative_batch_applied
      { scope = confirmation_batch.scope.graph
      ; commit = authoritative_commit2
      ; sync = sync2
      }
  in
  ignore
    (check_step
       "HP17"
       hp16.next
       hp17_event
       current2_observed
       [ Core.Publish (Core.State_changed current2_state) ])
;;

let config_is_bounded () =
  Alcotest.check
    Alcotest.bool
    "zero response bound is rejected"
    true
    (Result.is_error
       (Core.limits
          ~maximum_response_bytes:0
          ~maximum_artifact_bytes:1
          ~submission_batch_size:1))
;;

let authentication_delegates_catalog_transport () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let request = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Core.Token_provided (request, "token"))
  in
  let requested =
    List.exists
      (function
        | Core.Run (Core.Request (_, Core.Fetch_catalog _)) -> true
        | Run _ | Delegate _ | Publish _ -> false)
      authorized.effects
  in
  Alcotest.check Alcotest.bool "catalog request is transport-owned" true requested
;;

let websocket_connect_uses_deployed_graph_path () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let catalog_token = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Core.Token_provided (catalog_token, "catalog-token"))
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authorized.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authorized.effects
    |> Option.get
  in
  let selected = Core.step catalog.next (Core.Graph_selected graph_id) in
  let mirror_request =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_mirror request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      selected.effects
    |> Option.get
  in
  let inspected =
    Core.step selected.next (Core.Mirror_inspected (Core.Mirror_available mirror_request))
  in
  let attach_request =
    List.find_map
      (function
        | Core.Delegate (Core.Attach_graph request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      inspected.effects
    |> Option.get
  in
  let scope = attach_request.scope in
  let sync_token = Overlay.sync_token_of_string "sync-token:v1:1" |> Result.get_ok in
  let checkpoint =
    Overlay.Server_cursor.of_string "server-cursor:v1:0" |> Result.get_ok
  in
  let sync = Overlay.sync_view ~token:sync_token ~checkpoint ~submissions:[] in
  let attached = Core.step inspected.next (Core.Graph_attached { scope; sync }) in
  let websocket_token = token_request attached.effects in
  let connecting =
    Core.step attached.next (Core.Token_provided (websocket_token, "websocket-token"))
  in
  let uri =
    List.find_map
      (function
        | Core.Run (Core.Start_websocket request) -> Some request.uri
        | Run _ | Delegate _ | Publish _ -> None)
      connecting.effects
    |> Option.get
  in
  Alcotest.(check string)
    "deployed WebSocket endpoint"
    ("wss://api.logseq.io/sync/" ^ Logseq_db_types.Graph_types.Uuid.to_string graph_id)
    (Uri.to_string uri)
;;

let stale_token_is_ignored () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let request = token_request authenticated.effects in
  let rejected = Core.step authenticated.next (Core.Token_rejected request) in
  let replay = Core.step rejected.next (Core.Token_rejected request) in
  Alcotest.check
    Alcotest.int
    "replayed token emits nothing"
    0
    (List.length replay.effects)
;;

let authenticated_fetch user_id
  : Core.transition * Core.graph list Core.effect_ticket * Core.account_scope
  =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some user_id })
  in
  let request = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Core.Token_provided (request, "token"))
  in
  match authorized.effects with
  | [ Core.Run (Core.Request (ticket, Core.Fetch_catalog account)) ] ->
    authorized, ticket, account.account
  | _ -> Alcotest.fail "authentication did not issue one catalog request"
;;

let account_deletion_completion signed_out (result : (unit, Core.effect_error) result) =
  List.find_map
    (function
      | Core.Run (Core.Request (ticket, Core.Delete_account_secrets account)) ->
        Some (Core.Runner_completed (Core.Completion (ticket, result)), account)
      | Run _ | Delegate _ | Publish _ -> None)
    signed_out.Core.effects
  |> Option.get
;;

let sign_out_captures_identity_advances_generations_and_fences_old_work () =
  let authorized, catalog_ticket, old_account = authenticated_fetch "old-user" in
  let before = Core.state authorized.next in
  let signed_out =
    Core.step authorized.next (Core.Account_authenticated { user_id = None })
  in
  let after = Core.state signed_out.next in
  Alcotest.(check bool)
    "account generation advances"
    true
    (after.snapshot.startup.account_generation
     = before.snapshot.startup.account_generation + 1);
  Alcotest.(check bool)
    "presentation generation advances"
    true
    (after.snapshot.startup.presentation_generation
     = before.snapshot.startup.presentation_generation + 1);
  Alcotest.(check bool)
    "authentication is cleared"
    false
    after.snapshot.startup.authenticated;
  (match signed_out.effects with
   | [ Core.Run (Core.Cancel_effects cancelled)
     ; Core.Delegate (Core.Reset_managed_account reset)
     ; Core.Run (Core.Request (_, Core.Delete_account_secrets deleted))
     ; Core.Publish (Core.State_changed published)
     ] ->
     Alcotest.(check bool)
       "old account work is cancelled before cleanup"
       true
       (cancelled = Core.effect_scope_of_account old_account);
     Alcotest.(check bool) "worker reset captures old account" true (reset = old_account);
     Alcotest.(check bool) "cleanup captures old account" true (deleted = old_account);
     Alcotest.(check bool) "signed-out state is published" true (published = after)
   | _ -> Alcotest.fail "sign-out effects were missing or incorrectly ordered");
  let late_catalog =
    Core.step
      signed_out.next
      (Core.Runner_completed (Core.Completion (catalog_ticket, Ok [ graph ])))
  in
  Alcotest.(check int)
    "old catalog completion is inert"
    0
    (List.length late_catalog.effects);
  Alcotest.(check bool)
    "old catalog completion cannot restore state"
    true
    (Core.state late_catalog.next = after)
;;

let sign_out_cleanup_completion_is_inert_and_sanitized () =
  let authorized, _, _ = authenticated_fetch "old-user" in
  let signed_out =
    Core.step authorized.next (Core.Account_authenticated { user_id = None })
  in
  let success, _ = account_deletion_completion signed_out (Ok ()) in
  let succeeded = Core.step signed_out.next success in
  Alcotest.(check int)
    "successful cleanup publishes nothing"
    0
    (List.length succeeded.effects);
  Alcotest.(check bool)
    "successful cleanup leaves public state unchanged"
    true
    (Core.state succeeded.next = Core.state signed_out.next);
  let signed_out_again =
    Core.step authorized.next (Core.Account_authenticated { user_id = None })
  in
  let failure, _ =
    account_deletion_completion
      signed_out_again
      (Error (Core.Effect_failed "service=secret key=private"))
  in
  let failed = Core.step signed_out_again.next failure in
  let failed_state = Core.state failed.next in
  Alcotest.(check (option string))
    "cleanup failure is sanitized"
    (Some "account secret cleanup failed")
    failed_state.snapshot.last_error;
  Alcotest.(check bool)
    "cleanup failure does not restore authentication"
    false
    failed_state.snapshot.startup.authenticated;
  let replacement =
    Core.step
      signed_out_again.next
      (Core.Account_authenticated { user_id = Some "new-user" })
  in
  let late_failure = Core.step replacement.next failure in
  Alcotest.(check int)
    "old cleanup failure publishes nothing for replacement account"
    0
    (List.length late_failure.effects);
  Alcotest.(check bool)
    "old cleanup failure cannot fail replacement account"
    true
    (Core.state late_failure.next = Core.state replacement.next)
;;

let local_cache_deletion_uses_authenticated_account_and_requested_graph () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let requested_graph =
    Logseq_db_types.Graph_types.Uuid.of_string "33333333-3333-4333-8333-333333333333"
    |> Result.get_ok
  in
  let deletion =
    Core.step authenticated.next (Core.Local_cache_deletion_requested requested_graph)
  in
  let success =
    match deletion.effects with
    | [ Core.Delegate (Core.Delete_mirror mirror)
      ; Core.Run
          (Core.Request
             (ticket, Core.Delete_wrapped_graph_key { account; graph_id = deleted_graph }))
      ] ->
      Alcotest.(check bool)
        "mirror uses requested graph"
        true
        (mirror.graph_id = requested_graph);
      Alcotest.(check bool)
        "wrapped-key cleanup uses requested graph"
        true
        (deleted_graph = requested_graph);
      Alcotest.(check string) "cleanup captures authenticated user" "user" account.user_id;
      Core.Runner_completed (Core.Completion (ticket, Ok ()))
    | _ -> Alcotest.fail "local-cache deletion did not issue both cleanup operations"
  in
  let succeeded = Core.step deletion.next success in
  Alcotest.(check int)
    "successful graph-key cleanup is state-inert"
    0
    (List.length succeeded.effects);
  let deletion_again =
    Core.step authenticated.next (Core.Local_cache_deletion_requested requested_graph)
  in
  let failure =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Delete_wrapped_graph_key _)) ->
          Some
            (Core.Runner_completed
               (Core.Completion
                  (ticket, Error (Core.Effect_failed "keychain item secret bytes"))))
        | Run _ | Delegate _ | Publish _ -> None)
      deletion_again.effects
    |> Option.get
  in
  let failed = Core.step deletion_again.next failure in
  Alcotest.(check (option string))
    "graph cleanup failure is sanitized"
    (Some "wrapped graph key cleanup failed")
    (Core.state failed.next).snapshot.last_error;
  Alcotest.(check bool)
    "graph cleanup failure keeps authentication"
    true
    (Core.state failed.next).snapshot.startup.authenticated;
  let anonymous =
    Core.step (initial ()) (Core.Local_cache_deletion_requested requested_graph)
  in
  match anonymous.effects with
  | [ Core.Delegate (Core.Delete_mirror mirror) ] ->
    Alcotest.(check bool)
      "anonymous mirror deletion uses requested graph"
      true
      (mirror.graph_id = requested_graph)
  | _ -> Alcotest.fail "anonymous deletion invented a Keychain identity"
;;

let scenarios =
  [ Alcotest.test_case
      "pure reducer canonical overlay happy path"
      `Quick
      canonical_overlay_happy_path
  ; Pure_reducer_bad_case_01.scenario
  ; Pure_reducer_bad_case_02.scenario
  ; Pure_reducer_bad_case_03.scenario
  ; Pure_reducer_bad_case_04.scenario
  ; Pure_reducer_bad_case_05.scenario
  ; Pure_reducer_bad_case_06.scenario
  ; Pure_reducer_bad_case_07.scenario
  ; Pure_reducer_bad_case_08.scenario
  ; Pure_reducer_bad_case_09.scenario
  ; Pure_reducer_bad_case_10.scenario
  ; Alcotest.test_case "config is bounded" `Quick config_is_bounded
  ; Alcotest.test_case
      "authentication delegates catalog transport"
      `Quick
      authentication_delegates_catalog_transport
  ; Alcotest.test_case
      "websocket connect uses the deployed graph path"
      `Quick
      websocket_connect_uses_deployed_graph_path
  ; Alcotest.test_case "stale token is ignored" `Quick stale_token_is_ignored
  ; Alcotest.test_case
      "sign-out captures identity and fences old work"
      `Quick
      sign_out_captures_identity_advances_generations_and_fences_old_work
  ; Alcotest.test_case
      "sign-out cleanup completion is inert and sanitized"
      `Quick
      sign_out_cleanup_completion_is_inert_and_sanitized
  ; Alcotest.test_case
      "local cache deletion cleans the requested graph key"
      `Quick
      local_cache_deletion_uses_authenticated_account_and_requested_graph
  ; Alcotest.test_case
      "snapshot bootstrap preserves server cursor"
      `Quick
      snapshot_bootstrap_preserves_server_cursor
  ; Alcotest.test_case
      "invalid snapshot baseline fails bootstrap"
      `Quick
      invalid_snapshot_baseline_fails_bootstrap
  ; Alcotest.test_case
      "encrypted recovery unlocks graph key before bootstrap"
      `Quick
      encrypted_graph_recovery_fetches_and_unlocks_key_before_bootstrap
  ; Alcotest.test_case
      "warm encrypted graph loads key before attach and protects outbox"
      `Quick
      warm_encrypted_graph_loads_key_before_attach_and_protects_outbox
  ; Alcotest.test_case
      "graph picker clears terminal graph failure"
      `Quick
      graph_picker_clears_terminal_graph_failure
  ; Alcotest.test_case
      "graph picker fences late warm key completion"
      `Quick
      graph_picker_fences_late_warm_key_completion
  ; Alcotest.test_case
      "warm encrypted graph online recovery attaches existing mirror"
      `Quick
      warm_encrypted_graph_online_recovery_attaches_existing_mirror
  ; Alcotest.test_case
      "partial rejection is normalized exactly"
      `Quick
      partial_rejection_is_normalized_exactly
  ; Alcotest.test_case
      "local outbox change requests sync inspection"
      `Quick
      local_outbox_change_requests_sync_inspection
  ; Alcotest.test_case
      "accepted submission pulls its authoritative transaction"
      `Quick
      accepted_submission_pulls_its_authoritative_transaction
  ; Alcotest.test_case
      "whole-batch invalid tx partitions every member"
      `Quick
      whole_batch_invalid_tx_partitions_every_member
  ]
;;
