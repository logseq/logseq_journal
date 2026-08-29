module Core = Logseq_sync.Core

let fail format = Printf.ksprintf (fun message -> Alcotest.fail message) format

let contains source needle =
  let rec loop offset =
    offset + String.length needle <= String.length source
    && (String.equal (String.sub source offset (String.length needle)) needle
        || loop (offset + 1))
  in
  loop 0
;;

let limits () =
  Core.limits
    ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
    ~maximum_artifact_bytes:(1024 * 1024 * 1024)
    ~submission_batch_size:32
  |> Result.get_ok
;;

let config () =
  Core.config
    ~managed_sync_origin:(Uri.of_string "https://api.logseq.io")
    ~limits:(limits ())
  |> Result.get_ok
;;

let initial () = Core.initial (config ()) |> Result.get_ok

let token_request effects =
  List.find_map
    (function
      | Core.Publish (Core.Token_requested request) -> Some request
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some request -> request
  | None -> fail "transition did not publish a token request"
;;

let fetch_catalog_completion effects (graphs : Core.graph list) =
  let rec find = function
    | [] -> fail "transition did not request the remote catalog"
    | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) :: _ ->
      Core.Runner_completed (Core.Completion (ticket, Ok graphs))
    | _ :: rest -> find rest
  in
  find effects
;;

let test_config_validation_is_pure_and_bounded () =
  let invalid =
    Core.limits
      ~maximum_response_bytes:0
      ~maximum_artifact_bytes:1
      ~submission_batch_size:1
  in
  Alcotest.check
    Alcotest.bool
    "zero response bound is rejected"
    true
    (Result.is_error invalid);
  let limits = limits () in
  let insecure =
    Core.config ~managed_sync_origin:(Uri.of_string "http://api.logseq.io") ~limits
  in
  Alcotest.check
    Alcotest.bool
    "non-TLS origin is rejected"
    true
    (Result.is_error insecure)
;;

let test_step_is_immutable_and_replayable () =
  let core = initial () in
  let before = Core.state core in
  let event = Core.Account_authenticated { user_id = Some "user-1" } in
  let first = Core.step core event in
  let replay = Core.step core event in
  Alcotest.check
    Alcotest.bool
    "input state remains unchanged"
    true
    (Core.state core = before);
  Alcotest.check
    Alcotest.bool
    "replayed states are equal"
    true
    (Core.state first.next = Core.state replay.next);
  Alcotest.check
    Alcotest.bool
    "replayed ordered effects are equal"
    true
    (Core.equal_instructions first.effects replay.effects);
  Alcotest.check
    Alcotest.bool
    "authentication enters the connecting phase"
    true
    ((Core.state first.next).snapshot.sync_phase = Core.Connecting)
;;

let test_stale_and_duplicate_token_events_are_rejected () =
  let first_auth =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let first_request = token_request first_auth.effects in
  let second_auth =
    Core.step first_auth.next (Account_authenticated { user_id = Some "user-2" })
  in
  let second_request = token_request second_auth.effects in
  let stale =
    Core.step second_auth.next (Token_provided (first_request, "stale-token"))
  in
  Alcotest.check
    Alcotest.bool
    "stale token response does not mutate state"
    true
    (Core.state stale.next = Core.state second_auth.next);
  Alcotest.(check int) "stale token response emits nothing" 0 (List.length stale.effects);
  let rejected = Core.step stale.next (Token_rejected second_request) in
  Alcotest.check
    Alcotest.bool
    "current rejection fails the core"
    true
    ((Core.state rejected.next).snapshot.sync_phase = Core.Failed);
  let duplicate = Core.step rejected.next (Token_rejected second_request) in
  Alcotest.check
    Alcotest.bool
    "ticket-like token request is consumed once"
    true
    (Core.state duplicate.next = Core.state rejected.next && duplicate.effects = [])
;;

let test_runner_completion_is_scoped_and_consumed_once () =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let request = token_request authenticated.effects in
  let authorized = Core.step authenticated.next (Token_provided (request, "token")) in
  let completion = fetch_catalog_completion authorized.effects [] in
  let completed = Core.step authorized.next completion in
  let duplicate = Core.step completed.next completion in
  Alcotest.check
    Alcotest.bool
    "catalog completion leaves the core awaiting selection"
    true
    (Core.state completed.next).snapshot.startup.awaiting_selection;
  Alcotest.check
    Alcotest.bool
    "duplicate completion does not mutate state"
    true
    (Core.state duplicate.next = Core.state completed.next);
  Alcotest.(check int)
    "duplicate completion emits nothing"
    0
    (List.length duplicate.effects)
;;

let test_lifecycle_generation_fences_stale_events () =
  let core = initial () in
  let foreground =
    Core.step core (Foreground_changed { foreground = true; lifecycle_generation = 4L })
  in
  let stale =
    Core.step
      foreground.next
      (Foreground_changed { foreground = false; lifecycle_generation = 3L })
  in
  Alcotest.check
    Alcotest.bool
    "older lifecycle generation is ignored"
    true
    (Core.state stale.next = Core.state foreground.next && stale.effects = [])
;;

let test_shutdown_is_idempotent () =
  let core = initial () in
  let stopped = Core.step core Shutdown in
  let stopped_again = Core.step stopped.next Shutdown in
  let ignored =
    Core.step stopped_again.next (Account_authenticated { user_id = Some "ignored" })
  in
  Alcotest.check
    Alcotest.bool
    "closed core remains stable"
    true
    (Core.state stopped.next = Core.state stopped_again.next
     && Core.state stopped_again.next = Core.state ignored.next
     && stopped_again.effects = []
     && ignored.effects = [])
;;

let graph_id () =
  Logseq_db_types.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111"
  |> Result.get_ok
;;

let graph_scope () =
  let account : Core.account_scope =
    { managed_sync_origin = Uri.of_string "https://api.logseq.io"
    ; user_id = "user-1"
    ; account_generation = 1
    ; presentation_generation = 1
    ; lifecycle_generation = 1L
    }
  in
  Core.{ account; graph_id = graph_id (); graph_generation = 1 }
;;

let other_graph_id () =
  Logseq_db_types.Graph_types.Uuid.of_string "99999999-9999-4999-8999-999999999999"
  |> Result.get_ok
;;

let graph ?(encrypted = false) () : Core.graph =
  { graph_id = graph_id ()
  ; name = (if encrypted then "Encrypted Journal" else "Journal")
  ; schema = { major = 1; minor = 0; exact = true }
  ; encrypted
  }
;;

let other_graph () : Core.graph =
  { graph_id = other_graph_id ()
  ; name = "Other Journal"
  ; schema = { major = 1; minor = 0; exact = true }
  ; encrypted = false
  }
;;

let graph_id_equal = Logseq_db_types.Graph_types.Uuid.equal

let save_catalog_cache effects =
  List.find_map
    (function
      | Core.Run (Core.Request (_, Core.Save_catalog cache)) -> Some cache
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some cache -> cache
  | None -> fail "transition did not save the catalog cache"
;;

let load_catalog_completion effects (cache : Core.catalog_cache option) =
  List.find_map
    (function
      | Core.Run (Core.Request (ticket, Core.Load_catalog _)) ->
        Some (Core.Runner_completed (Core.Completion (ticket, Ok cache)))
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some completion -> completion
  | None -> fail "transition did not load the catalog cache"
;;

let complete_save_catalog transition (result : (unit, Core.effect_error) result) =
  List.find_map
    (function
      | Core.Run (Core.Request (ticket, Core.Save_catalog _)) ->
        Some
          (Core.step
             transition.Core.next
             (Runner_completed (Completion (ticket, result))))
      | Run _ | Delegate _ | Publish _ -> None)
    transition.Core.effects
  |> function
  | Some completed -> completed
  | None -> fail "transition did not save the catalog cache"
;;

let inspect_mirror_request effects =
  List.find_map
    (function
      | Core.Delegate (Core.Inspect_mirror request) -> Some request
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some request -> request
  | None -> fail "transition did not inspect the selected graph mirror"
;;

let has_graph_open_work effects =
  List.exists
    (function
      | Core.Delegate (Core.Inspect_mirror _) -> true
      | Core.Delegate (Core.Attach_graph _) -> true
      | Core.Delegate (Core.Activate_snapshot _) -> true
      | Run _ | Delegate _ | Publish _ -> false)
    effects
;;

let refresh_catalog core graphs =
  let requested = Core.step core Core.Catalog_refresh_requested in
  let token = token_request requested.effects in
  let authorized = Core.step requested.next (Token_provided (token, "refresh-token")) in
  Core.step authorized.next (fetch_catalog_completion authorized.effects graphs)
;;

let checkpoint graph_id =
  Logseq_db_types.Sync_checkpoint.create
    ~graph_id
    ~schema:Logseq_db_types.Graph_types.{ major = 1; minor = 0 }
    ~applied_server_t:0
    ~checksum:"0000000000000000"
  |> Result.get_ok
;;

let select_catalog_graph (graph : Core.graph) =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let catalog_token = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Token_provided (catalog_token, "catalog-token"))
  in
  let catalog =
    Core.step authorized.next (fetch_catalog_completion authorized.effects [ graph ])
  in
  let selected = Core.step catalog.next (Graph_selected graph.graph_id) in
  let mirror_request =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_mirror request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      selected.effects
    |> function
    | Some request -> request
    | None -> fail "graph selection did not inspect its mirror"
  in
  selected, mirror_request
;;

let complete_wrapped_key (transition : Core.transition) (handle : Core.graph_key_handle) =
  List.find_map
    (function
      | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
        Some
          (Core.step transition.next (Runner_completed (Completion (ticket, Ok handle))))
      | Run _ | Delegate _ | Publish _ -> None)
    transition.effects
  |> function
  | Some completed -> completed
  | None -> fail "transition did not load a wrapped graph key"
;;

let has_snapshot_token_request effects =
  List.exists
    (function
      | Core.Publish (Core.Token_requested request) ->
        Core.token_request_purpose request = Core.Snapshot_bootstrap
      | Run _ | Delegate _ | Publish _ -> false)
    effects
;;

let has_snapshot_work effects =
  List.exists
    (function
      | Core.Run (Core.Request (_, Core.Fetch_snapshot_baseline _)) -> true
      | Core.Run (Core.Request (_, Core.Fetch_snapshot_metadata _)) -> true
      | Core.Run (Core.Request (_, Core.Download_snapshot _)) -> true
      | Core.Delegate (Core.Activate_snapshot _) -> true
      | Run _ | Delegate _ | Publish _ -> false)
    effects
;;

let graph_key_load_scope effects =
  List.find_map
    (function
      | Core.Run (Core.Request (_, Core.Load_and_unlock_graph_key scope)) -> Some scope
      | Run _ | Delegate _ | Publish _ -> None)
    effects
;;

let open_request graph scope suffix : Core.graph_open_request =
  { graph
  ; graph_directory = "/worker/" ^ suffix
  ; database_path = "/worker/" ^ suffix ^ "/db.sqlite"
  ; checkpoint = checkpoint graph.graph_id
  ; scope
  }
;;

let complete_snapshot_bootstrap (transition : Core.transition) scope =
  let snapshot_token = token_request transition.effects in
  let baseline_requested =
    Core.step transition.next (Token_provided (snapshot_token, "snapshot-token"))
  in
  let metadata_requested =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_baseline _)) ->
          Some
            (Core.step
               baseline_requested.next
               (Runner_completed
                  (Completion (ticket, Ok "{\"type\":\"pull/ok\",\"t\":7}"))))
        | Run _ | Delegate _ | Publish _ -> None)
      baseline_requested.effects
    |> function
    | Some completed -> completed
    | None -> fail "snapshot bootstrap did not fetch its baseline"
  in
  let download_requested =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
          Some
            (Core.step
               metadata_requested.next
               (Runner_completed
                  (Completion
                     (ticket, Ok "{\"ok\":true,\"url\":\"https://snapshots.example/db\"}"))))
        | Run _ | Delegate _ | Publish _ -> None)
      metadata_requested.effects
    |> function
    | Some completed -> completed
    | None -> fail "snapshot bootstrap did not fetch its metadata"
  in
  let completed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Download_snapshot _)) ->
          let artifact =
            Core.staged_artifact
              ~id:"startup-matrix-artifact"
              ~scope
              ~path:"/staging/startup-matrix.artifact"
              ~expected_rows:2
          in
          Some
            (Core.step
               download_requested.next
               (Runner_completed (Completion (ticket, Ok artifact))))
        | Run _ | Delegate _ | Publish _ -> None)
      download_requested.effects
  in
  match completed with
  | Some completed ->
    let activation =
      List.find_map
        (function
          | Core.Delegate (Core.Activate_snapshot request) -> Some request
          | Run _ | Delegate _ | Publish _ -> None)
        completed.effects
    in
    (match activation with
     | Some request -> request
     | None -> fail "snapshot bootstrap did not delegate activation")
  | None -> fail "snapshot bootstrap did not download its artifact"
;;

let encrypted_open_graph () =
  let graph = graph ~encrypted:true () in
  let selected, mirror_request = select_catalog_graph graph in
  let open_request : Core.graph_open_request =
    { graph
    ; graph_directory = "/worker/encrypted-mirror"
    ; database_path = "/worker/encrypted-mirror/db.sqlite"
    ; checkpoint = checkpoint graph.graph_id
    ; scope = mirror_request.scope
    }
  in
  let inspected =
    Core.step selected.next (Mirror_inspected (Mirror_available open_request))
  in
  let key = Core.graph_key_handle ~id:"encrypted-key" ~scope:open_request.scope in
  let keyed = complete_wrapped_key inspected key in
  let attached =
    Core.step
      keyed.next
      (Graph_attached
         { scope = open_request.scope
         ; checkpoint = open_request.checkpoint
         ; outbox_records = []
         })
  in
  let websocket_token = token_request attached.effects in
  let connecting =
    Core.step attached.next (Token_provided (websocket_token, "websocket-token"))
  in
  let connection =
    List.find_map
      (function
        | Core.Run (Core.Start_websocket request) -> Some request.scope
        | Run _ | Delegate _ | Publish _ -> None)
      connecting.effects
    |> function
    | Some connection -> connection
    | None -> fail "attached encrypted graph did not start its WebSocket"
  in
  let opened = Core.step connecting.next (Websocket_opened connection) in
  opened.next, connection
;;

let encrypted_authoritative_context (connection : Core.connection_scope) =
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let envelope =
    Codec.to_string
      (Transit.Array [ Transit.Binary "snapshot-iv"; Transit.Binary "ciphertext" ])
  in
  let wire =
    Codec.to_string
      ~mode:Codec.Verbose
      (Transit.Array
         [ Transit.Array
             [ Transit.Keyword "db/add"
             ; Transit.String "remote-block"
             ; Transit.Keyword "block/title"
             ; Transit.String envelope
             ]
         ])
  in
  let payload =
    Yojson.Safe.to_string
      (`Assoc
          [ "type", `String "pull/ok"
          ; "t", `Int 1
          ; "txs", `List [ `Assoc [ "t", `Int 1; "tx", `String wire ] ]
          ])
  in
  let batch : Core.authoritative_batch =
    { payload
    ; scope = connection
    ; presentation_generation = connection.graph.account.presentation_generation
    ; lifecycle_generation = connection.graph.account.lifecycle_generation
    }
  in
  Core.
    { batch
    ; checkpoint = checkpoint connection.graph.graph_id
    ; database = Datascript.empty_db ()
    ; outbox_records = []
    }
;;

let local_batch_input ?key operations =
  Core.local_batch_input
    ~scope:(graph_scope ())
    ~key
    ~outbox_records:[]
    ~mutation_id:(graph_id ())
    ~mutation_payload:"mutation"
    ~mutation_fingerprint:"fingerprint"
    ~outliner_op:"save-block"
    ~database:(Datascript.empty_db ())
    ~operations
  |> Result.get_ok
;;

let test_local_batch_planning_separates_crypto_from_policy () =
  let unprotected =
    local_batch_input
      [ Datascript.Add
          ( Datascript.Temp_id "new-block"
          , "block/uuid"
          , Datascript.Uuid (Logseq_db_types.Graph_types.Uuid.to_string (graph_id ())) )
      ]
    |> Core.begin_local_batch
    |> Result.get_ok
  in
  Alcotest.check
    Alcotest.bool
    "unprotected batch needs no runner crypto"
    true
    (Core.local_batch_crypto_request unprotected = None);
  let record = Core.finish_local_batch unprotected None |> Result.get_ok in
  let encoded = Core.encode_outbox_records [ record ] |> Result.get_ok in
  let decoded = Core.decode_outbox_records encoded |> Result.get_ok in
  Alcotest.check Alcotest.bool "outbox codec round-trips" true (decoded = [ record ]);
  let key = Core.graph_key_handle ~id:"runner-owned" ~scope:(graph_scope ()) in
  let protected =
    local_batch_input
      ~key
      [ Datascript.Add
          (Datascript.Temp_id "new-block", "block/title", Datascript.String "secret")
      ]
    |> Core.begin_local_batch
    |> Result.get_ok
  in
  let request = Core.local_batch_crypto_request protected |> Option.get in
  Alcotest.(check (list string))
    "only serialized protected values leave for crypto"
    [ "[\"~#'\",\"secret\"]" ]
    request.plaintexts;
  Alcotest.check
    Alcotest.bool
    "missing encrypted results are rejected"
    true
    (Result.is_error (Core.finish_local_batch protected None));
  let protected_record =
    Core.finish_local_batch protected (Some [ "iv", "ciphertext" ]) |> Result.get_ok
  in
  let encoded = Core.encode_outbox_records [ protected_record ] |> Result.get_ok in
  Alcotest.check
    Alcotest.bool
    "plaintext is absent from durable outbox"
    true
    (not (contains (String.concat "" encoded) "secret"))
;;

let test_graph_selection_delegates_mirror_authority () =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let request = token_request authenticated.effects in
  let authorized = Core.step authenticated.next (Token_provided (request, "token")) in
  let graph : Core.graph =
    { graph_id = graph_id ()
    ; name = "Journal"
    ; schema = { major = 1; minor = 0; exact = true }
    ; encrypted = false
    }
  in
  let catalog =
    Core.step authorized.next (fetch_catalog_completion authorized.effects [ graph ])
  in
  let selected = Core.step catalog.next (Graph_selected graph.graph_id) in
  Alcotest.check
    Alcotest.bool
    "selection is reflected in the new state"
    true
    (match (Core.state selected.next).snapshot.selected_graph with
     | Some selected -> Logseq_db_types.Graph_types.Uuid.equal graph.graph_id selected
     | None -> false);
  Alcotest.check
    Alcotest.bool
    "worker mirror inspection is delegated"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Inspect_mirror request) ->
           Logseq_db_types.Graph_types.Uuid.equal request.graph.graph_id graph.graph_id
         | Run _ | Delegate _ | Publish _ -> false)
       selected.effects);
  let saved = save_catalog_cache selected.effects in
  Alcotest.check
    Alcotest.bool
    "selected graph is persisted in the catalog cache"
    true
    (match Core.catalog_cache_selected_graph saved with
     | Some selected_graph -> graph_id_equal selected_graph graph.graph_id
     | None -> false)
;;

let test_selected_graph_survives_picker_and_codec_restart () =
  let graph = graph () in
  let selected, _ = select_catalog_graph graph in
  let persisted = save_catalog_cache selected.effects in
  let persisted =
    persisted |> Core.encode_catalog_cache |> Core.decode_catalog_cache |> Result.get_ok
  in
  let picker = Core.step selected.next Core.Graph_picker_requested in
  Alcotest.check
    Alcotest.bool
    "picker clears only the current process selection"
    true
    ((Core.state picker.next).snapshot.selected_graph = None
     && (Core.state picker.next).snapshot.startup.awaiting_selection);
  Alcotest.check
    Alcotest.bool
    "returning to the picker does not overwrite the durable selection"
    true
    (not
       (List.exists
          (function
            | Core.Run (Core.Request (_, Core.Save_catalog _)) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          picker.effects));
  let restoring = Core.step (initial ()) (Restore_local_account { user_id = "user-1" }) in
  let generation_before = (Core.state restoring.next).snapshot.startup.graph_generation in
  let restored =
    Core.step restoring.next (load_catalog_completion restoring.effects (Some persisted))
  in
  let snapshot = (Core.state restored.next).snapshot in
  Alcotest.check
    Alcotest.bool
    "fresh core restores the codec-round-tripped selected graph"
    true
    (match snapshot.selected_graph with
     | Some selected_graph -> graph_id_equal selected_graph graph.graph_id
     | None -> false);
  Alcotest.check
    Alcotest.bool
    "warm restore advances generation and bypasses the picker"
    true
    ((not snapshot.startup.awaiting_selection)
     && snapshot.startup.graph_generation > generation_before);
  let request = inspect_mirror_request restored.effects in
  Alcotest.check
    Alcotest.bool
    "warm restore delegates mirror inspection in the restored scope"
    true
    (graph_id_equal request.graph.graph_id graph.graph_id
     && request.scope.graph_generation = snapshot.startup.graph_generation);
  Alcotest.check
    Alcotest.bool
    "loading a catalog cache does not immediately rewrite it"
    true
    (not
       (List.exists
          (function
            | Core.Run (Core.Request (_, Core.Save_catalog _)) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          restored.effects))
;;

let check_invalid_cached_selection label cache =
  let restoring = Core.step (initial ()) (Restore_local_account { user_id = "user-1" }) in
  let restored =
    Core.step restoring.next (load_catalog_completion restoring.effects (Some cache))
  in
  let snapshot = (Core.state restored.next).snapshot in
  Alcotest.check
    Alcotest.bool
    (label ^ " awaits selection")
    true
    (snapshot.startup.awaiting_selection && snapshot.selected_graph = None);
  Alcotest.check
    Alcotest.bool
    (label ^ " starts no graph work")
    false
    (has_graph_open_work restored.effects)
;;

let test_absent_stale_and_malformed_cached_selections_fail_closed () =
  let graph = graph () in
  let absent =
    Core.catalog_cache ~user_id:"user-1" ~graphs:[ graph ] ~selected_graph:None
  in
  check_invalid_cached_selection "absent cached selection" absent;
  let stale =
    Core.catalog_cache
      ~user_id:"user-1"
      ~graphs:[ graph ]
      ~selected_graph:(Some (other_graph_id ()))
  in
  check_invalid_cached_selection "stale cached selection" stale;
  let malformed =
    Core.encode_catalog_cache absent
    |> Yojson.Safe.from_string
    |> function
    | `Assoc fields ->
      `Assoc (("selectedGraph", `String "not-a-graph-uuid") :: fields)
      |> Yojson.Safe.to_string
      |> Core.decode_catalog_cache
      |> Result.get_ok
    | _ -> fail "encoded catalog cache was not an object"
  in
  check_invalid_cached_selection "malformed cached selection" malformed
;;

let test_catalog_refresh_preserves_admitted_selection () =
  let graph = graph () in
  let selected, _ = select_catalog_graph graph in
  let before = (Core.state selected.next).snapshot in
  let refreshed = refresh_catalog selected.next [ graph; other_graph () ] in
  let after = (Core.state refreshed.next).snapshot in
  Alcotest.check
    Alcotest.bool
    "refresh preserves the admitted selected graph"
    true
    (match after.selected_graph with
     | Some selected_graph -> graph_id_equal selected_graph graph.graph_id
     | None -> false);
  Alcotest.check
    Alcotest.bool
    "refresh keeps the active graph generation and bypasses the picker"
    true
    (after.startup.graph_generation = before.startup.graph_generation
     && not after.startup.awaiting_selection);
  let saved = save_catalog_cache refreshed.effects in
  Alcotest.check
    Alcotest.bool
    "refresh persists the admitted selected graph"
    true
    (match Core.catalog_cache_selected_graph saved with
     | Some selected_graph -> graph_id_equal selected_graph graph.graph_id
     | None -> false)
;;

let test_catalog_refresh_removes_unadmitted_selection () =
  let graph = graph () in
  let selected, _ = select_catalog_graph graph in
  let before = (Core.state selected.next).snapshot in
  let refreshed = refresh_catalog selected.next [ other_graph () ] in
  let after = (Core.state refreshed.next).snapshot in
  Alcotest.check
    Alcotest.bool
    "refresh clears a graph omitted by the authoritative catalog"
    true
    (after.selected_graph = None && after.startup.awaiting_selection);
  Alcotest.check
    Alcotest.bool
    "refresh fences the removed graph generation"
    true
    (after.startup.graph_generation > before.startup.graph_generation);
  Alcotest.check
    Alcotest.bool
    "refresh detaches the removed graph"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Detach_graph _) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       refreshed.effects);
  Alcotest.check
    Alcotest.bool
    "refresh starts no work for the removed graph"
    false
    (has_graph_open_work refreshed.effects);
  let saved = save_catalog_cache refreshed.effects in
  Alcotest.check
    (Alcotest.option Alcotest.string)
    "refresh persists no removed selection"
    None
    (Core.catalog_cache_selected_graph saved
     |> Option.map Logseq_db_types.Graph_types.Uuid.to_string)
;;

let test_catalog_save_failure_keeps_selected_graph_usable () =
  let graph = graph () in
  let selected, mirror_request = select_catalog_graph graph in
  let failed =
    complete_save_catalog selected (Error (Core.Effect_failed "disk unavailable"))
  in
  Alcotest.check
    Alcotest.bool
    "advisory save failure preserves the selected graph state"
    true
    (Core.state failed.next = Core.state selected.next);
  let available = open_request graph mirror_request.scope "save-failure" in
  let inspected =
    Core.step failed.next (Core.Mirror_inspected (Core.Mirror_available available))
  in
  Alcotest.check
    Alcotest.bool
    "mirror opening continues after advisory save failure"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Attach_graph request) ->
           request.scope = mirror_request.scope
         | Run _ | Delegate _ | Publish _ -> false)
       inspected.effects)
;;

let test_same_account_reconciliation_preserves_warm_restore () =
  let graph = graph () in
  let selected, _ = select_catalog_graph graph in
  let cache = save_catalog_cache selected.effects in
  let restoring = Core.step (initial ()) (Restore_local_account { user_id = "user-1" }) in
  let restored =
    Core.step restoring.next (load_catalog_completion restoring.effects (Some cache))
  in
  let restored_snapshot = (Core.state restored.next).snapshot in
  let reconciled =
    Core.step restored.next (Account_authenticated { user_id = Some "user-1" })
  in
  let reconciled_snapshot = (Core.state reconciled.next).snapshot in
  Alcotest.check
    Alcotest.bool
    "same-account authentication retains the warm selected graph"
    true
    (reconciled_snapshot.selected_graph = restored_snapshot.selected_graph
     && reconciled_snapshot.startup.graph_generation
        = restored_snapshot.startup.graph_generation
     && not reconciled_snapshot.startup.awaiting_selection);
  Alcotest.check
    Alcotest.bool
    "same-account authentication does not detach the warm graph"
    false
    (List.exists
       (function
         | Core.Delegate (Core.Detach_graph _) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       reconciled.effects);
  let catalog_token = token_request reconciled.effects in
  let authorized =
    Core.step reconciled.next (Token_provided (catalog_token, "catalog-token"))
  in
  let refreshed =
    Core.step authorized.next (fetch_catalog_completion authorized.effects [ graph ])
  in
  let saved = save_catalog_cache refreshed.effects in
  Alcotest.check
    Alcotest.bool
    "same-account catalog reconciliation persists the warm selection"
    true
    (match Core.catalog_cache_selected_graph saved with
     | Some graph_id -> graph_id_equal graph_id graph.graph_id
     | None -> false)
;;

let test_auth_and_remote_catalog_before_cache_load_do_not_erase_selection () =
  let graph = graph () in
  let cache =
    Core.catalog_cache
      ~user_id:"user-1"
      ~graphs:[ graph ]
      ~selected_graph:(Some graph.graph_id)
  in
  let restoring = Core.step (initial ()) (Restore_local_account { user_id = "user-1" }) in
  let reconciled =
    Core.step restoring.next (Account_authenticated { user_id = Some "user-1" })
  in
  let catalog_token = token_request reconciled.effects in
  let authorized =
    Core.step reconciled.next (Token_provided (catalog_token, "catalog-token"))
  in
  let fetched =
    Core.step authorized.next (fetch_catalog_completion authorized.effects [ graph ])
  in
  Alcotest.check
    Alcotest.bool
    "remote catalog does not overwrite a catalog cache that is still loading"
    false
    (List.exists
       (function
         | Core.Run (Core.Request (_, Core.Save_catalog _)) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       fetched.effects);
  let restored =
    Core.step fetched.next (load_catalog_completion restoring.effects (Some cache))
  in
  let snapshot = (Core.state restored.next).snapshot in
  Alcotest.check
    Alcotest.bool
    "late local cache completion restores the selected graph"
    true
    (match snapshot.selected_graph with
     | Some graph_id ->
       graph_id_equal graph_id graph.graph_id && not snapshot.startup.awaiting_selection
     | None -> false);
  ignore (inspect_mirror_request restored.effects)
;;

let test_snapshot_activation_reinspects_worker_mirror () =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let request = token_request authenticated.effects in
  let authorized = Core.step authenticated.next (Token_provided (request, "token")) in
  let graph : Core.graph =
    { graph_id = graph_id ()
    ; name = "Journal"
    ; schema = { major = 1; minor = 0; exact = true }
    ; encrypted = false
    }
  in
  let catalog =
    Core.step authorized.next (fetch_catalog_completion authorized.effects [ graph ])
  in
  let selected = Core.step catalog.next (Graph_selected graph.graph_id) in
  let scope =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_mirror request) -> Some request.scope
        | Run _ | Delegate _ | Publish _ -> None)
      selected.effects
    |> Option.get
  in
  let activated = Core.step selected.next (Snapshot_activated { scope }) in
  Alcotest.check
    Alcotest.bool
    "activated snapshot is re-resolved by worker authority"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Inspect_mirror request) -> request.scope = scope
         | Run _ | Delegate _ | Publish _ -> false)
       activated.effects)
;;

let test_encrypted_snapshot_activation_carries_decryption_capability () =
  let graph = graph ~encrypted:true () in
  let selected, mirror_request = select_catalog_graph graph in
  let missing =
    Core.step selected.next (Mirror_inspected (Mirror_absent mirror_request.scope))
  in
  let key = Core.graph_key_handle ~id:"cold-bootstrap-key" ~scope:mirror_request.scope in
  let keyed = complete_wrapped_key missing key in
  let snapshot_token = token_request keyed.effects in
  Alcotest.check
    Alcotest.bool
    "encrypted bootstrap requests a snapshot token only after the key is loaded"
    true
    (Core.token_request_purpose snapshot_token = Core.Snapshot_bootstrap);
  let baseline_requested =
    Core.step keyed.next (Token_provided (snapshot_token, "snapshot-token"))
  in
  let metadata_requested =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_baseline _)) ->
          Some
            (Core.step
               baseline_requested.next
               (Runner_completed
                  (Completion (ticket, Ok "{\"type\":\"pull/ok\",\"t\":7}"))))
        | Run _ | Delegate _ | Publish _ -> None)
      baseline_requested.effects
    |> function
    | Some transition -> transition
    | None -> fail "encrypted bootstrap did not fetch its baseline"
  in
  let download_requested =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_snapshot_metadata _)) ->
          Some
            (Core.step
               metadata_requested.next
               (Runner_completed
                  (Completion
                     (ticket, Ok "{\"ok\":true,\"url\":\"https://snapshots.example/db\"}"))))
        | Run _ | Delegate _ | Publish _ -> None)
      metadata_requested.effects
    |> function
    | Some transition -> transition
    | None -> fail "encrypted bootstrap did not fetch snapshot metadata"
  in
  let activated =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Download_snapshot _)) ->
          let artifact =
            Core.staged_artifact
              ~id:"encrypted-artifact"
              ~scope:mirror_request.scope
              ~path:"/staging/encrypted.artifact"
              ~expected_rows:2
          in
          Some
            (Core.step
               download_requested.next
               (Runner_completed (Completion (ticket, Ok artifact))))
        | Run _ | Delegate _ | Publish _ -> None)
      download_requested.effects
    |> function
    | Some transition -> transition
    | None -> fail "encrypted bootstrap did not download its snapshot"
  in
  let activation =
    List.find_map
      (function
        | Core.Delegate (Core.Activate_snapshot request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      activated.effects
    |> function
    | Some request -> request
    | None -> fail "downloaded encrypted snapshot was not activated"
  in
  Alcotest.check
    Alcotest.bool
    "encrypted snapshot activation carries the current scoped key handle"
    true
    (match activation.key with
     | Some actual ->
       String.equal (Core.graph_key_handle_id actual) (Core.graph_key_handle_id key)
       && Core.graph_key_handle_scope actual = mirror_request.scope
     | None -> false)
;;

let test_unencrypted_startup_matrix () =
  let graph = graph () in
  let selected, mirror_request = select_catalog_graph graph in
  let missing =
    Core.step selected.next (Mirror_inspected (Mirror_absent mirror_request.scope))
  in
  Alcotest.check
    Alcotest.bool
    "an unencrypted missing mirror requests snapshot authorization immediately"
    true
    (has_snapshot_token_request missing.effects);
  let activation = complete_snapshot_bootstrap missing mirror_request.scope in
  Alcotest.check
    Alcotest.bool
    "unencrypted snapshot activation carries no graph key"
    true
    (Option.is_none activation.key);
  let selected, mirror_request = select_catalog_graph graph in
  let available_request = open_request graph mirror_request.scope "plain-warm-mirror" in
  let available =
    Core.step selected.next (Mirror_inspected (Mirror_available available_request))
  in
  Alcotest.check
    Alcotest.bool
    "an unencrypted available mirror attaches immediately"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Attach_graph request) ->
           request.scope = mirror_request.scope
         | Run _ | Delegate _ | Publish _ -> false)
       available.effects);
  Alcotest.check
    Alcotest.bool
    "an unencrypted available mirror does not bootstrap a snapshot"
    true
    (not
       (has_snapshot_token_request available.effects
        || has_snapshot_work available.effects));
  let selected, _ = select_catalog_graph graph in
  let recovery = Core.step selected.next Online_recovery_requested in
  Alcotest.check
    Alcotest.bool
    "unencrypted online recovery requests snapshot authorization immediately"
    true
    (has_snapshot_token_request recovery.effects);
  let selected, mirror_request = select_catalog_graph graph in
  let deletion =
    Core.step selected.next (Local_cache_deletion_requested graph.graph_id)
  in
  Alcotest.check
    Alcotest.bool
    "unencrypted cache deletion requests snapshot authorization"
    true
    (has_snapshot_token_request deletion.effects);
  Alcotest.check
    Alcotest.bool
    "unencrypted cache deletion advances the graph generation"
    true
    ((Core.state deletion.next).snapshot.startup.graph_generation
     = mirror_request.scope.graph_generation + 1);
  Alcotest.check
    Alcotest.bool
    "unencrypted cache deletion delegates mirror deletion"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Delete_mirror request) ->
           Logseq_db_types.Graph_types.Uuid.equal request.graph_id graph.graph_id
         | Run _ | Delegate _ | Publish _ -> false)
       deletion.effects)
;;

let test_encrypted_bootstrap_routes_wait_for_a_scoped_key () =
  let graph = graph ~encrypted:true () in
  let selected, mirror_request = select_catalog_graph graph in
  let missing =
    Core.step selected.next (Mirror_inspected (Mirror_absent mirror_request.scope))
  in
  Alcotest.check
    Alcotest.bool
    "an encrypted missing mirror loads its key"
    true
    (graph_key_load_scope missing.effects = Some mirror_request.scope);
  Alcotest.check
    Alcotest.bool
    "an encrypted missing mirror starts no snapshot work before its key"
    true
    (not
       (has_snapshot_token_request missing.effects || has_snapshot_work missing.effects));
  let selected, mirror_request = select_catalog_graph graph in
  let recovery = Core.step selected.next Online_recovery_requested in
  Alcotest.check
    Alcotest.bool
    "encrypted online recovery loads its key"
    true
    (graph_key_load_scope recovery.effects = Some mirror_request.scope);
  Alcotest.check
    Alcotest.bool
    "encrypted online recovery starts no snapshot work before its key"
    true
    (not
       (has_snapshot_token_request recovery.effects || has_snapshot_work recovery.effects));
  let duplicate_recovery = Core.step recovery.next Online_recovery_requested in
  Alcotest.(check int)
    "repeated recovery during key loading emits no competing chain"
    0
    (List.length duplicate_recovery.effects);
  let selected, mirror_request = select_catalog_graph graph in
  let deletion =
    Core.step selected.next (Local_cache_deletion_requested graph.graph_id)
  in
  let new_scope = graph_key_load_scope deletion.effects in
  Alcotest.check
    Alcotest.bool
    "encrypted cache deletion reloads a key in the new generation"
    true
    (match new_scope with
     | Some scope ->
       scope.graph_generation = mirror_request.scope.graph_generation + 1
       && Logseq_db_types.Graph_types.Uuid.equal scope.graph_id graph.graph_id
     | None -> false);
  Alcotest.check
    Alcotest.bool
    "encrypted cache deletion starts no snapshot work before its new key"
    true
    (not
       (has_snapshot_token_request deletion.effects || has_snapshot_work deletion.effects))
;;

let test_encrypted_recovery_resumes_and_coalesces_snapshot_bootstrap () =
  let graph = graph ~encrypted:true () in
  let selected, mirror_request = select_catalog_graph graph in
  let available_request = open_request graph mirror_request.scope "keyed-recovery" in
  let inspected =
    Core.step selected.next (Mirror_inspected (Mirror_available available_request))
  in
  let key = Core.graph_key_handle ~id:"recovery-key" ~scope:mirror_request.scope in
  let keyed = complete_wrapped_key inspected key in
  let recovery = Core.step keyed.next Online_recovery_requested in
  Alcotest.check
    Alcotest.bool
    "online recovery reuses a correctly scoped key"
    true
    (has_snapshot_token_request recovery.effects
     && Option.is_none (graph_key_load_scope recovery.effects));
  let duplicate_token = Core.step recovery.next Online_recovery_requested in
  Alcotest.(check int)
    "repeated recovery while snapshot authorization is pending is coalesced"
    0
    (List.length duplicate_token.effects);
  let snapshot_token = token_request recovery.effects in
  let baseline =
    Core.step recovery.next (Token_provided (snapshot_token, "snapshot-token"))
  in
  let duplicate_baseline = Core.step baseline.next Online_recovery_requested in
  Alcotest.(check int)
    "repeated recovery while snapshot IO is pending is coalesced"
    0
    (List.length duplicate_baseline.effects)
;;

let test_cache_deletion_rejects_stale_and_wrong_scope_key_completions () =
  let graph = graph ~encrypted:true () in
  let selected, mirror_request = select_catalog_graph graph in
  let missing =
    Core.step selected.next (Mirror_inspected (Mirror_absent mirror_request.scope))
  in
  let stale_key = Core.graph_key_handle ~id:"stale-key" ~scope:mirror_request.scope in
  let deletion = Core.step missing.next (Local_cache_deletion_requested graph.graph_id) in
  let stale =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
          Some
            (Core.step
               deletion.next
               (Runner_completed (Completion (ticket, Ok stale_key))))
        | Run _ | Delegate _ | Publish _ -> None)
      missing.effects
    |> function
    | Some completed -> completed
    | None -> fail "missing mirror did not load a wrapped graph key"
  in
  Alcotest.(check int)
    "a completion from the deleted generation emits no snapshot work"
    0
    (List.length stale.effects);
  let new_scope =
    graph_key_load_scope deletion.effects
    |> function
    | Some scope -> scope
    | None -> fail "encrypted cache deletion did not reload its graph key"
  in
  let wrong_scope =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
          Some
            (Core.step
               deletion.next
               (Runner_completed (Completion (ticket, Ok stale_key))))
        | Run _ | Delegate _ | Publish _ -> None)
      deletion.effects
    |> function
    | Some completed -> completed
    | None -> fail "encrypted cache deletion did not reload its graph key"
  in
  Alcotest.check
    Alcotest.bool
    "a wrong-scope key cannot begin snapshot work"
    true
    (new_scope <> mirror_request.scope
     && not
          (has_snapshot_token_request wrong_scope.effects
           || has_snapshot_work wrong_scope.effects));
  Alcotest.check
    Alcotest.bool
    "a wrong-scope key completion enters E2EE failure"
    true
    ((Core.state wrong_scope.next).snapshot.startup.failure = Some Core.During_e2ee)
;;

let test_encrypted_bootstrap_recovers_a_missing_cached_key () =
  let graph = graph ~encrypted:true () in
  let selected, mirror_request = select_catalog_graph graph in
  let missing =
    Core.step selected.next (Mirror_inspected (Mirror_absent mirror_request.scope))
  in
  let failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
          Some
            (Core.step
               missing.next
               (Runner_completed
                  (Completion (ticket, Error (Effect_failed "cached key missing")))))
        | Run _ | Delegate _ | Publish _ -> None)
      missing.effects
    |> function
    | Some completed -> completed
    | None -> fail "missing mirror did not load a wrapped graph key"
  in
  let e2ee_token = token_request failed.effects in
  Alcotest.check
    Alcotest.bool
    "cached-key failure enters E2EE recovery"
    true
    (Core.token_request_purpose e2ee_token = Core.E2ee_key_access);
  Alcotest.check
    Alcotest.bool
    "cached-key failure starts no snapshot work"
    true
    (not (has_snapshot_token_request failed.effects || has_snapshot_work failed.effects));
  let graph_key_fetch =
    Core.step failed.next (Token_provided (e2ee_token, "e2ee-token"))
  in
  let remote_key_loaded =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_graph_key _)) ->
          Some
            (Core.step
               graph_key_fetch.next
               (Runner_completed
                  (Completion
                     ( ticket
                     , Ok "{\"encrypted-aes-key\":\"[\\\"~#binary\\\",\\\"AA==\\\"]\"}" ))))
        | Run _ | Delegate _ | Publish _ -> None)
      graph_key_fetch.effects
    |> function
    | Some completed -> completed
    | None -> fail "E2EE recovery did not fetch the remote graph key"
  in
  let recovered_key =
    Core.graph_key_handle ~id:"recovered-key" ~scope:mirror_request.scope
  in
  let recovered =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_and_unlock_graph_key _)) ->
          Some
            (Core.step
               remote_key_loaded.next
               (Runner_completed (Completion (ticket, Ok recovered_key))))
        | Run _ | Delegate _ | Publish _ -> None)
      remote_key_loaded.effects
    |> function
    | Some completed -> completed
    | None -> fail "E2EE recovery did not unlock the remote graph key"
  in
  Alcotest.check
    Alcotest.bool
    "remote graph-key recovery resumes snapshot authorization"
    true
    (has_snapshot_token_request recovered.effects);
  let activation = complete_snapshot_bootstrap recovered mirror_request.scope in
  Alcotest.check
    Alcotest.bool
    "recovered encrypted bootstrap retains the scoped handle through activation"
    true
    (match activation.key with
     | Some actual ->
       Core.graph_key_handle_id actual = Core.graph_key_handle_id recovered_key
       && Core.graph_key_handle_scope actual = mirror_request.scope
     | None -> false)
;;

let test_encrypted_warm_mirror_waits_for_a_scoped_graph_key () =
  let graph = graph ~encrypted:true () in
  let selected, mirror_request = select_catalog_graph graph in
  let open_request : Core.graph_open_request =
    { graph
    ; graph_directory = "/worker/encrypted-warm-mirror"
    ; database_path = "/worker/encrypted-warm-mirror/db.sqlite"
    ; checkpoint = checkpoint graph.graph_id
    ; scope = mirror_request.scope
    }
  in
  let inspected =
    Core.step selected.next (Mirror_inspected (Mirror_available open_request))
  in
  Alcotest.check
    Alcotest.bool
    "encrypted mirror is not attached before wrapped-key loading completes"
    true
    (not
       (List.exists
          (function
            | Core.Delegate (Core.Attach_graph _) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          inspected.effects));
  let correct_key = Core.graph_key_handle ~id:"warm-key" ~scope:mirror_request.scope in
  let correctly_keyed = complete_wrapped_key inspected correct_key in
  Alcotest.check
    Alcotest.bool
    "correctly scoped key permits warm-mirror attachment"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Attach_graph request) ->
           request.scope = mirror_request.scope
         | Run _ | Delegate _ | Publish _ -> false)
       correctly_keyed.effects);
  let already_keyed =
    Core.step correctly_keyed.next (Mirror_inspected (Mirror_available open_request))
  in
  Alcotest.check
    Alcotest.bool
    "a valid scoped key attaches without redundant key or snapshot requests"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Attach_graph request) ->
           request.scope = mirror_request.scope
         | Run _ | Delegate _ | Publish _ -> false)
       already_keyed.effects
     && Option.is_none (graph_key_load_scope already_keyed.effects)
     && not
          (has_snapshot_token_request already_keyed.effects
           || has_snapshot_work already_keyed.effects));
  let wrong_scope =
    { mirror_request.scope with
      graph_id = other_graph_id ()
    ; graph_generation = mirror_request.scope.graph_generation + 1
    }
  in
  let wrong_key = Core.graph_key_handle ~id:"wrong-key" ~scope:wrong_scope in
  let wrongly_keyed = complete_wrapped_key inspected wrong_key in
  Alcotest.check
    Alcotest.bool
    "out-of-scope key cannot attach the encrypted mirror"
    true
    (not
       (List.exists
          (function
            | Core.Delegate (Core.Attach_graph _) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          wrongly_keyed.effects));
  Alcotest.check
    Alcotest.bool
    "out-of-scope key is reported as an E2EE failure"
    true
    ((Core.state wrongly_keyed.next).snapshot.startup.failure = Some Core.During_e2ee)
;;

let test_encrypted_authoritative_pull_decrypts_before_worker_apply () =
  let core, connection = encrypted_open_graph () in
  let context = encrypted_authoritative_context connection in
  let decrypting = Core.step core (Authoritative_batch_inspected context) in
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let plaintext = Codec.to_string (Transit.String "decrypted title") in
  let decryption_request =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Decrypt_protected_values request)) ->
          Some
            (request, Core.Runner_completed (Core.Completion (ticket, Ok [ plaintext ])))
        | Run _ | Delegate _ | Publish _ -> None)
      decrypting.effects
    |> function
    | Some value -> value
    | None -> fail "encrypted authoritative pull did not request decryption"
  in
  let request, completion = decryption_request in
  Alcotest.(check (list (pair string string)))
    "only parsed encryption envelopes are sent to the runner"
    [ "snapshot-iv", "ciphertext" ]
    request.protected_values;
  Alcotest.check
    Alcotest.bool
    "worker apply is absent before authoritative decryption completes"
    true
    (not
       (List.exists
          (function
            | Core.Delegate (Core.Apply_authoritative_batch _) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          decrypting.effects));
  let decrypted = Core.step decrypting.next completion in
  let application =
    List.find_map
      (function
        | Core.Delegate (Core.Apply_authoritative_batch request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      decrypted.effects
    |> function
    | Some request -> request
    | None -> fail "decrypted authoritative pull was not delegated to the worker"
  in
  Alcotest.check
    Alcotest.bool
    "worker receives the decrypted protected value"
    true
    (List.exists
       (List.exists (function
          | Datascript.Add (_, "block/title", Datascript.String "decrypted title") -> true
          | _ -> false))
       application.transactions)
;;

let test_authoritative_decryption_failure_is_fail_closed () =
  let core, connection = encrypted_open_graph () in
  let context = encrypted_authoritative_context connection in
  let decrypting = Core.step core (Authoritative_batch_inspected context) in
  let failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Decrypt_protected_values _)) ->
          Some
            (Core.step
               decrypting.next
               (Runner_completed
                  (Completion (ticket, Error (Effect_failed "authentication failed")))))
        | Run _ | Delegate _ | Publish _ -> None)
      decrypting.effects
    |> function
    | Some transition -> transition
    | None -> fail "encrypted authoritative pull did not request decryption"
  in
  Alcotest.check
    Alcotest.bool
    "failed decryption never delegates authoritative application"
    true
    (not
       (List.exists
          (function
            | Core.Delegate (Core.Apply_authoritative_batch _) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          failed.effects));
  Alcotest.(check (option int))
    "failed decryption does not advance the public checkpoint"
    (Some 0)
    (Core.state failed.next).snapshot.applied_server_t;
  Alcotest.check
    Alcotest.bool
    "failed decryption is classified as an E2EE failure"
    true
    ((Core.state failed.next).snapshot.startup.failure = Some Core.During_e2ee)
;;

let authoritative_context ~server_t ~transaction_t =
  let module Transit = Transit_core.Json in
  let module Codec = Transit_native.Transit.Json in
  let wire =
    Codec.to_string
      ~mode:Codec.Verbose
      (Transit.Array
         [ Transit.Array
             [ Transit.Keyword "db/add"
             ; Transit.String "remote-block"
             ; Transit.Keyword "block/uuid"
             ; Transit.Uuid "22222222-2222-4222-8222-222222222222"
             ]
         ])
  in
  let payload =
    Yojson.Safe.to_string
      (`Assoc
          [ "type", `String "pull/ok"
          ; "t", `Int server_t
          ; "txs", `List [ `Assoc [ "t", `Int transaction_t; "tx", `String wire ] ]
          ])
  in
  let checkpoint =
    Logseq_db_types.Sync_checkpoint.create
      ~graph_id:(graph_id ())
      ~schema:Logseq_db_types.Graph_types.{ major = 1; minor = 0 }
      ~applied_server_t:0
      ~checksum:"0000000000000000"
    |> Result.get_ok
  in
  let batch : Core.authoritative_batch =
    { payload
    ; scope = { graph = graph_scope (); connection_generation = 1 }
    ; presentation_generation = 1
    ; lifecycle_generation = 1L
    }
  in
  Core.{ batch; checkpoint; database = Datascript.empty_db (); outbox_records = [] }
;;

let test_authoritative_pull_is_pure_and_advances_checkpoint () =
  let plan =
    authoritative_context ~server_t:1 ~transaction_t:1
    |> Core.begin_authoritative_batch
    |> Result.get_ok
  in
  Alcotest.check
    Alcotest.bool
    "plaintext authoritative transaction needs no crypto"
    true
    (Core.authoritative_crypto_request plan = None);
  let request = Core.finish_authoritative_batch plan None |> Result.get_ok in
  Alcotest.(check int) "one transaction is decoded" 1 (List.length request.transactions);
  Alcotest.(check int)
    "checkpoint advances atomically with the transaction"
    1
    request.checkpoint.applied_server_t;
  Alcotest.check
    Alcotest.bool
    "pull activity records an application"
    true
    (request.activity = Logseq_db_types.Sync_status.Pull_applied)
;;

let test_authoritative_pull_rejects_cursor_gaps () =
  let result =
    authoritative_context ~server_t:2 ~transaction_t:2 |> Core.begin_authoritative_batch
  in
  Alcotest.check Alcotest.bool "cursor gap is rejected" true (Result.is_error result)
;;

let test_submission_waits_for_durable_outbox_transition () =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let catalog_token = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Token_provided (catalog_token, "catalog-token"))
  in
  let graph : Core.graph =
    { graph_id = graph_id ()
    ; name = "Journal"
    ; schema = { major = 1; minor = 0; exact = true }
    ; encrypted = false
    }
  in
  let catalog =
    Core.step authorized.next (fetch_catalog_completion authorized.effects [ graph ])
  in
  let selected = Core.step catalog.next (Graph_selected graph.graph_id) in
  let mirror_request =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_mirror request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      selected.effects
    |> Option.get
  in
  let checkpoint =
    Logseq_db_types.Sync_checkpoint.create
      ~graph_id:graph.graph_id
      ~schema:Logseq_db_types.Graph_types.{ major = 1; minor = 0 }
      ~applied_server_t:0
      ~checksum:"0000000000000000"
    |> Result.get_ok
  in
  let open_request : Core.graph_open_request =
    { graph
    ; graph_directory = "/worker/mirror"
    ; database_path = "/worker/mirror/db.sqlite"
    ; checkpoint
    ; scope = mirror_request.scope
    }
  in
  let inspected =
    Core.step selected.next (Mirror_inspected (Mirror_available open_request))
  in
  let record =
    local_batch_input
      [ Datascript.Add
          ( Datascript.Temp_id "queued"
          , "block/uuid"
          , Datascript.Uuid "33333333-3333-4333-8333-333333333333" )
      ]
    |> Core.begin_local_batch
    |> Result.get_ok
    |> fun plan -> Core.finish_local_batch plan None |> Result.get_ok
  in
  let queued_records = Core.encode_outbox_records [ record ] |> Result.get_ok in
  let attached =
    Core.step
      inspected.next
      (Graph_attached
         { scope = open_request.scope; checkpoint; outbox_records = queued_records })
  in
  let websocket_token = token_request attached.effects in
  let connecting =
    Core.step attached.next (Token_provided (websocket_token, "websocket-token"))
  in
  let connection =
    List.find_map
      (function
        | Core.Run (Core.Start_websocket request) -> Some request.scope
        | Run _ | Delegate _ | Publish _ -> None)
      connecting.effects
    |> Option.get
  in
  let opened = Core.step connecting.next (Websocket_opened connection) in
  let transition =
    List.find_map
      (function
        | Core.Delegate (Core.Commit_outbox_transition transition) -> Some transition
        | Run _ | Delegate _ | Publish _ -> None)
      opened.effects
    |> Option.get
  in
  (match Core.decode_outbox_records transition.outbox_records with
   | Ok records ->
     Alcotest.(check int)
       "submitted durable outbox remains decodable"
       1
       (List.length records)
   | Error message ->
     Alcotest.failf "submitted durable outbox failed to decode: %s" message);
  Alcotest.check
    Alcotest.bool
    "WebSocket send is absent before durable transition"
    true
    (not
       (List.exists
          (function
            | Core.Run (Core.Send_websocket _) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          opened.effects));
  let committed =
    Core.step
      opened.next
      (Outbox_transition_committed
         { scope = transition.scope
         ; outbox_records = transition.outbox_records
         ; pending_payload = transition.pending_payload
         })
  in
  Alcotest.check
    Alcotest.bool
    "WebSocket send follows the durable transition fact"
    true
    (List.exists
       (function
         | Core.Run (Core.Send_websocket _) -> true
         | Run _ | Delegate _ | Publish _ -> false)
       committed.effects)
;;

let test_e2ee_recovery_keeps_password_out_of_core_state () =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let catalog_token = token_request authenticated.effects in
  let authorized =
    Core.step authenticated.next (Token_provided (catalog_token, "catalog-token"))
  in
  let graph : Core.graph =
    { graph_id = graph_id ()
    ; name = "Encrypted Journal"
    ; schema = { major = 1; minor = 0; exact = true }
    ; encrypted = true
    }
  in
  let catalog =
    Core.step authorized.next (fetch_catalog_completion authorized.effects [ graph ])
  in
  let selected = Core.step catalog.next (Graph_selected graph.graph_id) in
  let scope =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_mirror request) -> Some request.scope
        | Run _ | Delegate _ | Publish _ -> None)
      selected.effects
    |> Option.get
  in
  let missing = Core.step selected.next (Mirror_inspected (Mirror_absent scope)) in
  let wrapped_failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Load_and_unlock_graph_key _)) ->
          Some
            (Core.step
               missing.next
               (Runner_completed
                  (Completion (ticket, Error (Effect_failed "local key missing")))))
        | Run _ | Delegate _ | Publish _ -> None)
      missing.effects
    |> Option.get
  in
  let e2ee_token = token_request wrapped_failed.effects in
  let graph_key_fetch =
    Core.step wrapped_failed.next (Token_provided (e2ee_token, "e2ee-token"))
  in
  let graph_key_loaded =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_graph_key _)) ->
          Some
            (Core.step
               graph_key_fetch.next
               (Runner_completed
                  (Completion
                     ( ticket
                     , Ok "{\"encrypted-aes-key\":\"[\\\"~#binary\\\",\\\"AA==\\\"]\"}" ))))
        | Run _ | Delegate _ | Publish _ -> None)
      graph_key_fetch.effects
    |> Option.get
  in
  let unlock_failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_and_unlock_graph_key _)) ->
          Some
            (Core.step
               graph_key_loaded.next
               (Runner_completed
                  (Completion (ticket, Error (Effect_failed "private key missing")))))
        | Run _ | Delegate _ | Publish _ -> None)
      graph_key_loaded.effects
    |> Option.get
  in
  let user_keys_loaded =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_e2ee_user_keys _)) ->
          Some
            (Core.step
               unlock_failed.next
               (Runner_completed
                  (Completion
                     ( ticket
                     , Ok
                         "{\"public-key\":\"public\",\"encrypted-private-key\":\"package\"}"
                     ))))
        | Run _ | Delegate _ | Publish _ -> None)
      unlock_failed.effects
    |> Option.get
  in
  Alcotest.check
    Alcotest.bool
    "password prompt is visible"
    true
    (Core.state user_keys_loaded.next).snapshot.startup.awaiting_e2ee_password;
  let password = "correct horse battery staple" in
  let submitted = Core.step user_keys_loaded.next (E2ee_password_submitted password) in
  Alcotest.check
    Alcotest.bool
    "password crosses only the typed runner request"
    true
    (List.exists
       (function
         | Core.Run (Core.Request (_, Core.Unlock_private_key request)) ->
           String.equal request.password password
         | Run _ | Delegate _ | Publish _ -> false)
       submitted.effects);
  let diagnostics = (Core.state submitted.next).diagnostics in
  let diagnostic_text =
    diagnostics.history
    @ List.concat_map
        (fun group ->
           group.Core.entries |> List.concat_map (fun (key, value) -> [ key; value ]))
        diagnostics.groups
    |> String.concat " "
  in
  Alcotest.check
    Alcotest.bool
    "password is absent from core diagnostics"
    true
    (not (contains diagnostic_text password));
  let private_key_unlocked =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Unlock_private_key _)) ->
          Some (Core.step submitted.next (Runner_completed (Completion (ticket, Ok ()))))
        | Run _ | Delegate _ | Publish _ -> None)
      submitted.effects
    |> function
    | Some completed -> completed
    | None -> fail "password recovery did not unlock the private key"
  in
  let recovered_key = Core.graph_key_handle ~id:"password-key" ~scope in
  let graph_key_unlocked =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Fetch_and_unlock_graph_key _)) ->
          Some
            (Core.step
               private_key_unlocked.next
               (Runner_completed (Completion (ticket, Ok recovered_key))))
        | Run _ | Delegate _ | Publish _ -> None)
      private_key_unlocked.effects
    |> function
    | Some completed -> completed
    | None -> fail "password recovery did not retry graph-key unlocking"
  in
  Alcotest.check
    Alcotest.bool
    "password recovery resumes snapshot authorization"
    true
    (has_snapshot_token_request graph_key_unlocked.effects)
;;

let scenarios =
  [ Alcotest.test_case
      "configuration is bounded"
      `Quick
      test_config_validation_is_pure_and_bounded
  ; Alcotest.test_case
      "step is immutable and replayable"
      `Quick
      test_step_is_immutable_and_replayable
  ; Alcotest.test_case
      "stale token events are rejected"
      `Quick
      test_stale_and_duplicate_token_events_are_rejected
  ; Alcotest.test_case
      "runner completion is one-shot"
      `Quick
      test_runner_completion_is_scoped_and_consumed_once
  ; Alcotest.test_case
      "lifecycle generation is fenced"
      `Quick
      test_lifecycle_generation_fences_stale_events
  ; Alcotest.test_case "shutdown is idempotent" `Quick test_shutdown_is_idempotent
  ; Alcotest.test_case
      "local batch planning separates crypto"
      `Quick
      test_local_batch_planning_separates_crypto_from_policy
  ; Alcotest.test_case
      "graph selection delegates mirror authority"
      `Quick
      test_graph_selection_delegates_mirror_authority
  ; Alcotest.test_case
      "selected graph survives picker and codec restart"
      `Quick
      test_selected_graph_survives_picker_and_codec_restart
  ; Alcotest.test_case
      "invalid cached selections fail closed"
      `Quick
      test_absent_stale_and_malformed_cached_selections_fail_closed
  ; Alcotest.test_case
      "catalog refresh preserves admitted selection"
      `Quick
      test_catalog_refresh_preserves_admitted_selection
  ; Alcotest.test_case
      "catalog refresh removes unadmitted selection"
      `Quick
      test_catalog_refresh_removes_unadmitted_selection
  ; Alcotest.test_case
      "catalog save failure keeps selected graph usable"
      `Quick
      test_catalog_save_failure_keeps_selected_graph_usable
  ; Alcotest.test_case
      "same-account reconciliation preserves warm restore"
      `Quick
      test_same_account_reconciliation_preserves_warm_restore
  ; Alcotest.test_case
      "early auth and remote catalog preserve pending cache restore"
      `Quick
      test_auth_and_remote_catalog_before_cache_load_do_not_erase_selection
  ; Alcotest.test_case
      "snapshot activation re-inspects mirror"
      `Quick
      test_snapshot_activation_reinspects_worker_mirror
  ; Alcotest.test_case
      "encrypted snapshot activation carries decryption capability"
      `Quick
      test_encrypted_snapshot_activation_carries_decryption_capability
  ; Alcotest.test_case
      "unencrypted startup routes share bootstrap policy"
      `Quick
      test_unencrypted_startup_matrix
  ; Alcotest.test_case
      "encrypted bootstrap routes wait for a scoped key"
      `Quick
      test_encrypted_bootstrap_routes_wait_for_a_scoped_key
  ; Alcotest.test_case
      "encrypted recovery resumes and coalesces bootstrap"
      `Quick
      test_encrypted_recovery_resumes_and_coalesces_snapshot_bootstrap
  ; Alcotest.test_case
      "cache deletion fences stale graph keys"
      `Quick
      test_cache_deletion_rejects_stale_and_wrong_scope_key_completions
  ; Alcotest.test_case
      "encrypted bootstrap recovers a missing cached key"
      `Quick
      test_encrypted_bootstrap_recovers_a_missing_cached_key
  ; Alcotest.test_case
      "encrypted warm mirror waits for a scoped graph key"
      `Quick
      test_encrypted_warm_mirror_waits_for_a_scoped_graph_key
  ; Alcotest.test_case
      "encrypted authoritative pull decrypts before worker apply"
      `Quick
      test_encrypted_authoritative_pull_decrypts_before_worker_apply
  ; Alcotest.test_case
      "authoritative decryption failure is fail closed"
      `Quick
      test_authoritative_decryption_failure_is_fail_closed
  ; Alcotest.test_case
      "authoritative pull advances checkpoint"
      `Quick
      test_authoritative_pull_is_pure_and_advances_checkpoint
  ; Alcotest.test_case
      "authoritative pull rejects cursor gaps"
      `Quick
      test_authoritative_pull_rejects_cursor_gaps
  ; Alcotest.test_case
      "submission waits for durable outbox transition"
      `Quick
      test_submission_waits_for_durable_outbox_transition
  ; Alcotest.test_case
      "E2EE password stays out of core state"
      `Quick
      test_e2ee_recovery_keeps_password_out_of_core_state
  ]
;;
