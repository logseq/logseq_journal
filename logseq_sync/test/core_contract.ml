let server_cursor_of_int value =
  Logseq_db_types.Server_cursor.of_int64 (Int64.of_int value) |> Result.get_ok
;;

let cursor_testable =
  Alcotest.testable
    (fun fmt cursor ->
       Format.fprintf fmt "%Ld" (Logseq_db_types.Server_cursor.to_int64 cursor))
    Logseq_db_types.Server_cursor.equal
;;

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

let raw_initial () =
  Core.config
    ~managed_sync_origin:(Uri.of_string "https://api.logseq.io")
    ~limits:(limits ())
  |> Result.get_ok
  |> Core.initial
  |> Result.get_ok
;;

let startup_scope core : Core.startup_scope =
  let f = (Core.state core).snapshot.startup in
  { account_generation=f.account_generation;presentation_generation=f.presentation_generation }
;;
let timeline_scope core : Core.timeline_scope =
  let s=(Core.state core).snapshot in
  {startup=startup_scope core;graph_id=Option.get s.selected_graph;graph_generation=s.startup.graph_generation}
;;
let initial () = (Core.step (raw_initial ()) (Core.Sign_in_requested (startup_scope (raw_initial ())))).next
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

(* Invalid/stale submission scenarios still carry a genuine challenge, obtained
   through production events rather than a test constructor. *)
let fixture_challenge = lazy (
  let selected, scope = selected_graph encrypted_graph in
  let absent = Core.step selected.next (Core.Mirror_inspected (Core.Mirror_absent scope)) in
  let prepare = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
      Some (Core.step absent.next (Core.Runner_completed
        (Core.Completion (ticket, Error (Core.Effect_failed "synthetic missing key")))))
    | _ -> None) absent.effects |> Option.get in
  let graph_key = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_graph_key _)) ->
      Some (Core.step prepare.next (Core.Runner_completed
        (Core.Completion (ticket, Ok "encrypted-graph-key"))))
    | _ -> None) prepare.effects |> Option.get in
  let prompt = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_user_keys _)) ->
      Some (Core.step graph_key.next (Core.Runner_completed
        (Core.Completion (ticket, Ok "private-key-package"))))
    | _ -> None) graph_key.effects |> Option.get in
  Core.unlock_challenge (Core.state prompt.next).snapshot.unlock |> Option.get)
;;

let password_event core password =
  let challenge = Core.unlock_challenge (Core.state core).snapshot.unlock
    |> Option.value ~default:(Lazy.force fixture_challenge) in
  Core.E2ee_password_submitted (challenge, password)
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
  let requested = Core.step core (Core.Catalog_refresh_requested (startup_scope core)) in
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
    ((not snapshot.startup.authenticated)
     && (not snapshot.startup.awaiting_selection)
     && Option.equal
          Logseq_db_types.Graph_types.Uuid.equal
          snapshot.selected_graph
          (Some graph_id));
  ignore (inspect_mirror_request restored.effects);
  Alcotest.(check bool)
    "local admission alone does not authorize remote reconciliation"
    false
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
    ((Core.state failed.next).snapshot = (Core.state selected.next).snapshot);
  let groups = (Core.state failed.next).diagnostics.groups in
  Alcotest.(check bool) "ignored catalog save is visible in Diagnostics" true
    (List.exists (fun (g : Core.diagnostic_group) ->
       List.exists (fun (_, value) -> String.starts_with ~prefix:"saveCatalog" value) g.entries) groups);
  Alcotest.(check bool) "diagnostic update is published" true
    (List.exists (function Core.Publish (Core.State_changed _) -> true | _ -> false) failed.effects);
  let duplicate = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Save_catalog _)) ->
      Some (Core.step failed.next (Core.Runner_completed
        (Core.Completion (ticket, Error (Core.Effect_failed "sensitive ignored duplicate")))))
    | _ -> None) selected.effects |> Option.get in
  Alcotest.(check bool) "consumed duplicate cannot add or replace a diagnostic" true
    (Core.state duplicate.next = Core.state failed.next && duplicate.effects = []);
  let changed = Core.step failed.next (Core.Account_authenticated {user_id=Some "other-user"}) in
  Alcotest.(check bool) "new account cannot inherit advisory errors" true
    ((Core.state changed.next).diagnostics.groups = []);
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
      Logseq_overlay_db.Types.Server_cursor.of_int64 0L
      |> Result.map_error (fun `Negative_cursor -> "negative cursor")
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
  let recovery = failed in
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
    Core.step password_prompt.next (password_event password_prompt.next "password")
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
         | Core.Run (Core.Request (_, Core.Fetch_snapshot_metadata _)) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       recovered.effects)
;;

let e2ee_password_retry_recovers_after_failed_unlock () =
  let selected, scope = selected_graph encrypted_graph in
  let missing = Core.step selected.next (Core.Mirror_inspected (Mirror_absent scope)) in
  let failed_cache =
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
  let recovery = failed_cache in
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
  let prompt =
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
  let first = Core.step prompt.next (password_event prompt.next "wrong-synthetic") in
  let rejected, repeat_rejected =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Unlock_private_key _)) ->
          let event =
            Core.Runner_completed
              (Core.Completion
                 ( ticket
                 , Error (Core.Crypto_failed (Invalid_key_material, "wrong password")) ))
          in
          Some (Core.step first.next event, event)
        | Run _ | Delegate _ | Publish _ -> None)
      first.effects
    |> Option.get
  in
  Alcotest.(check bool)
    "failure stays visible"
    true
    ((Core.state rejected.next).snapshot.startup.failure = Some During_e2ee);
  let corrected =
    Core.step rejected.next (password_event rejected.next " corrected-synthetic ")
  in
  let requests =
    List.filter_map
      (function
        | Core.Run (Core.Request (ticket, Core.Unlock_private_key request)) ->
          Some
            ( request
            , fun (result : (unit, Core.effect_error) result) ->
                Core.Runner_completed (Core.Completion (ticket, result)) )
        | Run _ | Delegate _ | Publish _ -> None)
      corrected.effects
  in
  Alcotest.(check int)
    "corrected password emits one unlock request"
    1
    (List.length requests);
  let request, complete = List.hd requests in
  Alcotest.(check string)
    "retry preserves password bytes"
    " corrected-synthetic "
    request.password;
  Alcotest.(check string)
    "retry preserves encrypted package"
    "private-key-package"
    request.private_key_package;
  Alcotest.(check bool)
    "retry remains in account scope"
    true
    (request.scope = scope.account);
  Alcotest.(check bool)
    "failure awaits another password"
    true
    (Core.state rejected.next).snapshot.startup.awaiting_e2ee_password;
  Alcotest.(check bool)
    "retry clears previous failure"
    true
    ((Core.state corrected.next).snapshot.startup.failure = None);
  let duplicate =
    Core.step corrected.next (password_event corrected.next "duplicate-synthetic")
  in
  Alcotest.(check int) "pending duplicate is inert" 0 (List.length duplicate.effects);
  let stale = Core.step duplicate.next repeat_rejected in
  Alcotest.(check int) "old rejection completion is inert" 0 (List.length stale.effects);
  let again =
    Core.step stale.next (complete (Error (Core.Effect_failed "still wrong")))
  in
  Alcotest.(check bool)
    "repeated failure remains retryable"
    true
    (Core.state again.next).snapshot.startup.awaiting_e2ee_password;
  let final = Core.step again.next (password_event again.next "final-synthetic") in
  let unlocked =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Unlock_private_key _)) ->
          Some
            (Core.step
               final.next
               (Core.Runner_completed (Core.Completion (ticket, Ok ()))))
        | Run _ | Delegate _ | Publish _ -> None)
      final.effects
    |> Option.get
  in
  let resumed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_and_unlock_graph_key request)) ->
          Alcotest.(check string)
            "retry retains encrypted graph key"
            "encrypted-graph-key"
            request.encrypted_graph_key;
          let handle = Core.graph_key_handle ~id:"retry-graph-key" ~scope:request.scope in
          Some
            (Core.step
               unlocked.next
               (Core.Runner_completed (Core.Completion (ticket, Ok handle))))
        | Run _ | Delegate _ | Publish _ -> None)
      unlocked.effects
    |> Option.get
  in
  Alcotest.(check bool)
    "successful retry resumes snapshot bootstrap"
    true
    (List.exists
       (function
         | Core.Run (Core.Request (_, Core.Fetch_snapshot_metadata _)) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       resumed.effects);
  let picker = Core.step rejected.next Core.Graph_picker_requested in
  let abandoned =
    Core.step picker.next (password_event picker.next "abandoned-synthetic")
  in
  Alcotest.(check int)
    "picker discards password challenge"
    0
    (List.length abandoned.effects);
  let account =
    Core.step rejected.next (Core.Account_authenticated { user_id = Some "other-user" })
  in
  let abandoned =
    Core.step account.next (password_event account.next "other-account-synthetic")
  in
  Alcotest.(check int)
    "account switch discards password challenge"
    0
    (List.length abandoned.effects)
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
  let recovery = failed in
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
    Core.step password_prompt.next (password_event password_prompt.next "password")
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
    "bootstrap phase is published before waiting for metadata"
    true
    (List.exists
       (function
         | Core.Publish (Core.State_changed state) ->
           (match state.snapshot.unlock with Core.Unlock_bootstrapping _ -> true | _ -> false)
         | _ -> false)
       bootstrapping.effects);
  Alcotest.(check bool)
    "unlocked graph key resumes snapshot bootstrap"
    true
    (List.exists
       (function
         | Core.Run (Core.Request (_, Core.Fetch_snapshot_metadata _)) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       bootstrapping.effects)
;;

let begin_snapshot_bootstrap ?(graphs = [ graph ]) () =
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
               (Core.Runner_completed (Core.Completion (ticket, Ok graphs))))
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

let snapshot_activation_request effects =
  List.find_map (function Core.Delegate (Core.Activate_snapshot request) -> Some request
    | _ -> None) effects |> Option.get
;;

let snapshot_activation_fixture () =
  let requested, _ = begin_snapshot_bootstrap () in
  let downloading = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
      Some (Core.step requested.next (Core.Runner_completed (Core.Completion
        (ticket, Ok {|{"ok":true,"t":42,"url":"https://example.com/synthetic"}|}))))
    | _ -> None) requested.effects |> Option.get in
  let activating = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Download_snapshot request)) ->
      let artifact = Core.stage_snapshot_download request ~path:"/tmp/synthetic-activation"
        ~expected_rows:1 |> Result.get_ok in
      Some (Core.step downloading.next (Core.Runner_completed (Core.Completion (ticket, Ok artifact))))
    | _ -> None) downloading.effects |> Option.get in
  activating
;;

let fixture_snapshot_activation = lazy (snapshot_activation_request (snapshot_activation_fixture ()).effects)
;;

let snapshot_catchup_fixture () =
  let requested, _scope = begin_snapshot_bootstrap () in
  Alcotest.(check bool)
    "bootstrap starts with exactly one metadata request and no preliminary pull"
    true
    (match List.filter (function Core.Publish _ -> false | _ -> true) requested.effects with
     | [ Core.Run (Core.Request (_, Core.Fetch_snapshot_metadata _)) ] -> true
     | _ -> false);
  let download =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
          Some
            (Core.step
               requested.next
               (Core.Runner_completed
                  (Core.Completion
                     ( ticket
                     , Ok {|{"ok":true,"t":42,"url":"https://example.com/snapshot.sqlite"}|} ))))
        | Run _ | Delegate _ | Publish _ -> None)
      requested.effects
    |> Option.get
  in
  let activated =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Download_snapshot request)) ->
          Alcotest.(check int)
            "download retains configured bound"
            (1024 * 1024)
            (Core.snapshot_download_maximum_bytes request);
          let artifact =
            Core.stage_snapshot_download request ~path:"/tmp/snapshot.sqlite" ~expected_rows:10 |> Result.get_ok
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
  Alcotest.(check cursor_testable)
    "activation uses metadata cursor"
    (server_cursor_of_int 42)
    (Core.snapshot_activation_cursor activation);
  Alcotest.(check bool)
    "plain snapshot has no graph key"
    true
    (Option.is_none (Core.snapshot_activation_key activation));
  Alcotest.(check (option cursor_testable))
    "download completion cannot publish an uncommitted cursor"
    None (Core.state activated.next).snapshot.applied_server_t;
  let activated_snapshot = Core.step activated.next (Core.Snapshot_activated (Core.snapshot_activation_completed activation)) in
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
    Logseq_overlay_db.Types.Server_cursor.of_int64 42L
    |> Result.map_error (fun `Negative_cursor -> "negative cursor")
    |> Result.get_ok
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
       pulling.effects);
  pulling, connection, sync
;;

let cold_start_absent_mirror_reaches_pull_after_snapshot_activation () =
  ignore (snapshot_catchup_fixture ())
;;

let snapshot_baseline_decoder_retains_http_budget () =
  (* Ordinary cursor values and small valid Transit transactions form a valid
     HTTP pull response larger than a WebSocket frame, within the endpoint budget. *)
  let transaction =
    let module Transit = Transit_core.Json in
    Transit_native.Transit.Json.to_string
      (Transit.Array
         [ Transit.Array
             [ Transit.Keyword "db/add"
             ; Transit.Int 1
             ; Transit.Keyword "block/title"
             ; Transit.String (String.make 16_384 'x')
             ]
         ])
  in
  let body =
    Yojson.Safe.to_string
      (`Assoc
          [ "type", `String "pull/ok"
          ; "t", `Int 32
          ; ( "txs"
            , `List
                (List.init 32 (fun index ->
                   `Assoc [ "t", `Int (index + 1); "tx", `String transaction ])) )
          ])
  in
  Alcotest.(check bool)
    (Printf.sprintf
       "ordinary %d-byte HTTP fixture exceeds only the WebSocket budget"
       (String.length body))
    true
    (String.length body > Logseq_db_types.Limits.maximum_response_bytes
     && String.length body <= 64 * 1024 * 1024);
  Alcotest.(check bool)
    "legacy HTTP baseline decoder retains its endpoint budget"
    true
    (Result.is_ok (Logseq_sync_pure_reducer.Sync_protocol.decode_snapshot_baseline body))
;;

let invalid_snapshot_metadata_fails_bootstrap () =
  let requested, _scope = begin_snapshot_bootstrap () in
  let failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
          Some
            (Core.step
               requested.next
               (Core.Runner_completed
                  (Core.Completion (ticket, Ok {|{"ok":true,"t":-1,"url":"https://example.com/snapshot"}|}))))
        | Run _ | Delegate _ | Publish _ -> None)
      requested.effects
    |> Option.get
  in
  let snapshot = (Core.state failed.next).snapshot in
  Alcotest.(check bool)
    "invalid metadata cursor enters failed state"
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
    Overlay.Server_cursor.of_int64 0L
    |> Result.map_error (fun `Negative_cursor -> "negative cursor")
    |> Result.get_ok
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
    ; t = Some (server_cursor_of_int 1)
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
  (* Complete the opening pull before verifying a fresh accepted-submission pull. *)
  let core =
    (Core.step
       core
       (Core.Websocket_message
          ( connection
          , Protocol.Server.Pull_ok
              { t = server_cursor_of_int 0; checksum = None; txs = [] } )))
      .next
  in
  let acknowledged =
    Core.step
      core
      (Core.Websocket_message
         ( connection
         , Logseq_sync_pure_reducer.Sync_protocol.Server.Tx_batch_ok
             { t = server_cursor_of_int 1; checksum = Some "0123456789abcdef" } ))
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
    Overlay.Server_cursor.of_int64 0L
    |> Result.map_error (fun `Negative_cursor -> "negative cursor")
    |> Result.get_ok
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
                }) -> since = Some (server_cursor_of_int 0)
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
  let cursor_diagnostics local remote : Core.diagnostics =
    { groups = [ { Core.title = "Sync transactions"
                 ; entries = [ "Local tx", local; "Remote tx", remote ] } ] }
  in
  let origin = initial () in
  let initial_state = Core.state origin in
  let authenticated_startup =
    { initial_state.snapshot.startup with
      authenticated = true
    ; local_access = Core.Local_pending
    ; network_phase = Core.Online_by_user
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
  let (catalog_ticket, catalog_scope)
    : Core.graph list Core.effect_ticket * Core.account_scope
    =
    match hp01_preview.effects with
    | [ Core.Publish (Core.State_changed state)
      ; Core.Run (Core.Request (ticket, Core.Fetch_catalog scope))
      ]
      when state = authenticated_state && scope.user_id = "user" -> ticket, scope
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
  Alcotest.(check bool) "HP01 full account scope" true (catalog_scope = account_scope);
  let hp01 =
    check_step "HP01" origin hp01_event authenticated_observed hp01_preview.effects
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
      ; (Core.Run (Core.Request (_, Core.Save_catalog { account; cache })) as save_effect)
      ]
      when state = catalogued_state
           && account = account_scope
           && Core.catalog_cache_user_id cache = "user"
           && Core.catalog_cache_graphs cache = [ graph ]
           && Core.catalog_cache_selected_graph cache = None -> save_effect
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
    { account = {account_scope with presentation_generation=2}; graph_id; graph_generation = 1 }
  in
  let selected_startup =
    { catalogued_startup with
      awaiting_selection = false
    ; restoring_local = true
    ; graph_generation = 1
    ; presentation_generation = 2
    }
  in
  let selected_state =
    { Core.diagnostics = cursor_diagnostics "Not available" "Not available"
    ; snapshot =
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
      ; (Core.Run (Core.Request (_, Core.Save_catalog { account; cache })) as save_effect)
      ]
      when (request = Core.{ graph; scope = graph_scope })
           && state = selected_state
           && account = graph_scope.account
           && Core.catalog_cache_user_id cache = "user"
           && Core.catalog_cache_graphs cache = [ graph ]
           && Core.catalog_cache_selected_graph cache = Some graph_id ->
      request, save_effect
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
  let cursor0 = token Overlay.Server_cursor.of_int64 0L in
  let sync_token0 = token Overlay.sync_token_of_string "sync-token:v1:hp-0" in
  let empty_sync0 =
    Overlay.sync_view ~token:sync_token0 ~checkpoint:cursor0 ~submissions:[]
  in
  let attached_startup =
    { selected_startup with restoring_local = false; bootstrapping = false; local_access=Core.Local_available }
  in
  let attached_state =
    { Core.diagnostics = cursor_diagnostics "0" "Not available"
    ; snapshot =
        { selected_state.snapshot with
          sync_phase = Core.Current
        ; applied_server_t = Some (server_cursor_of_int 0)
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
  let hp06_preview = preview_step "HP06" hp05.next hp06_event in
  (match hp06_preview.effects with
   | [ Core.Publish (Core.State_changed state); Core.Run (Core.Start_websocket request) ]
     when state = connecting_state && request = websocket_request -> ()
   | _ -> Alcotest.fail "HP06 unexpected instruction shape");
  let hp06 =
    check_step "HP06" hp05.next hp06_event connecting_observed hp06_preview.effects
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
  let hp08_event = Core.Websocket_opened connection in
  let hp08_preview = preview_step "HP08" hp07.next hp08_event in
  (match hp08_preview.effects with
   | [ Core.Publish (Core.State_changed state)
     ; Core.Run (Core.Send_websocket { scope; message })
     ; Core.Run (Core.Schedule_timer timer)
     ]
     when timer.delay_seconds = 30.
          && timer.scope.connection_generation = Some connection.connection_generation
          && state = pulling0_state
          && scope = connection
          && message = Protocol.Client.Pull { since = Some (server_cursor_of_int 0) } ->
     ()
   | _ -> Alcotest.fail "HP08 unexpected instruction shape");
  let hp08 =
    check_step "HP08" hp07.next hp08_event pulling0_observed hp08_preview.effects
  in
  let remote_tx : Protocol.Server.pull_transaction =
    { t = server_cursor_of_int 1; tx = "[]"; outliner_op = Some "save-block" }
  in
  let opening_message =
    Protocol.Server.Pull_ok
      { t = server_cursor_of_int 1
      ; checksum = Some "0123456789abcdef"
      ; txs = [ remote_tx ]
      }
  in
  let hp09_event = Core.Websocket_message (connection, opening_message) in
  let hp09_preview = preview_step "HP09" hp08.next hp09_event in
  let pulling_remote1_state =
    { pulling0_state with diagnostics = cursor_diagnostics "0" "1" }
  in
  let opening_batch =
    match hp09_preview.effects with
    | [ Core.Delegate (Core.Apply_authoritative_batch request)
      ; Core.Publish (Core.State_changed state) ]
      when request.scope = connection
           && state = pulling_remote1_state
           && request.presentation_generation = 2
           && request.lifecycle_generation = 0L
           && request.key = None
           && Overlay.Server_cursor.to_int64
                (Overlay.authoritative_batch_through request.input)
              = 1L
           && List.length (Overlay.authoritative_batch_transactions request.input) = 1 ->
      request
    | _ -> Alcotest.fail "HP09 unexpected instruction shape"
  in
  let hp09 =
    check_step
      "HP09"
      hp08.next
      hp09_event
      { pulling0_observed with state = pulling_remote1_state }
      [ Core.Delegate (Core.Apply_authoritative_batch opening_batch)
      ; Core.Publish (Core.State_changed pulling_remote1_state) ]
  in
  let generation1 = token Overlay.Generation.of_string "generation:v1:hp-1" in
  let projection1 = token Overlay.Projection_revision.of_string "projection:v1:1" in
  let cursor1 = token Overlay.Server_cursor.of_int64 1L in
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
    { Core.diagnostics = cursor_diagnostics "1" "1"
    ; snapshot =
        { pulling0_state.snapshot with
          sync_phase = Core.Current
        ; applied_server_t = Some (server_cursor_of_int 1)
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
      ; t_before = server_cursor_of_int 1
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
  let hp13_preview = preview_step "HP13" hp12.next hp13_event in
  let hp13 =
    (match hp13_preview.effects with
     | [ Core.Run (Core.Send_websocket { scope; message })
       ; Core.Run (Core.Schedule_timer timer)
       ]
       when scope = connection
            && message = tx_message
            && timer.delay_seconds = 30.
            && timer.scope.connection_generation = Some connection.connection_generation
       -> ()
     | _ -> Alcotest.fail "HP13 submission omitted its scoped response timeout");
    check_step "HP13" hp12.next hp13_event submitting_observed hp13_preview.effects
  in
  let hp14_event =
    Core.Websocket_message
      ( connection
      , Protocol.Server.Tx_batch_ok
          { t = server_cursor_of_int 2; checksum = Some "fedcba9876543210" } )
  in
  let hp14_preview = preview_step "HP14" hp13.next hp14_event in
  let acknowledged_state =
    { submitting_state with diagnostics = cursor_diagnostics "1" "2" }
  in
  let accept_request =
    match hp14_preview.effects with
    | [ Core.Delegate (Core.Apply_outbox_transition request)
      ; Core.Publish (Core.State_changed state) ]
      when request.scope = graph_scope
           && state = acknowledged_state
           && request.key = None
           && Overlay.sync_token_equal request.expected sync_token2
           && request.transition
              = Overlay.Accept_group
                  { batch_id
                  ; barrier =
                      { through = token Overlay.Server_cursor.of_int64 2L
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
      { submitting_observed with state = acknowledged_state }
      [ Core.Delegate (Core.Apply_outbox_transition accept_request)
      ; Core.Publish (Core.State_changed acknowledged_state) ]
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
    { Core.diagnostics = cursor_diagnostics "1" "2"
    ; snapshot = { submitting_state.snapshot with sync_phase = Core.Pulling }
    }
  in
  let pulling1_observed =
    { state = pulling1_state; admitted_graph_scope = Some graph_scope }
  in
  let hp15_event =
    Core.Outbox_transition_applied
      { scope = accept_request.scope; commit = accept_commit; sync = accepted_sync }
  in
  let hp15_preview = preview_step "HP15" hp14.next hp15_event in
  (match hp15_preview.effects with
   | [ Core.Publish (Core.State_changed state)
     ; Core.Run (Core.Send_websocket { scope; message })
     ; Core.Run (Core.Schedule_timer timer)
     ]
     when timer.delay_seconds = 30.
          && timer.scope.connection_generation = Some connection.connection_generation
          && state = pulling1_state
          && scope = connection
          && message = Protocol.Client.Pull { since = Some (server_cursor_of_int 1) } ->
     ()
   | _ -> Alcotest.fail "HP15 unexpected instruction shape");
  let hp15 =
    check_step "HP15" hp14.next hp15_event pulling1_observed hp15_preview.effects
  in
  let incorporated_tx : Protocol.Server.pull_transaction =
    { t = server_cursor_of_int 2; tx = "[]"; outliner_op = Some "save-block" }
  in
  let confirmation_message =
    Protocol.Server.Pull_ok
      { t = server_cursor_of_int 2
      ; checksum = Some "fedcba9876543210"
      ; txs = [ incorporated_tx ]
      }
  in
  let hp16_event = Core.Websocket_message (connection, confirmation_message) in
  let hp16_preview = preview_step "HP16" hp15.next hp16_event in
  let confirmation_batch =
    match hp16_preview.effects with
    | [ Core.Delegate (Core.Apply_authoritative_batch request) ]
      when request.scope = connection
           && request.presentation_generation = 2
           && request.lifecycle_generation = 0L
           && request.key = None
           && Overlay.Server_cursor.to_int64
                (Overlay.authoritative_batch_through request.input)
              = 2L
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
  let cursor2 = token Overlay.Server_cursor.of_int64 2L in
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
    { Core.diagnostics = cursor_diagnostics "2" "2"
    ; snapshot =
        { pulling1_state.snapshot with
          sync_phase = Core.Current
        ; applied_server_t = Some (server_cursor_of_int 2)
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
    Overlay.Server_cursor.of_int64 0L
    |> Result.map_error (fun `Negative_cursor -> "negative cursor")
    |> Result.get_ok
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
  let login=Core.step signed_out_again.next (Core.Sign_in_requested (startup_scope signed_out_again.next)) in
  let replacement =
    Core.step login.next (Core.Account_authenticated { user_id = Some "new-user" })
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
  let downloading =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
          Some
            (Core.step
               absent.next
               (Core.Runner_completed
                  (Core.Completion
                     ( ticket
                     , Ok {|{"ok":true,"t":42,"url":"https://example.com/snapshot.sqlite"}|} ))))
        | _ -> None)
      absent.effects
    |> Option.get
  in
  let activating =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Download_snapshot download_request)) ->
          let artifact =
            Core.stage_snapshot_download download_request ~path:"/tmp/snapshot.sqlite" ~expected_rows:10 |> Result.get_ok
          in
          Some
            (Core.step
               downloading.next
               (Core.Runner_completed (Core.Completion (ticket, Ok artifact))))
        | _ -> None)
      downloading.effects
    |> Option.get
  in
  let activated = Core.step activating.next (Core.Snapshot_activated
    (Core.snapshot_activation_completed (snapshot_activation_request activating.effects))) in
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
    Overlay.Server_cursor.of_int64 0L
    |> Result.map_error (fun `Negative_cursor -> "negative cursor")
    |> Result.get_ok
  in
  let sync = Overlay.sync_view ~token ~checkpoint ~submissions:[] in
  let attached = Core.step attaching.next (Core.Graph_attached { scope; sync }) in
  let ready = Core.step attached.next (Core.Timeline_presented (timeline_scope attached.next)) in
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
  let request = List.find_map
    (function
      | Core.Delegate (Core.Delete_mirror request) -> Some request
      | _ -> None)
    effects in
  match request with
  | Some request -> request
  | None -> Alcotest.fail "non-current deletion must delegate mirror removal"
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

let deletion_blocked_events (scope : Core.graph_scope) sync =
  [ Core.Local_cache_deletion_requested graph_id
  ; Core.Local_cache_deletion_requested other_graph_id
  ; Core.Graph_selected graph_id
  ; Core.Graph_selected other_graph_id
  ; Core.Graph_picker_requested
  ; Core.Online_recovery_requested {startup={account_generation=scope.account.account_generation;presentation_generation=scope.account.presentation_generation};graph_id=scope.graph_id;graph_generation=scope.graph_generation}
  ; Core.Local_outbox_changed
  ; Core.Local_feed_acknowledged
  ; Core.Timeline_presented {startup={account_generation=scope.account.account_generation;presentation_generation=scope.account.presentation_generation};graph_id=scope.graph_id;graph_generation=scope.graph_generation}
  ; Core.Catalog_refresh_requested {account_generation=scope.account.account_generation;presentation_generation=scope.account.presentation_generation}
  ; Core.Account_authenticated { user_id = Some "user" }
  ; Core.E2ee_password_submitted (Lazy.force fixture_challenge, "ignored")
  ; Core.Foreground_changed { foreground = true; lifecycle_generation = 98L }
  ; Core.Foreground_changed { foreground = false; lifecycle_generation = 99L }
  ; Core.Graph_attached { scope; sync }
  ; Core.Sync_inspected { scope; sync }
  ; Core.Snapshot_activated (Core.snapshot_activation_completed (Lazy.force fixture_snapshot_activation))
  ; Core.Mirror_inspected (Core.Mirror_available { graph; scope })
  ; Core.Websocket_opened { graph = scope; connection_generation = 1 }
  ; Core.Websocket_closed
      ({ graph = scope; connection_generation = 1 }, Core.Recoverable_close { message = Some "late"; attention = Requires_attention })
  ]
;;

let deletion_noncurrent core =
  let target = List.find (fun (candidate : Core.graph) -> candidate.graph_id = graph_id)
      (Core.state core).snapshot.catalog in
  let catalog = refresh_catalog core [ target; other_graph ] in
  let selected = Core.step catalog.next (Core.Graph_selected other_graph_id) in
  let request = inspect_mirror_request selected.effects in
  let inspected = Core.step selected.next (Core.Mirror_inspected (Core.Mirror_available request)) in
  let token = Overlay.sync_token_of_string "sync-token:v1:noncurrent" |> Result.get_ok in
  let sync = Overlay.sync_view ~token ~checkpoint:(server_cursor_of_int 0) ~submissions:[] in
  let attached = Core.step inspected.next (Core.Graph_attached { scope = request.scope; sync }) in
  let ready = Core.step attached.next (Core.Timeline_presented (timeline_scope attached.next)) in
  ready.next, request.scope, sync, selected.effects
;;

let local_deletion_orders_cleanup encrypted () =
  let original, old_scope, _, _ = deletion_ready_graph encrypted in
  let ready, scope, sync, selection_effects = deletion_noncurrent original in
  check_no_work ready [ Core.Local_cache_deletion_requested other_graph_id ];
  let deleting = Core.step ready (Core.Local_cache_deletion_requested graph_id) in
  check_deletion_stage Deleting_mirror deleting.next;
  let request = deletion_mirror deleting.effects in
  Alcotest.(check bool) "target differs from current" true
    (request.graph_id = graph_id && scope.graph_id = other_graph_id);
  Alcotest.(check bool) "selected graph and admitted session remain unchanged" true
    ((Core.state deleting.next).snapshot.selected_graph = Some other_graph_id
     && Core.admitted_graph_scope deleting.next = Some scope);
  Alcotest.(check bool) "no active graph close or remote request" true
    (List.for_all (function Core.Delegate (Core.Delete_mirror _) | Core.Publish _ -> true | _ -> false) deleting.effects);
  check_no_work deleting.next
    [ Core.Local_cache_deletion_requested graph_id; Core.Local_cache_deletion_requested other_graph_id ];
  let stale = { request with scope = { request.scope with lifecycle_generation = Some 99999L } } in
  check_no_work deleting.next [ Core.Mirror_deleted (stale, Ok ()); Core.Graph_detached (old_scope, Ok ()) ];
  let removed = Core.step deleting.next (Core.Mirror_deleted (request, Ok ())) in
  let snapshot = (Core.state removed.next).snapshot in
  Alcotest.(check bool) "success retains current and catalog" true
    (snapshot.selected_graph = Some other_graph_id && snapshot.local_deletion = None
     && snapshot.catalog = (Core.state ready).snapshot.catalog
     && Core.admitted_graph_scope removed.next = Some scope && snapshot.last_error = None);
  check_no_work removed.next [ Core.Mirror_deleted (request, Ok ()); Core.Graph_detached (old_scope, Ok ()) ];
  let cache = save_catalog_cache selection_effects in
  Alcotest.(check bool) "saved selection remains the other graph" true
    (Core.catalog_cache_selected_graph cache = Some other_graph_id);
  let restarting = Core.step (initial ()) (Core.Restore_local_account { user_id = "user" }) in
  let restored = Core.step restarting.next (load_catalog_completion restarting.effects (Some cache)) in
  Alcotest.(check bool) "restart restores unchanged selection" true
    ((Core.state restored.next).snapshot.selected_graph = Some other_graph_id);
  let selected = Core.step removed.next (Core.Graph_selected graph_id) in
  let mirror = inspect_mirror_request selected.effects in
  let requested=Core.step selected.next (Core.Online_recovery_requested (timeline_scope selected.next)) in
  let absent = Core.step requested.next (Core.Mirror_inspected (Core.Mirror_absent mirror.scope)) in
  Alcotest.(check bool) "explicit download of deleted graph uses normal absent-mirror flow" true
    (List.exists (function
       | Core.Run (Core.Request (_, Core.Fetch_snapshot_metadata _)) -> not encrypted
       | Core.Run (Core.Request (_, Core.Load_and_unlock_graph_key _)) -> encrypted
       | _ -> false) absent.effects);
  let _ = sync in
  ()
;;

let local_deletion_discards_unsynchronized_work () =
  let submitted, connection = submitted_core () in
  Alcotest.(check bool) "fixture has unacknowledged work" true
    ((Core.state submitted).snapshot.sync_phase = Core.Submitting);
  let ready, scope, _, _ = deletion_noncurrent submitted in
  let deleting = Core.step ready (Core.Local_cache_deletion_requested graph_id) in
  let request = deletion_mirror deleting.effects in
  Alcotest.(check bool) "confirmed deletion does not wait for upload" true
    (request.graph_id = graph_id
     && Core.admitted_graph_scope deleting.next = Some scope
     && List.for_all (function Core.Publish _ | Core.Delegate (Core.Delete_mirror _) -> true | _ -> false) deleting.effects);
  check_no_work deleting.next
    [ Core.Websocket_message (connection, Protocol.Server.Tx_batch_ok
        { t = server_cursor_of_int 1; checksum = Some "0123456789abcdef" }) ];
  let removed = Core.step deleting.next (Core.Mirror_deleted (request, Ok ())) in
  Alcotest.(check bool) "unsynced discard completes locally" true
    ((Core.state removed.next).snapshot.local_deletion = None)
;;

let local_deletion_failures_stop encrypted () =
  let original, _, _, _ = deletion_ready_graph encrypted in
  let ready, scope, _, _ = deletion_noncurrent original in
  let deleting = Core.step ready (Core.Local_cache_deletion_requested graph_id) in
  let request = deletion_mirror deleting.effects in
  let failed = Core.step deleting.next (Core.Mirror_deleted (request, Error "secret path")) in
  let snapshot = (Core.state failed.next).snapshot in
  Alcotest.(check bool) "failure releases the flight and retains current session" true
    (snapshot.local_deletion = None && snapshot.selected_graph = Some other_graph_id
     && Core.admitted_graph_scope failed.next = Some scope);
  Alcotest.(check (option string)) "failure is sanitized"
    (Some "Local graph deletion failed. Try again.") snapshot.last_error;
  let retry = Core.step failed.next (Core.Local_cache_deletion_requested graph_id) in
  let retry_request = deletion_mirror retry.effects in
  Alcotest.(check bool) "retry has a distinct identity" true (retry_request <> request);
  check_no_work retry.next [ Core.Mirror_deleted (request, Ok ()); Core.Mirror_deleted (request, Error "late") ];
  let recovered = Core.step retry.next (Core.Mirror_deleted (retry_request, Ok ())) in
  Alcotest.(check bool) "retry recovers" true ((Core.state recovered.next).snapshot.last_error = None);
  let reopened = Core.step failed.next (Core.Graph_selected graph_id) in
  Alcotest.(check bool) "failed deletion can reopen intact graph" true
    ((inspect_mirror_request reopened.effects).graph.graph_id = graph_id)
;;

let local_deletion_account_change_fences_completion () =
  let original, _, _, _ = deletion_ready_graph false in
  let ready, _, _, _ = deletion_noncurrent original in
  let deleting = Core.step ready (Core.Local_cache_deletion_requested graph_id) in
  let request = deletion_mirror deleting.effects in
  let changed = Core.step deleting.next (Core.Account_authenticated { user_id = Some "another-user" }) in
  Alcotest.(check bool) "account change retires deletion" true
    ((Core.state changed.next).snapshot.startup.account_generation
      > (Core.state deleting.next).snapshot.startup.account_generation
     && (Core.state changed.next).snapshot.local_deletion = None);
  check_no_work changed.next [ Core.Mirror_deleted (request, Ok ()); Core.Mirror_deleted (request, Error "late") ]
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
  let shown=Core.step attached.next (Core.Timeline_presented (timeline_scope attached.next)) in
  let authenticated=Core.step shown.next (Core.Account_authenticated {user_id=Some "user"}) in
  let connection = recovery_connection authenticated.effects in
  let opened = Core.step authenticated.next (Core.Websocket_opened connection) in
  opened.next, connection
;;

let recovery_delete_transaction =
  "[[\"~:db/retractEntity\",[\"~:block/uuid\",\"~u11111111-1111-4111-8111-111111111111\"]]]"
;;

let submitted_delete_recovery_fixture () =
  let mutation_id = List.hd mutation_ids in
  let cursor =
    Overlay.Server_cursor.of_int64 0L
    |> Result.map_error (fun `Negative_cursor -> "negative cursor")
    |> Result.get_ok
  in
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
             { t = server_cursor_of_int 1
             ; checksum = Some "0123456789abcdef"
             ; txs =
                 [ { t = server_cursor_of_int 1
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
         , Protocol.Server.Tx_batch_ok
             { t = server_cursor_of_int 1; checksum = Some "0123456789abcdef" } ))
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
  Overlay.Server_cursor.of_int64 (Int64.of_int n)
  |> Result.map_error (fun `Negative_cursor -> "negative cursor")
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
     Alcotest.(check cursor_testable)
       "retry retains conditional baseline"
       (server_cursor_of_int 0)
       t_before;
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
        ; t = Some (server_cursor_of_int 1)
        ; checksum = Some "0123456789abcdef"
        ; success_tx_ids = []
        ; failed_tx_id = None
        ; missing_block_uuids = []
        ; error_detail = None
        ; data = None
        }
    else
      Protocol.Server.Tx_batch_ok
        { t = server_cursor_of_int 1; checksum = Some "0123456789abcdef" }
  in
  let terminal = Core.step retried.next (Core.Websocket_message (connection, response)) in
  let request = recovery_request terminal.effects in
  let state =
    if reject
    then
      Overlay.Stale_rejected_pending_authoritative
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
  Alcotest.(check (option cursor_testable))
    "recovery advances the durable checkpoint"
    (Some (server_cursor_of_int 1))
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

let restart_after_retirement core connection =
  let retired = Core.step core (Core.Websocket_retired connection) in
  let timer =
    List.find_map
      (function
        | Core.Run (Core.Schedule_timer timer) -> Some timer
        | _ -> None)
      retired.effects
    |> Option.get
  in
  Core.step retired.next (Core.Timer_elapsed timer.id)
;;

let submitted_delete_survives_disconnect_reconnect () =
  let submitted, connection, sync, wire_batch = submitted_delete_recovery_fixture () in
  let closed =
    Core.step
      submitted.next
      (Core.Websocket_closed (connection, Core.Recoverable_close { message = None; attention = Requires_attention }))
  in
  let restarting = restart_after_retirement closed.next connection in
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
  Alcotest.(check (option cursor_testable))
    "fresh Core restores the durable checkpoint"
    (Some (server_cursor_of_int 0))
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
         ( connection
         , Protocol.Server.Pull_ok
             { t = server_cursor_of_int 0; checksum = None; txs = [] } ))
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
      Overlay.Stale_rejected_pending_authoritative
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
         ( connection
         , Protocol.Server.Pull_ok
             { t = server_cursor_of_int 0; checksum = None; txs = [] } ))
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
  let closed =
    Core.step retry.next (Core.Websocket_closed (connection, Core.Recoverable_close { message = None; attention = Requires_attention }))
  in
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
  let restarted = restart_after_retirement committed.next connection in
  let new_connection = recovery_connection restarted.effects in
  let opened = Core.step restarted.next (Core.Websocket_opened new_connection) in
  let late =
    Core.step
      opened.next
      (Core.Websocket_message
         ( old_connection
         , Protocol.Server.Tx_batch_ok
             { t = server_cursor_of_int 1; checksum = Some "0123456789abcdef" } ))
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
  let retired = Core.step expired.next (Core.Websocket_retired connection) in
  let new_connection = recovery_connection retired.effects in
  let opened = Core.step retired.next (Core.Websocket_opened new_connection) in
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
         , Protocol.Server.Tx_batch_ok
             { t = server_cursor_of_int 1; checksum = Some "0123456789abcdef" } ))
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
         , Protocol.Server.Tx_batch_ok
             { t = server_cursor_of_int 1; checksum = Some "0123456789abcdef" } ))
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

let pull_sends effects =
  List.filter_map
    (function
      | Core.Run (Core.Send_websocket { scope; message = Protocol.Client.Pull { since } })
        -> Some (scope, since)
      | _ -> None)
    effects
;;

let check_pull_count message expected effects =
  Alcotest.(check int) message expected (List.length (pull_sends effects))
;;

let pull_timer effects =
  let timers =
    List.filter_map
      (function
        | Core.Run (Core.Schedule_timer timer) -> Some timer
        | _ -> None)
      effects
  in
  Alcotest.(check int) "one bounded pull timer" 1 (List.length timers);
  List.hd timers
;;

let pull_fixture () =
  let selected, _ = selected_graph graph in
  let mirror = inspect_mirror_request selected.effects in
  let inspected =
    Core.step selected.next (Core.Mirror_inspected (Core.Mirror_available mirror))
  in
  let sync =
    Overlay.sync_view
      ~token:(token Overlay.sync_token_of_string "sync-token:v1:pull-0")
      ~checkpoint:(recovery_cursor 0)
      ~submissions:[]
  in
  let attached =
    Core.step inspected.next (Core.Graph_attached { scope = mirror.scope; sync })
  in
  let connection = recovery_connection attached.effects in
  Core.step attached.next (Core.Websocket_opened connection), connection, sync
;;

let pull_message core connection message =
  Core.step core (Core.Websocket_message (connection, message))
;;

let pull_response core connection ~after through =
  let txs =
    List.init (through - after) (fun offset ->
      { Protocol.Server.t = server_cursor_of_int (after + offset + 1)
      ; tx = "[]"
      ; outliner_op = None
      })
  in
  pull_message
    core
    connection
    (Protocol.Server.Pull_ok { t = server_cursor_of_int through; checksum = None; txs })
;;

let pull_open_and_notifications_are_singleflight () =
  let opened, connection, _ = pull_fixture () in
  check_pull_count "opening baseline pull" 1 opened.effects;
  let hello =
    pull_message
      opened.next
      connection
      (Protocol.Server.Hello { t = server_cursor_of_int 100; checksum = None })
  in
  check_pull_count "hello joins the opening pull" 0 hello.effects;
  let state = ref hello.next in
  for t = 1 to 100 do
    let changed =
      pull_message
        !state
        connection
        (Protocol.Server.Changed { t = server_cursor_of_int t })
    in
    check_pull_count "notification burst joins the same pull" 0 changed.effects;
    state := changed.next
  done;
  Alcotest.(check (option cursor_testable))
    "notifications cannot advance the durable checkpoint"
    (Some (server_cursor_of_int 0))
    (Core.state !state).snapshot.applied_server_t
;;

let pull_demand_survives_authoritative_apply () =
  let opened, connection, sync = pull_fixture () in
  let notified =
    pull_message
      opened.next
      connection
      (Protocol.Server.Changed { t = server_cursor_of_int 1 })
  in
  let received = pull_response notified.next connection ~after:0 1 in
  let state = ref received.next in
  for index = 1 to 100 do
    let t = index + 1 in
    let changed =
      pull_message
        !state
        connection
        (Protocol.Server.Changed { t = server_cursor_of_int t })
    in
    check_pull_count "apply owns the pull until durable completion" 0 changed.effects;
    state := changed.next
  done;
  let committed =
    recovery_apply !state connection (recovery_sync sync ~checkpoint:1 1 [])
  in
  Alcotest.(check bool)
    "latest target schedules one pull from committed cursor"
    true
    (pull_sends committed.effects = [ connection, Some (server_cursor_of_int 1) ]);
  Alcotest.(check bool)
    "catchup owner is represented by Pulling phase"
    true
    ((Core.state committed.next).snapshot.sync_phase = Core.Pulling);
  Alcotest.(check bool)
    "catchup phase is publicly published"
    true
    (List.exists
       (function
         | Core.Publish (Core.State_changed state) ->
           state.snapshot.sync_phase = Core.Pulling
         | _ -> false)
       committed.effects);
  let received = pull_response committed.next connection ~after:1 2 in
  let committed =
    recovery_apply received.next connection (recovery_sync sync ~checkpoint:2 2 [])
  in
  Alcotest.(check bool)
    "partial catchup cannot drop the maximum requested target"
    true
    (pull_sends committed.effects = [ connection, Some (server_cursor_of_int 2) ]);
  (* This pure policy test uses a sparse page to acknowledge the newest target.
     The overlay separately enforces contiguous durable application. *)
  let received =
    pull_message
      committed.next
      connection
      (Protocol.Server.Pull_ok
         { t = server_cursor_of_int 101
         ; checksum = None
         ; txs =
             [ { Protocol.Server.t = server_cursor_of_int 101
               ; tx = "[]"
               ; outliner_op = None
               }
             ]
         })
  in
  let committed =
    recovery_apply received.next connection (recovery_sync sync ~checkpoint:101 3 [])
  in
  Alcotest.(check (option cursor_testable))
    "latest checkpoint is durably acknowledged"
    (Some (server_cursor_of_int 101))
    (Core.state committed.next).snapshot.applied_server_t;
  check_pull_count "caught up exactly to latest target" 0 committed.effects;
  let stale =
    pull_message
      committed.next
      connection
      (Protocol.Server.Changed { t = server_cursor_of_int 100 })
  in
  check_pull_count "old notifications need no pull" 0 stale.effects;
  let same =
    pull_message
      stale.next
      connection
      (Protocol.Server.Changed { t = server_cursor_of_int 101 })
  in
  check_pull_count "same cursor notification needs no pull" 0 same.effects
;;

let pull_no_progress_is_delayed_and_bounded () =
  let opened, connection, _ = pull_fixture () in
  (* The opening response alone can report demand, without Hello/Changed. *)
  let state = ref opened.next in
  let previous_delay = ref 0. in
  for round = 1 to 12 do
    let reported_head = if round mod 2 = 1 then 10 else 0 in
    let empty =
      pull_message
        !state
        connection
        (Protocol.Server.Pull_ok
           { t = server_cursor_of_int reported_head; checksum = None; txs = [] })
    in
    Alcotest.(check (option cursor_testable))
      "empty response cannot advance durable checkpoint"
      (Some (server_cursor_of_int 0))
      (Core.state empty.next).snapshot.applied_server_t;
    check_pull_count "no progress cannot immediately repeat the pull" 0 empty.effects;
    Alcotest.(check bool)
      "pending demand during retry is still Pulling"
      true
      ((Core.state empty.next).snapshot.sync_phase = Core.Pulling);
    Alcotest.(check bool)
      "retry delay cannot publish false Current"
      true
      (List.for_all
         (function
           | Core.Publish (Core.State_changed state) ->
             state.snapshot.sync_phase <> Core.Current
           | _ -> true)
         empty.effects);
    let timer = pull_timer empty.effects in
    Alcotest.(check bool)
      "retry delay is positive, bounded, and does not decrease"
      true
      (timer.delay_seconds >= 1.
       && timer.delay_seconds <= 30.
       && timer.delay_seconds >= !previous_delay);
    previous_delay := timer.delay_seconds;
    let notified =
      pull_message
        empty.next
        connection
        (Protocol.Server.Changed { t = server_cursor_of_int 10 })
    in
    check_pull_count "notifications cannot bypass retry delay" 0 notified.effects;
    let retried = Core.step notified.next (Core.Timer_elapsed timer.id) in
    Alcotest.(check bool)
      "retry retains demand and original durable cursor"
      true
      (pull_sends retried.effects = [ connection, Some (server_cursor_of_int 0) ]);
    let duplicate = Core.step retried.next (Core.Timer_elapsed timer.id) in
    check_instructions "retry timer is consumed once" [] duplicate.effects;
    state := duplicate.next
  done
;;

let pull_timeout_reconnects_and_fences_old_work () =
  let opened, connection, _ = pull_fixture () in
  let timer = pull_timer opened.effects in
  Alcotest.(check bool)
    "response timeout is finite and positive"
    true
    (Float.is_finite timer.delay_seconds && timer.delay_seconds > 0.);
  let expired = Core.step opened.next (Core.Timer_elapsed timer.id) in
  Alcotest.(check bool)
    "response timeout closes its exact connection"
    true
    (List.exists
       (function
         | Core.Run (Core.Close_websocket scope) -> scope = connection
         | _ -> false)
       expired.effects);
  let retired = Core.step expired.next (Core.Websocket_retired connection) in
  let replacement = recovery_connection retired.effects in
  let reopened = Core.step retired.next (Core.Websocket_opened replacement) in
  check_pull_count "reconnect starts one fresh baseline pull" 1 reopened.effects;
  let old_timeout = Core.step reopened.next (Core.Timer_elapsed timer.id) in
  check_instructions "old timeout cannot clear replacement owner" [] old_timeout.effects;
  let old_response = pull_response old_timeout.next connection ~after:0 1 in
  check_instructions "old connection response is inert" [] old_response.effects;
  let changed =
    pull_message
      old_response.next
      replacement
      (Protocol.Server.Changed { t = server_cursor_of_int 2 })
  in
  check_pull_count "replacement still owns its single pull" 0 changed.effects
;;

let pull_response_timer_does_not_interrupt_apply () =
  let opened, connection, sync = pull_fixture () in
  let timer = pull_timer opened.effects in
  let received = pull_response opened.next connection ~after:0 1 in
  let late_timer = Core.step received.next (Core.Timer_elapsed timer.id) in
  check_instructions
    "response arrived before timer while apply remains active"
    []
    late_timer.effects;
  let changed =
    pull_message
      late_timer.next
      connection
      (Protocol.Server.Changed { t = server_cursor_of_int 2 })
  in
  check_pull_count "notification waits for durable apply" 0 changed.effects;
  let committed =
    recovery_apply changed.next connection (recovery_sync sync ~checkpoint:1 1 [])
  in
  Alcotest.(check bool)
    "apply completion releases exactly one catchup"
    true
    (pull_sends committed.effects = [ connection, Some (server_cursor_of_int 1) ])
;;

let pull_terminal_outcome_joins_existing_round ~reject () =
  let core, connection = submitted_core () in
  let response =
    if reject
    then
      Protocol.Server.Tx_reject
        { reason = Protocol.Stale
        ; t = Some (server_cursor_of_int 1)
        ; checksum = Some "0123456789abcdef"
        ; success_tx_ids = []
        ; failed_tx_id = None
        ; missing_block_uuids = []
        ; error_detail = None
        ; data = None
        }
    else
      Protocol.Server.Tx_batch_ok
        { t = server_cursor_of_int 1; checksum = Some "0123456789abcdef" }
  in
  let terminal = pull_message core connection response in
  let request = recovery_request terminal.effects in
  let sync =
    Overlay.sync_view
      ~token:request.expected
      ~checkpoint:(recovery_cursor 0)
      ~submissions:[]
  in
  let committed = Core.step terminal.next (recovery_commit request sync None) in
  check_pull_count
    "terminal outbox completion joins already outstanding pull"
    0
    committed.effects;
  let empty = pull_response committed.next connection ~after:0 0 in
  check_pull_count "unresolved acceptance or rejection target cannot spin" 0 empty.effects;
  let timer = pull_timer empty.effects in
  let catchup = Core.step empty.next (Core.Timer_elapsed timer.id) in
  Alcotest.(check bool)
    "terminal outcome target survives until catchup"
    true
    (pull_sends catchup.effects = [ connection, Some (server_cursor_of_int 0) ])
;;

let pull_terminal_barrier_already_applied_is_current ~reject () =
  List.iter
    (fun through ->
       let core, connection = submitted_core () in
       let received = pull_response core connection ~after:0 1 in
       let sync =
         Overlay.sync_view
           ~token:(Overlay.sync_token_of_string "sync-token:v1:F5-phase" |> Result.get_ok)
           ~checkpoint:(recovery_cursor 1)
           ~submissions:[]
       in
       (* This is a public durable completion fact, not a SQLite/checksum test. *)
       let applied = recovery_apply received.next connection sync in
       let response =
         if reject
         then
           Protocol.Server.Tx_reject
             { reason = Protocol.Stale
             ; t = Some through
             ; checksum = Some "0123456789abcdef"
             ; success_tx_ids = []
             ; failed_tx_id = None
             ; missing_block_uuids = []
             ; error_detail = None
             ; data = None
             }
         else
           Protocol.Server.Tx_batch_ok { t = through; checksum = Some "0123456789abcdef" }
       in
       let terminal = pull_message applied.next connection response in
       let request = recovery_request terminal.effects in
       let completed = Core.step terminal.next (recovery_commit request sync None) in
       check_pull_count "already applied barrier needs no new pull" 0 completed.effects;
       Alcotest.(check bool)
         "completed barrier remains Current without a future response"
         true
         ((Core.state completed.next).snapshot.sync_phase = Core.Current);
       Alcotest.(check bool)
         "published terminal phase matches the settled owner"
         true
         (List.exists
            (function
              | Core.Publish (Core.State_changed state) ->
                state.snapshot.sync_phase = Core.Current
              | _ -> false)
            completed.effects))
    [ server_cursor_of_int 0; server_cursor_of_int 1 ]
;;

let pull_shutdown_and_graph_retirement_cancel_demand () =
  let opened, connection, _ = pull_fixture () in
  let timer = pull_timer opened.effects in
  List.iter
    (fun event ->
       let retired = Core.step opened.next event in
       let late_timer = Core.step retired.next (Core.Timer_elapsed timer.id) in
       check_instructions "retired graph timer is inert" [] late_timer.effects;
       let late_changed =
         pull_message
           late_timer.next
           connection
           (Protocol.Server.Changed { t = server_cursor_of_int 20 })
       in
       check_instructions "retired graph demand is inert" [] late_changed.effects;
       let late_response = pull_response late_changed.next connection ~after:0 1 in
       check_instructions "retired graph response is inert" [] late_response.effects)
    [ Core.Shutdown; Core.Graph_picker_requested ]
;;

let pull_singleflight_scenarios =
  [ Alcotest.test_case
      "F5 opening and notification burst share one pull"
      `Quick
      pull_open_and_notifications_are_singleflight
  ; Alcotest.test_case
      "F5 newest demand survives authoritative apply"
      `Quick
      pull_demand_survives_authoritative_apply
  ; Alcotest.test_case
      "F5 no progress has bounded reducer retry delay"
      `Quick
      pull_no_progress_is_delayed_and_bounded
  ; Alcotest.test_case
      "F5 response timeout reconnects and fences old work"
      `Quick
      pull_timeout_reconnects_and_fences_old_work
  ; Alcotest.test_case
      "F5 response timer cannot interrupt durable apply"
      `Quick
      pull_response_timer_does_not_interrupt_apply
  ; Alcotest.test_case
      "F5 acceptance joins an outstanding pull"
      `Quick
      (pull_terminal_outcome_joins_existing_round ~reject:false)
  ; Alcotest.test_case
      "F5 rejection joins an outstanding pull"
      `Quick
      (pull_terminal_outcome_joins_existing_round ~reject:true)
  ; Alcotest.test_case
      "F5 completed acceptance barrier is Current"
      `Quick
      (pull_terminal_barrier_already_applied_is_current ~reject:false)
  ; Alcotest.test_case
      "F5 completed rejection barrier is Current"
      `Quick
      (pull_terminal_barrier_already_applied_is_current ~reject:true)
  ; Alcotest.test_case
      "F5 shutdown and picker retire pending pull demand"
      `Quick
      pull_shutdown_and_graph_retirement_cancel_demand
  ]
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
  @ pull_singleflight_scenarios
;;

let rejected_submission_feedback () =
  let core, connection = submitted_core () in
  let rejection : Protocol.rejection =
    { reason = Db_transact_failed
    ; t = Some (server_cursor_of_int 0)
    ; checksum = None
    ; success_tx_ids = []
    ; failed_tx_id = Some (List.hd mutation_ids)
    ; missing_block_uuids = []
    ; error_detail = Some "transaction validation failed"
    ; data = None
    }
  in
  let rejected =
    Core.step
      core
      (Core.Websocket_message (connection, Protocol.Server.Tx_reject rejection))
  in
  let message = (Core.state rejected.next).snapshot.last_error in
  Alcotest.(check bool) "definitive rejection is visible" true (Option.is_some message);
  Alcotest.(check bool)
    "rejection publishes feedback"
    true
    (List.exists
       (function
         | Core.Publish (Core.State_changed state) -> state.snapshot.last_error = message
         | _ -> false)
       rejected.effects);
  Alcotest.(check bool)
    "rejection does not turn a usable graph into startup failure"
    true
    ((Core.state rejected.next).snapshot.startup.failure = None);
  let request = recovery_request rejected.effects in
  let submissions =
    List.map
      (fun mutation_id ->
         { Overlay.mutation_id
         ; fingerprint =
             Overlay.Mutation_fingerprint.of_string
               ("mutation-fingerprint:v1:"
                ^ Logseq_db_types.Graph_types.Uuid.to_string mutation_id)
             |> Result.get_ok
         ; state = Overlay.Blocked
         ; dependency_eligible = false
         ; attempt_count = 1
         ; plaintext_bytes = 16
         ; protected_bytes = Some 16
         })
      mutation_ids
  in
  let sync =
    Overlay.sync_view
      ~token:(Overlay.sync_token_of_string "sync-token:v1:feedback" |> Result.get_ok)
      ~checkpoint:(recovery_cursor 0)
      ~submissions
  in
  let committed = Core.step rejected.next (recovery_commit request sync None) in
  let pulled =
    Core.step
      committed.next
      (Core.Websocket_message
         ( connection
         , Protocol.Server.Pull_ok
             { t = server_cursor_of_int 0; checksum = None; txs = [] } ))
  in
  Alcotest.(check bool)
    "empty catch-up does not hide the rejected write"
    true
    (Option.is_some (Core.state pulled.next).snapshot.last_error);
  require_no_new_submission pulled.effects;
  let restored, restored_connection = restore_recovery_core sync in
  let caught_up =
    Core.step
      restored
      (Core.Websocket_message
         ( restored_connection
         , Protocol.Server.Pull_ok
             { t = server_cursor_of_int 0; checksum = None; txs = [] } ))
  in
  Alcotest.(check bool)
    "restored blocked writes retain visible feedback"
    true
    (Option.is_some (Core.state caught_up.next).snapshot.last_error);
  require_no_new_submission caught_up.effects
;;

let stale_rejection_is_not_a_failed_save_notice () =
  let core, connection = submitted_core () in
  let rejection : Protocol.rejection =
    { reason = Stale
    ; t = Some (server_cursor_of_int 1)
    ; checksum = None
    ; success_tx_ids = []
    ; failed_tx_id = None
    ; missing_block_uuids = []
    ; error_detail = None
    ; data = None
    }
  in
  let transition =
    Core.step
      core
      (Core.Websocket_message (connection, Protocol.Server.Tx_reject rejection))
  in
  Alcotest.(check (option string))
    "stale catch-up is recoverable"
    None
    (Core.state transition.next).snapshot.last_error;
  Alcotest.(check bool)
    "stale transition remains delegated"
    true
    (match rejection_transition transition.effects with
     | Overlay.Stale _ -> true
     | _ -> false)
;;

let decimal_boundary_pull_is_admitted () =
  List.iter
    (fun (first, last) ->
       let checkpoint = recovery_cursor (first - 1) in
       let sync =
         Overlay.sync_view
           ~token:(token Overlay.sync_token_of_string "sync-token:v1:numeric-cursor")
           ~checkpoint
           ~submissions:[]
       in
       let core, connection = restore_recovery_core sync in
       let txs =
         List.map
           (fun t ->
              Protocol.Server.
                { t = server_cursor_of_int t; tx = "[]"; outliner_op = None })
           [ first; last ]
       in
       let wire =
         Protocol.encode_server_message
           (Protocol.Server.Pull_ok
              { t = server_cursor_of_int last; checksum = None; txs })
         |> Result.get_ok
       in
       let message = Protocol.decode_server_message wire |> Result.get_ok in
       let received = Core.step core (Core.Websocket_message (connection, message)) in
       Alcotest.(check bool)
         "normal numeric pull reaches authoritative apply"
         true
         (List.exists
            (function
              | Core.Delegate (Core.Apply_authoritative_batch _) -> true
              | _ -> false)
            received.effects);
       Alcotest.(check bool)
         "normal numeric pull does not fail"
         false
         ((Core.state received.next).snapshot.sync_phase = Core.Failed))
    [ 9, 10; 99, 100; 999, 1000 ]
;;

let unordered_pull_is_rejected () =
  List.iter
    (fun values ->
       let opened, connection, _ = pull_fixture () in
       let txs =
         List.map
           (fun t ->
              Protocol.Server.
                { t = server_cursor_of_int t; tx = "[]"; outliner_op = None })
           values
       in
       let received =
         pull_message
           opened.next
           connection
           (Protocol.Server.Pull_ok
              { t = server_cursor_of_int (List.hd (List.rev values))
              ; checksum = None
              ; txs
              })
       in
       Alcotest.(check bool)
         "duplicate or reversed pull fails"
         true
         ((Core.state received.next).snapshot.sync_phase = Core.Failed))
    [ [ 9; 9 ]; [ 10; 9 ] ]
;;

let scenarios =
  [ Alcotest.test_case
      "snapshot baseline retains HTTP response budget"
      `Quick
      snapshot_baseline_decoder_retains_http_budget
  ; Alcotest.test_case
      "numeric cursor decimal boundaries"
      `Quick
      decimal_boundary_pull_is_admitted
  ; Alcotest.test_case
      "numeric cursor duplicate and reverse order"
      `Quick
      unordered_pull_is_rejected
  ; Alcotest.test_case "rejected submission feedback" `Quick rejected_submission_feedback
  ; Alcotest.test_case
      "stale rejection remains recoverable"
      `Quick
      stale_rejection_is_not_a_failed_save_notice
  ; Alcotest.test_case
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
      "local deletion account change fences completion"
      `Quick
      local_deletion_account_change_fences_completion
  ; Alcotest.test_case
      "cold start absent mirror reaches pull after snapshot activation"
      `Quick
      cold_start_absent_mirror_reaches_pull_after_snapshot_activation
  ; Alcotest.test_case
      "invalid snapshot metadata fails bootstrap"
      `Quick
      invalid_snapshot_metadata_fails_bootstrap
  ; Alcotest.test_case
      "E2EE password retry after failed unlock"
      `Quick
      e2ee_password_retry_recovers_after_failed_unlock
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

(* Core owns admission and acceptance; filesystem execution is tested by the runner. *)
let asset_version =
  Logseq_db_types.Asset_descriptor.version ~checksum:(String.make 64 'a') ~file_type:"bin"
  |> Result.get_ok
;;

let asset_fixture () =
  let selected, scope = selected_graph graph in
  selected.next, scope
;;

let asset_issue core scope operation action =
  let request : Core.asset_request = { scope; operation; action } in
  let transition = Core.step core (Core.Asset_requested request) in
  let ticket =
    List.find_map
      (function
        | Core.Run (Core.Asset_io (ticket, io)) when io.operation = operation ->
          Some ticket
        | _ -> None)
      transition.effects
    |> Option.get
  in
  transition, ticket, request
;;

let asset_outputs effects =
  List.filter_map
    (function
      | Core.Publish (Core.Asset_finished output) -> Some output
      | _ -> None)
    effects
;;

let asset_complete core ticket result =
  Core.step core (Core.Runner_completed (Core.Asset_completion (ticket, result)))
;;

let asset_accepts_exact_identity_once () =
  let core, scope = asset_fixture () in
  let first, ticket, request =
    asset_issue core scope "cache-1" (Core.Check_asset_cache (graph_id, asset_version))
  in
  Alcotest.(check int)
    "request emits no premature result"
    0
    (List.length (asset_outputs first.effects));
  let second, other, other_request =
    asset_issue
      first.next
      scope
      "cache-2"
      (Core.Check_asset_cache (graph_id, asset_version))
  in
  let completed = asset_complete second.next other (Ok (Core.Asset_cached None)) in
  Alcotest.(check bool)
    "second ticket resolves only second operation"
    true
    (asset_outputs completed.effects
     = [ { Core.request = other_request; result = Ok (Core.Asset_cached None) } ]);
  let first_done = asset_complete completed.next ticket (Ok (Core.Asset_cached None)) in
  Alcotest.(check bool)
    "first ticket remains pending"
    true
    (asset_outputs first_done.effects
     = [ { Core.request; result = Ok (Core.Asset_cached None) } ]);
  let repeated = asset_complete first_done.next ticket (Ok (Core.Asset_cached None)) in
  check_instructions "asset completion replay" [] repeated.effects
;;

let asset_rejects_foreign_scope_and_duplicate_request () =
  let core, scope = asset_fixture () in
  let pending, _, _ =
    asset_issue
      core
      scope
      "same"
      (Core.Fetch_asset
         { asset = graph_id; version = asset_version; maximum_plaintext_bytes = 32 })
  in
  let duplicate =
    Core.step
      pending.next
      (Core.Asset_requested
         { scope
         ; operation = "same"
         ; action =
             Core.Fetch_asset
               { asset = graph_id; version = asset_version; maximum_plaintext_bytes = 32 }
         })
  in
  Alcotest.(check bool)
    "duplicate request does not execute twice"
    false
    (List.exists
       (function
         | Core.Run (Core.Asset_io _) -> true
         | _ -> false)
       duplicate.effects);
  let foreign_scopes =
    [ { scope with graph_generation = scope.graph_generation + 1 }
    ; { scope with graph_id = other_graph_id }
    ; { scope with
        account =
          { scope.account with account_generation = scope.account.account_generation + 1 }
      }
    ; { scope with
        account =
          { scope.account with
            presentation_generation = scope.account.presentation_generation + 1
          }
      }
    ; { scope with
        account =
          { scope.account with
            lifecycle_generation = Int64.succ scope.account.lifecycle_generation
          }
      }
    ; { scope with account = { scope.account with user_id = "other-account" } }
    ; { scope with
        account =
          { scope.account with
            managed_sync_origin = Uri.of_string "https://other-origin.invalid"
          }
      }
    ]
  in
  List.iter
    (fun foreign_scope ->
       let rejected =
         Core.step
           duplicate.next
           (Core.Asset_requested
              { scope = foreign_scope
              ; operation = "foreign"
              ; action =
                  Core.Fetch_asset
                    { asset = graph_id
                    ; version = asset_version
                    ; maximum_plaintext_bytes = 32
                    }
              })
       in
       Alcotest.(check bool)
         "foreign scope identity cannot execute IO"
         false
         (List.exists
            (function
              | Core.Run (Core.Asset_io _) -> true
              | _ -> false)
            rejected.effects))
    foreign_scopes
;;

let asset_failure_is_published_once () =
  let core, scope = asset_fixture () in
  let pending, ticket, request =
    asset_issue
      core
      scope
      "failed"
      (Core.Put_asset_file
         { asset = graph_id
         ; version = asset_version
         ; file = "resource"
         ; maximum_plaintext_bytes = 32
         })
  in
  let failed = asset_complete pending.next ticket (Error Core.Asset_network) in
  Alcotest.(check bool)
    "typed failure preserves request identity"
    true
    (asset_outputs failed.effects
     = [ { Core.request; result = Error Core.Asset_network } ]);
  let repeated = asset_complete failed.next ticket (Error Core.Asset_network) in
  check_instructions "asset failure replay" [] repeated.effects
;;

let asset_cancelled_completion_cleans_resources () =
  List.iter
    (fun (action, value, cleanup) ->
       let core, scope = asset_fixture () in
       let pending, ticket, _ = asset_issue core scope "cancelled" action in
       let cancelled, _, _ =
         asset_issue pending.next scope "cancel" (Core.Cancel_asset_operation "cancelled")
       in
       let late = asset_complete cancelled.next ticket (Ok value) in
       Alcotest.(check int)
         "cancelled work never publishes success"
         0
         (List.length (asset_outputs late.effects));
       Alcotest.(check bool)
         "cancelled completion releases its resource"
         true
         (List.exists
            (function
              | Core.Run (Core.Asset_io (_, io)) -> io.action = cleanup
              | _ -> false)
            late.effects))
    [ ( Core.Fetch_asset
          { asset = graph_id; version = asset_version; maximum_plaintext_bytes = 32 }
      , Core.Asset_downloaded "file"
      , Core.Release_asset_file "file" )
    ; ( Core.Stage_asset_file
          { operation = graph_id; file_type = "bin"; source_file = "source" }
      , Core.Asset_staged { file = "stage"; checksum = String.make 64 'a'; size = 4L }
      , Core.Release_staged_file "stage" )
    ; ( Core.Retain_asset_file "file"
      , Core.Asset_retained (Some ("lease", "path"))
      , Core.Release_asset_file "lease" )
    ]
;;

let asset_scope_switch_cleans_late_resources () =
  List.iter
    (fun (action, result, cleanup) ->
       let core, scope = asset_fixture () in
       let pending, ticket, _ = asset_issue core scope "old-resource" action in
       let picker = Core.step pending.next Core.Graph_picker_requested in
       let late = asset_complete picker.next ticket (Ok result) in
       Alcotest.(check int)
         "old graph publishes no resource"
         0
         (List.length (asset_outputs late.effects));
       Alcotest.(check bool)
         "old graph resource is released via runner effect"
         true
         (List.exists
            (function
              | Core.Run (Core.Asset_io (_, io)) -> io.action = cleanup
              | _ -> false)
            late.effects))
    [ ( Core.Fetch_asset
          { asset = graph_id; version = asset_version; maximum_plaintext_bytes = 32 }
      , Core.Asset_downloaded "late-file"
      , Core.Release_asset_file "late-file" )
    ; ( Core.Stage_asset_file
          { operation = graph_id; file_type = "bin"; source_file = "source" }
      , Core.Asset_staged
          { file = "late-stage"; checksum = String.make 64 'a'; size = 4L }
      , Core.Release_staged_file "late-stage" )
    ; ( Core.Retain_asset_file "file"
      , Core.Asset_retained (Some ("late-lease", "path"))
      , Core.Release_asset_file "late-lease" )
    ]
;;

let asset_mismatched_completion_cleans_resource () =
  let core, scope = asset_fixture () in
  let pending, ticket, _ =
    asset_issue core scope "cache" (Core.Check_asset_cache (graph_id, asset_version))
  in
  let wrong =
    asset_complete
      pending.next
      ticket
      (Ok
         (Core.Asset_staged
            { file = "unexpected-stage"; checksum = String.make 64 'a'; size = 4L }))
  in
  Alcotest.(check bool)
    "wrong resource kind is not accepted"
    true
    (match asset_outputs wrong.effects with
     | [ { result = Error (Core.Asset_invalid_content _); _ } ] -> true
     | _ -> false);
  Alcotest.(check bool)
    "wrong resource is cleaned through runner"
    true
    (List.exists
       (function
         | Core.Run (Core.Asset_io (_, io)) ->
           io.action = Core.Release_staged_file "unexpected-stage"
         | _ -> false)
       wrong.effects)
;;

let asset_retry_completion_is_consumed_once () =
  let core, scope = asset_fixture () in
  let pending, ticket, request =
    asset_issue core scope "retry" (Core.Asset_retry_after 0.1)
  in
  let elapsed = asset_complete pending.next ticket (Ok Core.Asset_retry_elapsed) in
  Alcotest.(check bool)
    "timer returns to requesting owner"
    true
    (asset_outputs elapsed.effects
     = [ { Core.request; result = Ok Core.Asset_retry_elapsed } ]);
  let duplicate = asset_complete elapsed.next ticket (Ok Core.Asset_retry_elapsed) in
  check_instructions "asset timer replay" [] duplicate.effects
;;

let asset_cleanup_requires_admitted_scope () =
  let core, scope = asset_fixture () in
  let foreign =
    { scope with account = { scope.account with user_id = "forged-account" } }
  in
  List.iter
    (fun action ->
       let rejected =
         Core.step
           core
           (Core.Asset_requested { scope = foreign; operation = "forged-cleanup"; action })
       in
       Alcotest.(check bool)
         "foreign account cannot execute destructive or resource cleanup"
         false
         (List.exists
            (function
              | Core.Run (Core.Asset_io _) -> true
              | _ -> false)
            rejected.effects);
       Alcotest.(check bool)
         "rejected cleanup reports its own cancelled identity"
         true
         (match asset_outputs rejected.effects with
          | [ output ] ->
            output.request.scope = foreign && output.result = Error Core.Asset_cancelled
          | _ -> false))
    [ Core.Release_asset_file "resource"
    ; Core.Release_staged_file "stage"
    ; Core.Close_asset_scope
    ; (Core.Prepare_graph_asset_deletion (Core.retirement_id_of_string "96000000-0000-4000-8000-000000000001" |> Result.get_ok))
    ; Core.Delete_account_assets
    ; Core.Cancel_asset_operation "pending"
    ];
  let picker = Core.step core Core.Graph_picker_requested in
  List.iter
    (fun action ->
       let accepted =
         Core.step
           picker.next
           (Core.Asset_requested { scope; operation = "known-cleanup"; action })
       in
       Alcotest.(check bool)
         "previously admitted scope still permits required cleanup"
         true
         (List.exists
            (function
              | Core.Run (Core.Asset_io (_, io)) ->
                io.context.scope = scope && io.action = action
              | _ -> false)
            accepted.effects))
    [ Core.Release_asset_file "resource"
    ; Core.Release_staged_file "stage"
    ; Core.Close_asset_scope
    ]
;;

let asset_deletion_cancels_stage core scope deletion_scope action =
  let pending, ticket, request =
    asset_issue
      core
      scope
      "stage-before-deletion"
      (Core.Stage_asset_file
         { operation = graph_id; file_type = "bin"; source_file = "source" })
  in
  let deleting, _, _ = asset_issue pending.next deletion_scope "delete-assets" action in
  let late =
    asset_complete
      deleting.next
      ticket
      (Ok
         (Core.Asset_staged
            { file = "late-deleted-stage"; checksum = String.make 64 'a'; size = 4L }))
  in
  Alcotest.(check int)
    "deleted asset operation cannot publish late staging success"
    0
    (List.length (asset_outputs late.effects));
  Alcotest.(check bool)
    "deletion cancels the exact pending staging request"
    true
    (asset_outputs deleting.effects
     = [ { Core.request; result = Error Core.Asset_cancelled } ]);
  Alcotest.(check bool)
    "late staging completion cleans through the original resource scope"
    true
    (List.exists
       (function
         | Core.Run (Core.Asset_io (_, io)) ->
           io.context.scope = scope
           && io.action = Core.Release_staged_file "late-deleted-stage"
         | _ -> false)
       late.effects);
  let repeated =
    asset_complete
      late.next
      ticket
      (Ok
         (Core.Asset_staged
            { file = "late-deleted-stage"; checksum = String.make 64 'a'; size = 4L }))
  in
  check_instructions "deleted staging completion replay" [] repeated.effects
;;

let asset_graph_deletion_cancels_other_generation () =
  let core, scope = asset_fixture () in
  asset_deletion_cancels_stage
    core
    scope
    { scope with graph_generation = 0 }
    (Core.Prepare_graph_asset_deletion (Core.retirement_id_of_string "96000000-0000-4000-8000-000000000001" |> Result.get_ok))
;;

let asset_account_deletion_cancels_other_known_graph () =
  let core, old_scope = asset_fixture () in
  let catalogued = refresh_catalog core [ graph; other_graph ] in
  let picker = Core.step catalogued.next Core.Graph_picker_requested in
  let selected = Core.step picker.next (Core.Graph_selected other_graph_id) in
  let current_scope = Core.admitted_graph_scope selected.next |> Option.get in
  Alcotest.(check bool)
    "account deletion fixture keeps the same account across graph selection"
    true
    (Uri.equal
       current_scope.account.managed_sync_origin
       old_scope.account.managed_sync_origin
     && String.equal current_scope.account.user_id old_scope.account.user_id
     && current_scope.graph_id <> old_scope.graph_id);
  asset_deletion_cancels_stage
    selected.next
    current_scope
    old_scope
    Core.Delete_account_assets
;;

let completed_retirement_cannot_cancel_replacement_work () =
  let core, scope = asset_fixture () in
  let retirement = Core.retirement_id_of_string "96000000-0000-4000-8000-000000000003" |> Result.get_ok in
  let deletion = Core.asset_deletion_reference ~scope ~retirement in
  let preparing, ticket, _ = asset_issue core scope "prepare-old" (Core.Prepare_graph_asset_deletion retirement) in
  let prepared = asset_complete preparing.next ticket (Ok (Core.Asset_deletion_prepared deletion)) in
  let committing, ticket, _ = asset_issue prepared.next scope "commit-old" (Core.Commit_graph_asset_deletion deletion) in
  let committed = asset_complete committing.next ticket (Ok Core.Asset_unit) in
  let pending, _, fresh = asset_issue committed.next scope "replacement-fetch"
      (Core.Fetch_asset {asset=graph_id;version=asset_version;maximum_plaintext_bytes=8}) in
  let replay = Core.step pending.next (Core.Asset_requested
      {scope;operation="replay-old-prepare";action=Core.Prepare_graph_asset_deletion retirement}) in
  Alcotest.(check bool) "old retirement cannot cancel replacement work" false
    (List.exists (fun (output : Core.asset_output) -> output.request = fresh && output.result = Error Core.Asset_cancelled)
      (asset_outputs replay.effects))
;;

let retirement_replay_preserves_inflight_and_account_cleanup () =
  List.iter (fun after_account_cleanup ->
    let core, scope = asset_fixture () in
    let retirement = Core.retirement_id_of_string "96000000-0000-4000-8000-000000000014" |> Result.get_ok in
    let deletion = Core.asset_deletion_reference ~scope ~retirement in
    let preparing, ticket, original = asset_issue core scope "initial-prepare" (Core.Prepare_graph_asset_deletion retirement) in
    let owner, pending =
      if not after_account_cleanup then preparing.next, original
      else (
        let prepared = asset_complete preparing.next ticket (Ok (Core.Asset_deletion_prepared deletion)) in
        let clearing, ticket, _ = asset_issue prepared.next scope "account-cleanup" Core.Delete_account_assets in
        let cleared = asset_complete clearing.next ticket (Ok Core.Asset_unit) in
        let fresh, _, request = asset_issue cleared.next scope "new-account-fetch"
          (Core.Fetch_asset {asset=graph_id;version=asset_version;maximum_plaintext_bytes=8}) in
        fresh.next, request) in
    let replay = Core.step owner (Core.Asset_requested
      {scope;operation="replay-initial-prepare";action=Core.Prepare_graph_asset_deletion retirement}) in
    Alcotest.(check bool) "replay does not cancel the existing owner" false
      (List.exists (fun (output : Core.asset_output) -> output.request=pending && output.result=Error Core.Asset_cancelled)
        (asset_outputs replay.effects))) [false;true]
;;

let retirement_terminal_rejects_mismatched_token_scope () =
  let core, scope = asset_fixture () in
  let foreign = {scope with account={scope.account with user_id="foreign-token-account"}} in
  let retirement = Core.retirement_id_of_string "96000000-0000-4000-8000-000000000015" |> Result.get_ok in
  let deletion = Core.asset_deletion_reference ~scope:foreign ~retirement in
  List.iter (fun action ->
    let transition = Core.step core (Core.Asset_requested {scope;operation="foreign-token";action}) in
    Alcotest.(check bool) "current scope cannot execute another token's cleanup" false
      (List.exists (function Core.Run (Core.Asset_io _) -> true | _ -> false) transition.effects))
    [Core.Commit_graph_asset_deletion deletion;Core.Cancel_graph_asset_deletion deletion]
;;

let asset_scenarios =
  [ Alcotest.test_case "retirement replay preserves inflight and account cleanup" `Quick
      retirement_replay_preserves_inflight_and_account_cleanup
  ; Alcotest.test_case "retirement token scope is checked for active context" `Quick
      retirement_terminal_rejects_mismatched_token_scope
  ; Alcotest.test_case "completed retirement preserves replacement work" `Quick
      completed_retirement_cannot_cancel_replacement_work
  ; Alcotest.test_case
      "graph asset deletion cancels pending work across generations"
      `Quick
      asset_graph_deletion_cancels_other_generation
  ; Alcotest.test_case
      "account asset deletion cancels pending work on another known graph"
      `Quick
      asset_account_deletion_cancels_other_known_graph
  ; Alcotest.test_case
      "asset cleanup rejects foreign account and accepts retired known scope"
      `Quick
      asset_cleanup_requires_admitted_scope
  ; Alcotest.test_case
      "asset exact completion identity and replay"
      `Quick
      asset_accepts_exact_identity_once
  ; Alcotest.test_case
      "asset foreign scope and duplicate admission"
      `Quick
      asset_rejects_foreign_scope_and_duplicate_request
  ; Alcotest.test_case
      "asset failure resolves once"
      `Quick
      asset_failure_is_published_once
  ; Alcotest.test_case
      "asset cancellation cleans file staging and lease"
      `Quick
      asset_cancelled_completion_cleans_resources
  ; Alcotest.test_case
      "asset scope switch cleans stale resources"
      `Quick
      asset_scope_switch_cleans_late_resources
  ; Alcotest.test_case
      "asset mismatched completion cleans resource"
      `Quick
      asset_mismatched_completion_cleans_resource
  ; Alcotest.test_case
      "asset retry completion resolves once"
      `Quick
      asset_retry_completion_is_consumed_once
  ]
;;

(* Reconnect policy belongs to Core. Physical retirement and socket peaks are
   checked separately at the public Runner boundary, which executes resources. *)
let websocket_starts effects =
  List.filter_map
    (function
      | Core.Run (Core.Start_websocket r) -> Some r
      | _ -> None)
    effects
;;

let websocket_retry_timer effects =
  List.find_map
    (function
      | Core.Run (Core.Schedule_timer r) -> Some r
      | _ -> None)
    effects
  |> function
  | Some r -> r
  | None -> Alcotest.fail "recoverable close did not schedule retry"
;;

let websocket_retirement_required scope effects =
  Alcotest.(check bool)
    "exact owner retirement requested"
    true
    (List.exists
       (function
         | Core.Run (Core.Close_websocket s) -> s = scope
         | _ -> false)
       effects);
  Alcotest.(check int)
    "replacement waits for retirement"
    0
    (List.length (websocket_starts effects))
;;

let reconnect_fixture () =
  let fixture, current = Pure_reducer_bad_case_support.current_connected_fixture () in
  fixture.connection, current.next
;;

let reconnect_waits_for_retirement_and_consumes_retry () =
  let scope, core = reconnect_fixture () in
  let closed =
    Core.step core (Core.Websocket_closed (scope, Core.Recoverable_close { message = None; attention = Requires_attention }))
  in
  websocket_retirement_required scope closed.effects;
  List.iter (fun attention ->
    let message = Some "Synthetic closed transport" in
    let terminated = Core.step core (Core.Websocket_closed (scope,
      Core.Recoverable_close { message; attention })) in
    let snapshot = (Core.state terminated.next).snapshot in
    Alcotest.(check (option string)) "classification preserves exact message" message snapshot.last_error;
    Alcotest.(check bool) "typed attention reaches public snapshot" true
      (snapshot.last_error_attention = Some attention);
    websocket_retirement_required scope terminated.effects;
    let retired = Core.step terminated.next (Core.Websocket_retired scope) in
    Alcotest.(check (float 0.)) "attention cannot alter retry delay" 1.
      (websocket_retry_timer retired.effects).delay_seconds)
    [Core.Transient_connection; Core.Requires_attention];
  let duplicate =
    Core.step closed.next (Core.Websocket_closed (scope, Core.Recoverable_close { message = None; attention = Requires_attention }))
  in
  check_instructions "duplicate termination" [] duplicate.effects;
  let late = Core.step duplicate.next (Core.Websocket_opened scope) in
  check_instructions "late open cannot resurrect retiring owner" [] late.effects;
  let retired = Core.step late.next (Core.Websocket_retired scope) in
  let timer = websocket_retry_timer retired.effects in
  Alcotest.(check (float 0.)) "first retry delay" 1. timer.delay_seconds;
  let expired = Core.step retired.next (Core.Timer_elapsed timer.id) in
  let replacement =
    match websocket_starts expired.effects with
    | [ r ] -> r.scope
    | _ -> Alcotest.fail "retry must start exactly one owner"
  in
  Alcotest.(check bool)
    "replacement generation is fresh"
    true
    (replacement.connection_generation > scope.connection_generation);
  check_instructions
    "duplicate retry timer"
    []
    (Core.step expired.next (Core.Timer_elapsed timer.id)).effects;
  check_instructions
    "duplicate retirement"
    []
    (Core.step expired.next (Core.Websocket_retired scope)).effects;
  List.iter
    (fun event ->
       check_instructions
         "late old connection event"
         []
         (Core.step expired.next event).effects)
    [ Core.Websocket_opened scope
    ; Core.Websocket_closed (scope, Core.Recoverable_close { message = Some "late"; attention = Requires_attention })
    ; Core.Websocket_message
        ( scope
        , Logseq_sync_pure_reducer.Sync_protocol.Server.Changed
            { t = server_cursor_of_int 42 } )
    ];
  let repeated =
    Core.step
      expired.next
      (Core.Foreground_changed { foreground = true; lifecycle_generation = 1L })
  in
  Alcotest.(check int)
    "foreground cannot duplicate an opening owner"
    0
    (List.length (websocket_starts repeated.effects))
;;

let reconnect_backoff_is_capped_and_not_reset_by_handshake () =
  let scope, core = reconnect_fixture () in
  let rec attempt scope core = function
    | [] -> ()
    | delay :: rest ->
      let failed =
        Core.step
          core
          (Core.Websocket_closed (scope, Core.Recoverable_close { message = Some "EOF"; attention = Requires_attention }))
      in
      let retired = Core.step failed.next (Core.Websocket_retired scope) in
      let timer = websocket_retry_timer retired.effects in
      Alcotest.(check (float 0.)) "capped retry backoff" delay timer.delay_seconds;
      let opening = Core.step retired.next (Core.Timer_elapsed timer.id) in
      let scope =
        match websocket_starts opening.effects with
        | [ r ] -> r.scope
        | _ -> Alcotest.fail "missing retry"
      in
      let opened = Core.step opening.next (Core.Websocket_opened scope) in
      attempt scope opened.next rest
  in
  attempt scope core [ 1.; 2.; 4.; 8.; 16.; 30.; 30. ]
;;

let reconnect_terminal_failures_do_not_retry () =
  List.iter
    (fun reason ->
       let scope, core = reconnect_fixture () in
       let closed = Core.step core (Core.Websocket_closed (scope, reason)) in
       websocket_retirement_required scope closed.effects;
       let retired = Core.step closed.next (Core.Websocket_retired scope) in
       Alcotest.(check bool)
         "terminal close has no automatic retry"
         false
         (List.exists
            (function
              | Core.Run (Core.Schedule_timer _ | Core.Start_websocket _) -> true
              | _ -> false)
            retired.effects))
    [ Core.Local_close
    ; Core.Authentication_failure "401"
    ; Core.Protocol_failure "bad frame"
    ]
;;

let reconnect_background_shutdown_and_scope_fence () =
  let scope, core = reconnect_fixture () in
  let closed =
    Core.step core (Core.Websocket_closed (scope, Core.Recoverable_close { message = None; attention = Requires_attention }))
  in
  let retired = Core.step closed.next (Core.Websocket_retired scope) in
  let timer = websocket_retry_timer retired.effects in
  let background =
    Core.step
      retired.next
      (Core.Foreground_changed { foreground = false; lifecycle_generation = 1L })
  in
  Alcotest.(check bool)
    "background cancels scoped retry"
    true
    (List.exists
       (function
         | Core.Run (Core.Cancel_effects _) -> true
         | _ -> false)
       background.effects);
  check_instructions
    "background retry timer is inert"
    []
    (Core.step background.next (Core.Timer_elapsed timer.id)).effects;
  let foreground =
    Core.step
      background.next
      (Core.Foreground_changed { foreground = true; lifecycle_generation = 2L })
  in
  Alcotest.(check int)
    "foreground starts one owner"
    1
    (List.length (websocket_starts foreground.effects));
  let duplicate =
    Core.step
      foreground.next
      (Core.Foreground_changed { foreground = true; lifecycle_generation = 3L })
  in
  Alcotest.(check int)
    "repeated foreground does not dial again"
    0
    (List.length (websocket_starts duplicate.effects));
  let stopped = Core.step retired.next Core.Shutdown in
  check_instructions
    "shutdown retry timer is inert"
    []
    (Core.step stopped.next (Core.Timer_elapsed timer.id)).effects;
  let switched = Core.step retired.next Core.Graph_picker_requested in
  check_instructions
    "old graph retry timer is inert"
    []
    (Core.step switched.next (Core.Timer_elapsed timer.id)).effects;
  let logged_out =
    Core.step retired.next (Core.Account_authenticated { user_id = None })
  in
  check_instructions
    "old account retry timer is inert"
    []
    (Core.step logged_out.next (Core.Timer_elapsed timer.id)).effects
;;

let reconnect_scope_switch_waits_for_old_opening_owner () =
  let fixture = Pure_reducer_bad_case_support.connected_fixture () in
  let switched = Core.step fixture.attached.next (Core.Graph_selected graph_id) in
  websocket_retirement_required fixture.connection switched.effects;
  let request =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_mirror r) -> Some r
        | _ -> None)
      switched.effects
    |> Option.get
  in
  let inspected =
    Core.step switched.next (Core.Mirror_inspected (Core.Mirror_available request))
  in
  let attached =
    Core.step
      inspected.next
      (Core.Graph_attached { scope = request.scope; sync = fixture.attachment.sync })
  in
  Alcotest.(check int)
    "attachment cannot overlap old setup"
    0
    (List.length (websocket_starts attached.effects));
  check_instructions
    "late opening completion is fenced"
    []
    (Core.step attached.next (Core.Websocket_opened fixture.connection)).effects;
  let wrong =
    { fixture.connection with
      connection_generation = fixture.connection.connection_generation + 100
    }
  in
  check_instructions
    "unrelated retirement cannot release owner"
    []
    (Core.step attached.next (Core.Websocket_retired wrong)).effects;
  let retired = Core.step attached.next (Core.Websocket_retired fixture.connection) in
  let next =
    match websocket_starts retired.effects with
    | [ r ] -> r
    | _ -> Alcotest.fail "retirement must start latest attached target"
  in
  Alcotest.(check bool)
    "latest graph generation selected"
    true
    (next.scope.graph = request.scope)
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "reconnect waits for retirement and consumes retry"
        `Quick
        reconnect_waits_for_retirement_and_consumes_retry
    ; Alcotest.test_case
        "reconnect capped backoff survives short handshakes"
        `Quick
        reconnect_backoff_is_capped_and_not_reset_by_handshake
    ; Alcotest.test_case
        "reconnect terminal failures do not retry"
        `Quick
        reconnect_terminal_failures_do_not_retry
    ; Alcotest.test_case
        "reconnect background shutdown and scope fencing"
        `Quick
        reconnect_background_shutdown_and_scope_fence
    ; Alcotest.test_case
        "reconnect scope switch waits for opening owner"
        `Quick
        reconnect_scope_switch_waits_for_old_opening_owner
    ]
;;

let reconnect_resets_backoff_after_durable_nonempty_pull () =
  let opened, old_connection, sync = pull_fixture () in
  let closed =
    Core.step
      opened.next
      (Core.Websocket_closed (old_connection, Core.Recoverable_close { message = None; attention = Requires_attention }))
  in
  let restarting = restart_after_retirement closed.next old_connection in
  let connection = recovery_connection restarting.effects in
  let opened = Core.step restarting.next (Core.Websocket_opened connection) in
  let received = pull_response opened.next connection ~after:0 1 in
  let committed =
    recovery_apply received.next connection (recovery_sync sync ~checkpoint:1 1 [])
  in
  Alcotest.(check bool)
    "nonempty opening pull is durably current"
    true
    ((Core.state committed.next).snapshot.sync_phase = Core.Current);
  let closed =
    Core.step
      committed.next
      (Core.Websocket_closed (connection, Core.Recoverable_close { message = None; attention = Requires_attention }))
  in
  let retired = Core.step closed.next (Core.Websocket_retired connection) in
  Alcotest.(check (float 0.))
    "confirmed healthy connection resets reconnect backoff"
    1.
    (websocket_retry_timer retired.effects).delay_seconds
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "reconnect resets after durable nonempty pull"
        `Quick
        reconnect_resets_backoff_after_durable_nonempty_pull
    ]
;;

let generated_catalog_cache_rejects_legacy_and_invalid_domain_values () =
  let cache =
    Core.catalog_cache ~user_id:"user" ~graphs:[ graph ] ~selected_graph:(Some graph_id)
  in
  let encoded = Core.encode_catalog_cache cache in
  let restored = Core.decode_catalog_cache encoded |> Result.get_ok in
  Alcotest.(check bool)
    "generated cache restores validated graph and selection"
    true
    (Core.catalog_cache_graphs restored = [ graph ]
     && Core.catalog_cache_selected_graph restored = Some graph_id);
  let legacy = {|{"userId":"user","graphs":[],"selectedGraph":null}|} in
  Alcotest.(check bool)
    "old internal cache is explicitly rejected"
    true
    (Result.is_error (Core.decode_catalog_cache legacy));
  let native_invalid_selection =
    {|{"cache_user_id":"user","cache_graphs":[],"cache_selected_graph":"invalid"}|}
  in
  Alcotest.(check bool)
    "invalid optional UUID does not become no selection"
    true
    (Result.is_error (Core.decode_catalog_cache native_invalid_selection));
  let native_invalid_schema =
    {|{"cache_user_id":"user","cache_graphs":[{"graph_id":"11111111-1111-4111-8111-111111111111","name":"Journal","schema":{"major":-1,"minor":0,"exact":true},"encrypted":false}],"cache_selected_graph":null}|}
  in
  Alcotest.(check bool)
    "schema domain constraints remain enforced"
    true
    (Result.is_error (Core.decode_catalog_cache native_invalid_schema))
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "generated catalog cache rejects old format and invalid domains"
        `Quick
        generated_catalog_cache_rejects_legacy_and_invalid_domain_values
    ]
;;

(* Core owns challenge validity/recovery. Only its public events and opaque
   effect tickets reproduce these state defects; no runner/UI duplication. *)
let e2ee_preparation_fixture () =
  let selected, scope = selected_graph encrypted_graph in
  let absent = Core.step selected.next (Core.Mirror_inspected (Mirror_absent scope)) in
  let cached = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
      Some (Core.step absent.next (Core.Runner_completed (Core.Completion
        (ticket, Error (Core.Effect_failed "synthetic absent cache")))))
    | _ -> None) absent.effects |> Option.get in
  cached, scope
;;

let e2ee_finish_graph_fetch preparation (result : (string, Core.effect_error) result) =
  List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_graph_key _)) ->
      Some (Core.step preparation.Core.next
        (Core.Runner_completed (Core.Completion (ticket, result))))
    | _ -> None) preparation.effects |> Option.get
;;

let e2ee_finish_user_fetch preparation (result : (string, Core.effect_error) result) =
  List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_user_keys _)) ->
      Some (Core.step preparation.Core.next
        (Core.Runner_completed (Core.Completion (ticket, result))))
    | _ -> None) preparation.effects |> Option.get
;;

let e2ee_preparation_failure_retries fetch_user () =
  let preparation, scope = e2ee_preparation_fixture () in
  let error = Error (Core.Effect_failed "synthetic preparation failed") in
  let failed = if fetch_user then
    e2ee_finish_user_fetch (e2ee_finish_graph_fetch preparation (Ok "wrapped")) error
    else e2ee_finish_graph_fetch preparation error in
  let rejected = Core.step failed.next (password_event failed.next "unused-synthetic") in
  Alcotest.(check bool) "no challenge is advertised" false
    (Core.state rejected.next).snapshot.startup.awaiting_e2ee_password;
  Alcotest.(check int) "password without challenge starts no work" 0
    (List.length rejected.effects);
  let retry = Core.step rejected.next (Core.Online_recovery_requested (timeline_scope rejected.next)) in
  let fetched = List.filter (function
    | Core.Run (Core.Request (_, Core.Fetch_e2ee_graph_key actual)) -> actual = scope
    | _ -> false) retry.effects in
  Alcotest.(check int) "Retry reacquires graph key in retained scope" 1 (List.length fetched);
  Alcotest.(check bool) "Retry clears failure" true
    ((Core.state retry.next).snapshot.startup.failure = None);
  Alcotest.(check bool) "selected graph retained" true
    ((Core.state retry.next).snapshot.selected_graph = Some scope.graph_id);
  Alcotest.(check bool) "Retry performs no cache or credential deletion" false
    (List.exists (function
      | Core.Run (Core.Request (_, Core.Delete_account_secrets _)) -> true
      | _ -> false) retry.effects)
;;

let e2ee_invalidated_challenge_is_not_advertised () =
  let preparation, _ = e2ee_preparation_fixture () in
  let prompt = e2ee_finish_user_fetch
    (e2ee_finish_graph_fetch preparation (Ok "wrapped")) (Ok "package") in
  let refresh = Core.step prompt.next (Core.Catalog_refresh_requested (startup_scope prompt.next)) in
  let failed = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
      Some (Core.step refresh.next (Core.Runner_completed (Core.Completion
        (ticket, Error (Core.Effect_failed "synthetic catalog refresh failed")))))
    | _ -> None) refresh.effects |> Option.get in
  Alcotest.(check bool) "cleared key package cannot advertise a challenge" false
    (Core.state failed.next).snapshot.startup.awaiting_e2ee_password;
  let submit = Core.step failed.next (password_event failed.next "unused-synthetic") in
  Alcotest.(check int) "invalidated challenge starts no crypto" 0 (List.length submit.effects)
;;

let scenarios = scenarios @
  [ Alcotest.test_case "E2EE graph preparation failure Retry" `Quick
      (e2ee_preparation_failure_retries false)
  ; Alcotest.test_case "E2EE user preparation failure Retry" `Quick
      (e2ee_preparation_failure_retries true)
  ; Alcotest.test_case "E2EE invalidated challenge is not advertised" `Quick
      e2ee_invalidated_challenge_is_not_advertised ]
;;


let snapshot_metadata_open_fields_keep_declared_constraints () =
  List.iter
    (fun ((body : string), success) ->
       let requested, _ = begin_snapshot_bootstrap () in
       let downloaded =
         List.find_map
           (function
             | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
               Some
                 (Core.step
                    requested.next
                    (Core.Runner_completed (Core.Completion (ticket, Ok body))))
             | _ -> None)
           requested.effects
         |> Option.get
       in
       Alcotest.(check bool)
         "public Core owns metadata decoding and download decision"
         success
         (List.exists
            (function
              | Core.Run (Core.Request (_, Core.Download_snapshot _)) -> true
              | _ -> false)
            downloaded.effects))
    [ ( {|{"ok":true,"t":0,"url":"https://example.com/snapshot","key":"synthetic","future":{"nested":true}}|}
      , true )
    ; {|{"ok":true,"url":"https://example.com/snapshot"}|}, false
    ; {|{"ok":true,"t":null,"url":"https://example.com/snapshot"}|}, false
    ; {|{"ok":true,"t":-1,"url":"https://example.com/snapshot"}|}, false
    ; {|{"ok":true,"t":1.5,"url":"https://example.com/snapshot"}|}, false
    ; {|{"ok":true,"t":"42","url":"https://example.com/snapshot"}|}, false
    ; {|{"ok":true,"t":true,"url":"https://example.com/snapshot"}|}, false
    ; {|{"ok":true,"t":0,"t":1,"url":"https://example.com/snapshot"}|}, false
    ; {|{"ok":true,"t":9223372036854775808,"url":"https://example.com/snapshot"}|}, false
    ; {|{"ok":true,"t":0,"future":true}|}, false
    ; {|{"ok":true,"t":0,"url":null,"future":true}|}, false
    ; {|{"ok":"true","t":0,"url":"https://example.com/snapshot","future":true}|}, false
    ; {|{"ok":true,"t":0,"url":"http://example.com/snapshot","future":true}|}, false
    ]
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "snapshot metadata open fields keep declared constraints"
        `Quick
        snapshot_metadata_open_fields_keep_declared_constraints
    ]
;;


(* A missing wrapped-key cache is a valid local-access failure. Core owns whether
   to fetch the challenge or advertise a terminal failure; no runner/UI replica. *)
let e2ee_auto_preparation () =
  let selected, scope = selected_graph encrypted_graph in
  let absent = Core.step selected.next (Core.Mirror_inspected (Mirror_absent scope)) in
  let completion = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
      Some (Core.Runner_completed (Core.Completion
        (ticket, Error (Core.Effect_failed "wrappedGraphKeyUnavailable"))))
    | _ -> None) absent.effects |> Option.get in
  Core.step absent.next completion, scope, completion
;;

let e2ee_missing_cache_prepares_without_retry () =
  let preparation, scope, missing = e2ee_auto_preparation () in
  let snapshot = (Core.state preparation.next).snapshot in
  Alcotest.(check bool) "cache miss is not a terminal UI failure" true
    (snapshot.startup.failure = None && snapshot.last_error = None);
  Alcotest.(check bool) "no password prompt before materials exist" false
    snapshot.startup.awaiting_e2ee_password;
  Alcotest.(check int) "one automatic graph-key fetch" 1
    (List.length (List.filter (function
       | Core.Run (Core.Request (_, Core.Fetch_e2ee_graph_key actual)) -> actual = scope
       | _ -> false) preparation.effects));
  let repeated = Core.step preparation.next (Core.Online_recovery_requested (timeline_scope preparation.next)) in
  Alcotest.(check int) "recovery during preparation is inert" 0
    (List.length repeated.effects);
  let duplicate = Core.step preparation.next missing in
  Alcotest.(check int) "duplicate cache completion starts no work" 0
    (List.length duplicate.effects);
  let user_fetch = e2ee_finish_graph_fetch preparation (Ok "wrapped") in
  Alcotest.(check bool) "graph key alone cannot advertise password" false
    (Core.state user_fetch.next).snapshot.startup.awaiting_e2ee_password;
  let prompt = e2ee_finish_user_fetch user_fetch (Ok "private-package") in
  Alcotest.(check bool) "both materials directly advertise password" true
    (Core.state prompt.next).snapshot.startup.awaiting_e2ee_password;
  Alcotest.(check bool) "password prompt has no obsolete failure" true
    ((Core.state prompt.next).snapshot.startup.failure = None)
;;

let e2ee_auto_preparation_failure_is_bounded fetch_user message () =
  let preparation, _, _ = e2ee_auto_preparation () in
  let failed = if fetch_user then
    e2ee_finish_user_fetch (e2ee_finish_graph_fetch preparation (Ok "wrapped"))
      (Error (Core.Effect_failed message))
    else e2ee_finish_graph_fetch preparation (Error (Core.Effect_failed message)) in
  let snapshot = (Core.state failed.next).snapshot in
  Alcotest.(check bool) "remote error is visible" true
    (snapshot.startup.failure = Some Core.During_e2ee && snapshot.last_error = Some message);
  Alcotest.(check bool) "missing challenge never shows password" false
    snapshot.startup.awaiting_e2ee_password;
  Alcotest.(check bool) "failure does not automatically retry" false
    (List.exists (function Core.Run _ -> true | _ -> false) failed.effects);
  let blocked = Core.step failed.next (password_event failed.next "unused") in
  Alcotest.(check int) "no unusable password submission" 0 (List.length blocked.effects);
  let retry = Core.step failed.next (Core.Online_recovery_requested (timeline_scope failed.next)) in
  Alcotest.(check bool) "explicit Retry can reacquire materials" true
    (List.exists (function Core.Run (Core.Request (_, Core.Fetch_e2ee_graph_key _)) -> true
      | _ -> false) retry.effects);
  let picker = Core.step failed.next Core.Graph_picker_requested in
  Alcotest.(check bool) "failure can return to graph selection" true
    (Core.state picker.next).snapshot.startup.awaiting_selection
;;

let e2ee_late_preparation_cannot_reopen_challenge stage cancel result () =
  let preparation, scope, _ = e2ee_auto_preparation () in
  let flight, complete =
    if stage = 0 then preparation, (fun origin ->
      let finished = e2ee_finish_graph_fetch { preparation with next = origin } result in
      finished)
    else let user_fetch = e2ee_finish_graph_fetch preparation (Ok "old-wrapped") in
      if stage = 1 then user_fetch, (fun origin ->
        e2ee_finish_user_fetch { user_fetch with next = origin } result)
      else let prompt = e2ee_finish_user_fetch user_fetch (Ok "old-package") in
        let unlocking = Core.step prompt.next (password_event prompt.next "synthetic") in
        let completion = List.find_map (function
          | Core.Run (Core.Request (ticket, Core.Unlock_private_key _)) ->
            Some (Core.Runner_completed (Core.Completion (ticket,
              match result with Ok _ -> Ok () | Error e -> Error e)))
          | _ -> None) unlocking.effects |> Option.get in
        unlocking, (fun origin -> Core.step origin completion)
  in
  let left = Core.step flight.next
    (if cancel then Core.Graph_picker_requested else Core.Graph_selected scope.graph_id) in
  let before = Core.state left.next in
  let late = complete left.next in
  Alcotest.(check bool) "late completion preserves current public state" true
    (before = Core.state late.next);
  Alcotest.(check int) "late completion starts no next phase" 0 (List.length late.effects);
  let submit = Core.step late.next (password_event late.next "abandoned") in
  Alcotest.(check int) "obsolete challenge cannot submit" 0 (List.length submit.effects)
;;

let scenarios = scenarios @
  [ Alcotest.test_case "E2EE missing cache auto-prepares without Retry" `Quick
      e2ee_missing_cache_prepares_without_retry
  ; Alcotest.test_case "E2EE automatic graph-key network failure is bounded" `Quick
      (e2ee_auto_preparation_failure_is_bounded false "synthetic network unavailable")
  ; Alcotest.test_case "E2EE automatic user-key authentication failure is bounded" `Quick
      (e2ee_auto_preparation_failure_is_bounded true "synthetic authentication required")
  ] @ List.concat_map (fun stage -> List.concat_map (fun cancel ->
      List.map (fun success -> Alcotest.test_case
        (Printf.sprintf "E2EE late stage %d %s %s is fenced" stage
          (if cancel then "cancel" else "reentry") (if success then "success" else "error"))
        `Quick (e2ee_late_preparation_cannot_reopen_challenge stage cancel
          (if success then Ok "late-material" else Error (Core.Effect_failed "late error"))))
        [true; false]) [true; false]) [0;1;2]
;;

(* Startup policy is owned by Sync; these use the raw cold-start state rather
   than the explicit-online fixture used by the older synchronization tests. *)
let cold_start () =
  Core.config ~managed_sync_origin:(Uri.of_string "https://api.logseq.io") ~limits:(limits ())
  |> Result.get_ok |> Core.initial |> Result.get_ok
;;
let startup_ticket core : Core.startup_scope =
  let f = (Core.state core).snapshot.startup in
  { account_generation=f.account_generation; presentation_generation=f.presentation_generation }
;;
let timeline_ticket core : Core.timeline_scope =
  let s = (Core.state core).snapshot in
  { startup=startup_ticket core; graph_id=Option.get s.selected_graph
  ; graph_generation=s.startup.graph_generation }
;;
let local_selected ?(encrypted=false) () =
  let restoring = Core.step (cold_start ()) (Core.Restore_local_account {user_id="user"}) in
  let g = if encrypted then encrypted_graph else graph in
  let cache = Core.catalog_cache ~user_id:"user" ~graphs:[g] ~selected_graph:(Some graph_id) in
  let selected = Core.step restoring.next (load_catalog_completion restoring.effects (Some cache)) in
  selected, inspect_mirror_request selected.effects
;;
let local_attached () =
  let selected, request = local_selected () in
  let attaching = Core.step selected.next (Core.Mirror_inspected (Core.Mirror_available request)) in
  let token = Overlay.sync_token_of_string "sync-token:v1:local-startup" |> Result.get_ok in
  let sync = Overlay.sync_view ~token ~checkpoint:(server_cursor_of_int 0) ~submissions:[] in
  Core.step attaching.next (Core.Graph_attached {scope=request.scope;sync})
;;
let no_network message effects =
  Alcotest.(check bool) message false (List.exists (function
    | Core.Run (Core.Start_websocket _) -> true
    | Core.Run (Core.Request (_, (Core.Fetch_catalog _ | Core.Fetch_snapshot_baseline _
      | Core.Fetch_e2ee_graph_key _ | Core.Fetch_e2ee_user_keys _))) -> true
    | _ -> false) effects)
;;
let local_startup_has_no_network () =
  let cold = cold_start () in
  no_network "authentication notification cannot authorize cold-start networking"
    (Core.step cold (Core.Account_authenticated {user_id=Some "user"})).effects;
  let attached = local_attached () in
  no_network "attachment stays local" attached.effects;
  Alcotest.(check bool) "local access does not forge online credentials" false
    (Core.state attached.next).snapshot.startup.authenticated;
  Alcotest.(check bool) "local attachment is usable" true
    ((Core.state attached.next).snapshot.startup.local_access = Core.Local_available);
  no_network "feed completion does not authorize networking"
    (Core.step attached.next Core.Local_feed_acknowledged).effects;
  no_network "foreground does not authorize networking"
    (Core.step attached.next (Core.Foreground_changed {foreground=true;lifecycle_generation=1L})).effects
;;
let missing_local_data_stops_loading () =
  let selected, request = local_selected () in
  let absent = Core.step selected.next (Core.Mirror_inspected (Core.Mirror_absent request.scope)) in
  no_network "no automatic snapshot download" absent.effects;
  let f = (Core.state absent.next).snapshot.startup in
  Alcotest.(check bool) "missing mirror is terminal and accurate" true
    (not f.restoring_local && not f.bootstrapping && f.local_access=Core.Local_unavailable Core.Local_mirror_unavailable);
  let selected, request = local_selected ~encrypted:true () in
  let keys = Core.step selected.next (Core.Mirror_inspected (Core.Mirror_available request)) in
  let missing = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
      Some (Core.Runner_completed (Core.Completion (ticket, Error (Core.Effect_failed "local key absent"))))
    | _ -> None) keys.effects |> Option.get in
  let failed = Core.step keys.next missing in
  no_network "no automatic remote key recovery" failed.effects;
  Alcotest.(check bool) "key failure stops loading" true
    ((Core.state failed.next).snapshot.startup.local_access=Core.Local_unavailable Core.Local_key_unavailable);
  let restoring = Core.step (cold_start ()) (Core.Restore_local_account {user_id="user"}) in
  let absent = Core.step restoring.next (load_catalog_completion restoring.effects None) in
  Alcotest.(check bool) "missing catalog stops loading" true
    ((Core.state absent.next).snapshot.startup.local_access=Core.Local_unavailable Core.Local_catalog_unavailable)
;;
let appearance_is_scoped_and_authentication_is_required () =
  let attached = local_attached () in
  let ticket = timeline_ticket attached.next in
  let stale = {ticket with startup={ticket.startup with presentation_generation=ticket.startup.presentation_generation+1}} in
  let ignored = Core.step attached.next (Core.Timeline_presented stale) in
  Alcotest.(check bool) "stale appearance leaves gate closed" true
    ((Core.state ignored.next).snapshot.startup.network_phase=Core.Local_only);
  let shown = Core.step attached.next (Core.Timeline_presented ticket) in
  no_network "appearance authorizes authentication, not anonymous sync" shown.effects;
  Alcotest.(check bool) "current appearance opens phase" true
    ((Core.state shown.next).snapshot.startup.network_phase=Core.Online_after_timeline);
  let online = Core.step shown.next (Core.Account_authenticated {user_id=Some "user"}) in
  Alcotest.(check bool) "verified authentication starts websocket" true
    (List.exists (function Core.Run (Core.Start_websocket _) -> true | _ -> false) online.effects);
  let stopped=Core.step online.next (Core.Online_cancelled (startup_ticket online.next)) in
  Alcotest.(check bool) "closing permission retires its socket owner" true
    (List.exists (function Core.Run (Core.Close_websocket _) -> true | _ -> false) stopped.effects);
  let connection=List.find_map (function Core.Run(Core.Start_websocket request)->Some request.scope|_->None) online.effects |> Option.get in
  let retry=Core.step stopped.next (Core.Sign_in_requested (startup_ticket stopped.next)) in
  let retry=Core.step retry.next (Core.Account_authenticated {user_id=Some "user"}) in
  let retired=Core.step retry.next (Core.Websocket_retired connection) in
  Alcotest.(check bool) "retry while old socket retires is resumed after retirement" true
    (List.exists (function Core.Run(Core.Start_websocket _)->true|_->false) retired.effects);
  let duplicate = Core.step online.next (Core.Timeline_presented ticket) in
  Alcotest.(check int) "duplicate appearance is inert" 0 (List.length duplicate.effects);
  let changed = Core.step shown.next (Core.Graph_selected graph_id) in
  let stale_permission=Core.step changed.next (Core.Sign_in_requested ticket.startup) in
  Alcotest.(check bool) "old presentation cannot authorize a replacement graph" true
    ((Core.state stale_permission.next).snapshot.startup.network_phase=Core.Local_only);
  let late = Core.step changed.next (Core.Timeline_presented ticket) in
  Alcotest.(check bool) "old graph cannot open replacement gate" true
    ((Core.state late.next).snapshot.startup.network_phase=Core.Local_only);
  let cancelled = Core.step shown.next (Core.Online_cancelled (startup_ticket shown.next)) in
  no_network "late authentication after cancellation is inert"
    (Core.step cancelled.next (Core.Account_authenticated {user_id=Some "user"})).effects;
  let first = cold_start () in
  let missing = Core.step first (Core.Local_account_unavailable (startup_ticket first, Core.No_local_account)) in
  Alcotest.(check bool) "first installation has a terminal local result" true
    ((Core.state missing.next).snapshot.startup.local_access=Core.Local_unavailable Core.No_local_account);
  let granted = Core.step missing.next (Core.Sign_in_requested (startup_ticket missing.next)) in
  let authenticated = Core.step granted.next (Core.Account_authenticated {user_id=Some "new-user"}) in
  Alcotest.(check bool) "explicit sign-in still fetches catalog" true (has_catalog_request authenticated.effects)
;;
let cancelled_local_key_crypto_still_completes () =
  let preparation, scope = e2ee_preparation_fixture () in
  let prompt = e2ee_finish_user_fetch (e2ee_finish_graph_fetch preparation (Ok "wrapped")) (Ok "private-package") in
  let unlocking = Core.step prompt.next (password_event prompt.next "synthetic") in
  let finish_private (result : (unit, Core.effect_error) result) core = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Unlock_private_key _)) ->
      Some (Core.step core (Core.Runner_completed (Core.Completion (ticket, result))))
    | _ -> None) unlocking.effects |> Option.get in
  let cancelled = Core.step unlocking.next (Core.Online_cancelled (startup_ticket unlocking.next)) in
  let failed = finish_private (Error (Core.Effect_failed "synthetic failure")) cancelled.next in
  Alcotest.(check bool) "cancelled private-key failure cannot reopen unusable prompt" false
    (Core.state failed.next).snapshot.startup.awaiting_e2ee_password;
  let key = finish_private (Ok ()) cancelled.next in
  let loaded = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Fetch_and_unlock_graph_key _)) ->
      let cancelled = Core.step key.next (Core.Online_cancelled (startup_ticket key.next)) in
      Some (Core.step cancelled.next (Core.Runner_completed (Core.Completion
        (ticket, Ok (Core.graph_key_handle ~id:"recovered-local-key" ~scope)))))
    | _ -> None) key.effects |> Option.get in
  no_network "local key completion cannot begin remote snapshot after cancellation" loaded.effects;
  Alcotest.(check bool) "local wrapped-key unlock result remains usable" true
    (Option.fold ~none:false ~some:(fun (context : Core.asset_context) -> Option.is_some context.key) (Core.asset_context loaded.next))
;;
let local_staged_asset_publication_is_available_offline () =
  let attached = local_attached () in
  let scope = Core.admitted_graph_scope attached.next |> Option.get in
  let issued = Core.step attached.next (Core.Asset_requested
    {scope; operation="offline-publish";
     action=Core.Publish_staged_asset {asset=graph_id; version=asset_version; file="synthetic-staged-reference"}}) in
  Alcotest.(check bool) "local staged content can enter local cache while offline" true
    (List.exists (function Core.Run (Core.Asset_io (_, {action=Core.Publish_staged_asset _; _})) -> true | _ -> false) issued.effects)
;;
let cancellation_fences_deferred_catalog_and_snapshot () =
  let restoring = Core.step (cold_start ()) (Core.Restore_local_account {user_id="user"}) in
  let granted = Core.step restoring.next (Core.Sign_in_requested (startup_ticket restoring.next)) in
  let verified = Core.step granted.next (Core.Account_authenticated {user_id=Some "user"}) in
  let cancelled = Core.step verified.next (Core.Online_cancelled (startup_ticket verified.next)) in
  let cache = Core.catalog_cache ~user_id:"user" ~graphs:[graph] ~selected_graph:(Some graph_id) in
  let loaded = Core.step cancelled.next (load_catalog_completion restoring.effects (Some cache)) in
  no_network "deferred authentication cannot restart catalog after cancellation" loaded.effects;
  Alcotest.(check bool) "local completion cannot restore online authentication" false
    (Core.state loaded.next).snapshot.startup.authenticated;
  let requested, _ = begin_snapshot_bootstrap () in
  let cancelled = Core.step requested.next (Core.Online_cancelled (startup_ticket requested.next)) in
  List.iter (function
    | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
      let late = Core.step cancelled.next (Core.Runner_completed
        (Core.Completion (ticket, Ok {|{"ok":true,"t":42,"url":"https://example.com/snapshot"}|}))) in
      check_instructions "cancelled snapshot metadata completion" [] late.effects
    | _ -> ()) requested.effects;
  let facts = (Core.state cancelled.next).snapshot.startup in
  Alcotest.(check bool) "cancelled metadata has a terminal local result" true
    (match facts.local_access with Core.Local_unavailable _ -> true | _ -> false)
;;
let online_cancellation_preserves_local_restore () =
  let restoring = Core.step (cold_start ()) (Core.Restore_local_account {user_id="user"}) in
  let cancelled = Core.step restoring.next (Core.Online_cancelled (startup_ticket restoring.next)) in
  let facts = (Core.state cancelled.next).snapshot.startup in
  Alcotest.(check bool) "local catalog load remains pending" true
    (facts.restoring_local && facts.local_access = Core.Local_pending);
  Alcotest.(check bool) "online cancellation does not retire local resources" false
    (List.exists (function Core.Run (Core.Cancel_effects _) -> true | _ -> false) cancelled.effects);
  let cache = Core.catalog_cache ~user_id:"user" ~graphs:[graph] ~selected_graph:(Some graph_id) in
  let loaded = Core.step cancelled.next (load_catalog_completion restoring.effects (Some cache)) in
  ignore (inspect_mirror_request loaded.effects);
  let selected, request = local_selected ~encrypted:true () in
  let keys = Core.step selected.next (Core.Mirror_inspected (Core.Mirror_available request)) in
  let cancelled = Core.step keys.next (Core.Online_cancelled (startup_ticket keys.next)) in
  let completion = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key scope)) ->
      let key = Core.graph_key_handle ~id:"retained-local-key" ~scope in
      Some (Core.Runner_completed (Core.Completion (ticket, Ok key)))
    | _ -> None) keys.effects |> Option.get in
  let loaded = Core.step cancelled.next completion in
  Alcotest.(check bool) "pending local key completion still attaches graph" true
    (List.exists (function Core.Delegate (Core.Attach_graph _) -> true | _ -> false) loaded.effects)
;;
(* The pure owner can reproduce authenticated Local_only by public timeline,
   identity and graph-selection events; no native-result forgery is required. *)
let authenticated_local_catalog_refresh_waits_for_permission () =
  let attached=local_attached () in
  let shown=Core.step attached.next (Core.Timeline_presented (timeline_ticket attached.next)) in
  let verified=Core.step shown.next (Core.Account_authenticated {user_id=Some "user"}) in
  let selected=Core.step verified.next (Core.Graph_selected graph_id) in
  let startup=(Core.state selected.next).snapshot.startup in
  Alcotest.(check bool) "graph switch preserves identity while returning local" true
    (startup.authenticated && startup.network_phase=Core.Local_only);
  let refresh=Core.step selected.next (Core.Catalog_refresh_requested (startup_ticket selected.next)) in
  no_network "catalog refresh waits for native permission and identity round-trip" refresh.effects;
  Alcotest.(check bool) "native permission phase is published" true
    (List.exists (function Core.Publish (Core.State_changed state) ->
      state.snapshot.startup.network_phase=Core.Online_by_user | _ -> false) refresh.effects);
  let duplicate=Core.step refresh.next (Core.Catalog_refresh_requested (startup_ticket refresh.next)) in
  no_network "repeated refresh cannot bypass pending native permission" duplicate.effects;
  let confirmed=Core.step duplicate.next (Core.Account_authenticated {user_id=Some "user"}) in
  Alcotest.(check bool) "confirmed identity starts catalog refresh" true
    (has_catalog_request confirmed.effects);
  let repeated=Core.step confirmed.next (Core.Catalog_refresh_requested (startup_ticket confirmed.next)) in
  Alcotest.(check bool) "already online refresh remains direct" true (has_catalog_request repeated.effects)
;;
let scenarios = scenarios @
  [ Alcotest.test_case "authenticated local catalog refresh waits for permission" `Quick authenticated_local_catalog_refresh_waits_for_permission
  ; Alcotest.test_case "cancelled local key crypto completes without reopening password" `Quick cancelled_local_key_crypto_still_completes
  ; Alcotest.test_case "local staged asset publishes offline" `Quick local_staged_asset_publication_is_available_offline
  ; Alcotest.test_case "cancellation fences deferred catalog and snapshot metadata" `Quick cancellation_fences_deferred_catalog_and_snapshot
  ; Alcotest.test_case "online cancellation retains pending local restoration" `Quick online_cancellation_preserves_local_restore
  ; Alcotest.test_case "local startup emits zero network work" `Quick local_startup_has_no_network
  ; Alcotest.test_case "local insufficiency stops loading without network fallback" `Quick missing_local_data_stops_loading
  ; Alcotest.test_case "native appearance and explicit online permissions are scoped" `Quick appearance_is_scoped_and_authentication_is_required ]
;;

(* User graph selection owns the decision to download an absent mirror. A cold
   restore and unrelated storage/key failures still require explicit recovery. *)
let user_selected_missing_mirror () =
  let selected, _ = local_selected () in
  let chosen = Core.step selected.next (Core.Graph_selected graph_id) in
  let request = inspect_mirror_request chosen.effects in
  let missing = Core.step chosen.next (Core.Mirror_inspected (Core.Mirror_absent request.scope)) in
  no_network "selection requests native permission before remote work" missing.effects;
  let facts = (Core.state missing.next).snapshot.startup in
  Alcotest.(check bool) "absent user selection publishes online permission without error" true
    (facts.network_phase = Core.Online_by_user && facts.failure = None
     && facts.local_access = Core.Local_pending && not facts.authenticated);
  let confirmed = Core.step missing.next (Core.Account_authenticated {user_id=Some "user"}) in
  let downloading = confirmed in
  Alcotest.(check bool) "verified selection starts one metadata request" true
    (List.exists (function Core.Run(Core.Request(_,Core.Fetch_snapshot_metadata _))->true|_->false) downloading.effects);
  let failure = List.find_map (function
    | Core.Run(Core.Request(ticket,Core.Fetch_snapshot_metadata _)) ->
      Some (Core.Runner_completed(Core.Completion(ticket,Error(Core.Effect_failed "synthetic offline"))))
    | _ -> None) downloading.effects |> Option.get in
  let failed = Core.step downloading.next failure in
  Alcotest.(check bool) "download failure remains terminal instead of auto-retrying" true
    ((Core.state failed.next).snapshot.startup.failure = Some Core.During_bootstrap);
  no_network "failed request has no automatic retry" failed.effects;
  let retry = Core.step failed.next (Core.Online_recovery_requested (timeline_ticket failed.next)) in
  ignore (inspect_mirror_request retry.effects)
;;

let selected_download_cancellation_and_stale_inspections () =
  let selected, old_request = local_selected () in
  let chosen = Core.step selected.next (Core.Graph_selected graph_id) in
  let request = inspect_mirror_request chosen.effects in
  let stale = Core.step chosen.next (Core.Mirror_inspected(Core.Mirror_absent old_request.scope)) in
  Alcotest.(check bool) "old inspection cannot authorize selected graph" true
    ((Core.state stale.next).snapshot.startup.network_phase = Core.Local_only);
  let missing = Core.step stale.next (Core.Mirror_inspected(Core.Mirror_absent request.scope)) in
  let cancelled = Core.step missing.next (Core.Online_cancelled(startup_ticket missing.next)) in
  no_network "cancellation keeps remote work stopped" cancelled.effects;
  let late = Core.step cancelled.next (Core.Account_authenticated {user_id=Some "user"}) in
  no_network "late identity cannot resume cancelled download" late.effects;
  Alcotest.(check bool) "cancelled download offers explicit mirror recovery" true
    ((Core.state late.next).snapshot.startup.local_access = Core.Local_unavailable Core.Local_mirror_unavailable);
  let retry=Core.step late.next (Core.Online_recovery_requested(timeline_ticket late.next)) in
  let confirmed=Core.step retry.next (Core.Account_authenticated {user_id=Some "user"}) in
  ignore(inspect_mirror_request confirmed.effects);
  let replacement = Core.step chosen.next (Core.Graph_selected graph_id) in
  let retired = Core.step replacement.next (Core.Mirror_inspected(Core.Mirror_absent request.scope)) in
  no_network "replaced selection ignores previous inspection" retired.effects;
  Alcotest.(check bool) "replacement still starts locally" true
    ((Core.state retired.next).snapshot.startup.network_phase = Core.Local_only)
;;

let selected_available_mirror_keeps_local_key_failures () =
  let selected, _ = local_selected ~encrypted:true () in
  let chosen = Core.step selected.next (Core.Graph_selected graph_id) in
  let request = inspect_mirror_request chosen.effects in
  let available = Core.step chosen.next (Core.Mirror_inspected(Core.Mirror_available request)) in
  no_network "available selected mirror keeps local-only key access" available.effects;
  let completion = List.find_map (function
    | Core.Run(Core.Request(ticket,Core.Load_and_unlock_graph_key _)) ->
      Some(Core.Runner_completed(Core.Completion(ticket,Error(Core.Effect_failed "key missing"))))
    | _ -> None) available.effects |> Option.get in
  let failed=Core.step available.next completion in
  no_network "key failure is not a download request" failed.effects;
  Alcotest.(check bool) "key failure stays explicit" true
    ((Core.state failed.next).snapshot.startup.local_access=Core.Local_unavailable Core.Local_key_unavailable)
;;

let scenarios = scenarios @
  [ Alcotest.test_case "user-selected missing mirror requests direct download" `Quick user_selected_missing_mirror
  ; Alcotest.test_case "selected download cancellation and stale inspections are fenced" `Quick selected_download_cancellation_and_stale_inspections
  ; Alcotest.test_case "selected existing mirror retains local key failure" `Quick selected_available_mirror_keeps_local_key_failures ]
;;

let selected_encrypted_download_retains_crypto_and_failure () =
  let selected, _ = local_selected ~encrypted:true () in
  let chosen = Core.step selected.next (Core.Graph_selected graph_id) in
  let request=inspect_mirror_request chosen.effects in
  let missing=Core.step chosen.next (Core.Mirror_inspected(Core.Mirror_absent request.scope)) in
  Alcotest.(check bool) "encrypted selection opens scoped permission" true
    ((Core.state missing.next).snapshot.startup.network_phase=Core.Online_by_user);
  let confirmed=Core.step missing.next (Core.Account_authenticated {user_id=Some "user"}) in
  let keys=confirmed in
  Alcotest.(check bool) "encrypted selection still requires local key validation" true
    (List.exists (function Core.Run(Core.Request(_,Core.Load_and_unlock_graph_key _))->true|_->false) keys.effects);
  let missing_key=List.find_map (function
    | Core.Run(Core.Request(ticket,Core.Load_and_unlock_graph_key _)) ->
      Some(Core.Runner_completed(Core.Completion(ticket,Error(Core.Effect_failed "key missing"))))
    | _ -> None) keys.effects |> Option.get in
  let remote=Core.step keys.next missing_key in
  let failed=List.find_map (function
    | Core.Run(Core.Request(ticket,Core.Fetch_e2ee_graph_key _)) ->
      Some(Core.step remote.next (Core.Runner_completed(Core.Completion(ticket,Error(Core.Effect_failed "synthetic key server offline")))))
    | _ -> None) remote.effects |> Option.get in
  Alcotest.(check bool) "key recovery failure remains visible" true
    ((Core.state failed.next).snapshot.startup.failure=Some Core.During_e2ee);
  no_network "key recovery failure does not auto-repeat" failed.effects
;;
let scenarios=scenarios @ [Alcotest.test_case "selected encrypted download retains key validation and bounded failure" `Quick selected_encrypted_download_retains_crypto_and_failure]
;;

(* The stream is live: a write after metadata may already be present in the
   artifact. Core must still replay every journal position after metadata t,
   and only durable application may advance that cursor. *)
let snapshot_live_stream_catchup_keeps_metadata_cursor () =
  let opened, connection, sync = snapshot_catchup_fixture () in
  Alcotest.(check bool)
    "initial catchup starts at metadata t"
    true
    (pull_sends opened.effects = [ connection, Some (server_cursor_of_int 42) ]);
  let hello =
    pull_message
      opened.next
      connection
      (Protocol.Server.Hello { t = server_cursor_of_int 44; checksum = None })
  in
  let changed =
    pull_message
      hello.next
      connection
      (Protocol.Server.Changed { t = server_cursor_of_int 45 })
  in
  check_pull_count "head changes join the in-flight catchup" 0 changed.effects;
  Alcotest.(check (option cursor_testable))
    "later live stream writes cannot skip journal positions"
    (Some (server_cursor_of_int 42))
    (Core.state changed.next).snapshot.applied_server_t;
  let received = pull_response changed.next connection ~after:42 44 in
  let batches =
    List.filter_map
      (function
        | Core.Delegate (Core.Apply_authoritative_batch batch) -> Some batch
        | _ -> None)
      received.effects
  in
  let batch =
    match batches with
    | [ batch ] -> batch
    | _ -> Alcotest.fail "one catchup batch"
  in
  Alcotest.(check (list int64))
    "every post-metadata transaction reaches the owner in order"
    [ 43L; 44L ]
    (List.map
       (fun tx ->
          Overlay.authoritative_transaction_cursor tx
          |> Logseq_db_types.Server_cursor.to_int64)
       (Overlay.authoritative_batch_transactions batch.input));
  Alcotest.(check (option cursor_testable))
    "delegation is not a durable commit"
    (Some (server_cursor_of_int 42))
    (Core.state received.next).snapshot.applied_server_t;
  let committed =
    recovery_apply received.next connection (recovery_sync sync ~checkpoint:44 1 [])
  in
  Alcotest.(check bool)
    "next catchup starts at committed t, including concurrent write"
    true
    (pull_sends committed.effects = [ connection, Some (server_cursor_of_int 44) ]);
  let final = pull_response committed.next connection ~after:44 45 in
  let committed =
    recovery_apply final.next connection (recovery_sync sync ~checkpoint:45 2 [])
  in
  Alcotest.(check (option cursor_testable))
    "all concurrent writes are durably acknowledged"
    (Some (server_cursor_of_int 45))
    (Core.state committed.next).snapshot.applied_server_t;
  check_pull_count "caught up has no redundant pull" 0 committed.effects;
  let repeated = pull_response committed.next connection ~after:42 45 in
  Alcotest.(check bool)
    "repeated catchup cannot reapply committed transactions"
    false
    (List.exists
       (function
         | Core.Delegate (Core.Apply_authoritative_batch _) -> true
         | _ -> false)
       repeated.effects)
;;

let snapshot_failure_and_retry_keep_cursor_uncommitted () =
  List.iter
    (fun activation_failure ->
       let requested, _scope = begin_snapshot_bootstrap () in
       let download =
         List.find_map
           (function
             | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
               Some
                 (Core.step
                    requested.next
                    (Core.Runner_completed
                       (Core.Completion
                          ( ticket
                          , Ok
                              {|{"ok":true,"t":42,"key":"stream/graph.snapshot","url":"https://example.com/snapshot","content-encoding":"gzip"}|}
                          ))))
             | _ -> None)
           requested.effects
         |> Option.get
       in
       let failed, late_completion =
         List.find_map
           (function
             | Core.Run (Core.Request (ticket, Core.Download_snapshot download_request)) ->
               let artifact =
                 Core.stage_snapshot_download download_request ~path:"/tmp/synthetic-snapshot" ~expected_rows:1 |> Result.get_ok
               in
               let completion =
                 Core.Runner_completed (Core.Completion (ticket, Ok artifact))
               in
               let failed =
                 if activation_failure
                 then (
                   let activating = Core.step download.next completion in
                   Core.step
                     activating.next
                     (Core.Snapshot_activation_failed (Core.snapshot_activation_failed
                       (snapshot_activation_request activating.effects)
                       ~message:"synthetic activation failure")))
                 else
                   Core.step
                     download.next
                     (Core.Runner_completed
                        (Core.Completion
                           (ticket, Error (Core.Effect_failed "synthetic stream failure"))))
               in
               Some (failed, completion)
             | _ -> None)
           download.effects
         |> Option.get
       in
       Alcotest.(check (option cursor_testable))
         "failed bootstrap cannot publish a cursor"
         None
         (Core.state failed.next).snapshot.applied_server_t;
       Alcotest.(check bool)
         "failure stays visible"
         true
         ((Core.state failed.next).snapshot.startup.failure = Some Core.During_bootstrap);
       let stale = Core.step failed.next late_completion in
       check_instructions
         "completed download ticket cannot be consumed twice"
         []
         stale.effects;
       let retry =
         Core.step
           stale.next
           (Core.Online_recovery_requested (timeline_ticket stale.next))
       in
       let mirror = inspect_mirror_request retry.effects in
       let missing =
         Core.step retry.next (Core.Mirror_inspected (Core.Mirror_absent mirror.scope))
       in
       Alcotest.(check bool)
         "retry obtains fresh metadata without a preliminary pull"
         true
         (List.exists
            (function
              | Core.Run (Core.Request (_, Core.Fetch_snapshot_metadata _)) -> true
              | _ -> false)
            missing.effects
          && not
               (List.exists
                  (function
                    | Core.Run (Core.Request (_, Core.Fetch_snapshot_baseline _)) -> true
                    | _ -> false)
                  missing.effects)))
    [ false; true ]
;;

let scenarios =
  scenarios
  @ [ Alcotest.test_case
        "live snapshot catchup preserves metadata cursor"
        `Quick
        snapshot_live_stream_catchup_keeps_metadata_cursor
    ; Alcotest.test_case
        "snapshot stream and activation failure retry"
        `Quick
        snapshot_failure_and_retry_keep_cursor_uncommitted
    ]
;;

let replaced_snapshot_completions_are_inert () =
  let other = { graph with graph_id =
    Logseq_db_types.Graph_types.Uuid.of_string "22222222-2222-4222-8222-222222222222"
    |> Result.get_ok } in
  List.iter (fun download_pending ->
    let requested, _old_scope = begin_snapshot_bootstrap ~graphs:[graph; other] () in
    let metadata (result : (Core.snapshot_metadata, Core.effect_error) result) = List.find_map (function
      | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
        Some (Core.Runner_completed (Core.Completion (ticket, result)))
      | _ -> None) requested.effects |> Option.get in
    let old_owner, successes, failure =
      if download_pending then (
        let downloading = Core.step requested.next
          (metadata (Ok {|{"ok":true,"t":42,"url":"https://example.com/old"}|})) in
        List.find_map (function
          | Core.Run (Core.Request (ticket, Core.Download_snapshot download_request)) ->
            let artifact = Core.stage_snapshot_download download_request ~path:"/tmp/synthetic-old" ~expected_rows:1 |> Result.get_ok in
            Some (downloading.next,
              [Core.Runner_completed (Core.Completion (ticket, Ok artifact))],
              Core.Runner_completed (Core.Completion
                (ticket, Error (Core.Effect_failed "obsolete stream"))))
          | _ -> None) downloading.effects |> Option.get)
      else requested.next,
        [metadata (Ok {|{"ok":true,"t":42,"url":"https://example.com/old"}|});
         metadata (Ok {|{"ok":true,"url":"https://example.com/invalid"}|})],
        metadata (Error (Core.Effect_failed "obsolete metadata")) in
    let selected = Core.step old_owner (Core.Graph_selected other.graph_id) in
    let inspection = inspect_mirror_request selected.effects in
    let current = Core.step selected.next
      (Core.Mirror_inspected (Core.Mirror_absent inspection.scope)) in
    List.iter (fun completion ->
      let late = Core.step current.next completion in
      check_instructions "replaced snapshot completion has no effects" [] late.effects;
      check_observed "replaced snapshot" "current owner is unchanged"
        (observe current.next) (observe late.next);
      let fresh = List.find_map (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
          Some (Core.step late.next (Core.Runner_completed (Core.Completion
            (ticket, Ok {|{"ok":true,"t":84,"url":"https://example.com/current"}|}))))
        | _ -> None) current.effects |> Option.get in
      List.find_map (function
        | Core.Run (Core.Request (ticket, Core.Download_snapshot request)) ->
          Alcotest.(check bool) "fresh download retains graph and URL" true
            (Core.snapshot_download_scope request = inspection.scope && Core.snapshot_download_uri request = Uri.of_string "https://example.com/current");
          let artifact = Core.stage_snapshot_download request ~path:"/tmp/synthetic-current" ~expected_rows:1 |> Result.get_ok in
          Some (Core.step fresh.next (Core.Runner_completed
            (Core.Completion (ticket, Ok artifact))))
        | _ -> None) fresh.effects |> Option.get |> fun activation ->
      Alcotest.(check bool) "fresh activation keeps its own graph and cursor" true
        (List.exists (function
          | Core.Delegate (Core.Activate_snapshot request) ->
            Core.snapshot_activation_scope request = inspection.scope && Core.snapshot_activation_cursor request = server_cursor_of_int 84
          | _ -> false) activation.effects)) (successes @ [failure])) [false; true]
;;

let scenarios = scenarios @ [ Alcotest.test_case
  "replaced snapshot metadata and download completions are inert" `Quick
  replaced_snapshot_completions_are_inert ]
;;

let snapshot_artifact_from_retried_attempt_is_rejected () =
  let requested, _ = begin_snapshot_bootstrap () in
  let metadata (origin : Core.transition) cursor =
    List.find_map (function
      | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
        Some (Core.step origin.next (Core.Runner_completed (Core.Completion
          (ticket, Ok (Printf.sprintf "{\"ok\":true,\"t\":%d,\"url\":\"https://example.com/snapshot\"}" cursor)))))
      | _ -> None) origin.effects |> Option.get in
  let old = metadata requested 42 in
  let failed, old_artifact, old_scope = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Download_snapshot request)) ->
      let artifact = Core.stage_snapshot_download request ~path:"/tmp/synthetic-attempt-a"
        ~expected_rows:1 |> Result.get_ok in
      Some (Core.step old.next (Core.Runner_completed (Core.Completion
        (ticket, Error (Core.Effect_failed "synthetic interrupted stream")))), artifact,
        Core.snapshot_download_scope request)
    | _ -> None) old.effects |> Option.get in
  let retry = Core.step failed.next (Core.Online_recovery_requested (timeline_scope failed.next)) in
  let mirror = inspect_mirror_request retry.effects in
  let missing = Core.step retry.next (Core.Mirror_inspected (Core.Mirror_absent mirror.scope)) in
  let current = metadata missing 84 in
  let mismatch = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Download_snapshot request)) ->
      Alcotest.(check bool) "retry changes the generation of this production graph scope" false
        (Core.snapshot_download_scope request = old_scope);
      Some (Core.step current.next (Core.Runner_completed (Core.Completion (ticket, Ok old_artifact))))
    | _ -> None) current.effects |> Option.get in
  Alcotest.(check bool) "foreign attempt cannot activate" false
    (List.exists (function Core.Delegate (Core.Activate_snapshot _) -> true | _ -> false) mismatch.effects);
  Alcotest.(check bool) "mismatch terminates bootstrap with visible failure" true
    ((Core.state mismatch.next).snapshot.startup.failure = Some Core.During_bootstrap)
;;

let scenarios = scenarios @ [ Alcotest.test_case
  "old snapshot artifact cannot complete a fresh request" `Quick
  snapshot_artifact_from_retried_attempt_is_rejected ]
;;

let failed_snapshot_activation_receipts_are_inert () =
  let activating = snapshot_activation_fixture () in
  let request = snapshot_activation_request activating.effects in
  let failure = Core.Snapshot_activation_failed
    (Core.snapshot_activation_failed request ~message:"synthetic activation failure") in
  let failed = Core.step activating.next failure in
  let success = Core.Snapshot_activated (Core.snapshot_activation_completed request) in
  List.iter (fun event ->
    let late = Core.step failed.next event in
    check_observed "retired activation" "old receipt preserves failed owner"
      (observe failed.next) (observe late.next);
    check_instructions "retired activation receipt" [] late.effects) [success; failure]
;;

let scenarios = scenarios @ [ Alcotest.test_case
  "late activation success and failure cannot reopen failed bootstrap" `Quick
  failed_snapshot_activation_receipts_are_inert ]
;;

let sync_cursor_diagnostic core label =
  (Core.state core).diagnostics.groups
  |> List.concat_map (fun (group : Core.diagnostic_group) -> group.entries)
  |> List.assoc_opt label
;;

let diagnostics_observe_remote_cursor_without_advancing_local () =
  let selected, _ = selected_graph graph in
  List.iter (fun label ->
    Alcotest.(check (option string)) (label ^ " starts unknown")
      (Some "Not available") (sync_cursor_diagnostic selected.next label))
    ["Local tx"; "Remote tx"];
  let opened, connection, _ = pull_fixture () in
  let largest = Logseq_db_types.Server_cursor.of_int64 Int64.max_int |> Result.get_ok in
  let observed = pull_message opened.next connection
    (Protocol.Server.Hello { t = largest; checksum = None }) in
  Alcotest.(check (option string)) "remote cursor retains all int64 digits"
    (Some "9223372036854775807") (sync_cursor_diagnostic observed.next "Remote tx");
  Alcotest.(check (option string)) "server notification is not a local commit"
    (Some "0") (sync_cursor_diagnostic observed.next "Local tx");
  Alcotest.(check bool) "new cursor is published while an existing pull is occupied" true
    (List.exists (function
      | Core.Publish (Core.State_changed state) ->
        List.exists (fun (group : Core.diagnostic_group) ->
          List.assoc_opt "Remote tx" group.entries = Some "9223372036854775807") state.diagnostics.groups
      | _ -> false) observed.effects);
  let lower = pull_message observed.next connection
    (Protocol.Server.Changed { t = server_cursor_of_int 1 }) in
  Alcotest.(check (option string)) "older notifications cannot lower known remote maximum"
    (Some "9223372036854775807") (sync_cursor_diagnostic lower.next "Remote tx");
  let failed = pull_message lower.next connection
    (Protocol.Server.Error { message = "synthetic server failure" }) in
  Alcotest.(check (option string)) "failure retains the last server observation"
    (Some "9223372036854775807") (sync_cursor_diagnostic failed.next "Remote tx");
  let catalog = refresh_catalog lower.next [graph; other_graph] in
  let switched = Core.step catalog.next (Core.Graph_selected other_graph.graph_id) in
  List.iter (fun label ->
    Alcotest.(check (option string)) (label ^ " clears on graph switch")
      (Some "Not available") (sync_cursor_diagnostic switched.next label))
    ["Local tx"; "Remote tx"];
  let stale = pull_message switched.next connection
    (Protocol.Server.Changed { t = largest }) in
  Alcotest.(check (option string)) "old graph messages cannot repopulate remote cursor"
    (Some "Not available") (sync_cursor_diagnostic stale.next "Remote tx");
  let account = Core.step observed.next (Core.Account_authenticated {user_id=Some "other-user"}) in
  Alcotest.(check (option string)) "account switch removes old graph cursor rows"
    None (sync_cursor_diagnostic account.next "Remote tx")
;;

let diagnostics_local_cursor_tracks_authoritative_commit () =
  let opened, connection, _ = pull_fixture () in
  let received = pull_response opened.next connection ~after:0 1 in
  Alcotest.(check (option string)) "received authoritative data is not committed yet"
    (Some "0") (sync_cursor_diagnostic received.next "Local tx");
  Alcotest.(check (option string)) "pull response observes the remote cursor"
    (Some "1") (sync_cursor_diagnostic received.next "Remote tx");
  let sync = Overlay.sync_view
    ~token:(token Overlay.sync_token_of_string "sync-token:v1:diagnostic-commit")
    ~checkpoint:(server_cursor_of_int 1) ~submissions:[] in
  let committed = recovery_apply received.next connection sync in
  Alcotest.(check (option string)) "only authoritative completion advances local cursor"
    (Some "1") (sync_cursor_diagnostic committed.next "Local tx");
  Alcotest.(check (option string)) "completed catchup retains remote cursor"
    (Some "1") (sync_cursor_diagnostic committed.next "Remote tx");
  let selected, scope = selected_graph graph in
  let inspected = Core.step selected.next
    (Core.Mirror_inspected (Core.Mirror_available {graph;scope})) in
  let largest = Logseq_db_types.Server_cursor.of_int64 Int64.max_int |> Result.get_ok in
  let sync = Overlay.sync_view ~token:(Overlay.sync_view_token sync)
    ~checkpoint:largest ~submissions:[] in
  let attached = Core.step inspected.next (Core.Graph_attached {scope;sync}) in
  Alcotest.(check (option string)) "restored checkpoint retains all int64 digits"
    (Some "9223372036854775807") (sync_cursor_diagnostic attached.next "Local tx");
  Alcotest.(check (option string)) "local checkpoint does not invent server evidence"
    (Some "Not available") (sync_cursor_diagnostic attached.next "Remote tx")
;;

let scenarios = scenarios @
  [ Alcotest.test_case "diagnostics observes scoped remote cursor" `Quick
      diagnostics_observe_remote_cursor_without_advancing_local
  ; Alcotest.test_case "diagnostics local cursor follows durable commit" `Quick
      diagnostics_local_cursor_tracks_authoritative_commit
  ]
;;

let diagnostics_snapshot_metadata_is_remote_evidence () =
  let activating = snapshot_activation_fixture () in
  Alcotest.(check (option string)) "snapshot metadata observes remote progress before activation"
    (Some "42") (sync_cursor_diagnostic activating.next "Remote tx");
  Alcotest.(check (option string)) "download cannot publish an uncommitted local checkpoint"
    (Some "Not available") (sync_cursor_diagnostic activating.next "Local tx")
;;

let scenarios = scenarios @ [ Alcotest.test_case
  "diagnostics snapshot metadata is remote evidence" `Quick
  diagnostics_snapshot_metadata_is_remote_evidence ]
;;

let diagnostics_rejection_observes_remote_cursor () =
  let core, connection = submitted_core () in
  let rejection : Protocol.rejection =
    { reason = Stale; t = Some (server_cursor_of_int 7); checksum = None
    ; success_tx_ids = []; failed_tx_id = None; missing_block_uuids = []
    ; error_detail = None; data = None } in
  let rejected = pull_message core connection (Protocol.Server.Tx_reject rejection) in
  Alcotest.(check (option string)) "valid stale rejection observes server progress"
    (Some "7") (sync_cursor_diagnostic rejected.next "Remote tx");
  Alcotest.(check (option string)) "rejection does not commit authoritative changes"
    (Some "0") (sync_cursor_diagnostic rejected.next "Local tx")
;;

let scenarios = scenarios @ [ Alcotest.test_case
  "diagnostics rejection observes remote cursor" `Quick
  diagnostics_rejection_observes_remote_cursor ]
;;

(* Catalog advisory diagnostics are owned by this public reducer. A valid
   producer error is not an injected incorrect external result. *)
let catalog_save_keeps_the_safe_producer_cause () =
  let module D = Logseq_db_types.Failure_diagnostic in
  let selected, _ = selected_graph graph in
  let event = List.find_map (function
    | Core.Run (Core.Request (ticket, Core.Save_catalog _)) ->
      let diagnostic = D.create ~operation:"saveCatalog" ~reason:"persistenceFailed"
        ~source:"Unix.Unix_error(Unix.ENOSPC,PRIVATE_PATH,PRIVATE_PATH)" () in
      Some (Core.Runner_completed (Core.Completion (ticket, Error (Core.Effect_failed (D.encode diagnostic)))))
    | _ -> None) selected.effects |> Option.get in
  let transition = Core.step selected.next event in
  ignore (check_replay "catalog-safe-error" selected.next event transition);
  let before = Core.state selected.next and after = Core.state transition.next in
  Alcotest.(check bool) "advisory failure preserves graph and startup state" true
    (before.snapshot = after.snapshot);
  let text = after.diagnostics.groups |> List.concat_map (fun (g:Core.diagnostic_group) -> List.map snd g.entries)
    |> String.concat "\n" in
  let contains text part =
    let rec loop n = n + String.length part <= String.length text &&
      (String.sub text n (String.length part)=part || loop(n+1)) in loop 0 in
  Alcotest.(check bool) "catalog advisory preserves original safe reason" true
    (contains text "Persistence failed" && contains text "Storage has no free space");
  Alcotest.(check bool) "catalog advisory excludes raw path" false (contains text "PRIVATE_PATH");
  Alcotest.(check bool) "catalog advisory displays message, not a wire carrier" false
    (contains text "journal-failure:v1:")
;;
let scenarios = scenarios @ [Alcotest.test_case "catalog save retains safe producer cause" `Quick
  catalog_save_keeps_the_safe_producer_cause]
;;
