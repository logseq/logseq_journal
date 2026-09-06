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
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authenticated.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ selected_graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authenticated.effects
    |> Option.get
  in
  let selected = Core.step catalog.next (Core.Graph_selected selected_graph.graph_id) in
  selected, Core.admitted_graph_scope selected.next |> Option.get
;;

let other_graph_id =
  Logseq_db_types.Graph_types.Uuid.of_string "99999999-9999-4999-8999-999999999999"
  |> Result.get_ok
;;

let other_graph : Core.graph =
  { graph_id = other_graph_id
  ; name = "Other Journal"
  ; schema = { major = 1; minor = 0; exact = true }
  ; encrypted = false
  }
;;

let save_catalog_cache effects =
  List.find_map
    (function
      | Core.Run (Core.Request (_, Core.Save_catalog { cache; _ })) -> Some cache
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> Option.get
;;

let load_catalog_completion effects (cache : Core.catalog_cache option) =
  List.find_map
    (function
      | Core.Run (Core.Request (ticket, Core.Load_catalog _)) ->
        Some (Core.Runner_completed (Core.Completion (ticket, Ok cache)))
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> Option.get
;;

let fetch_catalog_completion effects (graphs : Core.graph list) =
  List.find_map
    (function
      | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
        Some (Core.Runner_completed (Core.Completion (ticket, Ok graphs)))
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> Option.get
;;

let inspect_mirror_request effects =
  List.find_map
    (function
      | Core.Delegate (Core.Inspect_mirror request) -> Some request
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> Option.get
;;

let has_graph_open_work effects =
  List.exists
    (function
      | Core.Delegate (Core.Inspect_mirror _)
      | Core.Delegate (Core.Attach_graph _)
      | Core.Delegate (Core.Activate_snapshot _) -> true
      | Run _ | Delegate _ | Publish _ -> false)
    effects
;;

let has_catalog_request effects =
  List.exists
    (function
      | Core.Run (Core.Request (_, Core.Fetch_catalog _)) -> true
      | Run _ | Delegate _ | Publish _ -> false)
    effects
;;

let refresh_catalog core graphs =
  let requested = Core.step core Core.Catalog_refresh_requested in
  Core.step requested.next (fetch_catalog_completion requested.effects graphs)
;;

let selected_graph_survives_picker_and_codec_restart () =
  let selected, _ = selected_graph graph in
  let persisted =
    save_catalog_cache selected.effects
    |> Core.encode_catalog_cache
    |> Core.decode_catalog_cache
    |> Result.get_ok
  in
  let picker = Core.step selected.next Core.Graph_picker_requested in
  let picker_snapshot = (Core.state picker.next).snapshot in
  Alcotest.(check bool)
    "picker clears only the current process selection"
    true
    (picker_snapshot.selected_graph = None && picker_snapshot.startup.awaiting_selection);
  Alcotest.(check bool)
    "picker does not overwrite the durable selection"
    false
    (List.exists
       (function
         | Core.Run (Core.Request (_, Core.Save_catalog _)) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       picker.effects);
  let restoring =
    Core.step (initial ()) (Core.Restore_local_account { user_id = "user" })
  in
  let generation_before = (Core.state restoring.next).snapshot.startup.graph_generation in
  let restored =
    Core.step restoring.next (load_catalog_completion restoring.effects (Some persisted))
  in
  let snapshot = (Core.state restored.next).snapshot in
  Alcotest.(check bool)
    "warm launch restores the cached selected graph"
    true
    (Option.equal
       Logseq_db_types.Graph_types.Uuid.equal
       snapshot.selected_graph
       (Some graph_id));
  Alcotest.(check bool)
    "warm launch bypasses graph selection with a fresh generation"
    true
    ((not snapshot.startup.awaiting_selection)
     && snapshot.startup.graph_generation > generation_before);
  let request = inspect_mirror_request restored.effects in
  Alcotest.(check bool)
    "warm launch inspects the admitted cached graph"
    true
    (Logseq_db_types.Graph_types.Uuid.equal request.graph.graph_id graph_id
     && request.scope.graph_generation = snapshot.startup.graph_generation);
  Alcotest.(check bool)
    "cache loading does not rewrite the cache"
    false
    (List.exists
       (function
         | Core.Run (Core.Request (_, Core.Save_catalog _)) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       restored.effects)
;;

let invalid_cached_selections_fail_closed () =
  let check label cache =
    let restoring =
      Core.step (initial ()) (Core.Restore_local_account { user_id = "user" })
    in
    let restored =
      Core.step restoring.next (load_catalog_completion restoring.effects (Some cache))
    in
    let snapshot = (Core.state restored.next).snapshot in
    Alcotest.(check bool)
      (label ^ " awaits graph selection")
      true
      (snapshot.startup.awaiting_selection && snapshot.selected_graph = None);
    Alcotest.(check bool)
      (label ^ " starts no graph work")
      false
      (has_graph_open_work restored.effects)
  in
  check
    "absent cached selection"
    (Core.catalog_cache ~user_id:"user" ~graphs:[ graph ] ~selected_graph:None);
  check
    "stale cached selection"
    (Core.catalog_cache
       ~user_id:"user"
       ~graphs:[ graph ]
       ~selected_graph:(Some other_graph_id));
  check
    "different-account cached selection"
    (Core.catalog_cache
       ~user_id:"other-user"
       ~graphs:[ graph ]
       ~selected_graph:(Some graph_id))
;;

let same_account_authentication_preserves_pending_warm_restore () =
  let selected, _ = selected_graph graph in
  let cache = save_catalog_cache selected.effects in
  let restoring =
    Core.step (initial ()) (Core.Restore_local_account { user_id = "user" })
  in
  let reconciled =
    Core.step restoring.next (Core.Account_authenticated { user_id = Some "user" })
  in
  Alcotest.(check bool)
    "same-account authentication waits for local cache admission"
    false
    (has_catalog_request reconciled.effects);
  let restored =
    Core.step reconciled.next (load_catalog_completion restoring.effects (Some cache))
  in
  let snapshot = (Core.state restored.next).snapshot in
  Alcotest.(check bool)
    "pending warm restore survives same-account authentication"
    true
    (snapshot.startup.authenticated
     && (not snapshot.startup.awaiting_selection)
     && Option.equal
          Logseq_db_types.Graph_types.Uuid.equal
          snapshot.selected_graph
          (Some graph_id));
  ignore (inspect_mirror_request restored.effects);
  Alcotest.(check bool)
    "remote reconciliation begins only after local admission"
    true
    (has_catalog_request restored.effects)
;;

let catalog_refresh_preserves_or_revokes_selection () =
  let selected, _ = selected_graph graph in
  let before = (Core.state selected.next).snapshot in
  let preserved = refresh_catalog selected.next [ graph; other_graph ] in
  let preserved_snapshot = (Core.state preserved.next).snapshot in
  Alcotest.(check bool)
    "refresh preserves an admitted selected graph"
    true
    (Option.equal
       Logseq_db_types.Graph_types.Uuid.equal
       preserved_snapshot.selected_graph
       (Some graph_id)
     && (not preserved_snapshot.startup.awaiting_selection)
     && preserved_snapshot.startup.graph_generation = before.startup.graph_generation);
  Alcotest.(check bool)
    "refresh persists the admitted selection"
    true
    (Option.equal
       Logseq_db_types.Graph_types.Uuid.equal
       (Core.catalog_cache_selected_graph (save_catalog_cache preserved.effects))
       (Some graph_id));
  let selected, _ = selected_graph graph in
  let before = (Core.state selected.next).snapshot in
  let revoked = refresh_catalog selected.next [ other_graph ] in
  let revoked_snapshot = (Core.state revoked.next).snapshot in
  Alcotest.(check bool)
    "refresh clears and fences a removed selection"
    true
    (revoked_snapshot.selected_graph = None
     && revoked_snapshot.startup.awaiting_selection
     && revoked_snapshot.startup.graph_generation > before.startup.graph_generation);
  Alcotest.(check bool)
    "refresh detaches the removed graph"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Detach_graph _) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       revoked.effects);
  Alcotest.(check bool)
    "refresh starts no work for the removed graph"
    false
    (has_graph_open_work revoked.effects);
  Alcotest.(check (option string))
    "refresh persists no removed selection"
    None
    (Core.catalog_cache_selected_graph (save_catalog_cache revoked.effects)
     |> Option.map Logseq_db_types.Graph_types.Uuid.to_string)
;;

let catalog_save_failure_keeps_selected_graph_usable () =
  let selected, scope = selected_graph graph in
  let failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Save_catalog _)) ->
          Some
            (Core.step
               selected.next
               (Core.Runner_completed
                  (Core.Completion (ticket, Error (Core.Effect_failed "disk unavailable")))))
        | Run _ | Delegate _ | Publish _ -> None)
      selected.effects
    |> Option.get
  in
  Alcotest.(check bool)
    "advisory cache save failure preserves selection"
    true
    (Core.state failed.next = Core.state selected.next);
  let inspected =
    Core.step failed.next (Core.Mirror_inspected (Core.Mirror_available { graph; scope }))
  in
  Alcotest.(check bool)
    "mirror opening continues after cache save failure"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Attach_graph request) -> request.scope = scope
         | Run _ | Delegate _ | Publish _ -> false)
       inspected.effects)
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
    let connection =
      List.find_map
        (function
          | Core.Run (Core.Start_websocket request) -> Some request.scope
          | Run _ | Delegate _ | Publish _ -> None)
        attached.effects
      |> Option.get
    in
    let opened = Core.step attached.next (Core.Websocket_opened connection) in
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
  let user_key_fetch =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_graph_key _)) ->
          Some
            (Core.step
               recovery.next
               (Core.Runner_completed (Core.Completion (ticket, Ok "encrypted-graph-key"))))
        | Run _ | Delegate _ | Publish _ -> None)
      recovery.effects
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
          let key = Core.graph_key_handle ~id:"online-warm-key" ~scope:request.scope in
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
         | Core.Run (Core.Request (_, Core.Fetch_snapshot_baseline _)) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       recovered.effects)
;;

let encrypted_graph_recovery_fetches_and_unlocks_key_before_bootstrap () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authenticated.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ encrypted_graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authenticated.effects
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
  let user_key_fetch =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_graph_key _)) ->
          Some
            (Core.step
               recovery.next
               (Core.Runner_completed (Core.Completion (ticket, Ok "encrypted-graph-key"))))
        | Run _ | Delegate _ | Publish _ -> None)
      recovery.effects
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
          let handle = Core.graph_key_handle ~id:"graph-key" ~scope:request.scope in
          Some
            (Core.step
               graph_key_unlock.next
               (Core.Runner_completed (Core.Completion (ticket, Ok handle))))
        | Run _ | Delegate _ | Publish _ -> None)
      graph_key_unlock.effects
    |> Option.get
  in
  Alcotest.(check bool)
    "unlocked graph key resumes snapshot bootstrap"
    true
    (List.exists
       (function
         | Core.Run (Core.Request (_, Core.Fetch_snapshot_baseline _)) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       bootstrapping.effects)
;;

let begin_snapshot_bootstrap () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authenticated.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authenticated.effects
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
  missing, scope
;;

let cold_start_absent_mirror_reaches_pull_after_snapshot_activation () =
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
    (Option.is_none activation.key);
  let activated_snapshot = Core.step activated.next (Core.Snapshot_activated { scope }) in
  let mirror = inspect_mirror_request activated_snapshot.effects in
  let attaching =
    Core.step
      activated_snapshot.next
      (Core.Mirror_inspected (Core.Mirror_available mirror))
  in
  let attachment =
    List.find_map
      (function
        | Core.Delegate (Core.Attach_graph request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      attaching.effects
    |> Option.get
  in
  let sync_token =
    Logseq_overlay_db.Types.sync_token_of_string "sync-token:v1:cold-start"
    |> Result.get_ok
  in
  let checkpoint =
    Logseq_overlay_db.Types.Server_cursor.of_string "server-cursor:v1:42" |> Result.get_ok
  in
  let sync =
    Logseq_overlay_db.Types.sync_view ~token:sync_token ~checkpoint ~submissions:[]
  in
  let attached =
    Core.step attaching.next (Core.Graph_attached { scope = attachment.scope; sync })
  in
  let connection =
    List.find_map
      (function
        | Core.Run (Core.Start_websocket request) -> Some request.scope
        | Run _ | Delegate _ | Publish _ -> None)
      attached.effects
    |> Option.get
  in
  let pulling = Core.step attached.next (Core.Websocket_opened connection) in
  Alcotest.(check bool)
    "cold start opens a pull without another lifecycle event"
    true
    (List.exists
       (function
         | Core.Run
             (Core.Send_websocket
                { scope; message = Logseq_sync_pure_reducer.Sync_protocol.Client.Pull _ })
           -> scope = connection
         | Run _ | Delegate _ | Publish _ -> false)
       pulling.effects)
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
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authenticated.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authenticated.effects
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
  let connection =
    List.find_map
      (function
        | Core.Run (Core.Start_websocket request) -> Some request.scope
        | Run _ | Delegate _ | Publish _ -> None)
      attached.effects
    |> Option.get
  in
  let opened = Core.step attached.next (Core.Websocket_opened connection) in
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
  let rejection : Logseq_sync_pure_reducer.Sync_protocol.rejection =
    { reason = Db_transact_failed
    ; t = Some 1
    ; checksum = Some "0123456789abcdef"
    ; success_tx_ids = [ first ]
    ; failed_tx_id = Some second
    ; missing_block_uuids = [ graph_id ]
    ; error_detail = Some "cannot store value as expected UUID type"
    ; data = None
    }
  in
  let rejected =
    Core.step
      core
      (Core.Websocket_message
         (connection, Logseq_sync_pure_reducer.Sync_protocol.Server.Tx_reject rejection))
  in
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
  let catalog_ticket : Core.graph list Core.effect_ticket =
    match hp01_preview.effects with
    | [ Core.Publish (Core.State_changed state)
      ; Core.Run (Core.Request (ticket, Core.Fetch_catalog scope))
      ]
      when state = authenticated_state && scope.user_id = "user" -> ticket
    | _ -> Alcotest.fail "HP01 unexpected instruction shape"
  in
  let account_scope : Core.account_scope =
    { managed_sync_origin = Uri.of_string "https://api.logseq.io"
    ; user_id = "user"
    ; account_generation = 1
    ; presentation_generation = 1
    ; lifecycle_generation = 0L
    }
  in
  let hp01 =
    check_step
      "HP01"
      origin
      hp01_event
      authenticated_observed
      [ Core.Publish (Core.State_changed authenticated_state)
      ; Core.Run (Core.Request (catalog_ticket, Core.Fetch_catalog account_scope))
      ]
  in
  let hp02 = hp01 in
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
  let hp06_event =
    Core.Graph_attached { scope = mirror_request.scope; sync = empty_sync0 }
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
    }
  in
  let hp06 =
    check_step
      "HP06"
      hp05.next
      hp06_event
      connecting_observed
      [ Core.Publish (Core.State_changed connecting_state)
      ; Core.Run (Core.Start_websocket websocket_request)
      ]
  in
  let hp07 = hp06 in
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
    let timer =
      match (Core.step hp12.next hp13_event).effects with
      | [ Core.Run (Core.Send_websocket _); Core.Run (Core.Schedule_timer timer) ]
        when timer.delay_seconds = 30.
             && timer.scope.connection_generation = Some connection.connection_generation
        -> timer
      | _ -> Alcotest.fail "HP13 submission omitted its scoped response timeout"
    in
    check_step
      "HP13"
      hp12.next
      hp13_event
      submitting_observed
      [ Core.Run (Core.Send_websocket { scope = connection; message = tx_message })
      ; Core.Run (Core.Schedule_timer timer)
      ]
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
  let requested =
    List.exists
      (function
        | Core.Run (Core.Request (_, Core.Fetch_catalog _)) -> true
        | Run _ | Delegate _ | Publish _ -> false)
      authenticated.effects
  in
  Alcotest.check Alcotest.bool "catalog request is transport-owned" true requested
;;

let websocket_connect_uses_deployed_graph_path () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let catalog =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
          Some
            (Core.step
               authenticated.next
               (Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))))
        | Run _ | Delegate _ | Publish _ -> None)
      authenticated.effects
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
  let uri =
    List.find_map
      (function
        | Core.Run (Core.Start_websocket request) -> Some request.uri
        | Run _ | Delegate _ | Publish _ -> None)
      attached.effects
    |> Option.get
  in
  Alcotest.(check string)
    "deployed WebSocket endpoint"
    ("wss://api.logseq.io/sync/" ^ Logseq_db_types.Graph_types.Uuid.to_string graph_id)
    (Uri.to_string uri)
;;

let authenticated_fetch user_id
  : Core.transition * Core.graph list Core.effect_ticket * Core.account_scope
  =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some user_id })
  in
  match authenticated.effects with
  | [ Core.Run (Core.Request (ticket, Core.Fetch_catalog account)) ] ->
    authenticated, ticket, account
  | [ Core.Publish _; Core.Run (Core.Request (ticket, Core.Fetch_catalog account)) ] ->
    authenticated, ticket, account
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

let local_cache_deletion_rejects_unopened_graphs () =
  let authenticated =
    Core.step (initial ()) (Core.Account_authenticated { user_id = Some "user" })
  in
  let selected, scope = selected_graph graph in
  let absent =
    Core.step selected.next (Core.Mirror_inspected (Core.Mirror_absent scope))
  in
  let metadata =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_baseline _)) ->
          Some
            (Core.step
               absent.next
               (Core.Runner_completed
                  (Core.Completion (ticket, Ok {|{"type":"pull/ok","t":42}|}))))
        | _ -> None)
      absent.effects
    |> Option.get
  in
  let downloading =
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
        | _ -> None)
      metadata.effects
    |> Option.get
  in
  let activating =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Download_snapshot _)) ->
          let artifact =
            Core.staged_artifact
              ~id:"deletion-admission"
              ~scope
              ~path:"/tmp/snapshot.sqlite"
              ~expected_rows:10
          in
          Some
            (Core.step
               downloading.next
               (Core.Runner_completed (Core.Completion (ticket, Ok artifact))))
        | _ -> None)
      downloading.effects
    |> Option.get
  in
  let activated = Core.step activating.next (Core.Snapshot_activated { scope }) in
  let attaching =
    Core.step
      activated.next
      (Core.Mirror_inspected
         (Core.Mirror_available (inspect_mirror_request activated.effects)))
  in
  let encrypted, _ = selected_graph encrypted_graph in
  let loading_key =
    Core.step
      encrypted.next
      (Core.Mirror_inspected
         (Core.Mirror_available (inspect_mirror_request encrypted.effects)))
  in
  List.iter
    (fun core ->
       let deletion = Core.step core (Core.Local_cache_deletion_requested graph_id) in
       Alcotest.(check bool)
         "unsupported deletion is inert"
         true
         (observe core = observe deletion.next && deletion.effects = []))
    [ initial ()
    ; authenticated.next
    ; selected.next
    ; absent.next
    ; metadata.next
    ; downloading.next
    ; activating.next
    ; activated.next
    ; attaching.next
    ; loading_key.next
    ]
;;

let deletion_ready_graph encrypted =
  let graph = { graph with encrypted } in
  let selected, scope = selected_graph graph in
  let inspected =
    Core.step
      selected.next
      (Core.Mirror_inspected
         (Core.Mirror_available (inspect_mirror_request selected.effects)))
  in
  let attaching =
    if encrypted
    then (
      let completion =
        List.find_map
          (function
            | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
              Some
                (Core.Runner_completed
                   (Core.Completion
                      (ticket, Ok (Core.graph_key_handle ~id:"retained-key" ~scope))))
            | _ -> None)
          inspected.effects
        |> Option.get
      in
      Core.step inspected.next completion)
    else inspected
  in
  let token = Overlay.sync_token_of_string "sync-token:v1:delete" |> Result.get_ok in
  let checkpoint =
    Overlay.Server_cursor.of_string "server-cursor:v1:0" |> Result.get_ok
  in
  let sync = Overlay.sync_view ~token ~checkpoint ~submissions:[] in
  let attached = Core.step attaching.next (Core.Graph_attached { scope; sync }) in
  let ready = Core.step attached.next Core.Timeline_presented in
  ready.next, scope, sync, selected.effects
;;

let deletion_save_completion effects (result : (unit, Core.effect_error) result) =
  List.find_map
    (function
      | Core.Run (Core.Request (ticket, Core.Save_catalog _)) ->
        Some (Core.Runner_completed (Core.Completion (ticket, result)))
      | _ -> None)
    effects
  |> Option.get
;;

let deletion_mirror effects =
  List.find_map
    (function
      | Core.Delegate (Core.Delete_mirror request) -> Some request
      | _ -> None)
    effects
  |> Option.get
;;

let check_deletion_stage stage core =
  Alcotest.(check bool)
    "visible deletion stage"
    true
    ((Core.state core).snapshot.local_deletion = Some (Core.Deletion_in_progress stage));
  Alcotest.(check bool)
    "picker waits for persistence"
    false
    (Core.state core).snapshot.startup.awaiting_selection
;;

let check_no_work core events =
  List.iter
    (fun event ->
       let step = Core.step core event in
       Alcotest.(check bool)
         "event cannot restart or change deletion"
         true
         (observe core = observe step.next && step.effects = []))
    events
;;

let deletion_blocked_events scope sync =
  [ Core.Local_cache_deletion_requested graph_id
  ; Core.Local_cache_deletion_requested other_graph_id
  ; Core.Graph_selected graph_id
  ; Core.Graph_selected other_graph_id
  ; Core.Graph_picker_requested
  ; Core.Online_recovery_requested
  ; Core.Local_outbox_changed
  ; Core.Local_feed_acknowledged
  ; Core.Timeline_presented
  ; Core.Catalog_refresh_requested
  ; Core.Account_authenticated { user_id = Some "user" }
  ; Core.E2ee_password_submitted "ignored"
  ; Core.Foreground_changed { foreground = true; lifecycle_generation = 98L }
  ; Core.Foreground_changed { foreground = false; lifecycle_generation = 99L }
  ; Core.Graph_attached { scope; sync }
  ; Core.Sync_inspected { scope; sync }
  ; Core.Snapshot_activated { scope }
  ; Core.Mirror_inspected (Core.Mirror_available { graph; scope })
  ; Core.Websocket_opened { graph = scope; connection_generation = 1 }
  ; Core.Websocket_closed ({ graph = scope; connection_generation = 1 }, Some "late")
  ]
;;

let local_deletion_orders_cleanup encrypted () =
  let ready, scope, sync, old_effects = deletion_ready_graph encrypted in
  let refreshing = Core.step ready Core.Catalog_refresh_requested in
  let late_catalog = fetch_catalog_completion refreshing.effects [] in
  let ready = refreshing.next in
  check_no_work ready [ Core.Local_cache_deletion_requested other_graph_id ];
  let deleting = Core.step ready (Core.Local_cache_deletion_requested graph_id) in
  check_deletion_stage Closing_graph deleting.next;
  Alcotest.(check bool)
    "no graph work admitted"
    true
    (Core.admitted_graph_scope deleting.next = None);
  Alcotest.(check bool)
    "selection retained until mirror removed"
    true
    ((Core.state deleting.next).snapshot.selected_graph = Some graph_id);
  let worker =
    List.filter_map
      (function
        | Core.Delegate instruction -> Some instruction
        | _ -> None)
      deleting.effects
  in
  Alcotest.(check bool)
    "only close is delegated initially"
    true
    (worker = [ Core.Detach_graph scope ]);
  Alcotest.(check bool)
    "old transport is cancelled"
    true
    (List.exists
       (function
         | Core.Run (Core.Cancel_effects _) -> true
         | _ -> false)
       deleting.effects);
  Alcotest.(check bool)
    "socket explicitly closes"
    true
    (List.exists
       (function
         | Core.Run (Core.Close_websocket connection) -> connection.graph = scope
         | _ -> false)
       deleting.effects);
  let snapshot = (Core.state deleting.next).snapshot in
  Alcotest.(check bool)
    "graph and presentation fences advance"
    true
    (snapshot.startup.graph_generation > scope.graph_generation
     && snapshot.startup.presentation_generation > scope.account.presentation_generation);
  let blocked = late_catalog :: deletion_blocked_events scope sync in
  check_no_work deleting.next blocked;
  let stale_scope = { scope with graph_generation = scope.graph_generation + 99 } in
  check_no_work
    deleting.next
    [ Core.Graph_detached (stale_scope, Ok ())
    ; Core.Mirror_deleted ({ graph_id; scope = Core.effect_scope_of_graph scope }, Ok ())
    ];
  let closed = Core.step deleting.next (Core.Graph_detached (scope, Ok ())) in
  check_deletion_stage Deleting_mirror closed.next;
  let request = deletion_mirror closed.effects in
  Alcotest.(check bool)
    "mirror carries captured scope"
    true
    (request.graph_id = graph_id && request.scope = Core.effect_scope_of_graph scope);
  check_no_work closed.next (Core.Graph_detached (scope, Ok ()) :: blocked);
  let removed = Core.step closed.next (Core.Mirror_deleted (request, Ok ())) in
  check_deletion_stage Clearing_selection removed.next;
  let cache = save_catalog_cache removed.effects in
  Alcotest.(check bool)
    "saved selection cleared; catalog retained"
    true
    (Core.catalog_cache_selected_graph cache = None
     && Core.catalog_cache_graphs cache = [ { graph with encrypted } ]);
  Alcotest.(check bool)
    "active selection cleared after cleanup"
    true
    ((Core.state removed.next).snapshot.selected_graph = None);
  check_no_work removed.next (Core.Mirror_deleted (request, Ok ()) :: blocked);
  let saved = Core.step removed.next (deletion_save_completion removed.effects (Ok ())) in
  let snapshot = (Core.state saved.next).snapshot in
  Alcotest.(check bool)
    "success reaches graph selection"
    true
    (snapshot.startup.awaiting_selection
     && snapshot.selected_graph = None
     && snapshot.local_deletion = None
     && snapshot.last_error = None);
  Alcotest.(check bool)
    "completion only publishes"
    true
    (List.for_all
       (function
         | Core.Publish _ -> true
         | _ -> false)
       saved.effects);
  List.iter
    (fun transition ->
       Alcotest.(check bool)
         "cleanup performs no key or bootstrap requests"
         true
         (List.for_all
            (function
              | Core.Run (Core.Request (_, Core.Save_catalog _)) -> true
              | Core.Run (Core.Request _) -> false
              | _ -> true)
            transition.Core.effects))
    [ deleting; closed; removed; saved ];
  check_no_work
    saved.next
    [ late_catalog
    ; Core.Graph_detached (scope, Ok ())
    ; Core.Mirror_deleted (request, Ok ())
    ; deletion_save_completion old_effects (Error (Core.Effect_failed "stale"))
    ];
  let restarting =
    Core.step (initial ()) (Core.Restore_local_account { user_id = "user" })
  in
  let restored =
    Core.step restarting.next (load_catalog_completion restarting.effects (Some cache))
  in
  Alcotest.(check bool)
    "restart has no selected graph or opening work"
    true
    ((Core.state restored.next).snapshot.selected_graph = None
     && (Core.state restored.next).snapshot.startup.awaiting_selection
     && not (has_graph_open_work restored.effects));
  let catalog = refresh_catalog saved.next [ { graph with encrypted }; other_graph ] in
  let other_selected = Core.step catalog.next (Core.Graph_selected other_graph_id) in
  let other_mirror = inspect_mirror_request other_selected.effects in
  Alcotest.(check bool)
    "another explicit selection follows normal opening"
    true
    (other_mirror.graph = other_graph && other_mirror.scope.graph_id = other_graph_id);
  check_no_work
    other_selected.next
    [ Core.Graph_detached (scope, Ok ())
    ; Core.Mirror_deleted (request, Ok ())
    ; Core.Graph_attached { scope; sync }
    ; Core.Snapshot_activated { scope }
    ];
  let selected = Core.step saved.next (Core.Graph_selected graph_id) in
  let mirror = inspect_mirror_request selected.effects in
  Alcotest.(check bool)
    "explicit selection uses a fresh scope"
    true
    (mirror.scope <> scope);
  let absent =
    Core.step selected.next (Core.Mirror_inspected (Core.Mirror_absent mirror.scope))
  in
  Alcotest.(check bool)
    "explicit selection starts normal absent-mirror flow"
    true
    (List.exists
       (function
         | Core.Run (Core.Request (_, Core.Load_and_unlock_graph_key _)) -> encrypted
         | Core.Run (Core.Request (_, Core.Fetch_snapshot_baseline _)) -> not encrypted
         | _ -> false)
       absent.effects);
  check_no_work
    selected.next
    [ Core.Graph_detached (scope, Ok ())
    ; Core.Mirror_deleted (request, Ok ())
    ; Core.Graph_attached { scope; sync }
    ; Core.Snapshot_activated { scope }
    ]
;;

let local_deletion_discards_unsynchronized_work () =
  let core, connection = submitted_core () in
  Alcotest.(check bool)
    "fixture has an unacknowledged submission"
    true
    ((Core.state core).snapshot.sync_phase = Core.Submitting);
  let deleting = Core.step core (Core.Local_cache_deletion_requested graph_id) in
  check_deletion_stage Closing_graph deleting.next;
  Alcotest.(check bool)
    "deletion neither flushes nor waits for the remote submission"
    true
    (List.for_all
       (function
         | Core.Publish _
         | Core.Run (Core.Close_websocket _ | Core.Cancel_effects _)
         | Core.Delegate (Core.Detach_graph _) -> true
         | _ -> false)
       deleting.effects);
  check_no_work
    deleting.next
    [ Core.Websocket_message
        ( connection
        , Protocol.Server.Tx_batch_ok { t = 1; checksum = Some "0123456789abcdef" } )
    ];
  let closed = Core.step deleting.next (Core.Graph_detached (connection.graph, Ok ())) in
  ignore (deletion_mirror closed.effects)
;;

let local_deletion_failures_stop encrypted () =
  let ready, scope, sync, _ = deletion_ready_graph encrypted in
  let deleting = Core.step ready (Core.Local_cache_deletion_requested graph_id) in
  let closed = Core.step deleting.next (Core.Graph_detached (scope, Ok ())) in
  let request = deletion_mirror closed.effects in
  let removed = Core.step closed.next (Core.Mirror_deleted (request, Ok ())) in
  List.iter
    (fun (stage, core, event, message) ->
       let failed = Core.step core event in
       let snapshot = (Core.state failed.next).snapshot in
       Alcotest.(check bool)
         "stage failure is terminal"
         true
         (snapshot.local_deletion = Some (Core.Deletion_failed stage)
          && snapshot.sync_phase = Core.Failed
          && not snapshot.startup.awaiting_selection);
       Alcotest.(check (option string))
         "sanitized stage error"
         (Some message)
         snapshot.last_error;
       Alcotest.(check bool)
         "failure only publishes"
         true
         (List.for_all
            (function
              | Core.Publish _ -> true
              | _ -> false)
            failed.effects);
       check_no_work
         failed.next
         (deletion_blocked_events scope sync
          @ [ Core.Graph_detached (scope, Ok ())
            ; Core.Mirror_deleted (request, Ok ())
            ; deletion_save_completion removed.effects (Ok ())
            ]))
    [ ( Core.Closing_graph
      , deleting.next
      , Core.Graph_detached (scope, Error "secret path")
      , "Local graph close failed." )
    ; ( Core.Deleting_mirror
      , closed.next
      , Core.Mirror_deleted (request, Error "secret path")
      , "Local graph deletion failed." )
    ; ( Core.Clearing_selection
      , removed.next
      , deletion_save_completion
          removed.effects
          (Error (Core.Effect_failed "secret path"))
      , "Clearing the saved graph selection failed." )
    ]
;;

let recovery_connection effects =
  List.find_map
    (function
      | Core.Run (Core.Start_websocket request) -> Some request.scope
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> Option.get
;;

let restore_recovery_core sync =
  let restoring =
    Core.step (initial ()) (Core.Restore_local_account { user_id = "user" })
  in
  let cache =
    Core.catalog_cache ~user_id:"user" ~graphs:[ graph ] ~selected_graph:(Some graph_id)
  in
  let restored =
    Core.step restoring.next (load_catalog_completion restoring.effects (Some cache))
  in
  let mirror = inspect_mirror_request restored.effects in
  let inspected =
    Core.step restored.next (Core.Mirror_inspected (Core.Mirror_available mirror))
  in
  let attached =
    Core.step inspected.next (Core.Graph_attached { scope = mirror.scope; sync })
  in
  let connection = recovery_connection attached.effects in
  let opened = Core.step attached.next (Core.Websocket_opened connection) in
  opened.next, connection
;;

let recovery_delete_transaction =
  "[[\"~:db/retractEntity\",[\"~:block/uuid\",\"~u11111111-1111-4111-8111-111111111111\"]]]"
;;

let submitted_delete_recovery_fixture () =
  let mutation_id = List.hd mutation_ids in
  let cursor = Overlay.Server_cursor.of_string "server-cursor:v1:0" |> Result.get_ok in
  let token ordinal =
    Overlay.sync_token_of_string (Printf.sprintf "sync-token:v1:%d" ordinal)
    |> Result.get_ok
  in
  let sync token submissions = Overlay.sync_view ~token ~checkpoint:cursor ~submissions in
  let core, connection = restore_recovery_core (sync (token 0) []) in
  let mutation : Overlay.submission_descriptor =
    { mutation_id
    ; fingerprint =
        Overlay.Mutation_fingerprint.of_string "mutation-fingerprint:v1:delete-recovery"
        |> Result.get_ok
    ; state = Overlay.Queued
    ; dependency_eligible = true
    ; attempt_count = 0
    ; plaintext_bytes = 128
    ; protected_bytes = Some 128
    }
  in
  let inspection = Core.step core Core.Local_outbox_changed in
  let planned =
    Core.step
      inspection.next
      (Core.Sync_inspected
         { scope = connection.graph; sync = sync (token 1) [ mutation ] })
  in
  let request =
    List.find_map
      (function
        | Core.Delegate (Core.Apply_outbox_transition request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      planned.effects
    |> Option.get
  in
  Alcotest.(check bool)
    "fixture submits exactly the delete mutation"
    true
    (request.transition = Overlay.Submit_group [ mutation_id ]);
  let batch_id =
    Overlay.Submission_batch_id.of_string "submission-batch:v1:delete-recovery"
    |> Result.get_ok
  in
  let wire =
    Overlay.submission_wire
      ~maximum_bytes:1024
      ~mutation_id
      ~operation:Overlay.Delete_blocks_operation
      ~protected_transaction:recovery_delete_transaction
    |> Result.get_ok
  in
  let batch =
    Overlay.submission_batch
      ~maximum_wires:1
      ~maximum_bytes:1024
      ~batch_id
      ~t_before:cursor
      ~wires:[ wire ]
    |> Result.get_ok
  in
  let submitted_sync =
    sync
      (token 2)
      [ { mutation with state = Overlay.Submitted batch_id; attempt_count = 1 } ]
  in
  let projection =
    Overlay.Projection_revision.of_string "projection:v1:1" |> Result.get_ok
  in
  let commit : Overlay.outbox_commit =
    { generation = Overlay.Generation.of_string "generation:v1:1" |> Result.get_ok
    ; before_projection_revision = projection
    ; after_projection_revision = projection
    ; sync_token = token 2
    ; transition = request.transition
    ; activity = Overlay.Logically_active
    ; logical_change_summary = Overlay.No_logical_change
    ; submission_batch = Some batch
    }
  in
  let submitted =
    Core.step
      planned.next
      (Core.Outbox_transition_applied
         { scope = request.scope; commit; sync = submitted_sync })
  in
  Alcotest.(check bool)
    "fixture sends the persisted delete batch"
    true
    (List.exists
       (function
         | Core.Run
             (Core.Send_websocket
                { scope; message = Protocol.Client.Tx_batch { txs = [ tx ]; _ } }) ->
           scope = connection && tx.outliner_op = Some "delete-blocks"
         | Run _ | Delegate _ | Publish _ -> false)
       submitted.effects);
  submitted, connection, submitted_sync, batch
;;

let defer_recovered_delete core connection batch_id =
  let pulled =
    Core.step
      core
      (Core.Websocket_message
         ( connection
         , Protocol.Server.Pull_ok
             { t = 1
             ; checksum = Some "0123456789abcdef"
             ; txs =
                 [ { t = 1
                   ; tx = recovery_delete_transaction
                   ; outliner_op = Some "delete-blocks"
                   }
                 ]
             } ))
  in
  let batch =
    List.find_map
      (function
        | Core.Delegate (Core.Apply_authoritative_batch request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      pulled.effects
    |> Option.get
  in
  Alcotest.(check bool)
    "pull reaches the authoritative worker boundary"
    true
    (batch.scope = connection);
  (* The overlay's deferred outcome is an input at this pure policy boundary. *)
  let event =
    Core.Authoritative_batch_deferred
      { scope = connection.graph; defer = Overlay.Await_submission_outcome batch_id }
  in
  let deferred = preview_step "submitted delete defer" pulled.next event in
  ignore (check_replay "submitted delete defer" pulled.next event deferred);
  deferred, batch
;;

let live_submitted_delete_resumes_after_acknowledgement () =
  let submitted, connection, sync, wire_batch = submitted_delete_recovery_fixture () in
  let batch_id = Overlay.submission_batch_id wire_batch in
  let deferred, batch = defer_recovered_delete submitted.next connection batch_id in
  let deferred = deferred.next in
  Alcotest.(check (option string))
    "live owner accepts the deferred result"
    None
    (Core.state deferred).snapshot.last_error;
  let acknowledged =
    Core.step
      deferred
      (Core.Websocket_message
         ( connection
         , Protocol.Server.Tx_batch_ok { t = 1; checksum = Some "0123456789abcdef" } ))
  in
  let request =
    List.find_map
      (function
        | Core.Delegate
            (Core.Apply_outbox_transition
               ({ transition = Overlay.Accept_group { batch_id = accepted; _ }; _ } as
                request))
          when Overlay.Submission_batch_id.equal accepted batch_id -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      acknowledged.effects
    |> Option.get
  in
  let accepted_sync =
    Overlay.sync_view
      ~token:(Overlay.sync_token_of_string "sync-token:v1:3" |> Result.get_ok)
      ~checkpoint:(Overlay.sync_view_checkpoint sync)
      ~submissions:
        (List.map
           (fun (descriptor : Overlay.submission_descriptor) ->
              { descriptor with state = Overlay.Accepted_pending_authoritative batch_id })
           (Overlay.sync_view_submissions sync))
  in
  let projection =
    Overlay.Projection_revision.of_string "projection:v1:1" |> Result.get_ok
  in
  let commit : Overlay.outbox_commit =
    { generation = Overlay.Generation.of_string "generation:v1:1" |> Result.get_ok
    ; before_projection_revision = projection
    ; after_projection_revision = projection
    ; sync_token = Overlay.sync_view_token accepted_sync
    ; transition = request.transition
    ; activity = Overlay.Logically_active
    ; logical_change_summary = Overlay.No_logical_change
    ; submission_batch = None
    }
  in
  let resumed =
    Core.step
      acknowledged.next
      (Core.Outbox_transition_applied
         { scope = request.scope; commit; sync = accepted_sync })
  in
  check_instructions
    "live acknowledgement resumes the same deferred batch"
    [ Core.Delegate (Core.Apply_authoritative_batch batch) ]
    resumed.effects
;;

let recovery_cursor n =
  Overlay.Server_cursor.of_string (Printf.sprintf "server-cursor:v1:%d" n)
  |> Result.get_ok
;;

let recovery_sync _sync ?(checkpoint = 0) ordinal submissions =
  Overlay.sync_view
    ~token:
      (Overlay.sync_token_of_string (Printf.sprintf "sync-token:v1:%d" ordinal)
       |> Result.get_ok)
    ~checkpoint:(recovery_cursor checkpoint)
    ~submissions
;;

let recovery_request effects =
  match
    List.filter_map
      (function
        | Core.Delegate (Core.Apply_outbox_transition request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      effects
  with
  | [ request ] -> request
  | _ -> Alcotest.fail "expected exactly one recovery outbox transition"
;;

let recovery_commit (request : Core.outbox_transition_request) sync submission_batch =
  let projection =
    Overlay.Projection_revision.of_string "projection:v1:1" |> Result.get_ok
  in
  let commit : Overlay.outbox_commit =
    { generation = Overlay.Generation.of_string "generation:v1:1" |> Result.get_ok
    ; before_projection_revision = projection
    ; after_projection_revision = projection
    ; sync_token = Overlay.sync_view_token sync
    ; transition = request.transition
    ; activity = Overlay.Logically_active
    ; logical_change_summary = Overlay.No_logical_change
    ; submission_batch
    }
  in
  Core.Outbox_transition_applied { scope = request.scope; commit; sync }
;;

let require_no_new_submission effects =
  Alcotest.(check bool)
    "unresolved recovery blocks new mutations"
    false
    (List.exists
       (function
         | Core.Delegate
             (Core.Apply_outbox_transition { transition = Overlay.Submit_group _; _ }) ->
           true
         | Run _ | Delegate _ | Publish _ -> false)
       effects)
;;

let recovery_apply core (connection : Core.connection_scope) sync =
  let projection =
    Overlay.Projection_revision.of_string "projection:v1:1" |> Result.get_ok
  in
  let commit : Overlay.authoritative_commit =
    { generation = Overlay.Generation.of_string "generation:v1:1" |> Result.get_ok
    ; before_projection_revision = projection
    ; after_projection_revision = projection
    ; checkpoint = Overlay.sync_view_checkpoint sync
    ; sync_token = Overlay.sync_view_token sync
    ; terminal_receipts = []
    ; replanned_queued_ids = []
    ; blocked_ids = []
    ; logical_change_summary = Overlay.No_logical_change
    }
  in
  Core.step
    core
    (Core.Authoritative_batch_applied { scope = connection.Core.graph; commit; sync })
;;

let recover_retry core connection sync wire_batch effects =
  let request = recovery_request effects in
  Alcotest.(check bool)
    "recover the original durable batch"
    true
    (request.transition = Overlay.Retry_group (Overlay.submission_batch_id wire_batch));
  let retried_sync =
    recovery_sync
      sync
      3
      (List.map
         (fun (item : Overlay.submission_descriptor) ->
            { item with attempt_count = item.attempt_count + 1 })
         (Overlay.sync_view_submissions sync))
  in
  let retried = Core.step core (recovery_commit request retried_sync (Some wire_batch)) in
  let sends =
    List.filter_map
      (function
        | Core.Run (Core.Send_websocket send) -> Some send
        | Run _ | Delegate _ | Publish _ -> None)
      retried.effects
  in
  (match sends with
   | [ { scope
       ; message = Protocol.Client.Tx_batch { client_revision; t_before; txs = [ tx ] }
       }
     ] ->
     Alcotest.(check bool) "retry uses the current connection" true (scope = connection);
     Alcotest.(check (option string))
       "retry retains batch ID"
       (Some
          (Overlay.Submission_batch_id.to_string (Overlay.submission_batch_id wire_batch)))
       client_revision;
     Alcotest.(check int) "retry retains conditional baseline" 0 t_before;
     Alcotest.(check string)
       "retry retains protected bytes"
       recovery_delete_transaction
       tx.tx
   | _ -> Alcotest.fail "retry did not send the original wire batch once");
  Alcotest.(check bool)
    "retry waits for terminal outcome before replaying deletion"
    false
    (List.exists
       (function
         | Core.Delegate (Core.Apply_authoritative_batch _) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       retried.effects);
  retried, retried_sync
;;

let finish_recovery ~reject core connection sync wire_batch effects batch =
  let retried, sync = recover_retry core connection sync wire_batch effects in
  let batch_id = Overlay.submission_batch_id wire_batch in
  let response =
    if reject
    then
      Protocol.Server.Tx_reject
        { reason = Protocol.Stale
        ; t = Some 1
        ; checksum = Some "0123456789abcdef"
        ; success_tx_ids = []
        ; failed_tx_id = None
        ; missing_block_uuids = []
        ; error_detail = None
        ; data = None
        }
    else Protocol.Server.Tx_batch_ok { t = 1; checksum = Some "0123456789abcdef" }
  in
  let terminal = Core.step retried.next (Core.Websocket_message (connection, response)) in
  let request = recovery_request terminal.effects in
  let state =
    if reject
    then
      Overlay.Delete_barrier_rejected_pending_authoritative
        { batch_id; through = recovery_cursor 1 }
    else Overlay.Accepted_pending_authoritative batch_id
  in
  let terminal_sync =
    recovery_sync
      sync
      4
      (List.map
         (fun (item : Overlay.submission_descriptor) -> { item with state })
         (Overlay.sync_view_submissions sync))
  in
  let resumed = Core.step terminal.next (recovery_commit request terminal_sync None) in
  Alcotest.(check bool)
    "terminal outcome replays the same deferred authoritative batch"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Apply_authoritative_batch actual) -> actual = batch
         | Run _ | Delegate _ | Publish _ -> false)
       resumed.effects);
  Alcotest.(check bool)
    "deferred replay is not Current"
    false
    ((Core.state resumed.next).snapshot.sync_phase = Core.Current);
  require_no_new_submission resumed.effects;
  let current =
    recovery_apply resumed.next connection (recovery_sync sync ~checkpoint:1 5 [])
  in
  Alcotest.(check (option int))
    "recovery advances the durable checkpoint"
    (Some 1)
    (Core.state current.next).snapshot.applied_server_t;
  Alcotest.(check bool)
    "completed recovery becomes Current"
    true
    ((Core.state current.next).snapshot.sync_phase = Core.Current)
;;

let check_submitted_delete_recovery ?(reject = false) core connection sync wire_batch =
  let recovered, batch =
    defer_recovered_delete core connection (Overlay.submission_batch_id wire_batch)
  in
  Alcotest.(check (option string))
    "a durable submitted delete must remain recoverable after its transport owner ends"
    None
    (Core.state recovered.next).snapshot.last_error;
  Alcotest.(check bool)
    "recovery does not enter Failed"
    false
    ((Core.state recovered.next).snapshot.sync_phase = Core.Failed);
  finish_recovery
    ~reject
    recovered.next
    connection
    sync
    wire_batch
    recovered.effects
    batch
;;

let submitted_delete_survives_disconnect_reconnect () =
  let submitted, connection, sync, wire_batch = submitted_delete_recovery_fixture () in
  let closed = Core.step submitted.next (Core.Websocket_closed (connection, None)) in
  let restarting =
    Core.step
      closed.next
      (Core.Foreground_changed { foreground = true; lifecycle_generation = 1L })
  in
  let current_connection = recovery_connection restarting.effects in
  Alcotest.(check bool)
    "reconnect advances the connection generation"
    true
    (current_connection.connection_generation > connection.connection_generation);
  let opened = Core.step restarting.next (Core.Websocket_opened current_connection) in
  check_submitted_delete_recovery opened.next current_connection sync wire_batch
;;

let submitted_delete_survives_fresh_core_restore () =
  let _, _, persisted_sync, wire_batch = submitted_delete_recovery_fixture () in
  let fresh, connection = restore_recovery_core persisted_sync in
  Alcotest.(check (option int))
    "fresh Core restores the durable checkpoint"
    (Some 0)
    (Core.state fresh).snapshot.applied_server_t;
  check_submitted_delete_recovery fresh connection persisted_sync wire_batch
;;

let recovery_stale_rejection_resumes_deletion () =
  let _, _, sync, wire_batch = submitted_delete_recovery_fixture () in
  let fresh, connection = restore_recovery_core sync in
  check_submitted_delete_recovery ~reject:true fresh connection sync wire_batch
;;

let recovery_empty_pull_prioritizes_submitted () =
  let _, _, sync, wire_batch = submitted_delete_recovery_fixture () in
  let original = List.hd (Overlay.sync_view_submissions sync) in
  let queued =
    { original with
      mutation_id = List.nth mutation_ids 1
    ; state = Overlay.Queued
    ; attempt_count = 0
    }
  in
  let sync = recovery_sync sync 3 [ queued; original ] in
  let fresh, connection = restore_recovery_core sync in
  let pulled =
    Core.step
      fresh
      (Core.Websocket_message
         (connection, Protocol.Server.Pull_ok { t = 0; checksum = None; txs = [] }))
  in
  require_no_new_submission pulled.effects;
  ignore (recover_retry pulled.next connection sync wire_batch pulled.effects)
;;

let recovery_barrier_blocks_queued ~rejected () =
  let _, _, sync, wire_batch = submitted_delete_recovery_fixture () in
  let batch_id = Overlay.submission_batch_id wire_batch in
  let original = List.hd (Overlay.sync_view_submissions sync) in
  let state =
    if rejected
    then
      Overlay.Delete_barrier_rejected_pending_authoritative
        { batch_id; through = recovery_cursor 1 }
    else Overlay.Accepted_pending_authoritative batch_id
  in
  let pending = { original with state } in
  let queued =
    { original with
      mutation_id = List.nth mutation_ids 1
    ; state = Overlay.Queued
    ; attempt_count = 0
    }
  in
  let sync = recovery_sync sync 3 [ queued; pending ] in
  let fresh, connection = restore_recovery_core sync in
  let pulled =
    Core.step
      fresh
      (Core.Websocket_message
         (connection, Protocol.Server.Pull_ok { t = 0; checksum = None; txs = [] }))
  in
  require_no_new_submission pulled.effects;
  Alcotest.(check bool)
    "unresolved barrier is not Current"
    false
    ((Core.state pulled.next).snapshot.sync_phase = Core.Current)
;;

let recovery_stale_connection_and_interrupted_retry () =
  let _, old_connection, sync, wire_batch = submitted_delete_recovery_fixture () in
  let fresh, connection = restore_recovery_core sync in
  let retry, _ =
    defer_recovered_delete fresh connection (Overlay.submission_batch_id wire_batch)
  in
  let request = recovery_request retry.effects in
  let closed = Core.step retry.next (Core.Websocket_closed (connection, None)) in
  let committed =
    Core.step closed.next (recovery_commit request sync (Some wire_batch))
  in
  Alcotest.(check bool)
    "offline durable completion emits no websocket send"
    false
    (List.exists
       (function
         | Core.Run (Core.Send_websocket _) -> true
         | _ -> false)
       committed.effects);
  let restarted =
    Core.step
      committed.next
      (Core.Foreground_changed { foreground = true; lifecycle_generation = 1L })
  in
  let new_connection = recovery_connection restarted.effects in
  let opened = Core.step restarted.next (Core.Websocket_opened new_connection) in
  let late =
    Core.step
      opened.next
      (Core.Websocket_message
         ( old_connection
         , Protocol.Server.Tx_batch_ok { t = 1; checksum = Some "0123456789abcdef" } ))
  in
  check_instructions "old response cannot accept recovered batch" [] late.effects;
  check_submitted_delete_recovery late.next new_connection sync wire_batch
;;

let recovery_submission_timeout () =
  let submitted, connection, sync, wire_batch = submitted_delete_recovery_fixture () in
  let timer =
    List.find_map
      (function
        | Core.Run (Core.Schedule_timer timer) -> Some timer
        | Run _ | Delegate _ | Publish _ -> None)
      submitted.effects
  in
  Alcotest.(check bool)
    "live submission has a bounded acknowledgement wait"
    true
    (Option.is_some timer);
  let timer = Option.get timer in
  let expired = Core.step submitted.next (Core.Timer_elapsed timer.id) in
  Alcotest.(check bool)
    "timeout closes the uncertain connection"
    true
    (List.exists
       (function
         | Core.Run (Core.Close_websocket scope) -> scope = connection
         | _ -> false)
       expired.effects);
  let new_connection = recovery_connection expired.effects in
  let opened = Core.step expired.next (Core.Websocket_opened new_connection) in
  let replay = Core.step opened.next (Core.Timer_elapsed timer.id) in
  check_instructions "old timeout is consumed" [] replay.effects;
  check_submitted_delete_recovery replay.next new_connection sync wire_batch
;;

let recovery_outbox_failure_is_correlated () =
  let submitted, connection, sync, batch = submitted_delete_recovery_fixture () in
  let acknowledged =
    Core.step
      submitted.next
      (Core.Websocket_message
         ( connection
         , Protocol.Server.Tx_batch_ok { t = 1; checksum = Some "0123456789abcdef" } ))
  in
  let request = recovery_request acknowledged.effects in
  let message = "The overlay outbox transition was rejected." in
  let fail request = Core.Outbox_transition_failed { request; message } in
  let foreign =
    { request with
      expected = Overlay.sync_token_of_string "sync-token:v1:999" |> Result.get_ok
    }
  in
  let ignored = Core.step acknowledged.next (fail foreign) in
  check_instructions
    "foreign expected token cannot fail pending transition"
    []
    ignored.effects;
  Alcotest.(check bool)
    "foreign failure leaves state unchanged"
    true
    (Core.state ignored.next = Core.state acknowledged.next);
  let failed = Core.step ignored.next (fail request) in
  Alcotest.(check bool)
    "outbox failure is terminal and visible"
    true
    ((Core.state failed.next).snapshot.sync_phase = Core.Failed);
  Alcotest.(check (option string))
    "outbox error is retained"
    (Some message)
    (Core.state failed.next).snapshot.last_error;
  Alcotest.(check bool)
    "failed response retires its connection"
    true
    (List.exists
       (function
         | Core.Run (Core.Close_websocket scope) -> scope = connection
         | _ -> false)
       failed.effects);
  let late = Core.step failed.next (recovery_commit request sync None) in
  check_instructions "late success cannot revive failed transition" [] late.effects;
  let duplicate = Core.step late.next (fail request) in
  check_instructions "duplicate failure is inert" [] duplicate.effects;
  let old_ack =
    Core.step
      duplicate.next
      (Core.Websocket_message
         ( connection
         , Protocol.Server.Tx_batch_ok { t = 1; checksum = Some "0123456789abcdef" } ))
  in
  check_instructions "old response cannot recreate a failed transition" [] old_ack.effects;
  ignore batch
;;

let recovery_retry_failure_is_visible () =
  let _, _, sync, batch = submitted_delete_recovery_fixture () in
  let fresh, connection = restore_recovery_core sync in
  let retry, _ =
    defer_recovered_delete fresh connection (Overlay.submission_batch_id batch)
  in
  let request = recovery_request retry.effects in
  let failed =
    Core.step
      retry.next
      (Core.Outbox_transition_failed { request; message = "Retry commit failed." })
  in
  Alcotest.(check bool)
    "retry failure does not remain Submitting"
    true
    ((Core.state failed.next).snapshot.sync_phase = Core.Failed);
  let late = Core.step failed.next (recovery_commit request sync (Some batch)) in
  check_instructions "failed retry completion cannot send" [] late.effects
;;

let sync_recovery_reproductions =
  [ Alcotest.test_case
      "outbox failures are correlated and terminal"
      `Quick
      recovery_outbox_failure_is_correlated
  ; Alcotest.test_case
      "retry commit failure is visible"
      `Quick
      recovery_retry_failure_is_visible
  ; Alcotest.test_case
      "live submitted delete resumes after acknowledgement"
      `Quick
      live_submitted_delete_resumes_after_acknowledgement
  ; Alcotest.test_case
      "M02 submitted delete survives disconnect and reconnect"
      `Quick
      submitted_delete_survives_disconnect_reconnect
  ; Alcotest.test_case
      "M02 submitted delete survives fresh Core restore"
      `Quick
      submitted_delete_survives_fresh_core_restore
  ; Alcotest.test_case
      "recovery Stale rejection resumes deletion"
      `Quick
      recovery_stale_rejection_resumes_deletion
  ; Alcotest.test_case
      "empty pull recovers Submitted before Queued"
      `Quick
      recovery_empty_pull_prioritizes_submitted
  ; Alcotest.test_case
      "restored acceptance barrier blocks Queued"
      `Quick
      (recovery_barrier_blocks_queued ~rejected:false)
  ; Alcotest.test_case
      "restored rejection barrier blocks Queued"
      `Quick
      (recovery_barrier_blocks_queued ~rejected:true)
  ; Alcotest.test_case
      "interrupted retry and old response are fenced"
      `Quick
      recovery_stale_connection_and_interrupted_retry
  ; Alcotest.test_case
      "missing batch response expires its connection"
      `Quick
      recovery_submission_timeout
  ]
;;

let scenarios =
  [ Alcotest.test_case
      "pure reducer canonical overlay happy path"
      `Quick
      canonical_overlay_happy_path
  ; Alcotest.test_case
      "selected graph survives picker and codec restart"
      `Quick
      selected_graph_survives_picker_and_codec_restart
  ; Alcotest.test_case
      "invalid cached selections fail closed"
      `Quick
      invalid_cached_selections_fail_closed
  ; Alcotest.test_case
      "same-account authentication preserves pending warm restore"
      `Quick
      same_account_authentication_preserves_pending_warm_restore
  ; Alcotest.test_case
      "catalog refresh preserves or revokes selection"
      `Quick
      catalog_refresh_preserves_or_revokes_selection
  ; Alcotest.test_case
      "catalog save failure keeps selected graph usable"
      `Quick
      catalog_save_failure_keeps_selected_graph_usable
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
  ; Alcotest.test_case
      "sign-out captures identity and fences old work"
      `Quick
      sign_out_captures_identity_advances_generations_and_fences_old_work
  ; Alcotest.test_case
      "sign-out cleanup completion is inert and sanitized"
      `Quick
      sign_out_cleanup_completion_is_inert_and_sanitized
  ; Alcotest.test_case
      "local cache deletion rejects unopened graphs"
      `Quick
      local_cache_deletion_rejects_unopened_graphs
  ; Alcotest.test_case
      "deletion discards unsynchronized work"
      `Quick
      local_deletion_discards_unsynchronized_work
  ; Alcotest.test_case
      "plain local deletion ordering"
      `Quick
      (local_deletion_orders_cleanup false)
  ; Alcotest.test_case
      "encrypted local deletion ordering"
      `Quick
      (local_deletion_orders_cleanup true)
  ; Alcotest.test_case
      "plain local deletion failures"
      `Quick
      (local_deletion_failures_stop false)
  ; Alcotest.test_case
      "encrypted local deletion failures"
      `Quick
      (local_deletion_failures_stop true)
  ; Alcotest.test_case
      "cold start absent mirror reaches pull after snapshot activation"
      `Quick
      cold_start_absent_mirror_reaches_pull_after_snapshot_activation
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
