module Core = Logseq_sync_pure_reducer.Core
module Sync_protocol = Logseq_sync_pure_reducer.Sync_protocol

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

let has_token_request effects =
  List.exists
    (function
      | Core.Publish (Core.Token_requested _) -> true
      | Run _ | Delegate _ | Publish _ -> false)
    effects
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
      | Core.Run (Core.Request (_, Core.Save_catalog { cache; _ })) -> Some cache
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
  let batch : Core.authoritative_batch =
    { message =
        Sync_protocol.Server.Pull_ok
          { t = 1; checksum = None; txs = [ { t = 1; tx = wire; outliner_op = None } ] }
    ; scope = connection
    ; presentation_generation = connection.graph.account.presentation_generation
    ; lifecycle_generation = connection.graph.account.lifecycle_generation
    }
  in
  Core.
    { batch
    ; precondition = "test-precondition"
    ; checkpoint = checkpoint connection.graph.graph_id
    ; database = Datascript.empty_db ()
    ; outbox_records = []
    }
;;

let local_batch_input
      ?key
      ?(scope = graph_scope ())
      ?(admission_id = "test-admission")
      ?(mutation_id = graph_id ())
      ?(mutation_payload = "mutation")
      ?(mutation_fingerprint = "fingerprint")
      operations
  =
  Core.local_batch_input
    ~scope
    ~admission_id
    ~key
    ~outbox_records:[]
    ~mutation_id
    ~mutation_payload
    ~mutation_fingerprint
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

let test_post_admission_planning_failure_emits_terminal_worker_effect () =
  let input =
    local_batch_input
      [ Datascript.Entity
          { db_id = Some (Datascript.Temp_id "unsupported")
          ; attrs =
              [ ( "block/uuid"
                , Datascript.One_value
                    (Datascript.Uuid "33333333-3333-4333-8333-333333333333") )
              ]
          }
      ]
  in
  let failed = Core.step (initial ()) (Local_batch_prepared input) in
  Alcotest.check
    Alcotest.bool
    "post-admission planning failure is correlated back to the worker"
    true
    (List.exists
       (function
         | Core.Delegate _ -> true
         | Run _ | Publish _ -> false)
       failed.effects)
;;

let test_post_admission_encryption_failure_emits_terminal_worker_effect () =
  let core, connection = encrypted_open_graph () in
  let input =
    local_batch_input
      ~scope:connection.graph
      [ Datascript.Add
          (Datascript.Temp_id "new-block", "block/title", Datascript.String "secret")
      ]
  in
  let encrypting = Core.step core (Local_batch_prepared input) in
  let failed =
    List.find_map
      (function
        | Core.Run (Core.Request (ticket, Core.Encrypt_protected_values _)) ->
          Some
            (Core.step
               encrypting.next
               (Runner_completed
                  (Completion
                     ( ticket
                     , Error
                         (Crypto_failed
                            (Crypto_provider_unavailable, "provider unavailable")) ))))
        | Run _ | Delegate _ | Publish _ -> None)
      encrypting.effects
    |> function
    | Some failed -> failed
    | None -> fail "protected local batch did not request encryption"
  in
  Alcotest.check
    Alcotest.bool
    "encryption failure terminally rejects the admitted mutation"
    true
    (List.exists
       (function
         | Core.Delegate _ -> true
         | Run _ | Publish _ -> false)
       failed.effects)
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
  Alcotest.check
    Alcotest.bool
    "same-account authentication waits for Timeline presentation"
    false
    (has_token_request reconciled.effects);
  let presented = Core.step reconciled.next Timeline_presented in
  let catalog_token = token_request presented.effects in
  let authorized =
    Core.step presented.next (Token_provided (catalog_token, "catalog-token"))
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

let test_warm_graph_attachment_defers_websocket_until_timeline () =
  let graph = graph () in
  let selected, _ = select_catalog_graph graph in
  let cache = save_catalog_cache selected.effects in
  let restoring = Core.step (initial ()) (Restore_local_account { user_id = "user-1" }) in
  let restored =
    Core.step restoring.next (load_catalog_completion restoring.effects (Some cache))
  in
  let reconciled =
    Core.step restored.next (Account_authenticated { user_id = Some "user-1" })
  in
  let mirror = inspect_mirror_request restored.effects in
  let request = open_request graph mirror.scope "warm-websocket-barrier" in
  let inspected =
    Core.step reconciled.next (Mirror_inspected (Mirror_available request))
  in
  let attached =
    Core.step
      inspected.next
      (Graph_attached
         { scope = request.scope; checkpoint = request.checkpoint; outbox_records = [] })
  in
  Alcotest.check
    Alcotest.bool
    "warm graph attachment emits no pre-presentation WebSocket token"
    false
    (has_token_request attached.effects);
  let presented = Core.step attached.next Timeline_presented in
  Alcotest.check
    Alcotest.bool
    "post-presentation reconciliation begins with catalog authentication"
    true
    (Core.token_request_purpose (token_request presented.effects) = Core.Catalog_discovery)
;;

let test_account_replacement_cancels_and_detaches_before_new_catalog_work () =
  let selected, mirror = select_catalog_graph (graph ()) in
  let replaced =
    Core.step selected.next (Account_authenticated { user_id = Some "user-2" })
  in
  let rec positions index cancel detach token = function
    | [] -> cancel, detach, token
    | Core.Run (Core.Cancel_effects scope) :: rest
      when scope = Core.effect_scope_of_account mirror.scope.account ->
      positions (index + 1) (Some index) detach token rest
    | Core.Delegate _ :: rest -> positions (index + 1) cancel (Some index) token rest
    | Core.Publish (Core.Token_requested _) :: rest ->
      positions (index + 1) cancel detach (Some index) rest
    | _ :: rest -> positions (index + 1) cancel detach token rest
  in
  match positions 0 None None None replaced.effects with
  | Some cancel, Some detach, Some token ->
    Alcotest.check
      Alcotest.bool
      "old account cancellation and worker detach precede replacement catalog work"
      true
      (cancel < detach && detach < token)
  | _ -> fail "account replacement omitted scoped cancellation, detach, or catalog work"
;;

let test_sign_out_cancels_and_detaches_the_managed_attachment () =
  let selected, mirror = select_catalog_graph (graph ()) in
  let signed_out = Core.step selected.next (Account_authenticated { user_id = None }) in
  Alcotest.check
    Alcotest.bool
    "sign-out cancels the exact old account scope"
    true
    (List.exists
       (function
         | Core.Run (Core.Cancel_effects scope) ->
           scope = Core.effect_scope_of_account mirror.scope.account
         | Run _ | Delegate _ | Publish _ -> false)
       signed_out.effects);
  Alcotest.check
    Alcotest.bool
    "sign-out delegates worker teardown"
    true
    (List.exists
       (function
         | Core.Delegate _ -> true
         | Run _ | Publish _ -> false)
       signed_out.effects)
;;

let test_auth_before_cache_load_waits_for_local_timeline () =
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
  Alcotest.check
    Alcotest.bool
    "authentication does not challenge while the local cache is loading"
    false
    (has_token_request reconciled.effects);
  let restored =
    Core.step reconciled.next (load_catalog_completion restoring.effects (Some cache))
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
  ignore (inspect_mirror_request restored.effects);
  Alcotest.check
    Alcotest.bool
    "local restoration remains network-free before Timeline presentation"
    false
    (has_token_request restored.effects);
  let presented = Core.step restored.next Timeline_presented in
  ignore (token_request presented.effects)
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
  Alcotest.check
    Alcotest.bool
    "cached-key failure enters explicit local recovery"
    true
    ((Core.state failed.next).snapshot.startup.failure = Some Core.During_local_restore
     && not (has_token_request failed.effects));
  Alcotest.check
    Alcotest.bool
    "cached-key failure starts no snapshot work"
    true
    (not (has_snapshot_token_request failed.effects || has_snapshot_work failed.effects));
  let reconciled =
    Core.step failed.next (Account_authenticated { user_id = Some "user-1" })
  in
  Alcotest.check
    Alcotest.bool
    "late same-account authentication preserves explicit local recovery"
    true
    ((Core.state reconciled.next).snapshot.startup.failure
     = Some Core.During_local_restore
     && not (has_token_request reconciled.effects));
  let recovery = Core.step reconciled.next Online_recovery_requested in
  let e2ee_token = token_request recovery.effects in
  Alcotest.check
    Alcotest.bool
    "user-approved recovery requests E2EE authorization"
    true
    (Core.token_request_purpose e2ee_token = Core.E2ee_key_access);
  let graph_key_fetch =
    Core.step recovery.next (Token_provided (e2ee_token, "e2ee-token"))
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
    "a duplicate mirror inspection is ignored after attachment is delegated"
    true
    (already_keyed.effects = []);
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

let remote_add_operation () =
  let module Transit = Transit_core.Json in
  Transit.Array
    [ Transit.Keyword "db/add"
    ; Transit.String "remote-block"
    ; Transit.Keyword "block/uuid"
    ; Transit.Uuid "22222222-2222-4222-8222-222222222222"
    ]
;;

let transit_wire value =
  Transit_native.Transit.Json.to_string ~mode:Transit_native.Transit.Json.Verbose value
;;

let authoritative_context
      ?(checkpoint_t = 0)
      ?wire
      ?(outbox_records = [])
      ~server_t
      ~transaction_t
      ()
  =
  let module Transit = Transit_core.Json in
  let wire =
    Option.value wire ~default:(transit_wire (Transit.Array [ remote_add_operation () ]))
  in
  let checkpoint =
    Logseq_db_types.Sync_checkpoint.create
      ~graph_id:(graph_id ())
      ~schema:Logseq_db_types.Graph_types.{ major = 1; minor = 0 }
      ~applied_server_t:checkpoint_t
      ~checksum:"0000000000000000"
    |> Result.get_ok
  in
  let batch : Core.authoritative_batch =
    { message =
        Sync_protocol.Server.Pull_ok
          { t = server_t
          ; checksum = None
          ; txs = [ { t = transaction_t; tx = wire; outliner_op = None } ]
          }
    ; scope = { graph = graph_scope (); connection_generation = 1 }
    ; presentation_generation = 1
    ; lifecycle_generation = 1L
    }
  in
  Core.
    { batch
    ; precondition = "test-precondition"
    ; checkpoint
    ; database = Datascript.empty_db ()
    ; outbox_records
    }
;;

let test_authoritative_pull_is_pure_and_advances_checkpoint () =
  let plan =
    authoritative_context ~server_t:1 ~transaction_t:1 ()
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
    authoritative_context ~server_t:2 ~transaction_t:2 ()
    |> Core.begin_authoritative_batch
  in
  Alcotest.check Alcotest.bool "cursor gap is rejected" true (Result.is_error result)
;;

let test_authoritative_pull_accepts_transit_list_collection () =
  let module Transit = Transit_core.Json in
  let wire = transit_wire (Transit.List [ remote_add_operation () ]) in
  let request =
    authoritative_context ~wire ~server_t:1 ~transaction_t:1 ()
    |> Core.begin_authoritative_batch
    |> Result.get_ok
    |> fun plan -> Core.finish_authoritative_batch plan None |> Result.get_ok
  in
  Alcotest.(check int)
    "Transit list contributes one transaction"
    1
    (List.length request.transactions);
  Alcotest.(check int)
    "Transit list advances the checkpoint"
    1
    request.checkpoint.applied_server_t
;;

let test_authoritative_pull_preserves_transit_cache_wire_order () =
  let wire =
    {|[["~:db/retractEntity",["~:block/uuid","~u22222222-2222-4222-8222-222222222222"]],["^0",["^1","~u33333333-3333-4333-8333-333333333333"]]]|}
  in
  let plan =
    authoritative_context ~wire ~server_t:1 ~transaction_t:1 ()
    |> Core.begin_authoritative_batch
    |> Result.get_ok
  in
  Alcotest.check
    Alcotest.bool
    "both cached retract-entity operations are accepted without crypto"
    true
    (Core.authoritative_crypto_request plan = None)
;;

let test_authoritative_pull_rejects_empty_or_non_array_operations () =
  let module Transit = Transit_core.Json in
  let empty_list = transit_wire (Transit.List []) in
  let list_operation =
    transit_wire
      (Transit.Array
         [ Transit.List
             [ Transit.Keyword "db/add"
             ; Transit.String "remote-block"
             ; Transit.Keyword "block/uuid"
             ; Transit.Uuid "22222222-2222-4222-8222-222222222222"
             ]
         ])
  in
  List.iter
    (fun wire ->
       let result =
         authoritative_context ~wire ~server_t:1 ~transaction_t:1 ()
         |> Core.begin_authoritative_batch
       in
       Alcotest.check
         Alcotest.bool
         "invalid transaction shape is rejected"
         true
         (Result.is_error result))
    [ empty_list; list_operation ]
;;

let queued_local_batch_input ?(scope = graph_scope ()) () =
  local_batch_input
    ~scope
    [ Datascript.Add
        ( Datascript.Temp_id "queued-duplicate"
        , "block/uuid"
        , Datascript.Uuid "33333333-3333-4333-8333-333333333333" )
    ]
;;

let queued_outbox_records () =
  let record =
    queued_local_batch_input ()
    |> Core.begin_local_batch
    |> Result.get_ok
    |> fun plan -> Core.finish_local_batch plan None |> Result.get_ok
  in
  Core.encode_outbox_records [ record ] |> Result.get_ok
;;

let accepted_outbox_records server_t =
  queued_outbox_records ()
  |> List.map (fun source ->
    match Yojson.Safe.from_string source with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (name, value) ->
              if String.equal name "state"
              then name, `Assoc [ "type", `String "accepted"; "serverT", `Int server_t ]
              else name, value)
           fields)
      |> Yojson.Safe.to_string
    | _ -> fail "encoded outbox record must be an object")
;;

let test_duplicate_pull_skips_authoritative_transaction_bodies () =
  let plan =
    authoritative_context
      ~checkpoint_t:1
      ~wire:"not transit"
      ~server_t:1
      ~transaction_t:1
      ()
    |> Core.begin_authoritative_batch
    |> Result.get_ok
  in
  Alcotest.check
    Alcotest.bool
    "duplicate malformed transaction requests no crypto"
    true
    (Core.authoritative_crypto_request plan = None);
  let request = Core.finish_authoritative_batch plan None |> Result.get_ok in
  Alcotest.check
    Alcotest.bool
    "duplicate is classified without decoding its body"
    true
    (request.activity = Logseq_db_types.Sync_status.Pull_duplicate);
  Alcotest.(check int)
    "duplicate applies no authoritative transactions"
    0
    (List.length request.transactions)
;;

let test_duplicate_pull_never_replays_stored_transport_transactions () =
  let queued = queued_outbox_records () in
  let projected =
    authoritative_context
      ~checkpoint_t:1
      ~wire:"not transit"
      ~outbox_records:queued
      ~server_t:1
      ~transaction_t:1
      ()
    |> Core.begin_authoritative_batch
    |> Result.get_ok
    |> fun plan -> Core.finish_authoritative_batch plan None |> Result.get_ok
  in
  Alcotest.(check int)
    "queued outbox transport bytes are not replayed after authoritative inspection"
    0
    (List.length projected.projection_transactions);
  Alcotest.(check int)
    "queued outbox remains durable"
    1
    (List.length projected.outbox_records);
  let accepted = accepted_outbox_records 1 in
  let cleaned =
    authoritative_context
      ~checkpoint_t:1
      ~wire:"not transit"
      ~outbox_records:accepted
      ~server_t:1
      ~transaction_t:1
      ()
    |> Core.begin_authoritative_batch
    |> Result.get_ok
    |> fun plan -> Core.finish_authoritative_batch plan None |> Result.get_ok
  in
  Alcotest.(check int)
    "acknowledged outbox is removed"
    0
    (List.length cleaned.outbox_records)
;;

let test_duplicate_pull_still_rejects_future_transaction_cursor () =
  let result =
    authoritative_context
      ~checkpoint_t:1
      ~wire:"not transit"
      ~server_t:1
      ~transaction_t:2
      ()
    |> Core.begin_authoritative_batch
  in
  Alcotest.check
    Alcotest.bool
    "duplicate future cursor is rejected before body inspection"
    true
    (Result.is_error result)
;;

let test_typed_websocket_messages_reach_policy_without_raw_json () =
  let core, connection = encrypted_open_graph () in
  let pong = Core.step core (Websocket_message (connection, Sync_protocol.Server.Pong)) in
  Alcotest.check
    Alcotest.bool
    "application pong is a typed non-authoritative no-op"
    true
    (Core.state pong.next = Core.state core && pong.effects = []);
  let presence =
    Core.step
      pong.next
      (Websocket_message
         ( connection
         , Sync_protocol.Server.Presence
             { user_id = "user-2"; editing_block_uuid = Some "block-2" } ))
  in
  Alcotest.check
    Alcotest.bool
    "presence is a typed non-authoritative no-op"
    true
    (Core.state presence.next = Core.state pong.next && presence.effects = []);
  let message = Sync_protocol.Server.Changed { t = 1 } in
  let changed = Core.step presence.next (Websocket_message (connection, message)) in
  Alcotest.check
    Alcotest.bool
    "authoritative typed message is delegated without re-encoding"
    true
    (List.exists
       (function
         | Core.Delegate (Core.Inspect_authoritative_batch batch) ->
           batch.message = message
         | Run _ | Delegate _ | Publish _ -> false)
       changed.effects)
;;

let opened_graph_with_outbox outbox_records =
  let graph = graph () in
  let selected, mirror = select_catalog_graph graph in
  let request = open_request graph mirror.scope "submission-owner" in
  let inspected = Core.step selected.next (Mirror_inspected (Mirror_available request)) in
  let attached =
    Core.step
      inspected.next
      (Graph_attached
         { scope = request.scope; checkpoint = request.checkpoint; outbox_records })
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
    | None -> fail "attached graph did not start its WebSocket"
  in
  let opened = Core.step connecting.next (Websocket_opened connection) in
  opened, request, connection
;;

let complete_opening_pull
      (opened : Core.transition)
      (request : Core.graph_open_request)
      (connection : Core.connection_scope)
      outbox_records
  =
  let message =
    Sync_protocol.Server.Pull_ok
      { t = request.checkpoint.applied_server_t; checksum = None; txs = [] }
  in
  let inspection = Core.step opened.next (Websocket_message (connection, message)) in
  let batch =
    List.find_map
      (function
        | Core.Delegate (Core.Inspect_authoritative_batch batch) -> Some batch
        | Run _ | Delegate _ | Publish _ -> None)
      inspection.effects
    |> function
    | Some batch -> batch
    | None -> fail "opening pull did not request authoritative inspection"
  in
  let context : Core.authoritative_context =
    { batch
    ; precondition = "opening-pull-precondition"
    ; checkpoint = request.checkpoint
    ; database = Datascript.empty_db ()
    ; outbox_records
    }
  in
  let inspected = Core.step inspection.next (Authoritative_batch_inspected context) in
  let apply_request =
    List.find_map
      (function
        | Core.Delegate (Core.Apply_authoritative_batch request) -> Some request
        | Run _ | Delegate _ | Publish _ -> None)
      inspected.effects
    |> function
    | Some request -> request
    | None -> fail "opening pull inspection did not request authoritative apply"
  in
  Core.step
    inspected.next
    (Authoritative_batch_applied
       { scope = apply_request.scope
       ; checkpoint = apply_request.checkpoint
       ; outbox_records = apply_request.outbox_records
       ; activity = apply_request.activity
       ; invalidation = None
       })
;;

let current_graph_with_outbox outbox_records =
  let opened, request, connection = opened_graph_with_outbox outbox_records in
  let current = complete_opening_pull opened request connection outbox_records in
  current, request, connection
;;

let test_submission_owner_is_reserved_before_durable_transition () =
  let current, request, _ = current_graph_with_outbox [] in
  let prepared =
    Core.step
      current.next
      (Local_batch_prepared (queued_local_batch_input ~scope:request.scope ()))
  in
  let queued =
    List.find_map
      (function
        | Core.Delegate
            (Core.Complete_local_batch { action = Core.Commit { outbox_records }; _ }) ->
          Some outbox_records
        | Delegate (Complete_local_batch { action = Reject _; _ })
        | Run _ | Delegate _ | Publish _ -> None)
      prepared.effects
    |> function
    | Some outbox_records -> outbox_records
    | None -> fail "local batch preparation did not request a durable commit"
  in
  let first =
    Core.step
      prepared.next
      (Local_batch_committed { scope = request.scope; outbox_records = queued })
  in
  let transition =
    List.find_map
      (function
        | Core.Delegate (Core.Commit_outbox_transition transition) -> Some transition
        | Run _ | Delegate _ | Publish _ -> None)
      first.effects
    |> function
    | Some transition -> transition
    | None -> fail "first queued mutation did not reserve a submission"
  in
  let duplicate_before_cas =
    Core.step
      first.next
      (Local_batch_committed { scope = request.scope; outbox_records = queued })
  in
  Alcotest.check
    Alcotest.bool
    "a reserving descriptor prevents a second batch before durable CAS completes"
    true
    (not
       (List.exists
          (function
            | Core.Delegate (Core.Commit_outbox_transition _) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          duplicate_before_cas.effects));
  let committed =
    Core.step
      first.next
      (Outbox_transition_committed
         { scope = transition.scope
         ; outbox_records = transition.outbox_records
         ; pending_message = transition.pending_message
         })
  in
  let next_mutation_id =
    Logseq_db_types.Graph_types.Uuid.of_string "44444444-4444-4444-8444-444444444444"
    |> Result.get_ok
  in
  let next_record =
    local_batch_input
      ~scope:request.scope
      ~mutation_id:next_mutation_id
      ~mutation_fingerprint:"next-fingerprint"
      [ Datascript.Add
          ( Datascript.Temp_id "queued-next"
          , "block/uuid"
          , Datascript.Uuid (Logseq_db_types.Graph_types.Uuid.to_string next_mutation_id)
          )
      ]
    |> Core.begin_local_batch
    |> Result.get_ok
    |> fun plan -> Core.finish_local_batch plan None |> Result.get_ok
  in
  let submitted = Core.decode_outbox_records transition.outbox_records |> Result.get_ok in
  let with_next =
    Core.encode_outbox_records (submitted @ [ next_record ]) |> Result.get_ok
  in
  let while_in_flight =
    Core.step
      committed.next
      (Local_batch_committed { scope = request.scope; outbox_records = with_next })
  in
  Alcotest.check
    Alcotest.bool
    "an in-flight descriptor leaves later mutations queued"
    true
    (not
       (List.exists
          (function
            | Core.Delegate (Core.Commit_outbox_transition _) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          while_in_flight.effects))
;;

let test_acknowledgement_without_submission_owner_is_ignored () =
  let current, _, connection = current_graph_with_outbox [] in
  let stale_ack =
    Core.step
      current.next
      (Websocket_message
         (connection, Sync_protocol.Server.Tx_batch_ok { t = 1; checksum = None }))
  in
  Alcotest.check
    Alcotest.bool
    "an acknowledgement with no live owner cannot reach authoritative inspection"
    true
    (not
       (List.exists
          (function
            | Core.Delegate (Core.Inspect_authoritative_batch _) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          stale_ack.effects))
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
  Alcotest.check
    Alcotest.bool
    "opening WebSocket waits for the authoritative pull"
    true
    ((Core.state opened.next).snapshot.sync_phase = Core.Pulling);
  Alcotest.check
    Alcotest.bool
    "opening WebSocket sends the checkpoint pull"
    true
    (List.exists
       (function
         | Core.Run (Core.Send_websocket { message; _ }) ->
           message = Sync_protocol.Client.Pull { since = Some 0 }
         | Run _ | Delegate _ | Publish _ -> false)
       opened.effects);
  Alcotest.check
    Alcotest.bool
    "queued submission waits for the opening pull"
    true
    (not
       (List.exists
          (function
            | Core.Delegate (Core.Commit_outbox_transition _) -> true
            | Run _ | Delegate _ | Publish _ -> false)
          opened.effects));
  let current = complete_opening_pull opened open_request connection queued_records in
  let transition =
    List.find_map
      (function
        | Core.Delegate (Core.Commit_outbox_transition transition) -> Some transition
        | Run _ | Delegate _ | Publish _ -> None)
      current.effects
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
          current.effects));
  let committed =
    Core.step
      current.next
      (Outbox_transition_committed
         { scope = transition.scope
         ; outbox_records = transition.outbox_records
         ; pending_message = transition.pending_message
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
  Alcotest.check
    Alcotest.bool
    "missing cached key waits for explicit online recovery"
    true
    ((Core.state wrapped_failed.next).snapshot.startup.failure
     = Some Core.During_local_restore
     && not (has_token_request wrapped_failed.effects));
  let recovery = Core.step wrapped_failed.next Online_recovery_requested in
  let e2ee_token = token_request recovery.effects in
  let graph_key_fetch =
    Core.step recovery.next (Token_provided (e2ee_token, "e2ee-token"))
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

type state_view =
  { state : Core.state
  ; admitted_graph_scope : Core.graph_scope option
  }

type runner_request_kind =
  | Load_catalog_request
  | Save_catalog_request
  | Fetch_catalog_request
  | Fetch_snapshot_baseline_request
  | Fetch_snapshot_metadata_request
  | Download_snapshot_request
  | Fetch_e2ee_graph_key_request
  | Fetch_e2ee_user_keys_request
  | Load_and_unlock_graph_key_request
  | Fetch_and_unlock_graph_key_request
  | Unlock_private_key_request
  | Encrypt_protected_values_request
  | Decrypt_protected_values_request

type runner_request_view =
  { ticket_id : string
  ; ticket_scope : string
  ; request_kind : runner_request_kind
  ; request_payload : string
  }

type websocket_request_view =
  { websocket_scope : string
  ; websocket_uri : string
  ; websocket_token : string
  }

type websocket_send_view =
  { websocket_send_scope : string
  ; websocket_message : string
  }

type timer_request_view =
  { timer_diagnostic : string
  ; timer_scope : string
  ; delay_seconds : float
  }

type worker_effect_kind =
  | Inspect_mirror_effect
  | Activate_snapshot_effect
  | Delete_mirror_effect
  | Attach_graph_effect
  | Detach_graph_effect
  | Reset_managed_account_effect
  | Complete_local_batch_effect
  | Inspect_authoritative_batch_effect
  | Apply_authoritative_batch_effect
  | Commit_outbox_transition_effect

type worker_effect_view =
  { worker_effect_kind : worker_effect_kind
  ; worker_effect_payload : string
  }

type token_request_view =
  { token_request_id : string
  ; token_request_purpose : Core.token_purpose
  }

type effect_view =
  | Run_request of runner_request_view
  | Start_websocket of websocket_request_view
  | Send_websocket of websocket_send_view
  | Close_websocket of string
  | Schedule_timer of timer_request_view
  | Cancel_effects of string
  | Delegate of worker_effect_view
  | Publish_state of state_view
  | Publish_token_request of token_request_view
  | Publish_bootstrap_progress of Core.bootstrap_progress
  | Publish_graph_invalidation of Core.invalidation

let json_string value = Yojson.Safe.to_string value
let uuid_string = Logseq_db_types.Graph_types.Uuid.to_string

let option_json convert = function
  | None -> `Null
  | Some value -> convert value
;;

let secret_json value =
  `Assoc
    [ "length", `Int (String.length value)
    ; "digest", `String (Digest.to_hex (Digest.string value))
    ]
;;

let graph_json (graph : Core.graph) =
  `Assoc
    [ "graph_id", `String (uuid_string graph.graph_id)
    ; "name", `String graph.name
    ; ( "schema"
      , `Assoc
          [ "major", `Int graph.schema.major
          ; "minor", `Int graph.schema.minor
          ; "exact", `Bool graph.schema.exact
          ] )
    ; "encrypted", `Bool graph.encrypted
    ]
;;

let account_scope_json (scope : Core.account_scope) =
  `Assoc
    [ "managed_sync_origin", `String (Uri.to_string scope.managed_sync_origin)
    ; "user_id", `String scope.user_id
    ; "account_generation", `Int scope.account_generation
    ; "presentation_generation", `Int scope.presentation_generation
    ; "lifecycle_generation", `String (Int64.to_string scope.lifecycle_generation)
    ]
;;

let authenticated_account_scope_json (scope : Core.authenticated_account_scope) =
  `Assoc [ "account", account_scope_json scope.account; "token", secret_json scope.token ]
;;

let graph_scope_json (scope : Core.graph_scope) =
  `Assoc
    [ "account", account_scope_json scope.account
    ; "graph_id", `String (uuid_string scope.graph_id)
    ; "graph_generation", `Int scope.graph_generation
    ]
;;

let authorized_graph_scope_json (scope : Core.authorized_graph_scope) =
  `Assoc [ "graph", graph_scope_json scope.graph; "token", secret_json scope.token ]
;;

let connection_scope_json (scope : Core.connection_scope) =
  `Assoc
    [ "graph", graph_scope_json scope.graph
    ; "connection_generation", `Int scope.connection_generation
    ]
;;

let effect_scope_json (scope : Core.effect_scope) =
  let option_int = option_json (fun value -> `Int value) in
  `Assoc
    [ "account_generation", option_int scope.account_generation
    ; "graph_generation", option_int scope.graph_generation
    ; "connection_generation", option_int scope.connection_generation
    ; "presentation_generation", option_int scope.presentation_generation
    ; ( "lifecycle_generation"
      , option_json
          (fun value -> `String (Int64.to_string value))
          scope.lifecycle_generation )
    ]
;;

let graph_key_json key =
  `Assoc
    [ "id", `String (Core.graph_key_handle_id key)
    ; "scope", graph_scope_json (Core.graph_key_handle_scope key)
    ]
;;

let catalog_cache_json cache =
  `Assoc
    [ "user_id", `String (Core.catalog_cache_user_id cache)
    ; "graphs", `List (List.map graph_json (Core.catalog_cache_graphs cache))
    ; ( "selected_graph"
      , option_json
          (fun graph_id -> `String (uuid_string graph_id))
          (Core.catalog_cache_selected_graph cache) )
    ]
;;

let rec datascript_entity_ref_json = function
  | Datascript.Entity_id id -> `Assoc [ "entity_id", `Int id ]
  | Temp_id id -> `Assoc [ "temp_id", `String id ]
  | CurrentTx -> `String "current_tx"
  | Ident ident -> `Assoc [ "ident", `String ident ]
  | Lookup_ref (attribute, value) ->
    `Assoc [ "lookup_ref", `List [ `String attribute; datascript_value_json value ] ]

and datascript_value_json = function
  | Datascript.Nil -> `String "nil"
  | Int value -> `Assoc [ "int", `Int value ]
  | Float value -> `Assoc [ "float", `Float value ]
  | String value -> `Assoc [ "string", `String value ]
  | Symbol value -> `Assoc [ "symbol", `String value ]
  | Bool value -> `Assoc [ "bool", `Bool value ]
  | Keyword value -> `Assoc [ "keyword", `String value ]
  | Uuid value -> `Assoc [ "uuid", `String value ]
  | Instant value -> `Assoc [ "instant", `Int value ]
  | Regex value -> `Assoc [ "regex", `String value ]
  | Ref value -> `Assoc [ "ref", `Int value ]
  | List values -> `Assoc [ "list", `List (List.map datascript_value_json values) ]
  | Vector values -> `Assoc [ "vector", `List (List.map datascript_value_json values) ]
  | Map entries ->
    `Assoc
      [ ( "map"
        , `List
            (List.map
               (fun (key, value) ->
                  `List [ datascript_value_json key; datascript_value_json value ])
               entries) )
      ]
  | Set values -> `Assoc [ "set", `List (List.map datascript_value_json values) ]
  | Tuple values ->
    `Assoc [ "tuple", `List (List.map (option_json datascript_value_json) values) ]
  | TxRef -> `String "tx_ref"
  | Ref_to reference -> `Assoc [ "ref_to", datascript_entity_ref_json reference ]
;;

let rec datascript_tx_value_json = function
  | Datascript.One_value value -> `Assoc [ "one_value", datascript_value_json value ]
  | Many_values values ->
    `Assoc [ "many_values", `List (List.map datascript_value_json values) ]
  | One_entity entity -> `Assoc [ "one_entity", datascript_tx_entity_json entity ]
  | Many_entities entities ->
    `Assoc [ "many_entities", `List (List.map datascript_tx_entity_json entities) ]

and datascript_tx_entity_json (entity : Datascript.tx_entity) =
  `Assoc
    [ "db_id", option_json datascript_entity_ref_json entity.db_id
    ; ( "attrs"
      , `List
          (List.map
             (fun (attribute, value) ->
                `List [ `String attribute; datascript_tx_value_json value ])
             entity.attrs) )
    ]
;;

let datascript_datom_json (datom : Datascript.datom) =
  `Assoc
    [ "e", `Int datom.e
    ; "a", `String datom.a
    ; "v", datascript_value_json datom.v
    ; "tx", `Int datom.tx
    ; "added", `Bool datom.added
    ]
;;

let datascript_tx_op_json = function
  | Datascript.Add (entity, attribute, value) ->
    `Assoc
      [ ( "add"
        , `List
            [ datascript_entity_ref_json entity
            ; `String attribute
            ; datascript_value_json value
            ] )
      ]
  | Retract (entity, attribute, value) ->
    `Assoc
      [ ( "retract"
        , `List
            [ datascript_entity_ref_json entity
            ; `String attribute
            ; option_json datascript_value_json value
            ] )
      ]
  | RetractEntity entity -> `Assoc [ "retract_entity", datascript_entity_ref_json entity ]
  | RetractAttr (entity, attribute) ->
    `Assoc
      [ "retract_attr", `List [ datascript_entity_ref_json entity; `String attribute ] ]
  | CompareAndSet (entity, attribute, previous, next) ->
    `Assoc
      [ ( "compare_and_set"
        , `List
            [ datascript_entity_ref_json entity
            ; `String attribute
            ; option_json datascript_value_json previous
            ; datascript_value_json next
            ] )
      ]
  | Entity entity -> `Assoc [ "entity", datascript_tx_entity_json entity ]
  | Raw_datom datom -> `Assoc [ "raw_datom", datascript_datom_json datom ]
  | InstallTxFn (entity, _) ->
    `Assoc [ "install_tx_fn", datascript_entity_ref_json entity ]
  | CallIdent (entity, values) ->
    `Assoc
      [ ( "call_ident"
        , `List
            [ datascript_entity_ref_json entity
            ; `List (List.map datascript_value_json values)
            ] )
      ]
  | Call _ -> `String "call"
;;

let checkpoint_json (checkpoint : Logseq_db_types.Sync_checkpoint.t) =
  let status =
    match checkpoint.status with
    | Logseq_db_types.Sync_checkpoint.Active -> "active"
    | Paused -> "paused"
  in
  `Assoc
    [ "format_version", `Int checkpoint.format_version
    ; "graph_id", `String (uuid_string checkpoint.graph_id)
    ; ( "schema"
      , `Assoc
          [ "major", `Int checkpoint.schema.major; "minor", `Int checkpoint.schema.minor ]
      )
    ; "applied_server_t", `Int checkpoint.applied_server_t
    ; "checksum", `String checkpoint.checksum
    ; "status", `String status
    ; "last_error", option_json (fun value -> `String value) checkpoint.last_error
    ]
;;

let sync_activity_json = function
  | Logseq_db_types.Sync_status.Pull_applied -> `String "pull_applied"
  | Pull_duplicate -> `String "pull_duplicate"
  | Pull_required -> `String "pull_required"
  | Sync_paused -> `String "sync_paused"
  | Sync_submission_blocked -> `String "sync_submission_blocked"
;;

let client_message_json message =
  match Sync_protocol.encode_client_message message with
  | Ok encoded -> Yojson.Safe.from_string encoded
  | Error error ->
    fail "unable to project client message: %s" (Sync_protocol.error_to_string error)
;;

let server_message_json message =
  match Sync_protocol.encode_server_message message with
  | Ok encoded -> Yojson.Safe.from_string encoded
  | Error error ->
    fail "unable to project server message: %s" (Sync_protocol.error_to_string error)
;;

let outbox_state_json = function
  | Core.Queued -> `String "queued"
  | Submitted -> `String "submitted"
  | Accepted cursor -> `Assoc [ "accepted", `Int cursor ]
  | Blocked message -> `Assoc [ "blocked", `String message ]
;;

let outbox_records_json records =
  let raw_record_json raw =
    match Core.decode_outbox_records [ raw ] with
    | Ok [ record ] ->
      `Assoc
        [ "mutation_id", `String (uuid_string (Core.outbox_record_mutation_id record))
        ; "fingerprint", `String (Core.outbox_record_fingerprint record)
        ; "mutation_payload", secret_json (Core.outbox_record_mutation_payload record)
        ; "outliner_op", `String (Core.outbox_record_outliner_op record)
        ; "state", outbox_state_json (Core.outbox_record_state record)
        ; "encoded_record", secret_json raw
        ]
    | Ok _ | Error _ -> `Assoc [ "invalid_encoded_record", secret_json raw ]
  in
  `List (List.map raw_record_json records)
;;

let authoritative_batch_json (batch : Core.authoritative_batch) =
  `Assoc
    [ "message", server_message_json batch.message
    ; "scope", connection_scope_json batch.scope
    ; "presentation_generation", `Int batch.presentation_generation
    ; "lifecycle_generation", `String (Int64.to_string batch.lifecycle_generation)
    ]
;;

let invalidation_json (invalidation : Core.invalidation) =
  `Assoc
    [ "basis", `String (Int64.to_string invalidation.basis)
    ; ( "changed_uuids"
      , `List (List.map (fun id -> `String (uuid_string id)) invalidation.changed_uuids) )
    ; "changed_uuids_truncated", `Bool invalidation.changed_uuids_truncated
    ]
;;

let graph_open_request_json (request : Core.graph_open_request) =
  `Assoc
    [ "graph", graph_json request.graph
    ; "graph_directory", `String request.graph_directory
    ; "database_path", `String request.database_path
    ; "checkpoint", checkpoint_json request.checkpoint
    ; "scope", graph_scope_json request.scope
    ]
;;

let runner_request_view
  : type a. a Core.effect_ticket -> a Core.runner_request -> runner_request_view
  =
  fun ticket request ->
  let request_kind, payload =
    match request with
    | Core.Load_catalog account -> Load_catalog_request, account_scope_json account
    | Save_catalog { account; cache } ->
      ( Save_catalog_request
      , `Assoc
          [ "account", account_scope_json account; "cache", catalog_cache_json cache ] )
    | Fetch_catalog scope -> Fetch_catalog_request, authenticated_account_scope_json scope
    | Fetch_snapshot_baseline scope ->
      Fetch_snapshot_baseline_request, authorized_graph_scope_json scope
    | Fetch_snapshot_metadata scope ->
      Fetch_snapshot_metadata_request, authorized_graph_scope_json scope
    | Download_snapshot request ->
      ( Download_snapshot_request
      , `Assoc
          [ "scope", authorized_graph_scope_json request.scope
          ; "uri", `String (Uri.to_string request.uri)
          ; ( "expected_bytes"
            , option_json
                (fun value -> `String (Int64.to_string value))
                request.expected_bytes )
          ; "maximum_bytes", `Int request.maximum_bytes
          ] )
    | Fetch_e2ee_graph_key scope ->
      Fetch_e2ee_graph_key_request, authorized_graph_scope_json scope
    | Fetch_e2ee_user_keys scope ->
      Fetch_e2ee_user_keys_request, authenticated_account_scope_json scope
    | Load_and_unlock_graph_key scope ->
      Load_and_unlock_graph_key_request, graph_scope_json scope
    | Fetch_and_unlock_graph_key request ->
      ( Fetch_and_unlock_graph_key_request
      , `Assoc
          [ "scope", authorized_graph_scope_json request.scope
          ; "encrypted_graph_key", secret_json request.encrypted_graph_key
          ] )
    | Unlock_private_key request ->
      ( Unlock_private_key_request
      , `Assoc
          [ "scope", authenticated_account_scope_json request.scope
          ; "password", secret_json request.password
          ; "private_key_package", secret_json request.private_key_package
          ] )
    | Encrypt_protected_values request ->
      ( Encrypt_protected_values_request
      , `Assoc
          [ "scope", graph_scope_json request.scope
          ; "key", graph_key_json request.key
          ; "plaintexts", `List (List.map secret_json request.plaintexts)
          ] )
    | Decrypt_protected_values request ->
      ( Decrypt_protected_values_request
      , `Assoc
          [ "scope", graph_scope_json request.scope
          ; "key", graph_key_json request.key
          ; ( "protected_values"
            , `List
                (List.map
                   (fun (attribute, encrypted) ->
                      `List [ `String attribute; secret_json encrypted ])
                   request.protected_values) )
          ] )
  in
  { ticket_id = Core.effect_id_to_string (Core.effect_ticket_id ticket)
  ; ticket_scope = effect_scope_json (Core.effect_ticket_scope ticket) |> json_string
  ; request_kind
  ; request_payload = json_string payload
  }
;;

let local_batch_action_json = function
  | Core.Commit { outbox_records } ->
    `Assoc [ "commit", outbox_records_json outbox_records ]
  | Reject { kind; message } ->
    let kind =
      match kind with
      | Core.Planning_failed -> "planning_failed"
      | Encryption_failed -> "encryption_failed"
      | Encoding_failed -> "encoding_failed"
      | Scope_closed -> "scope_closed"
      | Engine_unavailable -> "engine_unavailable"
      | Persistence_failed -> "persistence_failed"
    in
    `Assoc [ "reject", `Assoc [ "kind", `String kind; "message", `String message ] ]
;;

let worker_effect_view worker =
  let worker_effect_kind, payload =
    match worker with
    | Core.Inspect_mirror request ->
      ( Inspect_mirror_effect
      , `Assoc
          [ "graph", graph_json request.graph; "scope", graph_scope_json request.scope ] )
    | Activate_snapshot request ->
      ( Activate_snapshot_effect
      , `Assoc
          [ "artifact_path", `String (Core.staged_artifact_path request.artifact)
          ; ( "artifact_expected_rows"
            , `Int (Core.staged_artifact_expected_rows request.artifact) )
          ; "scope", graph_scope_json request.scope
          ; "applied_server_t", `Int request.applied_server_t
          ; "key", option_json graph_key_json request.key
          ] )
    | Delete_mirror request ->
      ( Delete_mirror_effect
      , `Assoc
          [ "graph_id", `String (uuid_string request.graph_id)
          ; "scope", effect_scope_json request.scope
          ] )
    | Attach_graph request -> Attach_graph_effect, graph_open_request_json request
    | Detach_graph scope -> Detach_graph_effect, graph_scope_json scope
    | Reset_managed_account scope ->
      Reset_managed_account_effect, account_scope_json scope
    | Complete_local_batch request ->
      ( Complete_local_batch_effect
      , `Assoc
          [ "operation_id", `String (uuid_string request.operation_id)
          ; "admission_id", `String request.admission_id
          ; "scope", graph_scope_json request.scope
          ; "action", local_batch_action_json request.action
          ] )
    | Inspect_authoritative_batch batch ->
      Inspect_authoritative_batch_effect, authoritative_batch_json batch
    | Apply_authoritative_batch request ->
      ( Apply_authoritative_batch_effect
      , `Assoc
          [ "batch", authoritative_batch_json request.batch
          ; "precondition", `String request.precondition
          ; "scope", graph_scope_json request.scope
          ; "key", option_json graph_key_json request.key
          ; ( "transactions"
            , `List
                (List.map
                   (fun transaction -> `List (List.map datascript_tx_op_json transaction))
                   request.transactions) )
          ; ( "projection_transactions"
            , `List
                (List.map
                   (fun transaction -> `List (List.map datascript_tx_op_json transaction))
                   request.projection_transactions) )
          ; "checkpoint", checkpoint_json request.checkpoint
          ; "outbox_records", outbox_records_json request.outbox_records
          ; "activity", sync_activity_json request.activity
          ] )
    | Commit_outbox_transition request ->
      ( Commit_outbox_transition_effect
      , `Assoc
          [ "scope", graph_scope_json request.scope
          ; "presentation_generation", `Int request.presentation_generation
          ; "lifecycle_generation", `String (Int64.to_string request.lifecycle_generation)
          ; "expected_outbox_records", outbox_records_json request.expected_outbox_records
          ; "outbox_records", outbox_records_json request.outbox_records
          ; "pending_message", option_json client_message_json request.pending_message
          ] )
  in
  { worker_effect_kind; worker_effect_payload = json_string payload }
;;

let view_state core =
  { state = Core.state core; admitted_graph_scope = Core.admitted_graph_scope core }
;;

let view_instruction = function
  | Core.Run (Core.Request (ticket, request)) ->
    Run_request (runner_request_view ticket request)
  | Run (Start_websocket request) ->
    Start_websocket
      { websocket_scope = connection_scope_json request.scope |> json_string
      ; websocket_uri = Uri.to_string request.uri
      ; websocket_token = secret_json request.token |> json_string
      }
  | Run (Send_websocket request) ->
    Send_websocket
      { websocket_send_scope = connection_scope_json request.scope |> json_string
      ; websocket_message = client_message_json request.message |> json_string
      }
  | Run (Close_websocket scope) ->
    Close_websocket (connection_scope_json scope |> json_string)
  | Run (Schedule_timer request as runner_effect) ->
    Schedule_timer
      { timer_diagnostic = Core.runner_effect_diagnostic runner_effect
      ; timer_scope = effect_scope_json request.scope |> json_string
      ; delay_seconds = request.delay_seconds
      }
  | Run (Cancel_effects scope) -> Cancel_effects (effect_scope_json scope |> json_string)
  | Delegate worker -> Delegate (worker_effect_view worker)
  | Publish (State_changed state) -> Publish_state { state; admitted_graph_scope = None }
  | Publish (Token_requested request) ->
    Publish_token_request
      { token_request_id = Core.token_request_id request
      ; token_request_purpose = Core.token_request_purpose request
      }
  | Publish (Bootstrap_progressed progress) -> Publish_bootstrap_progress progress
  | Publish (Graph_invalidated invalidation) -> Publish_graph_invalidation invalidation
;;

let runner_request_kind_name = function
  | Load_catalog_request -> "Load_catalog"
  | Save_catalog_request -> "Save_catalog"
  | Fetch_catalog_request -> "Fetch_catalog"
  | Fetch_snapshot_baseline_request -> "Fetch_snapshot_baseline"
  | Fetch_snapshot_metadata_request -> "Fetch_snapshot_metadata"
  | Download_snapshot_request -> "Download_snapshot"
  | Fetch_e2ee_graph_key_request -> "Fetch_e2ee_graph_key"
  | Fetch_e2ee_user_keys_request -> "Fetch_e2ee_user_keys"
  | Load_and_unlock_graph_key_request -> "Load_and_unlock_graph_key"
  | Fetch_and_unlock_graph_key_request -> "Fetch_and_unlock_graph_key"
  | Unlock_private_key_request -> "Unlock_private_key"
  | Encrypt_protected_values_request -> "Encrypt_protected_values"
  | Decrypt_protected_values_request -> "Decrypt_protected_values"
;;

let worker_effect_kind_name = function
  | Inspect_mirror_effect -> "Inspect_mirror"
  | Activate_snapshot_effect -> "Activate_snapshot"
  | Delete_mirror_effect -> "Delete_mirror"
  | Attach_graph_effect -> "Attach_graph"
  | Detach_graph_effect -> "Detach_graph"
  | Reset_managed_account_effect -> "Reset_managed_account"
  | Complete_local_batch_effect -> "Complete_local_batch"
  | Inspect_authoritative_batch_effect -> "Inspect_authoritative_batch"
  | Apply_authoritative_batch_effect -> "Apply_authoritative_batch"
  | Commit_outbox_transition_effect -> "Commit_outbox_transition"
;;

let token_purpose_name = function
  | Core.Catalog_discovery -> "Catalog_discovery"
  | Snapshot_bootstrap -> "Snapshot_bootstrap"
  | E2ee_key_access -> "E2ee_key_access"
  | Websocket_connect -> "Websocket_connect"
;;

let state_view_json view =
  let snapshot = view.state.snapshot in
  let startup = snapshot.startup in
  let sync_phase =
    match snapshot.sync_phase with
    | Core.Offline -> "offline"
    | Connecting -> "connecting"
    | Pulling -> "pulling"
    | Submitting -> "submitting"
    | Current -> "current"
    | Paused -> "paused"
    | Failed -> "failed"
  in
  let failure =
    option_json
      (fun failure ->
         `String
           (match failure with
            | Core.During_authentication -> "during_authentication"
            | During_catalog -> "during_catalog"
            | During_local_restore -> "during_local_restore"
            | During_bootstrap -> "during_bootstrap"
            | During_e2ee -> "during_e2ee"))
      startup.failure
  in
  let diagnostic_group_json (group : Core.diagnostic_group) =
    `Assoc
      [ "title", `String group.title
      ; ( "entries"
        , `List
            (List.map
               (fun (key, value) -> `List [ `String key; `String value ])
               group.entries) )
      ]
  in
  `Assoc
    [ ( "state"
      , `Assoc
          [ ( "snapshot"
            , `Assoc
                [ "sync_phase", `String sync_phase
                ; "catalog", `List (List.map graph_json snapshot.catalog)
                ; ( "selected_graph"
                  , option_json
                      (fun value -> `String (uuid_string value))
                      snapshot.selected_graph )
                ; ( "applied_server_t"
                  , option_json (fun value -> `Int value) snapshot.applied_server_t )
                ; ( "timeline_presentation_pending"
                  , `Bool snapshot.timeline_presentation_pending )
                ; ( "startup"
                  , `Assoc
                      [ "authenticated", `Bool startup.authenticated
                      ; "catalog_loading", `Bool startup.catalog_loading
                      ; "awaiting_selection", `Bool startup.awaiting_selection
                      ; "restoring_local", `Bool startup.restoring_local
                      ; "bootstrapping", `Bool startup.bootstrapping
                      ; "awaiting_e2ee_password", `Bool startup.awaiting_e2ee_password
                      ; "failure", failure
                      ; "account_generation", `Int startup.account_generation
                      ; "graph_generation", `Int startup.graph_generation
                      ; "presentation_generation", `Int startup.presentation_generation
                      ] )
                ; ( "last_error"
                  , option_json (fun value -> `String value) snapshot.last_error )
                ] )
          ; ( "diagnostics"
            , `Assoc
                [ ( "groups"
                  , `List (List.map diagnostic_group_json view.state.diagnostics.groups) )
                ; ( "history"
                  , `List
                      (List.map
                         (fun value -> `String value)
                         view.state.diagnostics.history) )
                ] )
          ] )
    ; "admitted_graph_scope", option_json graph_scope_json view.admitted_graph_scope
    ]
;;

let show_state_view view = state_view_json view |> json_string

let show_effect_view = function
  | Run_request request ->
    Printf.sprintf
      "Run_request(kind=%s,ticket=%s,scope=%s,payload=%s)"
      (runner_request_kind_name request.request_kind)
      request.ticket_id
      request.ticket_scope
      request.request_payload
  | Start_websocket request ->
    Printf.sprintf
      "Start_websocket(scope=%s,uri=%s,token=%s)"
      request.websocket_scope
      request.websocket_uri
      request.websocket_token
  | Send_websocket request ->
    Printf.sprintf
      "Send_websocket(scope=%s,message=%s)"
      request.websocket_send_scope
      request.websocket_message
  | Close_websocket scope -> "Close_websocket(scope=" ^ scope ^ ")"
  | Schedule_timer request ->
    Printf.sprintf
      "Schedule_timer(diagnostic=%s,scope=%s,delay=%g)"
      request.timer_diagnostic
      request.timer_scope
      request.delay_seconds
  | Cancel_effects scope -> "Cancel_effects(scope=" ^ scope ^ ")"
  | Delegate worker ->
    Printf.sprintf
      "Delegate(kind=%s,payload=%s)"
      (worker_effect_kind_name worker.worker_effect_kind)
      worker.worker_effect_payload
  | Publish_state state -> "Publish_state(" ^ show_state_view state ^ ")"
  | Publish_token_request request ->
    Printf.sprintf
      "Publish_token_request(id=%s,purpose=%s)"
      request.token_request_id
      (token_purpose_name request.token_request_purpose)
  | Publish_bootstrap_progress progress ->
    Printf.sprintf
      "Publish_bootstrap_progress(graph=%s,received=%Ld,total=%s)"
      (uuid_string progress.graph_id)
      progress.received_bytes
      (Option.fold ~none:"none" ~some:Int64.to_string progress.total_bytes)
  | Publish_graph_invalidation invalidation ->
    "Publish_graph_invalidation(" ^ (invalidation_json invalidation |> json_string) ^ ")"
;;

let first_state_difference expected actual =
  let expected_snapshot = expected.state.snapshot in
  let actual_snapshot = actual.state.snapshot in
  let expected_startup = expected_snapshot.startup in
  let actual_startup = actual_snapshot.startup in
  if expected_snapshot.sync_phase <> actual_snapshot.sync_phase
  then "state.snapshot.sync_phase"
  else if expected_snapshot.catalog <> actual_snapshot.catalog
  then "state.snapshot.catalog"
  else if expected_snapshot.selected_graph <> actual_snapshot.selected_graph
  then "state.snapshot.selected_graph"
  else if expected_snapshot.applied_server_t <> actual_snapshot.applied_server_t
  then "state.snapshot.applied_server_t"
  else if
    expected_snapshot.timeline_presentation_pending
    <> actual_snapshot.timeline_presentation_pending
  then "state.snapshot.timeline_presentation_pending"
  else if expected_startup.authenticated <> actual_startup.authenticated
  then "state.snapshot.startup.authenticated"
  else if expected_startup.catalog_loading <> actual_startup.catalog_loading
  then "state.snapshot.startup.catalog_loading"
  else if expected_startup.awaiting_selection <> actual_startup.awaiting_selection
  then "state.snapshot.startup.awaiting_selection"
  else if expected_startup.restoring_local <> actual_startup.restoring_local
  then "state.snapshot.startup.restoring_local"
  else if expected_startup.bootstrapping <> actual_startup.bootstrapping
  then "state.snapshot.startup.bootstrapping"
  else if expected_startup.awaiting_e2ee_password <> actual_startup.awaiting_e2ee_password
  then "state.snapshot.startup.awaiting_e2ee_password"
  else if expected_startup.failure <> actual_startup.failure
  then "state.snapshot.startup.failure"
  else if expected_startup.account_generation <> actual_startup.account_generation
  then "state.snapshot.startup.account_generation"
  else if expected_startup.graph_generation <> actual_startup.graph_generation
  then "state.snapshot.startup.graph_generation"
  else if
    expected_startup.presentation_generation <> actual_startup.presentation_generation
  then "state.snapshot.startup.presentation_generation"
  else if expected_snapshot.last_error <> actual_snapshot.last_error
  then "state.snapshot.last_error"
  else if expected.state.diagnostics.groups <> actual.state.diagnostics.groups
  then "state.diagnostics.groups"
  else if expected.state.diagnostics.history <> actual.state.diagnostics.history
  then "state.diagnostics.history"
  else if expected.admitted_graph_scope <> actual.admitted_graph_scope
  then "admitted_graph_scope"
  else "unknown"
;;

let first_effect_difference expected actual =
  let rec loop index expected actual =
    match expected, actual with
    | expected :: expected_rest, actual :: actual_rest when expected = actual ->
      loop (index + 1) expected_rest actual_rest
    | expected :: _, actual :: _ ->
      Printf.sprintf
        "effect[%d] expected %s but got %s"
        index
        (show_effect_view expected)
        (show_effect_view actual)
    | [], actual :: _ ->
      Printf.sprintf "effect[%d] was unexpectedly %s" index (show_effect_view actual)
    | expected :: _, [] ->
      Printf.sprintf
        "effect[%d] was missing; expected %s"
        index
        (show_effect_view expected)
    | [], [] -> "unknown effect difference"
  in
  loop 0 expected actual
;;

let static_uuid value = Logseq_db_types.Graph_types.Uuid.of_string value |> Result.get_ok

let make_state_view
      ~sync_phase
      ~catalog
      ~selected_graph
      ~applied_server_t
      ~timeline_presentation_pending
      ~authenticated
      ~catalog_loading
      ~awaiting_selection
      ~restoring_local
      ~bootstrapping
      ~awaiting_e2ee_password
      ~failure
      ~account_generation
      ~graph_generation
      ~presentation_generation
      ~last_error
      ~diagnostic_groups
      ~diagnostic_history
      ~admitted_graph_scope
  =
  let startup : Core.startup_facts =
    { authenticated
    ; catalog_loading
    ; awaiting_selection
    ; restoring_local
    ; bootstrapping
    ; awaiting_e2ee_password
    ; failure
    ; account_generation
    ; graph_generation
    ; presentation_generation
    }
  in
  let snapshot : Core.snapshot =
    { sync_phase
    ; catalog
    ; selected_graph
    ; applied_server_t
    ; timeline_presentation_pending
    ; startup
    ; last_error
    }
  in
  let diagnostics : Core.diagnostics =
    { groups = diagnostic_groups; history = diagnostic_history }
  in
  { state = { snapshot; diagnostics }; admitted_graph_scope }
;;

type happy_path_rationale =
  { id : string
  ; contract : string
  ; owner : string
  ; unchanged : string
  ; changes : string
  ; effects : string
  }

let happy_path_rationales =
  [ { id = "HP01"
    ; contract = "Authentication starts a fresh managed-account generation."
    ; owner = "The authenticated user establishes the account generation."
    ; unchanged = "The empty catalog and absent graph selection remain empty."
    ; changes = "Authentication and catalog loading become active."
    ; effects = "Publish the new state, then request a catalog token."
    }
  ; { id = "HP02"
    ; contract = "A current catalog token authorizes one catalog fetch."
    ; owner = "The exact catalog token request emitted by HP01."
    ; unchanged = "The public catalog-loading state is retained."
    ; changes = "The token owner is consumed and one runner ticket is created."
    ; effects = "Run exactly one typed Fetch_catalog request."
    }
  ; { id = "HP03"
    ; contract = "A successful catalog fetch installs the account catalog."
    ; owner = "The exact Fetch_catalog ticket emitted by HP02."
    ; unchanged = "No graph is selected or admitted."
    ; changes = "Catalog loading ends and graph selection becomes available."
    ; effects = "Publish Offline state, then persist the unselected catalog cache."
    }
  ; { id = "HP04"
    ; contract = "Selecting a declared catalog member admits a graph generation."
    ; owner = "The selected UUID belongs to the catalog installed by HP03."
    ; unchanged = "The catalog and account generation remain stable."
    ; changes = "The graph is selected, admitted, and marked bootstrapping."
    ; effects = "Inspect the mirror, publish state, then persist the selection."
    }
  ; { id = "HP05"
    ; contract = "A matching existing mirror can be attached."
    ; owner = "The exact graph scope inspected by HP04."
    ; unchanged = "The selected bootstrapping public view is retained."
    ; changes = "Only private attachment ownership advances."
    ; effects = "Delegate exactly one Attach_graph request."
    }
  ; { id = "HP06"
    ; contract = "Attachment establishes the durable checkpoint and outbox."
    ; owner = "The exact Attach_graph request emitted by HP05."
    ; unchanged = "Catalog, selection, and graph generation remain stable."
    ; changes = "Bootstrap clears and Connecting starts at server cursor zero."
    ; effects = "Publish state, then request a WebSocket token."
    }
  ; { id = "HP07"
    ; contract = "A current WebSocket token starts one scoped connection."
    ; owner = "The exact Websocket_connect token request emitted by HP06."
    ; unchanged = "The public Connecting state is retained."
    ; changes = "The connection generation advances exactly once."
    ; effects = "Run exactly one Start_websocket instruction."
    }
  ; { id = "HP08"
    ; contract = "Opening the admitted connection starts the authoritative pull."
    ; owner = "The exact connection scope emitted by HP07."
    ; unchanged = "Catalog, graph, and checkpoint remain stable."
    ; changes = "The connection becomes live and the phase becomes Pulling."
    ; effects = "Publish Pulling, then send Pull since cursor zero."
    }
  ; { id = "HP09"
    ; contract = "A pull response requires worker inspection before Current."
    ; owner = "The live connection emitted by HP07 and opened by HP08."
    ; unchanged = "The public Pulling state and cursor remain unchanged."
    ; changes = "An authoritative batch owner is reserved privately."
    ; effects = "Delegate exactly one inspection of the typed pull response."
    }
  ; { id = "HP10"
    ; contract = "Worker inspection supplies the authoritative apply precondition."
    ; owner = "The exact authoritative batch emitted by HP09."
    ; unchanged = "Public state and active authoritative ownership remain stable."
    ; changes = "The inspected context becomes a duplicate-pull apply request."
    ; effects = "Delegate one apply with the worker checkpoint, outbox, and precondition."
    }
  ; { id = "HP11"
    ; contract = "Only a completed authoritative apply can establish Current."
    ; owner = "The exact apply request emitted by HP10."
    ; unchanged = "The admitted graph and cursor-zero checkpoint remain stable."
    ; changes = "The authoritative owner clears and the phase becomes Current."
    ; effects = "Publish Current and open no submission for an empty outbox."
    }
  ; { id = "HP12"
    ; contract = "A plaintext local mutation is planned without crypto."
    ; owner = "The mutation targets the graph admitted by HP04."
    ; unchanged = "Current sync state and durable outbox remain unchanged in Core."
    ; changes = "A stable worker commit operation is produced."
    ; effects = "Delegate one Complete_local_batch containing a queued record."
    }
  ; { id = "HP13"
    ; contract = "A worker-committed queued record must be reserved durably."
    ; owner = "The exact local completion operation emitted by HP12."
    ; unchanged = "The public Current state remains unchanged."
    ; changes = "The queued outbox is adopted and one submission owner is reserved."
    ; effects = "Commit Queued to Submitted without sending on the WebSocket."
    }
  ; { id = "HP14"
    ; contract = "Only the exact durable reservation may dispatch a transaction."
    ; owner = "The exact outbox transition emitted by HP13."
    ; unchanged = "Catalog, graph, and cursor remain stable."
    ; changes = "The owner becomes dispatched and the phase becomes Submitting."
    ; effects = "Send Tx_batch first, then publish Submitting."
    }
  ; { id = "HP15"
    ; contract = "A transaction acknowledgement must correlate to its dispatched owner."
    ; owner = "The live dispatched owner and its exact connection."
    ; unchanged = "The public Submitting state and durable record remain unchanged."
    ; changes = "The owner advances to acknowledgement application."
    ; effects = "Delegate one authoritative inspection of Tx_batch_ok."
    }
  ; { id = "HP16"
    ; contract = "Acknowledgement inspection accepts only the owned mutation."
    ; owner = "The exact acknowledgement batch emitted by HP15."
    ; unchanged = "Public state, mutation identity, and checkpoint stay stable."
    ; changes = "The owned durable record becomes Accepted at cursor one."
    ; effects = "Delegate one Pull_required apply with the worker precondition."
    }
  ; { id = "HP17"
    ; contract = "Acknowledgement apply retains ownership until confirmation."
    ; owner = "The exact Pull_required apply emitted by HP16."
    ; unchanged = "The accepted record and applied cursor zero remain durable."
    ; changes = "The owner awaits cursor one and the phase becomes Pulling."
    ; effects = "Publish Pulling, then send one Pull since cursor zero."
    }
  ; { id = "HP18"
    ; contract = "The confirmation response begins a new authoritative apply chain."
    ; owner = "The live connection retained by HP17."
    ; unchanged = "Public Pulling state and accepted mutation remain stable."
    ; changes = "A confirmation authoritative owner is reserved."
    ; effects = "Delegate one inspection of the cursor-one response."
    }
  ; { id = "HP19"
    ; contract = "Confirmation inspection reconciles accepted durable work."
    ; owner = "The exact confirmation batch emitted by HP18."
    ; unchanged = "Public state and worker precondition remain stable."
    ; changes = "The checkpoint advances and the confirmed record is removed."
    ; effects = "Delegate one Pull_applied request with rebuilt empty outbox."
    }
  ; { id = "HP20"
    ; contract = "A committed authoritative confirmation releases submission ownership."
    ; owner = "The exact Pull_applied request emitted by HP19."
    ; unchanged = "Catalog, selection, and graph admission remain stable."
    ; changes = "Current advances to cursor one, outbox empties, and owner releases."
    ; effects = "Publish state, then worker invalidation, with no duplicate submission."
    }
  ]
;;

let happy_graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
let happy_mutation_id = static_uuid "33333333-3333-4333-8333-333333333333"

let happy_graph : Core.graph =
  { graph_id = happy_graph_id
  ; name = "Journal"
  ; schema = { major = 1; minor = 0; exact = true }
  ; encrypted = false
  }
;;

let happy_account_scope : Core.account_scope =
  { managed_sync_origin = Uri.of_string "https://api.logseq.io"
  ; user_id = "user-1"
  ; account_generation = 1
  ; presentation_generation = 1
  ; lifecycle_generation = 0L
  }
;;

let happy_graph_scope : Core.graph_scope =
  { account = happy_account_scope; graph_id = happy_graph_id; graph_generation = 2 }
;;

let happy_connection_scope : Core.connection_scope =
  { graph = happy_graph_scope; connection_generation = 1 }
;;

let happy_checkpoint_0 = checkpoint happy_graph_id

let happy_checkpoint_1 =
  Logseq_db_types.Sync_checkpoint.create
    ~graph_id:happy_graph_id
    ~schema:Logseq_db_types.Graph_types.{ major = 1; minor = 0 }
    ~applied_server_t:1
    ~checksum:"0000000000000000"
  |> Result.get_ok
;;

let happy_open_request : Core.graph_open_request =
  { graph = happy_graph
  ; graph_directory = "/worker/canonical-happy-path"
  ; database_path = "/worker/canonical-happy-path/db.sqlite"
  ; checkpoint = happy_checkpoint_0
  ; scope = happy_graph_scope
  }
;;

let happy_operation =
  Datascript.Add
    ( Datascript.Temp_id "hp-block"
    , "block/uuid"
    , Datascript.Uuid "33333333-3333-4333-8333-333333333333" )
;;

let happy_encoded_tx =
  "[[\"~:db/add\",\"hp-block\",\"~:block/uuid\",\"~u33333333-3333-4333-8333-333333333333\"]]"
;;

let happy_queued_record =
  "{\"mutationId\":\"33333333-3333-4333-8333-333333333333\",\"mutationPayload\":\"hp-mutation\",\"mutationFingerprint\":\"hp-fingerprint\",\"outlinerOp\":\"save-block\",\"state\":{\"type\":\"queued\"},\"encodedTx\":\"[[\\\"~:db/add\\\",\\\"hp-block\\\",\\\"~:block/uuid\\\",\\\"~u33333333-3333-4333-8333-333333333333\\\"]]\"}"
;;

let happy_submitted_record =
  "{\"mutationId\":\"33333333-3333-4333-8333-333333333333\",\"mutationPayload\":\"hp-mutation\",\"mutationFingerprint\":\"hp-fingerprint\",\"outlinerOp\":\"save-block\",\"state\":{\"type\":\"submitted\"},\"encodedTx\":\"[[\\\"~:db/add\\\",\\\"hp-block\\\",\\\"~:block/uuid\\\",\\\"~u33333333-3333-4333-8333-333333333333\\\"]]\"}"
;;

let happy_accepted_record =
  "{\"mutationId\":\"33333333-3333-4333-8333-333333333333\",\"mutationPayload\":\"hp-mutation\",\"mutationFingerprint\":\"hp-fingerprint\",\"outlinerOp\":\"save-block\",\"state\":{\"type\":\"accepted\",\"serverT\":1},\"encodedTx\":\"[[\\\"~:db/add\\\",\\\"hp-block\\\",\\\"~:block/uuid\\\",\\\"~u33333333-3333-4333-8333-333333333333\\\"]]\"}"
;;

let happy_tx_message =
  Sync_protocol.Client.Tx_batch
    { client_revision = None
    ; t_before = 0
    ; txs =
        [ { tx = happy_encoded_tx
          ; tx_id = Some happy_mutation_id
          ; outliner_op = Some "save-block"
          }
        ]
    }
;;

let happy_opening_message =
  Sync_protocol.Server.Pull_ok { t = 0; checksum = Some "0000000000000000"; txs = [] }
;;

let happy_ack_message =
  Sync_protocol.Server.Tx_batch_ok { t = 1; checksum = Some "0000000000000000" }
;;

let happy_confirmation_message =
  Sync_protocol.Server.Pull_ok
    { t = 1
    ; checksum = Some "0000000000000000"
    ; txs = [ { t = 1; tx = happy_encoded_tx; outliner_op = Some "save-block" } ]
    }
;;

let happy_batch message : Core.authoritative_batch =
  { message
  ; scope = happy_connection_scope
  ; presentation_generation = 1
  ; lifecycle_generation = 0L
  }
;;

let happy_state
      ~sync_phase
      ~catalog
      ~selected_graph
      ~applied_server_t
      ~authenticated
      ~catalog_loading
      ~awaiting_selection
      ~bootstrapping
      ~account_generation
      ~graph_generation
      ~presentation_generation
      ~admitted_graph_scope
  =
  make_state_view
    ~sync_phase
    ~catalog
    ~selected_graph
    ~applied_server_t
    ~timeline_presentation_pending:true
    ~authenticated
    ~catalog_loading
    ~awaiting_selection
    ~restoring_local:false
    ~bootstrapping
    ~awaiting_e2ee_password:false
    ~failure:None
    ~account_generation
    ~graph_generation
    ~presentation_generation
    ~last_error:None
    ~diagnostic_groups:[]
    ~diagnostic_history:[]
    ~admitted_graph_scope
;;

let happy_catalog_loading_state =
  happy_state
    ~sync_phase:Core.Connecting
    ~catalog:[]
    ~selected_graph:None
    ~applied_server_t:None
    ~authenticated:true
    ~catalog_loading:true
    ~awaiting_selection:false
    ~bootstrapping:false
    ~account_generation:1
    ~graph_generation:1
    ~presentation_generation:1
    ~admitted_graph_scope:None
;;

let happy_catalog_state =
  happy_state
    ~sync_phase:Core.Offline
    ~catalog:[ happy_graph ]
    ~selected_graph:None
    ~applied_server_t:None
    ~authenticated:true
    ~catalog_loading:false
    ~awaiting_selection:true
    ~bootstrapping:false
    ~account_generation:1
    ~graph_generation:1
    ~presentation_generation:1
    ~admitted_graph_scope:None
;;

let happy_selected_state =
  happy_state
    ~sync_phase:Core.Offline
    ~catalog:[ happy_graph ]
    ~selected_graph:(Some happy_graph_id)
    ~applied_server_t:None
    ~authenticated:true
    ~catalog_loading:false
    ~awaiting_selection:false
    ~bootstrapping:true
    ~account_generation:1
    ~graph_generation:2
    ~presentation_generation:1
    ~admitted_graph_scope:(Some happy_graph_scope)
;;

let happy_sync_state sync_phase applied_server_t =
  happy_state
    ~sync_phase
    ~catalog:[ happy_graph ]
    ~selected_graph:(Some happy_graph_id)
    ~applied_server_t:(Some applied_server_t)
    ~authenticated:true
    ~catalog_loading:false
    ~awaiting_selection:false
    ~bootstrapping:false
    ~account_generation:1
    ~graph_generation:2
    ~presentation_generation:1
    ~admitted_graph_scope:(Some happy_graph_scope)
;;

let published_state view = Publish_state { view with admitted_graph_scope = None }
let static_instruction_view instruction = view_instruction instruction

let expected_runner_request ~id ~scope ~request_kind ~request_payload =
  Run_request
    { ticket_id = string_of_int id
    ; ticket_scope = effect_scope_json scope |> json_string
    ; request_kind
    ; request_payload = json_string request_payload
    }
;;

let check_happy_step id origin event expected_next expected_effects =
  let origin_before = view_state origin in
  let first =
    try Core.step origin event with
    | exn -> fail "%s raised %s" id (Printexc.to_string exn)
  in
  let actual_next = view_state first.next in
  if actual_next <> expected_next
  then
    fail
      "%s changed %s; expected %s but got %s"
      id
      (first_state_difference expected_next actual_next)
      (show_state_view expected_next)
      (show_state_view actual_next);
  let actual_effects = List.map view_instruction first.effects in
  if actual_effects <> expected_effects
  then fail "%s %s" id (first_effect_difference expected_effects actual_effects);
  let origin_after = view_state origin in
  if origin_after <> origin_before
  then
    fail
      "%s mutated its origin at %s"
      id
      (first_state_difference origin_before origin_after);
  let replay =
    try Core.step origin event with
    | exn -> fail "%s replay raised %s" id (Printexc.to_string exn)
  in
  let replay_next = view_state replay.next in
  let replay_effects = List.map view_instruction replay.effects in
  if replay_next <> actual_next
  then fail "%s replay changed %s" id (first_state_difference actual_next replay_next);
  if replay_effects <> actual_effects
  then fail "%s replay %s" id (first_effect_difference actual_effects replay_effects);
  first
;;

let extract_fetch_catalog_completion id effects (graphs : Core.graph list) : Core.event =
  List.find_map
    (function
      | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
        Some (Core.Runner_completed (Core.Completion (ticket, Ok graphs)))
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some completion -> completion
  | None -> fail "%s did not emit Fetch_catalog" id
;;

let extract_mirror_request id effects =
  List.find_map
    (function
      | Core.Delegate (Core.Inspect_mirror request) -> Some request
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some request -> request
  | None -> fail "%s did not emit Inspect_mirror" id
;;

let extract_attach_request id effects =
  List.find_map
    (function
      | Core.Delegate (Core.Attach_graph request) -> Some request
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some request -> request
  | None -> fail "%s did not emit Attach_graph" id
;;

let extract_websocket_connection id effects =
  List.find_map
    (function
      | Core.Run (Core.Start_websocket request) -> Some request.scope
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some scope -> scope
  | None -> fail "%s did not emit Start_websocket" id
;;

let extract_authoritative_batch id effects =
  List.find_map
    (function
      | Core.Delegate (Core.Inspect_authoritative_batch batch) -> Some batch
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some batch -> batch
  | None -> fail "%s did not emit Inspect_authoritative_batch" id
;;

let extract_authoritative_apply id effects =
  List.find_map
    (function
      | Core.Delegate (Core.Apply_authoritative_batch request) -> Some request
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some request -> request
  | None -> fail "%s did not emit Apply_authoritative_batch" id
;;

let extract_local_commit id effects =
  List.find_map
    (function
      | Core.Delegate (Core.Complete_local_batch request) ->
        (match request.action with
         | Core.Commit { outbox_records } -> Some (request, outbox_records)
         | Reject _ -> None)
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some commit -> commit
  | None -> fail "%s did not emit a committing Complete_local_batch" id
;;

let extract_outbox_transition id effects =
  List.find_map
    (function
      | Core.Delegate (Core.Commit_outbox_transition transition) -> Some transition
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some transition -> transition
  | None -> fail "%s did not emit Commit_outbox_transition" id
;;

let authoritative_result ?invalidation (request : Core.authoritative_commit_request) =
  Core.
    { scope = request.scope
    ; checkpoint = request.checkpoint
    ; outbox_records = request.outbox_records
    ; activity = request.activity
    ; invalidation
    }
;;

let test_pure_reducer_canonical_happy_path () =
  let expected_ids = List.init 20 (fun index -> Printf.sprintf "HP%02d" (index + 1)) in
  let actual_ids = List.map (fun rationale -> rationale.id) happy_path_rationales in
  Alcotest.(check (list string)) "canonical rationale IDs" expected_ids actual_ids;
  List.iter
    (fun rationale ->
       let fields =
         [ rationale.contract
         ; rationale.owner
         ; rationale.unchanged
         ; rationale.changes
         ; rationale.effects
         ]
       in
       Alcotest.check
         Alcotest.bool
         (rationale.id ^ " rationale fields are non-empty")
         true
         (List.for_all (fun value -> String.length value > 0) fields))
    happy_path_rationales;
  let hp01 =
    check_happy_step
      "HP01"
      (initial ())
      (Core.Account_authenticated { user_id = Some "user-1" })
      happy_catalog_loading_state
      [ published_state happy_catalog_loading_state
      ; Publish_token_request
          { token_request_id = "catalog-1"
          ; token_request_purpose = Core.Catalog_discovery
          }
      ]
  in
  let catalog_token = token_request hp01.effects in
  let authenticated_scope : Core.authenticated_account_scope =
    { account = happy_account_scope; token = "catalog-token" }
  in
  let hp02 =
    check_happy_step
      "HP02"
      hp01.next
      (Core.Token_provided (catalog_token, "catalog-token"))
      happy_catalog_loading_state
      [ expected_runner_request
          ~id:0
          ~scope:(Core.effect_scope_of_account happy_account_scope)
          ~request_kind:Fetch_catalog_request
          ~request_payload:(authenticated_account_scope_json authenticated_scope)
      ]
  in
  let catalog_completion =
    extract_fetch_catalog_completion "HP02" hp02.effects [ happy_graph ]
  in
  let expected_unselected_cache =
    Core.catalog_cache ~user_id:"user-1" ~graphs:[ happy_graph ] ~selected_graph:None
  in
  let hp03 =
    check_happy_step
      "HP03"
      hp02.next
      catalog_completion
      happy_catalog_state
      [ published_state happy_catalog_state
      ; expected_runner_request
          ~id:1
          ~scope:(Core.effect_scope_of_account happy_account_scope)
          ~request_kind:Save_catalog_request
          ~request_payload:
            (`Assoc
                [ "account", account_scope_json happy_account_scope
                ; "cache", catalog_cache_json expected_unselected_cache
                ])
      ]
  in
  let expected_selected_cache =
    Core.catalog_cache
      ~user_id:"user-1"
      ~graphs:[ happy_graph ]
      ~selected_graph:(Some happy_graph_id)
  in
  let hp04 =
    check_happy_step
      "HP04"
      hp03.next
      (Core.Graph_selected happy_graph_id)
      happy_selected_state
      [ static_instruction_view
          (Core.Delegate
             (Core.Inspect_mirror { graph = happy_graph; scope = happy_graph_scope }))
      ; published_state happy_selected_state
      ; expected_runner_request
          ~id:2
          ~scope:(Core.effect_scope_of_account happy_account_scope)
          ~request_kind:Save_catalog_request
          ~request_payload:
            (`Assoc
                [ "account", account_scope_json happy_account_scope
                ; "cache", catalog_cache_json expected_selected_cache
                ])
      ]
  in
  let mirror_request = extract_mirror_request "HP04" hp04.effects in
  let inspected_open_request : Core.graph_open_request =
    { happy_open_request with graph = mirror_request.graph; scope = mirror_request.scope }
  in
  let hp05 =
    check_happy_step
      "HP05"
      hp04.next
      (Core.Mirror_inspected (Core.Mirror_available inspected_open_request))
      happy_selected_state
      [ static_instruction_view (Core.Delegate (Core.Attach_graph happy_open_request)) ]
  in
  let attach_request = extract_attach_request "HP05" hp05.effects in
  let happy_connecting_state = happy_sync_state Core.Connecting 0 in
  let hp06 =
    check_happy_step
      "HP06"
      hp05.next
      (Core.Graph_attached
         { scope = attach_request.scope
         ; checkpoint = attach_request.checkpoint
         ; outbox_records = []
         })
      happy_connecting_state
      [ published_state happy_connecting_state
      ; Publish_token_request
          { token_request_id = "websocket-1-2"
          ; token_request_purpose = Core.Websocket_connect
          }
      ]
  in
  let websocket_token = token_request hp06.effects in
  let websocket_request : Core.websocket_request =
    { scope = happy_connection_scope
    ; uri = Uri.of_string "wss://api.logseq.io/sync/11111111-1111-4111-8111-111111111111"
    ; token = "websocket-token"
    }
  in
  let hp07 =
    check_happy_step
      "HP07"
      hp06.next
      (Core.Token_provided (websocket_token, "websocket-token"))
      happy_connecting_state
      [ static_instruction_view (Core.Run (Core.Start_websocket websocket_request)) ]
  in
  let connection = extract_websocket_connection "HP07" hp07.effects in
  let happy_pulling_state_0 = happy_sync_state Core.Pulling 0 in
  let hp08 =
    check_happy_step
      "HP08"
      hp07.next
      (Core.Websocket_opened connection)
      happy_pulling_state_0
      [ published_state happy_pulling_state_0
      ; static_instruction_view
          (Core.Run
             (Core.Send_websocket
                { scope = happy_connection_scope
                ; message = Sync_protocol.Client.Pull { since = Some 0 }
                }))
      ]
  in
  let opening_batch = happy_batch happy_opening_message in
  let hp09 =
    check_happy_step
      "HP09"
      hp08.next
      (Core.Websocket_message (connection, happy_opening_message))
      happy_pulling_state_0
      [ static_instruction_view
          (Core.Delegate (Core.Inspect_authoritative_batch opening_batch))
      ]
  in
  let inspected_opening_batch = extract_authoritative_batch "HP09" hp09.effects in
  let opening_context : Core.authoritative_context =
    { batch = inspected_opening_batch
    ; precondition = "hp-opening-precondition"
    ; checkpoint = happy_checkpoint_0
    ; database = Datascript.empty_db ()
    ; outbox_records = []
    }
  in
  let opening_apply : Core.authoritative_commit_request =
    { batch = opening_batch
    ; precondition = "hp-opening-precondition"
    ; scope = happy_graph_scope
    ; key = None
    ; transactions = []
    ; projection_transactions = []
    ; checkpoint = happy_checkpoint_0
    ; outbox_records = []
    ; activity = Logseq_db_types.Sync_status.Pull_duplicate
    }
  in
  let hp10 =
    check_happy_step
      "HP10"
      hp09.next
      (Core.Authoritative_batch_inspected opening_context)
      happy_pulling_state_0
      [ static_instruction_view
          (Core.Delegate (Core.Apply_authoritative_batch opening_apply))
      ]
  in
  let opening_apply_request = extract_authoritative_apply "HP10" hp10.effects in
  let happy_current_state_0 = happy_sync_state Core.Current 0 in
  let hp11 =
    check_happy_step
      "HP11"
      hp10.next
      (Core.Authoritative_batch_applied (authoritative_result opening_apply_request))
      happy_current_state_0
      [ published_state happy_current_state_0 ]
  in
  let local_input =
    Core.local_batch_input
      ~scope:happy_graph_scope
      ~admission_id:"hp-admission"
      ~key:None
      ~outbox_records:[]
      ~mutation_id:happy_mutation_id
      ~mutation_payload:"hp-mutation"
      ~mutation_fingerprint:"hp-fingerprint"
      ~outliner_op:"save-block"
      ~database:(Datascript.empty_db ())
      ~operations:[ happy_operation ]
    |> Result.get_ok
  in
  let local_commit_request : Core.local_batch_completion_request =
    { operation_id = happy_mutation_id
    ; admission_id = "hp-admission"
    ; scope = happy_graph_scope
    ; action = Core.Commit { outbox_records = [ happy_queued_record ] }
    }
  in
  let hp12 =
    check_happy_step
      "HP12"
      hp11.next
      (Core.Local_batch_prepared local_input)
      happy_current_state_0
      [ static_instruction_view
          (Core.Delegate (Core.Complete_local_batch local_commit_request))
      ]
  in
  let committed_local_request, committed_queued_outbox =
    extract_local_commit "HP12" hp12.effects
  in
  let expected_outbox_transition : Core.outbox_transition =
    { scope = happy_graph_scope
    ; presentation_generation = 1
    ; lifecycle_generation = 0L
    ; expected_outbox_records = [ happy_queued_record ]
    ; outbox_records = [ happy_submitted_record ]
    ; pending_message = Some happy_tx_message
    }
  in
  let hp13 =
    check_happy_step
      "HP13"
      hp12.next
      (Core.Local_batch_committed
         { scope = committed_local_request.scope
         ; outbox_records = committed_queued_outbox
         })
      happy_current_state_0
      [ static_instruction_view
          (Core.Delegate (Core.Commit_outbox_transition expected_outbox_transition))
      ]
  in
  let reserved_transition = extract_outbox_transition "HP13" hp13.effects in
  let happy_submitting_state = happy_sync_state Core.Submitting 0 in
  let hp14 =
    check_happy_step
      "HP14"
      hp13.next
      (Core.Outbox_transition_committed
         { scope = reserved_transition.scope
         ; outbox_records = reserved_transition.outbox_records
         ; pending_message = reserved_transition.pending_message
         })
      happy_submitting_state
      [ static_instruction_view
          (Core.Run
             (Core.Send_websocket
                { scope = happy_connection_scope; message = happy_tx_message }))
      ; published_state happy_submitting_state
      ]
  in
  let ack_batch = happy_batch happy_ack_message in
  let hp15 =
    check_happy_step
      "HP15"
      hp14.next
      (Core.Websocket_message (connection, happy_ack_message))
      happy_submitting_state
      [ static_instruction_view
          (Core.Delegate (Core.Inspect_authoritative_batch ack_batch))
      ]
  in
  let inspected_ack_batch = extract_authoritative_batch "HP15" hp15.effects in
  let ack_context : Core.authoritative_context =
    { batch = inspected_ack_batch
    ; precondition = "hp-ack-precondition"
    ; checkpoint = happy_checkpoint_0
    ; database = Datascript.empty_db ()
    ; outbox_records = [ happy_submitted_record ]
    }
  in
  let ack_apply : Core.authoritative_commit_request =
    { batch = ack_batch
    ; precondition = "hp-ack-precondition"
    ; scope = happy_graph_scope
    ; key = None
    ; transactions = []
    ; projection_transactions = []
    ; checkpoint = happy_checkpoint_0
    ; outbox_records = [ happy_accepted_record ]
    ; activity = Logseq_db_types.Sync_status.Pull_required
    }
  in
  let hp16 =
    check_happy_step
      "HP16"
      hp15.next
      (Core.Authoritative_batch_inspected ack_context)
      happy_submitting_state
      [ static_instruction_view (Core.Delegate (Core.Apply_authoritative_batch ack_apply))
      ]
  in
  let ack_apply_request = extract_authoritative_apply "HP16" hp16.effects in
  let hp17 =
    check_happy_step
      "HP17"
      hp16.next
      (Core.Authoritative_batch_applied (authoritative_result ack_apply_request))
      happy_pulling_state_0
      [ published_state happy_pulling_state_0
      ; static_instruction_view
          (Core.Run
             (Core.Send_websocket
                { scope = happy_connection_scope
                ; message = Sync_protocol.Client.Pull { since = Some 0 }
                }))
      ]
  in
  let confirmation_batch = happy_batch happy_confirmation_message in
  let hp18 =
    check_happy_step
      "HP18"
      hp17.next
      (Core.Websocket_message (connection, happy_confirmation_message))
      happy_pulling_state_0
      [ static_instruction_view
          (Core.Delegate (Core.Inspect_authoritative_batch confirmation_batch))
      ]
  in
  let inspected_confirmation_batch = extract_authoritative_batch "HP18" hp18.effects in
  let confirmation_context : Core.authoritative_context =
    { batch = inspected_confirmation_batch
    ; precondition = "hp-confirmation-precondition"
    ; checkpoint = happy_checkpoint_0
    ; database = Datascript.empty_db ()
    ; outbox_records = [ happy_accepted_record ]
    }
  in
  let confirmation_apply : Core.authoritative_commit_request =
    { batch = confirmation_batch
    ; precondition = "hp-confirmation-precondition"
    ; scope = happy_graph_scope
    ; key = None
    ; transactions = [ [ happy_operation ] ]
    ; projection_transactions = []
    ; checkpoint = happy_checkpoint_1
    ; outbox_records = []
    ; activity = Logseq_db_types.Sync_status.Pull_applied
    }
  in
  let hp19 =
    check_happy_step
      "HP19"
      hp18.next
      (Core.Authoritative_batch_inspected confirmation_context)
      happy_pulling_state_0
      [ static_instruction_view
          (Core.Delegate (Core.Apply_authoritative_batch confirmation_apply))
      ]
  in
  let confirmation_apply_request = extract_authoritative_apply "HP19" hp19.effects in
  let invalidation : Core.invalidation =
    { basis = 7L; changed_uuids = [ happy_mutation_id ]; changed_uuids_truncated = false }
  in
  let happy_current_state_1 = happy_sync_state Core.Current 1 in
  ignore
    (check_happy_step
       "HP20"
       hp19.next
       (Core.Authoritative_batch_applied
          (authoritative_result ~invalidation confirmation_apply_request))
       happy_current_state_1
       [ published_state happy_current_state_1; Publish_graph_invalidation invalidation ])
;;

let scenarios =
  [ Alcotest.test_case
      "configuration is bounded"
      `Quick
      test_config_validation_is_pure_and_bounded
  ; Alcotest.test_case
      "stale token events are rejected"
      `Quick
      test_stale_and_duplicate_token_events_are_rejected
  ; Alcotest.test_case
      "runner completion is one-shot"
      `Quick
      test_runner_completion_is_scoped_and_consumed_once
  ; Alcotest.test_case
      "local batch planning separates crypto"
      `Quick
      test_local_batch_planning_separates_crypto_from_policy
  ; Alcotest.test_case
      "post-admission planning failure is terminal"
      `Quick
      test_post_admission_planning_failure_emits_terminal_worker_effect
  ; Alcotest.test_case
      "post-admission encryption failure is terminal"
      `Quick
      test_post_admission_encryption_failure_emits_terminal_worker_effect
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
      "warm graph attachment defers WebSocket until Timeline"
      `Quick
      test_warm_graph_attachment_defers_websocket_until_timeline
  ; Alcotest.test_case
      "account replacement tears down the previous account first"
      `Quick
      test_account_replacement_cancels_and_detaches_before_new_catalog_work
  ; Alcotest.test_case
      "sign-out tears down the managed attachment"
      `Quick
      test_sign_out_cancels_and_detaches_the_managed_attachment
  ; Alcotest.test_case
      "auth before cache load waits for local Timeline"
      `Quick
      test_auth_before_cache_load_waits_for_local_timeline
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
      "authoritative pull accepts Transit list collection"
      `Quick
      test_authoritative_pull_accepts_transit_list_collection
  ; Alcotest.test_case
      "authoritative pull preserves Transit cache wire order"
      `Quick
      test_authoritative_pull_preserves_transit_cache_wire_order
  ; Alcotest.test_case
      "authoritative pull rejects invalid collection entries"
      `Quick
      test_authoritative_pull_rejects_empty_or_non_array_operations
  ; Alcotest.test_case
      "duplicate pull skips authoritative transaction bodies"
      `Quick
      test_duplicate_pull_skips_authoritative_transaction_bodies
  ; Alcotest.test_case
      "duplicate pull never replays stored transport transactions"
      `Quick
      test_duplicate_pull_never_replays_stored_transport_transactions
  ; Alcotest.test_case
      "duplicate pull rejects future transaction cursor"
      `Quick
      test_duplicate_pull_still_rejects_future_transaction_cursor
  ; Alcotest.test_case
      "typed WebSocket messages reach sync policy"
      `Quick
      test_typed_websocket_messages_reach_policy_without_raw_json
  ; Alcotest.test_case
      "submission owner is reserved before durable transition"
      `Quick
      test_submission_owner_is_reserved_before_durable_transition
  ; Alcotest.test_case
      "acknowledgement without owner is ignored"
      `Quick
      test_acknowledgement_without_submission_owner_is_ignored
  ; Alcotest.test_case
      "submission waits for durable outbox transition"
      `Quick
      test_submission_waits_for_durable_outbox_transition
  ; Alcotest.test_case
      "E2EE password stays out of core state"
      `Quick
      test_e2ee_recovery_keeps_password_out_of_core_state
  ; Alcotest.test_case
      "canonical pure reducer happy path"
      `Quick
      test_pure_reducer_canonical_happy_path
  ]
;;
