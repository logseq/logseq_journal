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

let queued_outbox_records () =
  let record =
    local_batch_input
      [ Datascript.Add
          ( Datascript.Temp_id "queued-duplicate"
          , "block/uuid"
          , Datascript.Uuid "33333333-3333-4333-8333-333333333333" )
      ]
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

let current_graph_with_outbox outbox_records =
  let opened, request, connection = opened_graph_with_outbox outbox_records in
  let current =
    Core.step
      opened.next
      (Authoritative_batch_applied
         { scope = request.scope
         ; checkpoint = request.checkpoint
         ; outbox_records
         ; activity = Logseq_db_types.Sync_status.Pull_duplicate
         ; invalidation = None
         })
  in
  current, request, connection
;;

let test_submission_owner_is_reserved_before_durable_transition () =
  let queued = queued_outbox_records () in
  let current, request, _ = current_graph_with_outbox [] in
  let first =
    Core.step
      current.next
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
  let current =
    Core.step
      opened.next
      (Authoritative_batch_applied
         { scope = open_request.scope
         ; checkpoint
         ; outbox_records = queued_records
         ; activity = Logseq_db_types.Sync_status.Pull_duplicate
         ; invalidation = None
         })
  in
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

type checkpoint =
  { name : string
  ; core : Core.t
  ; expected_view : state_view
  }

type event_case =
  { name : string
  ; event : Core.event
  ; event_constructor : string
  }

type transition_case =
  { origin : checkpoint
  ; event : event_case
  ; expected_next : state_view
  ; expected_effects : effect_view list
  }

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

let event_constructor_name : Core.event -> string = function
  | Restore_local_account _ -> "Restore_local_account"
  | Account_authenticated _ -> "Account_authenticated"
  | Local_feed_acknowledged -> "Local_feed_acknowledged"
  | Timeline_presented -> "Timeline_presented"
  | Token_provided _ -> "Token_provided"
  | Token_rejected _ -> "Token_rejected"
  | Graph_selected _ -> "Graph_selected"
  | Graph_picker_requested -> "Graph_picker_requested"
  | Catalog_refresh_requested -> "Catalog_refresh_requested"
  | Online_recovery_requested -> "Online_recovery_requested"
  | E2ee_password_submitted _ -> "E2ee_password_submitted"
  | Local_cache_deletion_requested _ -> "Local_cache_deletion_requested"
  | Foreground_changed _ -> "Foreground_changed"
  | Mirror_inspected _ -> "Mirror_inspected"
  | Graph_attached _ -> "Graph_attached"
  | Graph_attachment_failed _ -> "Graph_attachment_failed"
  | Local_batch_prepared _ -> "Local_batch_prepared"
  | Local_batch_committed _ -> "Local_batch_committed"
  | Authoritative_batch_inspected _ -> "Authoritative_batch_inspected"
  | Authoritative_batch_applied _ -> "Authoritative_batch_applied"
  | Authoritative_batch_conflicted _ -> "Authoritative_batch_conflicted"
  | Authoritative_batch_failed _ -> "Authoritative_batch_failed"
  | Outbox_transition_committed _ -> "Outbox_transition_committed"
  | Outbox_transition_rejected _ -> "Outbox_transition_rejected"
  | Snapshot_activated _ -> "Snapshot_activated"
  | Snapshot_activation_failed _ -> "Snapshot_activation_failed"
  | Runner_completed _ -> "Runner_completed"
  | Snapshot_download_progress _ -> "Snapshot_download_progress"
  | Websocket_opened _ -> "Websocket_opened"
  | Websocket_message _ -> "Websocket_message"
  | Websocket_protocol_error _ -> "Websocket_protocol_error"
  | Websocket_closed _ -> "Websocket_closed"
  | Timer_elapsed _ -> "Timer_elapsed"
  | Shutdown -> "Shutdown"
;;

let expected_event_constructor_names =
  [ "Restore_local_account"
  ; "Account_authenticated"
  ; "Local_feed_acknowledged"
  ; "Timeline_presented"
  ; "Token_provided"
  ; "Token_rejected"
  ; "Graph_selected"
  ; "Graph_picker_requested"
  ; "Catalog_refresh_requested"
  ; "Online_recovery_requested"
  ; "E2ee_password_submitted"
  ; "Local_cache_deletion_requested"
  ; "Foreground_changed"
  ; "Mirror_inspected"
  ; "Graph_attached"
  ; "Graph_attachment_failed"
  ; "Local_batch_prepared"
  ; "Local_batch_committed"
  ; "Authoritative_batch_inspected"
  ; "Authoritative_batch_applied"
  ; "Authoritative_batch_conflicted"
  ; "Authoritative_batch_failed"
  ; "Outbox_transition_committed"
  ; "Outbox_transition_rejected"
  ; "Snapshot_activated"
  ; "Snapshot_activation_failed"
  ; "Runner_completed"
  ; "Snapshot_download_progress"
  ; "Websocket_opened"
  ; "Websocket_message"
  ; "Websocket_protocol_error"
  ; "Websocket_closed"
  ; "Timer_elapsed"
  ; "Shutdown"
  ]
;;

let matrix_event variant event =
  let event_constructor = event_constructor_name event in
  { name = event_constructor ^ "/" ^ variant; event; event_constructor }
;;

let websocket_scope effects =
  List.find_map
    (function
      | Core.Run (Core.Start_websocket request) -> Some request.scope
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some scope -> scope
  | None -> fail "matrix fixture did not start a WebSocket"
;;

let catalog_failure_completion effects =
  List.find_map
    (function
      | Core.Run (Core.Request (ticket, Core.Fetch_catalog _)) ->
        Some
          (Core.Runner_completed
             (Core.Completion (ticket, Error (Core.Effect_failed "fixture failure"))))
      | Run _ | Delegate _ | Publish _ -> None)
    effects
  |> function
  | Some event -> event
  | None -> fail "matrix fixture did not request the remote catalog"
;;

let test_exact_pure_reducer_transition_cases () =
  let graph = graph () in
  let initial_core = initial () in
  let restoring =
    Core.step initial_core (Restore_local_account { user_id = "matrix-user" })
  in
  let authenticated =
    Core.step initial_core (Account_authenticated { user_id = Some "user-1" })
  in
  let catalog_token = token_request authenticated.effects in
  let catalog_loading =
    Core.step authenticated.next (Token_provided (catalog_token, "catalog-token"))
  in
  let catalog_completion = fetch_catalog_completion catalog_loading.effects [ graph ] in
  let catalog_ready = Core.step catalog_loading.next catalog_completion in
  let selected = Core.step catalog_ready.next (Graph_selected graph.graph_id) in
  let mirror = inspect_mirror_request selected.effects in
  let open_request = open_request graph mirror.scope "state-event-matrix" in
  let inspected =
    Core.step selected.next (Mirror_inspected (Mirror_available open_request))
  in
  let attached =
    Core.step
      inspected.next
      (Graph_attached
         { scope = open_request.scope
         ; checkpoint = open_request.checkpoint
         ; outbox_records = []
         })
  in
  let websocket_token = token_request attached.effects in
  let websocket_starting =
    Core.step attached.next (Token_provided (websocket_token, "websocket-token"))
  in
  let connection = websocket_scope websocket_starting.effects in
  let pulling = Core.step websocket_starting.next (Websocket_opened connection) in
  let authoritative_result activity : Core.authoritative_commit_result =
    { scope = open_request.scope
    ; checkpoint = open_request.checkpoint
    ; outbox_records = []
    ; activity
    ; invalidation = None
    }
  in
  let current =
    Core.step
      pulling.next
      (Authoritative_batch_applied
         (authoritative_result Logseq_db_types.Sync_status.Pull_duplicate))
  in
  let paused =
    Core.step
      pulling.next
      (Authoritative_batch_applied
         (authoritative_result Logseq_db_types.Sync_status.Sync_paused))
  in
  let failed = Core.step authenticated.next (Token_rejected catalog_token) in
  let queued = queued_outbox_records () in
  let submission_reserved =
    Core.step
      current.next
      (Local_batch_committed { scope = open_request.scope; outbox_records = queued })
  in
  let outbox_transition =
    List.find_map
      (function
        | Core.Delegate (Core.Commit_outbox_transition transition) -> Some transition
        | Run _ | Delegate _ | Publish _ -> None)
      submission_reserved.effects
    |> function
    | Some transition -> transition
    | None -> fail "matrix fixture did not reserve an outbox transition"
  in
  let submitting =
    Core.step
      submission_reserved.next
      (Outbox_transition_committed
         { scope = outbox_transition.scope
         ; outbox_records = outbox_transition.outbox_records
         ; pending_message = outbox_transition.pending_message
         })
  in
  let backgrounded =
    Core.step
      current.next
      (Foreground_changed { foreground = false; lifecycle_generation = 1L })
  in
  let closed = Core.step current.next Shutdown in
  let stale_authenticated =
    Core.step authenticated.next (Account_authenticated { user_id = Some "stale-user" })
  in
  let stale_token = token_request stale_authenticated.effects in
  let stale_scope =
    { open_request.scope with graph_generation = open_request.scope.graph_generation + 1 }
  in
  let stale_connection = { connection with graph = stale_scope } in
  let current_error : Core.scoped_error =
    { scope = Core.effect_scope_of_graph open_request.scope; message = "current failure" }
  in
  let stale_error : Core.scoped_error =
    { scope = Core.effect_scope_of_graph stale_scope; message = "stale failure" }
  in
  let authoritative_batch scope : Core.authoritative_batch =
    { message = Sync_protocol.Server.Changed { t = 1 }
    ; scope
    ; presentation_generation = scope.graph.account.presentation_generation
    ; lifecycle_generation = scope.graph.account.lifecycle_generation
    }
  in
  let authoritative_context scope : Core.authoritative_context =
    { batch = authoritative_batch scope
    ; precondition = "matrix-precondition"
    ; checkpoint = checkpoint scope.graph.graph_id
    ; database = Datascript.empty_db ()
    ; outbox_records = []
    }
  in
  let local_input scope = local_batch_input ~scope [] in
  let codec_error : Sync_protocol.codec_error =
    { direction = Sync_protocol.Server
    ; message_type = Some "matrix"
    ; path = []
    ; kind = Sync_protocol.Invalid_json
    }
  in
  let expected_state_000 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:0
      ~graph_generation:0
      ~presentation_generation:0
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_001 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:true
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_002 =
    make_state_view
      ~sync_phase:Core.Connecting
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_003 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:true
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_004 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_005 =
    make_state_view
      ~sync_phase:Core.Connecting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_006 =
    make_state_view
      ~sync_phase:Core.Pulling
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_007 =
    make_state_view
      ~sync_phase:Core.Current
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_008 =
    make_state_view
      ~sync_phase:Core.Submitting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_009 =
    make_state_view
      ~sync_phase:Core.Paused
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_010 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_authentication)
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:(Some "authentication token was rejected")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_011 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_012 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_013 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:false
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:0
      ~graph_generation:0
      ~presentation_generation:0
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_014 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:0
      ~graph_generation:0
      ~presentation_generation:0
      ~last_error:(Some "E2EE password must be bounded non-empty UTF-8 text")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_015 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:true
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:2
      ~graph_generation:2
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_016 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:true
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_017 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:2
      ~graph_generation:2
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_018 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:false
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:true
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_019 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:true
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_020 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:true
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_021 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:(Some "E2EE password must be bounded non-empty UTF-8 text")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_022 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:(Some "fixture failure")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_023 =
    make_state_view
      ~sync_phase:Core.Connecting
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:2
      ~graph_generation:2
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_024 =
    make_state_view
      ~sync_phase:Core.Connecting
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_025 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:true
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_026 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:(Some "E2EE password must be bounded non-empty UTF-8 text")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_027 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:(Some "fixture failure")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_028 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:true
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_029 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_030 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:true
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_031 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:true
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_032 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:true
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:(Some "E2EE password must be bounded non-empty UTF-8 text")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_033 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:true
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:2
      ~graph_generation:3
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_034 =
    make_state_view
      ~sync_phase:Core.Connecting
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:2
      ~graph_generation:3
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_035 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:false
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:2
      ~graph_generation:3
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_036 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_037 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_038 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:3
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 3
             })
  in
  let expected_state_039 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:3
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_040 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:true
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:3
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_041 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_042 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_043 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "E2EE password must be bounded non-empty UTF-8 text")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_044 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "E2EE password must be bounded non-empty UTF-8 text")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_045 =
    make_state_view
      ~sync_phase:Core.Connecting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_046 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "current failure")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_047 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "current failure")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_048 =
    make_state_view
      ~sync_phase:Core.Current
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_049 =
    make_state_view
      ~sync_phase:Core.Current
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_050 =
    make_state_view
      ~sync_phase:Core.Connecting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_051 =
    make_state_view
      ~sync_phase:Core.Connecting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_052 =
    make_state_view
      ~sync_phase:Core.Connecting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_053 =
    make_state_view
      ~sync_phase:Core.Connecting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_054 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "E2EE password must be bounded non-empty UTF-8 text")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_055 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "E2EE password must be bounded non-empty UTF-8 text")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_056 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_057 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "current failure")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_058 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "current failure")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_059 =
    make_state_view
      ~sync_phase:Core.Current
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_060 =
    make_state_view
      ~sync_phase:Core.Pulling
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_061 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "server sync protocol matrix at $: invalid JSON")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_062 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_catalog)
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "server sync protocol matrix at $: invalid JSON")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_063 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "closed")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_064 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:(Some "closed")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_065 =
    make_state_view
      ~sync_phase:Core.Pulling
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_066 =
    make_state_view
      ~sync_phase:Core.Pulling
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_067 =
    make_state_view
      ~sync_phase:Core.Pulling
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_068 =
    make_state_view
      ~sync_phase:Core.Pulling
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_069 =
    make_state_view
      ~sync_phase:Core.Current
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_070 =
    make_state_view
      ~sync_phase:Core.Current
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_071 =
    make_state_view
      ~sync_phase:Core.Current
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_072 =
    make_state_view
      ~sync_phase:Core.Current
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_073 =
    make_state_view
      ~sync_phase:Core.Submitting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_074 =
    make_state_view
      ~sync_phase:Core.Submitting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_075 =
    make_state_view
      ~sync_phase:Core.Submitting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_076 =
    make_state_view
      ~sync_phase:Core.Submitting
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_077 =
    make_state_view
      ~sync_phase:Core.Paused
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_078 =
    make_state_view
      ~sync_phase:Core.Paused
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_079 =
    make_state_view
      ~sync_phase:Core.Paused
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_080 =
    make_state_view
      ~sync_phase:Core.Paused
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_081 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:(Some Core.During_authentication)
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:(Some "authentication token was rejected")
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_082 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:true
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:2
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_083 =
    make_state_view
      ~sync_phase:Core.Failed
      ~catalog:[]
      ~selected_graph:None
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:1
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_084 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_085 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:false
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_state_086 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:None
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:false
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:true
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:3
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 1L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 3
             })
  in
  let expected_state_087 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:
        (Some
           Core.
             { account =
                 Core.
                   { managed_sync_origin = Uri.of_string "https://api.logseq.io"
                   ; user_id = "user-1"
                   ; account_generation = 1
                   ; presentation_generation = 1
                   ; lifecycle_generation = 0L
                   }
             ; graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
             ; graph_generation = 2
             })
  in
  let expected_state_088 =
    make_state_view
      ~sync_phase:Core.Offline
      ~catalog:[ graph ]
      ~selected_graph:(Some (static_uuid "11111111-1111-4111-8111-111111111111"))
      ~applied_server_t:(Some 0)
      ~timeline_presentation_pending:true
      ~authenticated:true
      ~catalog_loading:true
      ~awaiting_selection:false
      ~restoring_local:false
      ~bootstrapping:false
      ~awaiting_e2ee_password:false
      ~failure:None
      ~account_generation:1
      ~graph_generation:2
      ~presentation_generation:1
      ~last_error:None
      ~diagnostic_groups:[]
      ~diagnostic_history:[]
      ~admitted_graph_scope:None
  in
  let expected_effects_000 =
    [ Publish_state expected_state_001
    ; Run_request
        { ticket_id = "0"
        ; ticket_scope =
            "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        ; request_kind = Load_catalog_request
        ; request_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"matrix-user\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        }
    ]
  in
  let expected_effects_001 =
    [ Publish_state expected_state_002
    ; Publish_token_request
        { token_request_id = "catalog-1"; token_request_purpose = Core.Catalog_discovery }
    ]
  in
  let expected_effects_002 = [ Publish_state expected_state_012 ] in
  let expected_effects_003 = [] in
  let expected_effects_004 = [ Publish_state expected_state_013 ] in
  let expected_effects_005 = [ Publish_state expected_state_014 ] in
  let expected_effects_006 =
    [ Delegate
        { worker_effect_kind = Delete_mirror_effect
        ; worker_effect_payload =
            "{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"scope\":{\"account_generation\":null,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":null,\"lifecycle_generation\":null}}"
        }
    ]
  in
  let expected_effects_007 =
    [ Delegate
        { worker_effect_kind = Delete_mirror_effect
        ; worker_effect_payload =
            "{\"graph_id\":\"99999999-9999-4999-8999-999999999999\",\"scope\":{\"account_generation\":null,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":null,\"lifecycle_generation\":null}}"
        }
    ]
  in
  let expected_effects_008 =
    [ Delegate
        { worker_effect_kind = Complete_local_batch_effect
        ; worker_effect_payload =
            "{\"operation_id\":\"11111111-1111-4111-8111-111111111111\",\"admission_id\":\"test-admission\",\"scope\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2},\"action\":{\"reject\":{\"kind\":\"scope_closed\",\"message\":\"managed \
             graph scope is closed\"}}}"
        }
    ]
  in
  let expected_effects_009 =
    [ Delegate
        { worker_effect_kind = Complete_local_batch_effect
        ; worker_effect_payload =
            "{\"operation_id\":\"11111111-1111-4111-8111-111111111111\",\"admission_id\":\"test-admission\",\"scope\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":3},\"action\":{\"reject\":{\"kind\":\"scope_closed\",\"message\":\"managed \
             graph scope is closed\"}}}"
        }
    ]
  in
  let expected_effects_010 =
    [ Publish_bootstrap_progress
        Core.
          { graph_id = static_uuid "11111111-1111-4111-8111-111111111111"
          ; received_bytes = 1L
          ; total_bytes = Some 2L
          }
    ]
  in
  let expected_effects_011 =
    [ Cancel_effects
        "{\"account_generation\":null,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":null,\"lifecycle_generation\":null}"
    ]
  in
  let expected_effects_012 =
    [ Publish_state expected_state_015
    ; Run_request
        { ticket_id = "1"
        ; ticket_scope =
            "{\"account_generation\":2,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":2,\"lifecycle_generation\":\"0\"}"
        ; request_kind = Load_catalog_request
        ; request_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"matrix-user\",\"account_generation\":2,\"presentation_generation\":2,\"lifecycle_generation\":\"0\"}"
        }
    ]
  in
  let expected_effects_013 = [ Publish_state expected_state_016 ] in
  let expected_effects_014 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
    ; Delegate
        { worker_effect_kind = Reset_managed_account_effect
        ; worker_effect_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"matrix-user\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        }
    ; Publish_state expected_state_017
    ]
  in
  let expected_effects_015 = [ Publish_state expected_state_018 ] in
  let expected_effects_016 = [ Publish_state expected_state_019 ] in
  let expected_effects_017 =
    [ Publish_state expected_state_020
    ; Publish_token_request
        { token_request_id = "catalog-1-1"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_018 = [ Publish_state expected_state_021 ] in
  let expected_effects_019 =
    [ Delegate
        { worker_effect_kind = Delete_mirror_effect
        ; worker_effect_payload =
            "{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"scope\":{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}}"
        }
    ]
  in
  let expected_effects_020 =
    [ Delegate
        { worker_effect_kind = Delete_mirror_effect
        ; worker_effect_payload =
            "{\"graph_id\":\"99999999-9999-4999-8999-999999999999\",\"scope\":{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}}"
        }
    ]
  in
  let expected_effects_021 = [ Publish_state expected_state_022 ] in
  let expected_effects_022 =
    [ Cancel_effects
        "{\"account_generation\":null,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":null,\"lifecycle_generation\":null}"
    ; Delegate
        { worker_effect_kind = Reset_managed_account_effect
        ; worker_effect_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"matrix-user\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        }
    ]
  in
  let expected_effects_023 =
    [ Publish_state expected_state_015
    ; Run_request
        { ticket_id = "0"
        ; ticket_scope =
            "{\"account_generation\":2,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":2,\"lifecycle_generation\":\"0\"}"
        ; request_kind = Load_catalog_request
        ; request_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"matrix-user\",\"account_generation\":2,\"presentation_generation\":2,\"lifecycle_generation\":\"0\"}"
        }
    ]
  in
  let expected_effects_024 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
    ; Delegate
        { worker_effect_kind = Reset_managed_account_effect
        ; worker_effect_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        }
    ; Publish_state expected_state_023
    ; Publish_token_request
        { token_request_id = "catalog-2"; token_request_purpose = Core.Catalog_discovery }
    ]
  in
  let expected_effects_025 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
    ; Delegate
        { worker_effect_kind = Reset_managed_account_effect
        ; worker_effect_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        }
    ; Publish_state expected_state_017
    ]
  in
  let expected_effects_026 = [ Publish_state expected_state_024 ] in
  let expected_effects_027 =
    [ Run_request
        { ticket_id = "0"
        ; ticket_scope =
            "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        ; request_kind = Fetch_catalog_request
        ; request_payload =
            "{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"token\":{\"length\":5,\"digest\":\"94a08da1fecbb6e8b46990538c7b50b2\"}}"
        }
    ]
  in
  let expected_effects_028 = [ Publish_state expected_state_010 ] in
  let expected_effects_029 = [ Publish_state expected_state_025 ] in
  let expected_effects_030 =
    [ Publish_state expected_state_002
    ; Publish_token_request
        { token_request_id = "catalog-1-0"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_031 = [ Publish_state expected_state_026 ] in
  let expected_effects_032 =
    [ Cancel_effects
        "{\"account_generation\":null,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":null,\"lifecycle_generation\":null}"
    ; Delegate
        { worker_effect_kind = Reset_managed_account_effect
        ; worker_effect_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        }
    ]
  in
  let expected_effects_033 =
    [ Publish_state expected_state_002
    ; Publish_token_request
        { token_request_id = "catalog-1-1"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_034 =
    [ Publish_state expected_state_003
    ; Run_request
        { ticket_id = "1"
        ; ticket_scope =
            "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        ; request_kind = Save_catalog_request
        ; request_payload =
            "{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"cache\":{\"user_id\":\"user-1\",\"graphs\":[{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"Journal\",\"schema\":{\"major\":1,\"minor\":0,\"exact\":true},\"encrypted\":false}],\"selected_graph\":null}}"
        }
    ]
  in
  let expected_effects_035 = [ Publish_state expected_state_027 ] in
  let expected_effects_036 =
    [ Publish_state expected_state_015
    ; Run_request
        { ticket_id = "2"
        ; ticket_scope =
            "{\"account_generation\":2,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":2,\"lifecycle_generation\":\"0\"}"
        ; request_kind = Load_catalog_request
        ; request_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"matrix-user\",\"account_generation\":2,\"presentation_generation\":2,\"lifecycle_generation\":\"0\"}"
        }
    ]
  in
  let expected_effects_037 = [ Publish_state expected_state_028 ] in
  let expected_effects_038 =
    [ Delegate
        { worker_effect_kind = Inspect_mirror_effect
        ; worker_effect_payload =
            "{\"graph\":{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"Journal\",\"schema\":{\"major\":1,\"minor\":0,\"exact\":true},\"encrypted\":false},\"scope\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2}}"
        }
    ; Publish_state expected_state_029
    ; Run_request
        { ticket_id = "2"
        ; ticket_scope =
            "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        ; request_kind = Save_catalog_request
        ; request_payload =
            "{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"cache\":{\"user_id\":\"user-1\",\"graphs\":[{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"Journal\",\"schema\":{\"major\":1,\"minor\":0,\"exact\":true},\"encrypted\":false}],\"selected_graph\":\"11111111-1111-4111-8111-111111111111\"}}"
        }
    ]
  in
  let expected_effects_039 = [ Publish_state expected_state_030 ] in
  let expected_effects_040 =
    [ Publish_state expected_state_031
    ; Publish_token_request
        { token_request_id = "catalog-1-2"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_041 = [ Publish_state expected_state_032 ] in
  let expected_effects_042 =
    [ Publish_state expected_state_033
    ; Run_request
        { ticket_id = "3"
        ; ticket_scope =
            "{\"account_generation\":2,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":2,\"lifecycle_generation\":\"0\"}"
        ; request_kind = Load_catalog_request
        ; request_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"matrix-user\",\"account_generation\":2,\"presentation_generation\":2,\"lifecycle_generation\":\"0\"}"
        }
    ]
  in
  let expected_effects_043 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
    ; Delegate
        { worker_effect_kind = Reset_managed_account_effect
        ; worker_effect_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        }
    ; Publish_state expected_state_034
    ; Publish_token_request
        { token_request_id = "catalog-2"; token_request_purpose = Core.Catalog_discovery }
    ]
  in
  let expected_effects_044 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
    ; Delegate
        { worker_effect_kind = Reset_managed_account_effect
        ; worker_effect_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        }
    ; Publish_state expected_state_035
    ]
  in
  let expected_effects_045 = [ Publish_state expected_state_037 ] in
  let expected_effects_046 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":2,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
    ; Delegate
        { worker_effect_kind = Detach_graph_effect
        ; worker_effect_payload =
            "{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2}"
        }
    ; Delegate
        { worker_effect_kind = Inspect_mirror_effect
        ; worker_effect_payload =
            "{\"graph\":{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"Journal\",\"schema\":{\"major\":1,\"minor\":0,\"exact\":true},\"encrypted\":false},\"scope\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":3}}"
        }
    ; Publish_state expected_state_039
    ; Run_request
        { ticket_id = "3"
        ; ticket_scope =
            "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
        ; request_kind = Save_catalog_request
        ; request_payload =
            "{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"cache\":{\"user_id\":\"user-1\",\"graphs\":[{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"Journal\",\"schema\":{\"major\":1,\"minor\":0,\"exact\":true},\"encrypted\":false}],\"selected_graph\":\"11111111-1111-4111-8111-111111111111\"}}"
        }
    ]
  in
  let expected_effects_047 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":2,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
    ; Delegate
        { worker_effect_kind = Detach_graph_effect
        ; worker_effect_payload =
            "{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2}"
        }
    ; Publish_state expected_state_040
    ]
  in
  let expected_effects_048 =
    [ Publish_state expected_state_042
    ; Publish_token_request
        { token_request_id = "catalog-1-3"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_049 =
    [ Publish_token_request
        { token_request_id = "snapshot-1-2"
        ; token_request_purpose = Core.Snapshot_bootstrap
        }
    ]
  in
  let expected_effects_050 = [ Publish_state expected_state_044 ] in
  let expected_effects_051 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":2,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
    ; Delegate
        { worker_effect_kind = Detach_graph_effect
        ; worker_effect_payload =
            "{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2}"
        }
    ; Delegate
        { worker_effect_kind = Delete_mirror_effect
        ; worker_effect_payload =
            "{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"scope\":{\"account_generation\":1,\"graph_generation\":2,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}}"
        }
    ; Publish_state expected_state_039
    ; Publish_token_request
        { token_request_id = "snapshot-1-3"
        ; token_request_purpose = Core.Snapshot_bootstrap
        }
    ]
  in
  let expected_effects_052 =
    [ Delegate
        { worker_effect_kind = Delete_mirror_effect
        ; worker_effect_payload =
            "{\"graph_id\":\"99999999-9999-4999-8999-999999999999\",\"scope\":{\"account_generation\":1,\"graph_generation\":2,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}}"
        }
    ]
  in
  let expected_effects_053 =
    [ Close_websocket
        "{\"graph\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2},\"connection_generation\":0}"
    ; Publish_state expected_state_029
    ]
  in
  let expected_effects_054 =
    [ Delegate
        { worker_effect_kind = Attach_graph_effect
        ; worker_effect_payload =
            "{\"graph\":{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"Journal\",\"schema\":{\"major\":1,\"minor\":0,\"exact\":true},\"encrypted\":false},\"graph_directory\":\"/worker/state-event-matrix\",\"database_path\":\"/worker/state-event-matrix/db.sqlite\",\"checkpoint\":{\"format_version\":2,\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"schema\":{\"major\":1,\"minor\":0},\"applied_server_t\":0,\"checksum\":\"0000000000000000\",\"status\":\"active\",\"last_error\":null},\"scope\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2}}"
        }
    ]
  in
  let expected_effects_055 =
    [ Publish_state expected_state_045
    ; Publish_token_request
        { token_request_id = "websocket-1-2"
        ; token_request_purpose = Core.Websocket_connect
        }
    ]
  in
  let expected_effects_056 = [ Publish_state expected_state_047 ] in
  let expected_effects_057 =
    [ Delegate
        { worker_effect_kind = Complete_local_batch_effect
        ; worker_effect_payload =
            "{\"operation_id\":\"11111111-1111-4111-8111-111111111111\",\"admission_id\":\"test-admission\",\"scope\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2},\"action\":{\"commit\":[{\"mutation_id\":\"11111111-1111-4111-8111-111111111111\",\"fingerprint\":\"fingerprint\",\"mutation_payload\":{\"length\":8,\"digest\":\"32a228ed0a1940b82b13321edb86288f\"},\"outliner_op\":\"save-block\",\"state\":\"queued\",\"encoded_record\":{\"length\":187,\"digest\":\"49fd74565f910221a24b6ca1d37e783d\"}}]}}"
        }
    ]
  in
  let expected_effects_058 = [ Publish_state expected_state_049 ] in
  let expected_effects_059 =
    [ Delegate
        { worker_effect_kind = Inspect_mirror_effect
        ; worker_effect_payload =
            "{\"graph\":{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"Journal\",\"schema\":{\"major\":1,\"minor\":0,\"exact\":true},\"encrypted\":false},\"scope\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2}}"
        }
    ]
  in
  let expected_effects_060 = [ Publish_state expected_state_051 ] in
  let expected_effects_061 =
    [ Publish_state expected_state_053
    ; Publish_token_request
        { token_request_id = "catalog-1-3"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_062 = [ Publish_state expected_state_055 ] in
  let expected_effects_063 =
    [ Close_websocket
        "{\"graph\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2},\"connection_generation\":0}"
    ; Publish_state expected_state_056
    ]
  in
  let expected_effects_064 =
    [ Publish_token_request
        { token_request_id = "websocket-1-2"
        ; token_request_purpose = Core.Websocket_connect
        }
    ]
  in
  let expected_effects_065 = [ Publish_state expected_state_058 ] in
  let expected_effects_066 = [ Publish_state expected_state_059 ] in
  let expected_effects_067 =
    [ Publish_state expected_state_051
    ; Publish_token_request
        { token_request_id = "websocket-1-2"
        ; token_request_purpose = Core.Websocket_connect
        }
    ]
  in
  let expected_effects_068 =
    [ Close_websocket
        "{\"graph\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2},\"connection_generation\":1}"
    ; Publish_state expected_state_056
    ]
  in
  let expected_effects_069 =
    [ Delegate
        { worker_effect_kind = Apply_authoritative_batch_effect
        ; worker_effect_payload =
            "{\"batch\":{\"message\":{\"type\":\"changed\",\"t\":1},\"scope\":{\"graph\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2},\"connection_generation\":1},\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"precondition\":\"matrix-precondition\",\"scope\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2},\"key\":null,\"transactions\":[],\"projection_transactions\":[],\"checkpoint\":{\"format_version\":2,\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"schema\":{\"major\":1,\"minor\":0},\"applied_server_t\":0,\"checksum\":\"0000000000000000\",\"status\":\"active\",\"last_error\":null},\"outbox_records\":[],\"activity\":\"pull_required\"}"
        }
    ]
  in
  let expected_effects_070 =
    [ Publish_state expected_state_060
    ; Send_websocket
        { websocket_send_scope =
            "{\"graph\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2},\"connection_generation\":1}"
        ; websocket_message = "{\"type\":\"pull\",\"since\":0}"
        }
    ]
  in
  let expected_effects_071 = [ Publish_state expected_state_062 ] in
  let expected_effects_072 = [ Publish_state expected_state_064 ] in
  let expected_effects_073 = [ Publish_state expected_state_066 ] in
  let expected_effects_074 =
    [ Publish_state expected_state_068
    ; Publish_token_request
        { token_request_id = "catalog-1-3"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_075 = [ Publish_state expected_state_070 ] in
  let expected_effects_076 =
    [ Publish_state expected_state_072
    ; Publish_token_request
        { token_request_id = "catalog-1-3"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_077 = [ Publish_state expected_state_074 ] in
  let expected_effects_078 =
    [ Publish_state expected_state_076
    ; Publish_token_request
        { token_request_id = "catalog-1-3"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_079 = [ Publish_state expected_state_078 ] in
  let expected_effects_080 =
    [ Publish_state expected_state_080
    ; Publish_token_request
        { token_request_id = "catalog-1-3"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_081 = [ Publish_state expected_state_081 ] in
  let expected_effects_082 = [ Publish_state expected_state_082 ] in
  let expected_effects_083 =
    [ Publish_state expected_state_083
    ; Publish_token_request
        { token_request_id = "catalog-1-0"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_084 =
    [ Publish_state expected_state_033
    ; Run_request
        { ticket_id = "3"
        ; ticket_scope =
            "{\"account_generation\":2,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":2,\"lifecycle_generation\":\"1\"}"
        ; request_kind = Load_catalog_request
        ; request_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"matrix-user\",\"account_generation\":2,\"presentation_generation\":2,\"lifecycle_generation\":\"1\"}"
        }
    ]
  in
  let expected_effects_085 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"1\"}"
    ; Delegate
        { worker_effect_kind = Reset_managed_account_effect
        ; worker_effect_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"1\"}"
        }
    ; Publish_state expected_state_034
    ; Publish_token_request
        { token_request_id = "catalog-2"; token_request_purpose = Core.Catalog_discovery }
    ]
  in
  let expected_effects_086 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"1\"}"
    ; Delegate
        { worker_effect_kind = Reset_managed_account_effect
        ; worker_effect_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"1\"}"
        }
    ; Publish_state expected_state_035
    ]
  in
  let expected_effects_087 =
    [ Publish_state expected_state_085
    ; Publish_token_request
        { token_request_id = "websocket-1-2"
        ; token_request_purpose = Core.Websocket_connect
        }
    ]
  in
  let expected_effects_088 =
    [ Cancel_effects
        "{\"account_generation\":1,\"graph_generation\":2,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"}"
    ; Delegate
        { worker_effect_kind = Detach_graph_effect
        ; worker_effect_payload =
            "{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"0\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":2}"
        }
    ; Delegate
        { worker_effect_kind = Inspect_mirror_effect
        ; worker_effect_payload =
            "{\"graph\":{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"Journal\",\"schema\":{\"major\":1,\"minor\":0,\"exact\":true},\"encrypted\":false},\"scope\":{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"1\"},\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"graph_generation\":3}}"
        }
    ; Publish_state expected_state_039
    ; Run_request
        { ticket_id = "3"
        ; ticket_scope =
            "{\"account_generation\":1,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":1,\"lifecycle_generation\":\"1\"}"
        ; request_kind = Save_catalog_request
        ; request_payload =
            "{\"account\":{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"1\"},\"cache\":{\"user_id\":\"user-1\",\"graphs\":[{\"graph_id\":\"11111111-1111-4111-8111-111111111111\",\"name\":\"Journal\",\"schema\":{\"major\":1,\"minor\":0,\"exact\":true},\"encrypted\":false}],\"selected_graph\":\"11111111-1111-4111-8111-111111111111\"}}"
        }
    ]
  in
  let expected_effects_089 =
    [ Publish_state expected_state_088
    ; Publish_token_request
        { token_request_id = "catalog-1-3"
        ; token_request_purpose = Core.Catalog_discovery
        }
    ]
  in
  let expected_effects_090 =
    [ Cancel_effects
        "{\"account_generation\":null,\"graph_generation\":null,\"connection_generation\":null,\"presentation_generation\":null,\"lifecycle_generation\":null}"
    ; Delegate
        { worker_effect_kind = Reset_managed_account_effect
        ; worker_effect_payload =
            "{\"managed_sync_origin\":\"https://api.logseq.io\",\"user_id\":\"user-1\",\"account_generation\":1,\"presentation_generation\":1,\"lifecycle_generation\":\"1\"}"
        }
    ]
  in
  let checkpoints =
    [ "initial/offline", initial_core, expected_state_000
    ; "local-restore/loading", restoring.next, expected_state_001
    ; "authentication/token-pending", authenticated.next, expected_state_002
    ; "catalog/request-pending", catalog_loading.next, expected_state_002
    ; "catalog/awaiting-selection", catalog_ready.next, expected_state_003
    ; "graph/selected", selected.next, expected_state_004
    ; "graph/attachment-pending", inspected.next, expected_state_004
    ; "websocket/token-pending", attached.next, expected_state_005
    ; "websocket/starting", websocket_starting.next, expected_state_005
    ; "sync/pulling", pulling.next, expected_state_006
    ; "sync/current", current.next, expected_state_007
    ; "sync/submission-reserved", submission_reserved.next, expected_state_007
    ; "sync/submitting", submitting.next, expected_state_008
    ; "sync/paused", paused.next, expected_state_009
    ; "sync/failed", failed.next, expected_state_010
    ; "lifecycle/backgrounded", backgrounded.next, expected_state_011
    ; "lifecycle/closed", closed.next, expected_state_007
    ]
    |> List.map (fun (name, core, expected_view) -> { name; core; expected_view })
  in
  let events =
    [ matrix_event "valid" (Restore_local_account { user_id = "matrix-user" })
    ; matrix_event "sign-in" (Account_authenticated { user_id = Some "matrix-user" })
    ; matrix_event "sign-out" (Account_authenticated { user_id = None })
    ; matrix_event "acknowledged" Local_feed_acknowledged
    ; matrix_event "presented" Timeline_presented
    ; matrix_event "current" (Token_provided (catalog_token, "token"))
    ; matrix_event "stale" (Token_provided (stale_token, "token"))
    ; matrix_event "current" (Token_rejected catalog_token)
    ; matrix_event "stale" (Token_rejected stale_token)
    ; matrix_event "catalog-member" (Graph_selected graph.graph_id)
    ; matrix_event "unknown" (Graph_selected (other_graph_id ()))
    ; matrix_event "requested" Graph_picker_requested
    ; matrix_event "requested" Catalog_refresh_requested
    ; matrix_event "requested" Online_recovery_requested
    ; matrix_event "valid" (E2ee_password_submitted "matrix-password")
    ; matrix_event "invalid-empty" (E2ee_password_submitted "")
    ; matrix_event "current" (Local_cache_deletion_requested graph.graph_id)
    ; matrix_event "unknown" (Local_cache_deletion_requested (other_graph_id ()))
    ; matrix_event
        "stale"
        (Foreground_changed { foreground = true; lifecycle_generation = 0L })
    ; matrix_event
        "background"
        (Foreground_changed { foreground = false; lifecycle_generation = 2L })
    ; matrix_event
        "foreground"
        (Foreground_changed { foreground = true; lifecycle_generation = 2L })
    ; matrix_event "current-available" (Mirror_inspected (Mirror_available open_request))
    ; matrix_event "current-absent" (Mirror_inspected (Mirror_absent open_request.scope))
    ; matrix_event "stale-absent" (Mirror_inspected (Mirror_absent stale_scope))
    ; matrix_event
        "current"
        (Graph_attached
           { scope = open_request.scope
           ; checkpoint = open_request.checkpoint
           ; outbox_records = []
           })
    ; matrix_event
        "stale"
        (Graph_attached
           { scope = stale_scope
           ; checkpoint = checkpoint stale_scope.graph_id
           ; outbox_records = []
           })
    ; matrix_event "current" (Graph_attachment_failed current_error)
    ; matrix_event "stale" (Graph_attachment_failed stale_error)
    ; matrix_event "current" (Local_batch_prepared (local_input open_request.scope))
    ; matrix_event "stale" (Local_batch_prepared (local_input stale_scope))
    ; matrix_event
        "current"
        (Local_batch_committed { scope = open_request.scope; outbox_records = [] })
    ; matrix_event
        "stale"
        (Local_batch_committed { scope = stale_scope; outbox_records = [] })
    ; matrix_event
        "current"
        (Authoritative_batch_inspected (authoritative_context connection))
    ; matrix_event
        "stale"
        (Authoritative_batch_inspected (authoritative_context stale_connection))
    ; matrix_event
        "current"
        (Authoritative_batch_applied
           (authoritative_result Logseq_db_types.Sync_status.Pull_duplicate))
    ; matrix_event
        "stale"
        (Authoritative_batch_applied
           { (authoritative_result Logseq_db_types.Sync_status.Pull_duplicate) with
             scope = stale_scope
           })
    ; matrix_event
        "current"
        (Authoritative_batch_conflicted (authoritative_batch connection))
    ; matrix_event
        "stale"
        (Authoritative_batch_conflicted (authoritative_batch stale_connection))
    ; matrix_event "current" (Authoritative_batch_failed current_error)
    ; matrix_event "stale" (Authoritative_batch_failed stale_error)
    ; matrix_event
        "current"
        (Outbox_transition_committed
           { scope = open_request.scope; outbox_records = []; pending_message = None })
    ; matrix_event
        "stale"
        (Outbox_transition_committed
           { scope = stale_scope; outbox_records = []; pending_message = None })
    ; matrix_event
        "current"
        (Outbox_transition_rejected
           { scope = open_request.scope; outbox_records = []; message = "rejected" })
    ; matrix_event
        "stale"
        (Outbox_transition_rejected
           { scope = stale_scope; outbox_records = []; message = "rejected" })
    ; matrix_event "current" (Snapshot_activated { scope = open_request.scope })
    ; matrix_event "stale" (Snapshot_activated { scope = stale_scope })
    ; matrix_event "current" (Snapshot_activation_failed current_error)
    ; matrix_event "stale" (Snapshot_activation_failed stale_error)
    ; matrix_event "success" catalog_completion
    ; matrix_event "failure" (catalog_failure_completion catalog_loading.effects)
    ; matrix_event
        "bounded"
        (Snapshot_download_progress
           { graph_id = graph.graph_id; received_bytes = 1L; total_bytes = Some 2L })
    ; matrix_event "current" (Websocket_opened connection)
    ; matrix_event "stale" (Websocket_opened stale_connection)
    ; matrix_event "current" (Websocket_message (connection, Sync_protocol.Server.Pong))
    ; matrix_event
        "stale"
        (Websocket_message (stale_connection, Sync_protocol.Server.Pong))
    ; matrix_event "current" (Websocket_protocol_error (connection, codec_error))
    ; matrix_event "stale" (Websocket_protocol_error (stale_connection, codec_error))
    ; matrix_event "current" (Websocket_closed (connection, Some "closed"))
    ; matrix_event "stale" (Websocket_closed (stale_connection, Some "closed"))
    ; matrix_event "requested" Shutdown
    ]
  in
  let intentionally_unconstructible_events =
    [ ( "Timer_elapsed"
      , "Core.timer_id is abstract and no reachable Schedule_timer instruction supplies \
         one" )
    ]
  in
  let declared_checkpoint name =
    match
      List.find_opt
        (fun (checkpoint : checkpoint) -> String.equal checkpoint.name name)
        checkpoints
    with
    | Some checkpoint -> checkpoint
    | None -> fail "transition case refers to undeclared checkpoint %S" name
  in
  let declared_event name =
    match
      List.find_opt (fun (event : event_case) -> String.equal event.name name) events
    with
    | Some event -> event
    | None -> fail "transition case refers to undeclared event case %S" name
  in
  let exact_case origin event expected_next expected_effects =
    { origin = declared_checkpoint origin
    ; event = declared_event event
    ; expected_next
    ; expected_effects
    }
  in
  let transition_cases =
    [ exact_case
        "initial/offline"
        "Restore_local_account/valid"
        expected_state_001
        expected_effects_000
    ; exact_case
        "initial/offline"
        "Account_authenticated/sign-in"
        expected_state_002
        expected_effects_001
    ; exact_case
        "initial/offline"
        "Account_authenticated/sign-out"
        expected_state_012
        expected_effects_002
    ; exact_case
        "initial/offline"
        "Local_feed_acknowledged/acknowledged"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Timeline_presented/presented"
        expected_state_013
        expected_effects_004
    ; exact_case
        "initial/offline"
        "Token_provided/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Token_provided/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Token_rejected/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Token_rejected/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Graph_selected/catalog-member"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Graph_selected/unknown"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Graph_picker_requested/requested"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Catalog_refresh_requested/requested"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Online_recovery_requested/requested"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "E2ee_password_submitted/valid"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "E2ee_password_submitted/invalid-empty"
        expected_state_014
        expected_effects_005
    ; exact_case
        "initial/offline"
        "Local_cache_deletion_requested/current"
        expected_state_000
        expected_effects_006
    ; exact_case
        "initial/offline"
        "Local_cache_deletion_requested/unknown"
        expected_state_000
        expected_effects_007
    ; exact_case
        "initial/offline"
        "Foreground_changed/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Foreground_changed/background"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Foreground_changed/foreground"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Mirror_inspected/current-available"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Mirror_inspected/current-absent"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Mirror_inspected/stale-absent"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Graph_attached/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Graph_attached/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Graph_attachment_failed/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Graph_attachment_failed/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Local_batch_prepared/current"
        expected_state_000
        expected_effects_008
    ; exact_case
        "initial/offline"
        "Local_batch_prepared/stale"
        expected_state_000
        expected_effects_009
    ; exact_case
        "initial/offline"
        "Local_batch_committed/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Local_batch_committed/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Authoritative_batch_inspected/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Authoritative_batch_inspected/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Authoritative_batch_applied/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Authoritative_batch_applied/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Authoritative_batch_conflicted/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Authoritative_batch_conflicted/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Authoritative_batch_failed/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Authoritative_batch_failed/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Outbox_transition_committed/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Outbox_transition_committed/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Outbox_transition_rejected/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Outbox_transition_rejected/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Snapshot_activated/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Snapshot_activated/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Snapshot_activation_failed/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Snapshot_activation_failed/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Runner_completed/success"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Runner_completed/failure"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Snapshot_download_progress/bounded"
        expected_state_000
        expected_effects_010
    ; exact_case
        "initial/offline"
        "Websocket_opened/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Websocket_opened/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Websocket_message/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Websocket_message/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Websocket_protocol_error/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Websocket_protocol_error/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Websocket_closed/current"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Websocket_closed/stale"
        expected_state_000
        expected_effects_003
    ; exact_case
        "initial/offline"
        "Shutdown/requested"
        expected_state_000
        expected_effects_011
    ; exact_case
        "local-restore/loading"
        "Restore_local_account/valid"
        expected_state_015
        expected_effects_012
    ; exact_case
        "local-restore/loading"
        "Account_authenticated/sign-in"
        expected_state_016
        expected_effects_013
    ; exact_case
        "local-restore/loading"
        "Account_authenticated/sign-out"
        expected_state_017
        expected_effects_014
    ; exact_case
        "local-restore/loading"
        "Local_feed_acknowledged/acknowledged"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Timeline_presented/presented"
        expected_state_018
        expected_effects_015
    ; exact_case
        "local-restore/loading"
        "Token_provided/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Token_provided/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Token_rejected/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Token_rejected/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Graph_selected/catalog-member"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Graph_selected/unknown"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Graph_picker_requested/requested"
        expected_state_019
        expected_effects_016
    ; exact_case
        "local-restore/loading"
        "Catalog_refresh_requested/requested"
        expected_state_020
        expected_effects_017
    ; exact_case
        "local-restore/loading"
        "Online_recovery_requested/requested"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "E2ee_password_submitted/valid"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "E2ee_password_submitted/invalid-empty"
        expected_state_021
        expected_effects_018
    ; exact_case
        "local-restore/loading"
        "Local_cache_deletion_requested/current"
        expected_state_001
        expected_effects_019
    ; exact_case
        "local-restore/loading"
        "Local_cache_deletion_requested/unknown"
        expected_state_001
        expected_effects_020
    ; exact_case
        "local-restore/loading"
        "Foreground_changed/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Foreground_changed/background"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Foreground_changed/foreground"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Mirror_inspected/current-available"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Mirror_inspected/current-absent"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Mirror_inspected/stale-absent"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Graph_attached/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Graph_attached/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Graph_attachment_failed/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Graph_attachment_failed/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Local_batch_prepared/current"
        expected_state_001
        expected_effects_008
    ; exact_case
        "local-restore/loading"
        "Local_batch_prepared/stale"
        expected_state_001
        expected_effects_009
    ; exact_case
        "local-restore/loading"
        "Local_batch_committed/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Local_batch_committed/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Authoritative_batch_inspected/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Authoritative_batch_inspected/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Authoritative_batch_applied/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Authoritative_batch_applied/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Authoritative_batch_conflicted/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Authoritative_batch_conflicted/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Authoritative_batch_failed/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Authoritative_batch_failed/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Outbox_transition_committed/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Outbox_transition_committed/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Outbox_transition_rejected/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Outbox_transition_rejected/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Snapshot_activated/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Snapshot_activated/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Snapshot_activation_failed/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Snapshot_activation_failed/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Runner_completed/success"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Runner_completed/failure"
        expected_state_022
        expected_effects_021
    ; exact_case
        "local-restore/loading"
        "Snapshot_download_progress/bounded"
        expected_state_001
        expected_effects_010
    ; exact_case
        "local-restore/loading"
        "Websocket_opened/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Websocket_opened/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Websocket_message/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Websocket_message/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Websocket_protocol_error/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Websocket_protocol_error/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Websocket_closed/current"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Websocket_closed/stale"
        expected_state_001
        expected_effects_003
    ; exact_case
        "local-restore/loading"
        "Shutdown/requested"
        expected_state_001
        expected_effects_022
    ; exact_case
        "authentication/token-pending"
        "Restore_local_account/valid"
        expected_state_015
        expected_effects_023
    ; exact_case
        "authentication/token-pending"
        "Account_authenticated/sign-in"
        expected_state_023
        expected_effects_024
    ; exact_case
        "authentication/token-pending"
        "Account_authenticated/sign-out"
        expected_state_017
        expected_effects_025
    ; exact_case
        "authentication/token-pending"
        "Local_feed_acknowledged/acknowledged"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Timeline_presented/presented"
        expected_state_024
        expected_effects_026
    ; exact_case
        "authentication/token-pending"
        "Token_provided/current"
        expected_state_002
        expected_effects_027
    ; exact_case
        "authentication/token-pending"
        "Token_provided/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Token_rejected/current"
        expected_state_010
        expected_effects_028
    ; exact_case
        "authentication/token-pending"
        "Token_rejected/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Graph_selected/catalog-member"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Graph_selected/unknown"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Graph_picker_requested/requested"
        expected_state_025
        expected_effects_029
    ; exact_case
        "authentication/token-pending"
        "Catalog_refresh_requested/requested"
        expected_state_002
        expected_effects_030
    ; exact_case
        "authentication/token-pending"
        "Online_recovery_requested/requested"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "E2ee_password_submitted/valid"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "E2ee_password_submitted/invalid-empty"
        expected_state_026
        expected_effects_031
    ; exact_case
        "authentication/token-pending"
        "Local_cache_deletion_requested/current"
        expected_state_002
        expected_effects_019
    ; exact_case
        "authentication/token-pending"
        "Local_cache_deletion_requested/unknown"
        expected_state_002
        expected_effects_020
    ; exact_case
        "authentication/token-pending"
        "Foreground_changed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Foreground_changed/background"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Foreground_changed/foreground"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Mirror_inspected/current-available"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Mirror_inspected/current-absent"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Mirror_inspected/stale-absent"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Graph_attached/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Graph_attached/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Graph_attachment_failed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Graph_attachment_failed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Local_batch_prepared/current"
        expected_state_002
        expected_effects_008
    ; exact_case
        "authentication/token-pending"
        "Local_batch_prepared/stale"
        expected_state_002
        expected_effects_009
    ; exact_case
        "authentication/token-pending"
        "Local_batch_committed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Local_batch_committed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Authoritative_batch_inspected/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Authoritative_batch_inspected/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Authoritative_batch_applied/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Authoritative_batch_applied/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Authoritative_batch_conflicted/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Authoritative_batch_conflicted/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Authoritative_batch_failed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Authoritative_batch_failed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Outbox_transition_committed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Outbox_transition_committed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Outbox_transition_rejected/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Outbox_transition_rejected/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Snapshot_activated/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Snapshot_activated/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Snapshot_activation_failed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Snapshot_activation_failed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Runner_completed/success"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Runner_completed/failure"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Snapshot_download_progress/bounded"
        expected_state_002
        expected_effects_010
    ; exact_case
        "authentication/token-pending"
        "Websocket_opened/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Websocket_opened/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Websocket_message/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Websocket_message/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Websocket_protocol_error/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Websocket_protocol_error/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Websocket_closed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Websocket_closed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "authentication/token-pending"
        "Shutdown/requested"
        expected_state_002
        expected_effects_032
    ; exact_case
        "catalog/request-pending"
        "Restore_local_account/valid"
        expected_state_015
        expected_effects_012
    ; exact_case
        "catalog/request-pending"
        "Account_authenticated/sign-in"
        expected_state_023
        expected_effects_024
    ; exact_case
        "catalog/request-pending"
        "Account_authenticated/sign-out"
        expected_state_017
        expected_effects_025
    ; exact_case
        "catalog/request-pending"
        "Local_feed_acknowledged/acknowledged"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Timeline_presented/presented"
        expected_state_024
        expected_effects_026
    ; exact_case
        "catalog/request-pending"
        "Token_provided/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Token_provided/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Token_rejected/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Token_rejected/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Graph_selected/catalog-member"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Graph_selected/unknown"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Graph_picker_requested/requested"
        expected_state_025
        expected_effects_029
    ; exact_case
        "catalog/request-pending"
        "Catalog_refresh_requested/requested"
        expected_state_002
        expected_effects_033
    ; exact_case
        "catalog/request-pending"
        "Online_recovery_requested/requested"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "E2ee_password_submitted/valid"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "E2ee_password_submitted/invalid-empty"
        expected_state_026
        expected_effects_031
    ; exact_case
        "catalog/request-pending"
        "Local_cache_deletion_requested/current"
        expected_state_002
        expected_effects_019
    ; exact_case
        "catalog/request-pending"
        "Local_cache_deletion_requested/unknown"
        expected_state_002
        expected_effects_020
    ; exact_case
        "catalog/request-pending"
        "Foreground_changed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Foreground_changed/background"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Foreground_changed/foreground"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Mirror_inspected/current-available"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Mirror_inspected/current-absent"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Mirror_inspected/stale-absent"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Graph_attached/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Graph_attached/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Graph_attachment_failed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Graph_attachment_failed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Local_batch_prepared/current"
        expected_state_002
        expected_effects_008
    ; exact_case
        "catalog/request-pending"
        "Local_batch_prepared/stale"
        expected_state_002
        expected_effects_009
    ; exact_case
        "catalog/request-pending"
        "Local_batch_committed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Local_batch_committed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Authoritative_batch_inspected/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Authoritative_batch_inspected/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Authoritative_batch_applied/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Authoritative_batch_applied/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Authoritative_batch_conflicted/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Authoritative_batch_conflicted/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Authoritative_batch_failed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Authoritative_batch_failed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Outbox_transition_committed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Outbox_transition_committed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Outbox_transition_rejected/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Outbox_transition_rejected/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Snapshot_activated/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Snapshot_activated/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Snapshot_activation_failed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Snapshot_activation_failed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Runner_completed/success"
        expected_state_003
        expected_effects_034
    ; exact_case
        "catalog/request-pending"
        "Runner_completed/failure"
        expected_state_027
        expected_effects_035
    ; exact_case
        "catalog/request-pending"
        "Snapshot_download_progress/bounded"
        expected_state_002
        expected_effects_010
    ; exact_case
        "catalog/request-pending"
        "Websocket_opened/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Websocket_opened/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Websocket_message/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Websocket_message/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Websocket_protocol_error/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Websocket_protocol_error/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Websocket_closed/current"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Websocket_closed/stale"
        expected_state_002
        expected_effects_003
    ; exact_case
        "catalog/request-pending"
        "Shutdown/requested"
        expected_state_002
        expected_effects_032
    ; exact_case
        "catalog/awaiting-selection"
        "Restore_local_account/valid"
        expected_state_015
        expected_effects_036
    ; exact_case
        "catalog/awaiting-selection"
        "Account_authenticated/sign-in"
        expected_state_023
        expected_effects_024
    ; exact_case
        "catalog/awaiting-selection"
        "Account_authenticated/sign-out"
        expected_state_017
        expected_effects_025
    ; exact_case
        "catalog/awaiting-selection"
        "Local_feed_acknowledged/acknowledged"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Timeline_presented/presented"
        expected_state_028
        expected_effects_037
    ; exact_case
        "catalog/awaiting-selection"
        "Token_provided/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Token_provided/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Token_rejected/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Token_rejected/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Graph_selected/catalog-member"
        expected_state_004
        expected_effects_038
    ; exact_case
        "catalog/awaiting-selection"
        "Graph_selected/unknown"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Graph_picker_requested/requested"
        expected_state_030
        expected_effects_039
    ; exact_case
        "catalog/awaiting-selection"
        "Catalog_refresh_requested/requested"
        expected_state_031
        expected_effects_040
    ; exact_case
        "catalog/awaiting-selection"
        "Online_recovery_requested/requested"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "E2ee_password_submitted/valid"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "E2ee_password_submitted/invalid-empty"
        expected_state_032
        expected_effects_041
    ; exact_case
        "catalog/awaiting-selection"
        "Local_cache_deletion_requested/current"
        expected_state_003
        expected_effects_019
    ; exact_case
        "catalog/awaiting-selection"
        "Local_cache_deletion_requested/unknown"
        expected_state_003
        expected_effects_020
    ; exact_case
        "catalog/awaiting-selection"
        "Foreground_changed/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Foreground_changed/background"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Foreground_changed/foreground"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Mirror_inspected/current-available"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Mirror_inspected/current-absent"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Mirror_inspected/stale-absent"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Graph_attached/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Graph_attached/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Graph_attachment_failed/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Graph_attachment_failed/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Local_batch_prepared/current"
        expected_state_003
        expected_effects_008
    ; exact_case
        "catalog/awaiting-selection"
        "Local_batch_prepared/stale"
        expected_state_003
        expected_effects_009
    ; exact_case
        "catalog/awaiting-selection"
        "Local_batch_committed/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Local_batch_committed/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Authoritative_batch_inspected/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Authoritative_batch_inspected/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Authoritative_batch_applied/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Authoritative_batch_applied/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Authoritative_batch_conflicted/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Authoritative_batch_conflicted/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Authoritative_batch_failed/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Authoritative_batch_failed/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Outbox_transition_committed/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Outbox_transition_committed/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Outbox_transition_rejected/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Outbox_transition_rejected/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Snapshot_activated/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Snapshot_activated/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Snapshot_activation_failed/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Snapshot_activation_failed/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Runner_completed/success"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Runner_completed/failure"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Snapshot_download_progress/bounded"
        expected_state_003
        expected_effects_010
    ; exact_case
        "catalog/awaiting-selection"
        "Websocket_opened/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Websocket_opened/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Websocket_message/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Websocket_message/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Websocket_protocol_error/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Websocket_protocol_error/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Websocket_closed/current"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Websocket_closed/stale"
        expected_state_003
        expected_effects_003
    ; exact_case
        "catalog/awaiting-selection"
        "Shutdown/requested"
        expected_state_003
        expected_effects_032
    ; exact_case
        "graph/selected"
        "Restore_local_account/valid"
        expected_state_033
        expected_effects_042
    ; exact_case
        "graph/selected"
        "Account_authenticated/sign-in"
        expected_state_034
        expected_effects_043
    ; exact_case
        "graph/selected"
        "Account_authenticated/sign-out"
        expected_state_035
        expected_effects_044
    ; exact_case
        "graph/selected"
        "Local_feed_acknowledged/acknowledged"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Timeline_presented/presented"
        expected_state_036
        expected_effects_045
    ; exact_case
        "graph/selected"
        "Token_provided/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Token_provided/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Token_rejected/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Token_rejected/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Graph_selected/catalog-member"
        expected_state_038
        expected_effects_046
    ; exact_case
        "graph/selected"
        "Graph_selected/unknown"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Graph_picker_requested/requested"
        expected_state_040
        expected_effects_047
    ; exact_case
        "graph/selected"
        "Catalog_refresh_requested/requested"
        expected_state_041
        expected_effects_048
    ; exact_case
        "graph/selected"
        "Online_recovery_requested/requested"
        expected_state_004
        expected_effects_049
    ; exact_case
        "graph/selected"
        "E2ee_password_submitted/valid"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "E2ee_password_submitted/invalid-empty"
        expected_state_043
        expected_effects_050
    ; exact_case
        "graph/selected"
        "Local_cache_deletion_requested/current"
        expected_state_038
        expected_effects_051
    ; exact_case
        "graph/selected"
        "Local_cache_deletion_requested/unknown"
        expected_state_004
        expected_effects_052
    ; exact_case
        "graph/selected"
        "Foreground_changed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Foreground_changed/background"
        expected_state_004
        expected_effects_053
    ; exact_case
        "graph/selected"
        "Foreground_changed/foreground"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Mirror_inspected/current-available"
        expected_state_004
        expected_effects_054
    ; exact_case
        "graph/selected"
        "Mirror_inspected/current-absent"
        expected_state_004
        expected_effects_049
    ; exact_case
        "graph/selected"
        "Mirror_inspected/stale-absent"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Graph_attached/current"
        expected_state_005
        expected_effects_055
    ; exact_case
        "graph/selected"
        "Graph_attached/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Graph_attachment_failed/current"
        expected_state_046
        expected_effects_056
    ; exact_case
        "graph/selected"
        "Graph_attachment_failed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Local_batch_prepared/current"
        expected_state_004
        expected_effects_057
    ; exact_case
        "graph/selected"
        "Local_batch_prepared/stale"
        expected_state_004
        expected_effects_009
    ; exact_case
        "graph/selected"
        "Local_batch_committed/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Local_batch_committed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Authoritative_batch_inspected/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Authoritative_batch_inspected/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Authoritative_batch_applied/current"
        expected_state_048
        expected_effects_058
    ; exact_case
        "graph/selected"
        "Authoritative_batch_applied/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Authoritative_batch_conflicted/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Authoritative_batch_conflicted/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Authoritative_batch_failed/current"
        expected_state_046
        expected_effects_056
    ; exact_case
        "graph/selected"
        "Authoritative_batch_failed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Outbox_transition_committed/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Outbox_transition_committed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Outbox_transition_rejected/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Outbox_transition_rejected/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Snapshot_activated/current"
        expected_state_004
        expected_effects_059
    ; exact_case
        "graph/selected"
        "Snapshot_activated/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Snapshot_activation_failed/current"
        expected_state_046
        expected_effects_056
    ; exact_case
        "graph/selected"
        "Snapshot_activation_failed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Runner_completed/success"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Runner_completed/failure"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Snapshot_download_progress/bounded"
        expected_state_004
        expected_effects_010
    ; exact_case
        "graph/selected"
        "Websocket_opened/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Websocket_opened/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Websocket_message/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Websocket_message/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Websocket_protocol_error/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Websocket_protocol_error/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Websocket_closed/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Websocket_closed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/selected"
        "Shutdown/requested"
        expected_state_004
        expected_effects_032
    ; exact_case
        "graph/attachment-pending"
        "Restore_local_account/valid"
        expected_state_033
        expected_effects_042
    ; exact_case
        "graph/attachment-pending"
        "Account_authenticated/sign-in"
        expected_state_034
        expected_effects_043
    ; exact_case
        "graph/attachment-pending"
        "Account_authenticated/sign-out"
        expected_state_035
        expected_effects_044
    ; exact_case
        "graph/attachment-pending"
        "Local_feed_acknowledged/acknowledged"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Timeline_presented/presented"
        expected_state_036
        expected_effects_045
    ; exact_case
        "graph/attachment-pending"
        "Token_provided/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Token_provided/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Token_rejected/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Token_rejected/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Graph_selected/catalog-member"
        expected_state_038
        expected_effects_046
    ; exact_case
        "graph/attachment-pending"
        "Graph_selected/unknown"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Graph_picker_requested/requested"
        expected_state_040
        expected_effects_047
    ; exact_case
        "graph/attachment-pending"
        "Catalog_refresh_requested/requested"
        expected_state_041
        expected_effects_048
    ; exact_case
        "graph/attachment-pending"
        "Online_recovery_requested/requested"
        expected_state_004
        expected_effects_049
    ; exact_case
        "graph/attachment-pending"
        "E2ee_password_submitted/valid"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "E2ee_password_submitted/invalid-empty"
        expected_state_043
        expected_effects_050
    ; exact_case
        "graph/attachment-pending"
        "Local_cache_deletion_requested/current"
        expected_state_038
        expected_effects_051
    ; exact_case
        "graph/attachment-pending"
        "Local_cache_deletion_requested/unknown"
        expected_state_004
        expected_effects_052
    ; exact_case
        "graph/attachment-pending"
        "Foreground_changed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Foreground_changed/background"
        expected_state_004
        expected_effects_053
    ; exact_case
        "graph/attachment-pending"
        "Foreground_changed/foreground"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Mirror_inspected/current-available"
        expected_state_004
        expected_effects_054
    ; exact_case
        "graph/attachment-pending"
        "Mirror_inspected/current-absent"
        expected_state_004
        expected_effects_049
    ; exact_case
        "graph/attachment-pending"
        "Mirror_inspected/stale-absent"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Graph_attached/current"
        expected_state_005
        expected_effects_055
    ; exact_case
        "graph/attachment-pending"
        "Graph_attached/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Graph_attachment_failed/current"
        expected_state_046
        expected_effects_056
    ; exact_case
        "graph/attachment-pending"
        "Graph_attachment_failed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Local_batch_prepared/current"
        expected_state_004
        expected_effects_057
    ; exact_case
        "graph/attachment-pending"
        "Local_batch_prepared/stale"
        expected_state_004
        expected_effects_009
    ; exact_case
        "graph/attachment-pending"
        "Local_batch_committed/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Local_batch_committed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Authoritative_batch_inspected/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Authoritative_batch_inspected/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Authoritative_batch_applied/current"
        expected_state_048
        expected_effects_058
    ; exact_case
        "graph/attachment-pending"
        "Authoritative_batch_applied/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Authoritative_batch_conflicted/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Authoritative_batch_conflicted/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Authoritative_batch_failed/current"
        expected_state_046
        expected_effects_056
    ; exact_case
        "graph/attachment-pending"
        "Authoritative_batch_failed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Outbox_transition_committed/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Outbox_transition_committed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Outbox_transition_rejected/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Outbox_transition_rejected/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Snapshot_activated/current"
        expected_state_004
        expected_effects_059
    ; exact_case
        "graph/attachment-pending"
        "Snapshot_activated/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Snapshot_activation_failed/current"
        expected_state_046
        expected_effects_056
    ; exact_case
        "graph/attachment-pending"
        "Snapshot_activation_failed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Runner_completed/success"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Runner_completed/failure"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Snapshot_download_progress/bounded"
        expected_state_004
        expected_effects_010
    ; exact_case
        "graph/attachment-pending"
        "Websocket_opened/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Websocket_opened/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Websocket_message/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Websocket_message/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Websocket_protocol_error/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Websocket_protocol_error/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Websocket_closed/current"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Websocket_closed/stale"
        expected_state_004
        expected_effects_003
    ; exact_case
        "graph/attachment-pending"
        "Shutdown/requested"
        expected_state_004
        expected_effects_032
    ; exact_case
        "websocket/token-pending"
        "Restore_local_account/valid"
        expected_state_033
        expected_effects_042
    ; exact_case
        "websocket/token-pending"
        "Account_authenticated/sign-in"
        expected_state_034
        expected_effects_043
    ; exact_case
        "websocket/token-pending"
        "Account_authenticated/sign-out"
        expected_state_035
        expected_effects_044
    ; exact_case
        "websocket/token-pending"
        "Local_feed_acknowledged/acknowledged"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Timeline_presented/presented"
        expected_state_050
        expected_effects_060
    ; exact_case
        "websocket/token-pending"
        "Token_provided/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Token_provided/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Token_rejected/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Token_rejected/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Graph_selected/catalog-member"
        expected_state_038
        expected_effects_046
    ; exact_case
        "websocket/token-pending"
        "Graph_selected/unknown"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Graph_picker_requested/requested"
        expected_state_040
        expected_effects_047
    ; exact_case
        "websocket/token-pending"
        "Catalog_refresh_requested/requested"
        expected_state_052
        expected_effects_061
    ; exact_case
        "websocket/token-pending"
        "Online_recovery_requested/requested"
        expected_state_005
        expected_effects_049
    ; exact_case
        "websocket/token-pending"
        "E2ee_password_submitted/valid"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "E2ee_password_submitted/invalid-empty"
        expected_state_054
        expected_effects_062
    ; exact_case
        "websocket/token-pending"
        "Local_cache_deletion_requested/current"
        expected_state_038
        expected_effects_051
    ; exact_case
        "websocket/token-pending"
        "Local_cache_deletion_requested/unknown"
        expected_state_005
        expected_effects_052
    ; exact_case
        "websocket/token-pending"
        "Foreground_changed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Foreground_changed/background"
        expected_state_011
        expected_effects_063
    ; exact_case
        "websocket/token-pending"
        "Foreground_changed/foreground"
        expected_state_005
        expected_effects_064
    ; exact_case
        "websocket/token-pending"
        "Mirror_inspected/current-available"
        expected_state_005
        expected_effects_054
    ; exact_case
        "websocket/token-pending"
        "Mirror_inspected/current-absent"
        expected_state_005
        expected_effects_049
    ; exact_case
        "websocket/token-pending"
        "Mirror_inspected/stale-absent"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Graph_attached/current"
        expected_state_005
        expected_effects_055
    ; exact_case
        "websocket/token-pending"
        "Graph_attached/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Graph_attachment_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "websocket/token-pending"
        "Graph_attachment_failed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Local_batch_prepared/current"
        expected_state_005
        expected_effects_057
    ; exact_case
        "websocket/token-pending"
        "Local_batch_prepared/stale"
        expected_state_005
        expected_effects_009
    ; exact_case
        "websocket/token-pending"
        "Local_batch_committed/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Local_batch_committed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Authoritative_batch_inspected/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Authoritative_batch_inspected/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Authoritative_batch_applied/current"
        expected_state_007
        expected_effects_066
    ; exact_case
        "websocket/token-pending"
        "Authoritative_batch_applied/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Authoritative_batch_conflicted/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Authoritative_batch_conflicted/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Authoritative_batch_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "websocket/token-pending"
        "Authoritative_batch_failed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Outbox_transition_committed/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Outbox_transition_committed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Outbox_transition_rejected/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Outbox_transition_rejected/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Snapshot_activated/current"
        expected_state_005
        expected_effects_059
    ; exact_case
        "websocket/token-pending"
        "Snapshot_activated/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Snapshot_activation_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "websocket/token-pending"
        "Snapshot_activation_failed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Runner_completed/success"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Runner_completed/failure"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Snapshot_download_progress/bounded"
        expected_state_005
        expected_effects_010
    ; exact_case
        "websocket/token-pending"
        "Websocket_opened/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Websocket_opened/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Websocket_message/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Websocket_message/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Websocket_protocol_error/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Websocket_protocol_error/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Websocket_closed/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Websocket_closed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/token-pending"
        "Shutdown/requested"
        expected_state_005
        expected_effects_032
    ; exact_case
        "websocket/starting"
        "Restore_local_account/valid"
        expected_state_033
        expected_effects_042
    ; exact_case
        "websocket/starting"
        "Account_authenticated/sign-in"
        expected_state_034
        expected_effects_043
    ; exact_case
        "websocket/starting"
        "Account_authenticated/sign-out"
        expected_state_035
        expected_effects_044
    ; exact_case
        "websocket/starting"
        "Local_feed_acknowledged/acknowledged"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Timeline_presented/presented"
        expected_state_050
        expected_effects_067
    ; exact_case
        "websocket/starting"
        "Token_provided/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Token_provided/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Token_rejected/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Token_rejected/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Graph_selected/catalog-member"
        expected_state_038
        expected_effects_046
    ; exact_case
        "websocket/starting"
        "Graph_selected/unknown"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Graph_picker_requested/requested"
        expected_state_040
        expected_effects_047
    ; exact_case
        "websocket/starting"
        "Catalog_refresh_requested/requested"
        expected_state_052
        expected_effects_061
    ; exact_case
        "websocket/starting"
        "Online_recovery_requested/requested"
        expected_state_005
        expected_effects_049
    ; exact_case
        "websocket/starting"
        "E2ee_password_submitted/valid"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "E2ee_password_submitted/invalid-empty"
        expected_state_054
        expected_effects_062
    ; exact_case
        "websocket/starting"
        "Local_cache_deletion_requested/current"
        expected_state_038
        expected_effects_051
    ; exact_case
        "websocket/starting"
        "Local_cache_deletion_requested/unknown"
        expected_state_005
        expected_effects_052
    ; exact_case
        "websocket/starting"
        "Foreground_changed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Foreground_changed/background"
        expected_state_011
        expected_effects_068
    ; exact_case
        "websocket/starting"
        "Foreground_changed/foreground"
        expected_state_005
        expected_effects_064
    ; exact_case
        "websocket/starting"
        "Mirror_inspected/current-available"
        expected_state_005
        expected_effects_054
    ; exact_case
        "websocket/starting"
        "Mirror_inspected/current-absent"
        expected_state_005
        expected_effects_049
    ; exact_case
        "websocket/starting"
        "Mirror_inspected/stale-absent"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Graph_attached/current"
        expected_state_005
        expected_effects_055
    ; exact_case
        "websocket/starting"
        "Graph_attached/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Graph_attachment_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "websocket/starting"
        "Graph_attachment_failed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Local_batch_prepared/current"
        expected_state_005
        expected_effects_057
    ; exact_case
        "websocket/starting"
        "Local_batch_prepared/stale"
        expected_state_005
        expected_effects_009
    ; exact_case
        "websocket/starting"
        "Local_batch_committed/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Local_batch_committed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Authoritative_batch_inspected/current"
        expected_state_005
        expected_effects_069
    ; exact_case
        "websocket/starting"
        "Authoritative_batch_inspected/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Authoritative_batch_applied/current"
        expected_state_007
        expected_effects_066
    ; exact_case
        "websocket/starting"
        "Authoritative_batch_applied/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Authoritative_batch_conflicted/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Authoritative_batch_conflicted/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Authoritative_batch_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "websocket/starting"
        "Authoritative_batch_failed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Outbox_transition_committed/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Outbox_transition_committed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Outbox_transition_rejected/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Outbox_transition_rejected/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Snapshot_activated/current"
        expected_state_005
        expected_effects_059
    ; exact_case
        "websocket/starting"
        "Snapshot_activated/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Snapshot_activation_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "websocket/starting"
        "Snapshot_activation_failed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Runner_completed/success"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Runner_completed/failure"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Snapshot_download_progress/bounded"
        expected_state_005
        expected_effects_010
    ; exact_case
        "websocket/starting"
        "Websocket_opened/current"
        expected_state_006
        expected_effects_070
    ; exact_case
        "websocket/starting"
        "Websocket_opened/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Websocket_message/current"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Websocket_message/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Websocket_protocol_error/current"
        expected_state_061
        expected_effects_071
    ; exact_case
        "websocket/starting"
        "Websocket_protocol_error/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Websocket_closed/current"
        expected_state_063
        expected_effects_072
    ; exact_case
        "websocket/starting"
        "Websocket_closed/stale"
        expected_state_005
        expected_effects_003
    ; exact_case
        "websocket/starting"
        "Shutdown/requested"
        expected_state_005
        expected_effects_032
    ; exact_case
        "sync/pulling"
        "Restore_local_account/valid"
        expected_state_033
        expected_effects_042
    ; exact_case
        "sync/pulling"
        "Account_authenticated/sign-in"
        expected_state_034
        expected_effects_043
    ; exact_case
        "sync/pulling"
        "Account_authenticated/sign-out"
        expected_state_035
        expected_effects_044
    ; exact_case
        "sync/pulling"
        "Local_feed_acknowledged/acknowledged"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Timeline_presented/presented"
        expected_state_065
        expected_effects_073
    ; exact_case
        "sync/pulling"
        "Token_provided/current"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Token_provided/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Token_rejected/current"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Token_rejected/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Graph_selected/catalog-member"
        expected_state_038
        expected_effects_046
    ; exact_case
        "sync/pulling"
        "Graph_selected/unknown"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Graph_picker_requested/requested"
        expected_state_040
        expected_effects_047
    ; exact_case
        "sync/pulling"
        "Catalog_refresh_requested/requested"
        expected_state_067
        expected_effects_074
    ; exact_case
        "sync/pulling"
        "Online_recovery_requested/requested"
        expected_state_006
        expected_effects_049
    ; exact_case
        "sync/pulling"
        "E2ee_password_submitted/valid"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "E2ee_password_submitted/invalid-empty"
        expected_state_054
        expected_effects_062
    ; exact_case
        "sync/pulling"
        "Local_cache_deletion_requested/current"
        expected_state_038
        expected_effects_051
    ; exact_case
        "sync/pulling"
        "Local_cache_deletion_requested/unknown"
        expected_state_006
        expected_effects_052
    ; exact_case
        "sync/pulling"
        "Foreground_changed/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Foreground_changed/background"
        expected_state_011
        expected_effects_068
    ; exact_case
        "sync/pulling"
        "Foreground_changed/foreground"
        expected_state_006
        expected_effects_064
    ; exact_case
        "sync/pulling"
        "Mirror_inspected/current-available"
        expected_state_006
        expected_effects_054
    ; exact_case
        "sync/pulling"
        "Mirror_inspected/current-absent"
        expected_state_006
        expected_effects_049
    ; exact_case
        "sync/pulling"
        "Mirror_inspected/stale-absent"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Graph_attached/current"
        expected_state_005
        expected_effects_055
    ; exact_case
        "sync/pulling"
        "Graph_attached/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Graph_attachment_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/pulling"
        "Graph_attachment_failed/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Local_batch_prepared/current"
        expected_state_006
        expected_effects_057
    ; exact_case
        "sync/pulling"
        "Local_batch_prepared/stale"
        expected_state_006
        expected_effects_009
    ; exact_case
        "sync/pulling"
        "Local_batch_committed/current"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Local_batch_committed/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Authoritative_batch_inspected/current"
        expected_state_006
        expected_effects_069
    ; exact_case
        "sync/pulling"
        "Authoritative_batch_inspected/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Authoritative_batch_applied/current"
        expected_state_007
        expected_effects_066
    ; exact_case
        "sync/pulling"
        "Authoritative_batch_applied/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Authoritative_batch_conflicted/current"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Authoritative_batch_conflicted/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Authoritative_batch_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/pulling"
        "Authoritative_batch_failed/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Outbox_transition_committed/current"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Outbox_transition_committed/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Outbox_transition_rejected/current"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Outbox_transition_rejected/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Snapshot_activated/current"
        expected_state_006
        expected_effects_059
    ; exact_case
        "sync/pulling"
        "Snapshot_activated/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Snapshot_activation_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/pulling"
        "Snapshot_activation_failed/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Runner_completed/success"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Runner_completed/failure"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Snapshot_download_progress/bounded"
        expected_state_006
        expected_effects_010
    ; exact_case
        "sync/pulling"
        "Websocket_opened/current"
        expected_state_006
        expected_effects_070
    ; exact_case
        "sync/pulling"
        "Websocket_opened/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Websocket_message/current"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Websocket_message/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Websocket_protocol_error/current"
        expected_state_061
        expected_effects_071
    ; exact_case
        "sync/pulling"
        "Websocket_protocol_error/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Websocket_closed/current"
        expected_state_063
        expected_effects_072
    ; exact_case
        "sync/pulling"
        "Websocket_closed/stale"
        expected_state_006
        expected_effects_003
    ; exact_case
        "sync/pulling"
        "Shutdown/requested"
        expected_state_006
        expected_effects_032
    ; exact_case
        "sync/current"
        "Restore_local_account/valid"
        expected_state_033
        expected_effects_042
    ; exact_case
        "sync/current"
        "Account_authenticated/sign-in"
        expected_state_034
        expected_effects_043
    ; exact_case
        "sync/current"
        "Account_authenticated/sign-out"
        expected_state_035
        expected_effects_044
    ; exact_case
        "sync/current"
        "Local_feed_acknowledged/acknowledged"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Timeline_presented/presented"
        expected_state_069
        expected_effects_075
    ; exact_case
        "sync/current"
        "Token_provided/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Token_provided/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Token_rejected/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Token_rejected/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Graph_selected/catalog-member"
        expected_state_038
        expected_effects_046
    ; exact_case
        "sync/current"
        "Graph_selected/unknown"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Graph_picker_requested/requested"
        expected_state_040
        expected_effects_047
    ; exact_case
        "sync/current"
        "Catalog_refresh_requested/requested"
        expected_state_071
        expected_effects_076
    ; exact_case
        "sync/current"
        "Online_recovery_requested/requested"
        expected_state_007
        expected_effects_049
    ; exact_case
        "sync/current"
        "E2ee_password_submitted/valid"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "E2ee_password_submitted/invalid-empty"
        expected_state_054
        expected_effects_062
    ; exact_case
        "sync/current"
        "Local_cache_deletion_requested/current"
        expected_state_038
        expected_effects_051
    ; exact_case
        "sync/current"
        "Local_cache_deletion_requested/unknown"
        expected_state_007
        expected_effects_052
    ; exact_case
        "sync/current"
        "Foreground_changed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Foreground_changed/background"
        expected_state_011
        expected_effects_068
    ; exact_case
        "sync/current"
        "Foreground_changed/foreground"
        expected_state_007
        expected_effects_064
    ; exact_case
        "sync/current"
        "Mirror_inspected/current-available"
        expected_state_007
        expected_effects_054
    ; exact_case
        "sync/current"
        "Mirror_inspected/current-absent"
        expected_state_007
        expected_effects_049
    ; exact_case
        "sync/current"
        "Mirror_inspected/stale-absent"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Graph_attached/current"
        expected_state_005
        expected_effects_055
    ; exact_case
        "sync/current"
        "Graph_attached/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Graph_attachment_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/current"
        "Graph_attachment_failed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Local_batch_prepared/current"
        expected_state_007
        expected_effects_057
    ; exact_case
        "sync/current"
        "Local_batch_prepared/stale"
        expected_state_007
        expected_effects_009
    ; exact_case
        "sync/current"
        "Local_batch_committed/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Local_batch_committed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Authoritative_batch_inspected/current"
        expected_state_007
        expected_effects_069
    ; exact_case
        "sync/current"
        "Authoritative_batch_inspected/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Authoritative_batch_applied/current"
        expected_state_007
        expected_effects_066
    ; exact_case
        "sync/current"
        "Authoritative_batch_applied/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Authoritative_batch_conflicted/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Authoritative_batch_conflicted/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Authoritative_batch_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/current"
        "Authoritative_batch_failed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Outbox_transition_committed/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Outbox_transition_committed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Outbox_transition_rejected/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Outbox_transition_rejected/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Snapshot_activated/current"
        expected_state_007
        expected_effects_059
    ; exact_case
        "sync/current"
        "Snapshot_activated/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Snapshot_activation_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/current"
        "Snapshot_activation_failed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Runner_completed/success"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Runner_completed/failure"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Snapshot_download_progress/bounded"
        expected_state_007
        expected_effects_010
    ; exact_case
        "sync/current"
        "Websocket_opened/current"
        expected_state_006
        expected_effects_070
    ; exact_case
        "sync/current"
        "Websocket_opened/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Websocket_message/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Websocket_message/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Websocket_protocol_error/current"
        expected_state_061
        expected_effects_071
    ; exact_case
        "sync/current"
        "Websocket_protocol_error/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Websocket_closed/current"
        expected_state_063
        expected_effects_072
    ; exact_case
        "sync/current"
        "Websocket_closed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/current"
        "Shutdown/requested"
        expected_state_007
        expected_effects_032
    ; exact_case
        "sync/submission-reserved"
        "Restore_local_account/valid"
        expected_state_033
        expected_effects_042
    ; exact_case
        "sync/submission-reserved"
        "Account_authenticated/sign-in"
        expected_state_034
        expected_effects_043
    ; exact_case
        "sync/submission-reserved"
        "Account_authenticated/sign-out"
        expected_state_035
        expected_effects_044
    ; exact_case
        "sync/submission-reserved"
        "Local_feed_acknowledged/acknowledged"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Timeline_presented/presented"
        expected_state_069
        expected_effects_075
    ; exact_case
        "sync/submission-reserved"
        "Token_provided/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Token_provided/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Token_rejected/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Token_rejected/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Graph_selected/catalog-member"
        expected_state_038
        expected_effects_046
    ; exact_case
        "sync/submission-reserved"
        "Graph_selected/unknown"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Graph_picker_requested/requested"
        expected_state_040
        expected_effects_047
    ; exact_case
        "sync/submission-reserved"
        "Catalog_refresh_requested/requested"
        expected_state_071
        expected_effects_076
    ; exact_case
        "sync/submission-reserved"
        "Online_recovery_requested/requested"
        expected_state_007
        expected_effects_049
    ; exact_case
        "sync/submission-reserved"
        "E2ee_password_submitted/valid"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "E2ee_password_submitted/invalid-empty"
        expected_state_054
        expected_effects_062
    ; exact_case
        "sync/submission-reserved"
        "Local_cache_deletion_requested/current"
        expected_state_038
        expected_effects_051
    ; exact_case
        "sync/submission-reserved"
        "Local_cache_deletion_requested/unknown"
        expected_state_007
        expected_effects_052
    ; exact_case
        "sync/submission-reserved"
        "Foreground_changed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Foreground_changed/background"
        expected_state_011
        expected_effects_068
    ; exact_case
        "sync/submission-reserved"
        "Foreground_changed/foreground"
        expected_state_007
        expected_effects_064
    ; exact_case
        "sync/submission-reserved"
        "Mirror_inspected/current-available"
        expected_state_007
        expected_effects_054
    ; exact_case
        "sync/submission-reserved"
        "Mirror_inspected/current-absent"
        expected_state_007
        expected_effects_049
    ; exact_case
        "sync/submission-reserved"
        "Mirror_inspected/stale-absent"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Graph_attached/current"
        expected_state_005
        expected_effects_055
    ; exact_case
        "sync/submission-reserved"
        "Graph_attached/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Graph_attachment_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/submission-reserved"
        "Graph_attachment_failed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Local_batch_prepared/current"
        expected_state_007
        expected_effects_057
    ; exact_case
        "sync/submission-reserved"
        "Local_batch_prepared/stale"
        expected_state_007
        expected_effects_009
    ; exact_case
        "sync/submission-reserved"
        "Local_batch_committed/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Local_batch_committed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Authoritative_batch_inspected/current"
        expected_state_007
        expected_effects_069
    ; exact_case
        "sync/submission-reserved"
        "Authoritative_batch_inspected/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Authoritative_batch_applied/current"
        expected_state_007
        expected_effects_066
    ; exact_case
        "sync/submission-reserved"
        "Authoritative_batch_applied/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Authoritative_batch_conflicted/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Authoritative_batch_conflicted/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Authoritative_batch_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/submission-reserved"
        "Authoritative_batch_failed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Outbox_transition_committed/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Outbox_transition_committed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Outbox_transition_rejected/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Outbox_transition_rejected/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Snapshot_activated/current"
        expected_state_007
        expected_effects_059
    ; exact_case
        "sync/submission-reserved"
        "Snapshot_activated/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Snapshot_activation_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/submission-reserved"
        "Snapshot_activation_failed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Runner_completed/success"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Runner_completed/failure"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Snapshot_download_progress/bounded"
        expected_state_007
        expected_effects_010
    ; exact_case
        "sync/submission-reserved"
        "Websocket_opened/current"
        expected_state_006
        expected_effects_070
    ; exact_case
        "sync/submission-reserved"
        "Websocket_opened/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Websocket_message/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Websocket_message/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Websocket_protocol_error/current"
        expected_state_061
        expected_effects_071
    ; exact_case
        "sync/submission-reserved"
        "Websocket_protocol_error/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Websocket_closed/current"
        expected_state_063
        expected_effects_072
    ; exact_case
        "sync/submission-reserved"
        "Websocket_closed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "sync/submission-reserved"
        "Shutdown/requested"
        expected_state_007
        expected_effects_032
    ; exact_case
        "sync/submitting"
        "Restore_local_account/valid"
        expected_state_033
        expected_effects_042
    ; exact_case
        "sync/submitting"
        "Account_authenticated/sign-in"
        expected_state_034
        expected_effects_043
    ; exact_case
        "sync/submitting"
        "Account_authenticated/sign-out"
        expected_state_035
        expected_effects_044
    ; exact_case
        "sync/submitting"
        "Local_feed_acknowledged/acknowledged"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Timeline_presented/presented"
        expected_state_073
        expected_effects_077
    ; exact_case
        "sync/submitting"
        "Token_provided/current"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Token_provided/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Token_rejected/current"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Token_rejected/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Graph_selected/catalog-member"
        expected_state_038
        expected_effects_046
    ; exact_case
        "sync/submitting"
        "Graph_selected/unknown"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Graph_picker_requested/requested"
        expected_state_040
        expected_effects_047
    ; exact_case
        "sync/submitting"
        "Catalog_refresh_requested/requested"
        expected_state_075
        expected_effects_078
    ; exact_case
        "sync/submitting"
        "Online_recovery_requested/requested"
        expected_state_008
        expected_effects_049
    ; exact_case
        "sync/submitting"
        "E2ee_password_submitted/valid"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "E2ee_password_submitted/invalid-empty"
        expected_state_054
        expected_effects_062
    ; exact_case
        "sync/submitting"
        "Local_cache_deletion_requested/current"
        expected_state_038
        expected_effects_051
    ; exact_case
        "sync/submitting"
        "Local_cache_deletion_requested/unknown"
        expected_state_008
        expected_effects_052
    ; exact_case
        "sync/submitting"
        "Foreground_changed/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Foreground_changed/background"
        expected_state_011
        expected_effects_068
    ; exact_case
        "sync/submitting"
        "Foreground_changed/foreground"
        expected_state_008
        expected_effects_064
    ; exact_case
        "sync/submitting"
        "Mirror_inspected/current-available"
        expected_state_008
        expected_effects_054
    ; exact_case
        "sync/submitting"
        "Mirror_inspected/current-absent"
        expected_state_008
        expected_effects_049
    ; exact_case
        "sync/submitting"
        "Mirror_inspected/stale-absent"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Graph_attached/current"
        expected_state_005
        expected_effects_055
    ; exact_case
        "sync/submitting"
        "Graph_attached/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Graph_attachment_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/submitting"
        "Graph_attachment_failed/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Local_batch_prepared/current"
        expected_state_008
        expected_effects_057
    ; exact_case
        "sync/submitting"
        "Local_batch_prepared/stale"
        expected_state_008
        expected_effects_009
    ; exact_case
        "sync/submitting"
        "Local_batch_committed/current"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Local_batch_committed/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Authoritative_batch_inspected/current"
        expected_state_008
        expected_effects_069
    ; exact_case
        "sync/submitting"
        "Authoritative_batch_inspected/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Authoritative_batch_applied/current"
        expected_state_007
        expected_effects_066
    ; exact_case
        "sync/submitting"
        "Authoritative_batch_applied/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Authoritative_batch_conflicted/current"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Authoritative_batch_conflicted/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Authoritative_batch_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/submitting"
        "Authoritative_batch_failed/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Outbox_transition_committed/current"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Outbox_transition_committed/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Outbox_transition_rejected/current"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Outbox_transition_rejected/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Snapshot_activated/current"
        expected_state_008
        expected_effects_059
    ; exact_case
        "sync/submitting"
        "Snapshot_activated/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Snapshot_activation_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/submitting"
        "Snapshot_activation_failed/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Runner_completed/success"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Runner_completed/failure"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Snapshot_download_progress/bounded"
        expected_state_008
        expected_effects_010
    ; exact_case
        "sync/submitting"
        "Websocket_opened/current"
        expected_state_006
        expected_effects_070
    ; exact_case
        "sync/submitting"
        "Websocket_opened/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Websocket_message/current"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Websocket_message/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Websocket_protocol_error/current"
        expected_state_061
        expected_effects_071
    ; exact_case
        "sync/submitting"
        "Websocket_protocol_error/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Websocket_closed/current"
        expected_state_063
        expected_effects_072
    ; exact_case
        "sync/submitting"
        "Websocket_closed/stale"
        expected_state_008
        expected_effects_003
    ; exact_case
        "sync/submitting"
        "Shutdown/requested"
        expected_state_008
        expected_effects_032
    ; exact_case
        "sync/paused"
        "Restore_local_account/valid"
        expected_state_033
        expected_effects_042
    ; exact_case
        "sync/paused"
        "Account_authenticated/sign-in"
        expected_state_034
        expected_effects_043
    ; exact_case
        "sync/paused"
        "Account_authenticated/sign-out"
        expected_state_035
        expected_effects_044
    ; exact_case
        "sync/paused"
        "Local_feed_acknowledged/acknowledged"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Timeline_presented/presented"
        expected_state_077
        expected_effects_079
    ; exact_case
        "sync/paused"
        "Token_provided/current"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Token_provided/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Token_rejected/current"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Token_rejected/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Graph_selected/catalog-member"
        expected_state_038
        expected_effects_046
    ; exact_case
        "sync/paused"
        "Graph_selected/unknown"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Graph_picker_requested/requested"
        expected_state_040
        expected_effects_047
    ; exact_case
        "sync/paused"
        "Catalog_refresh_requested/requested"
        expected_state_079
        expected_effects_080
    ; exact_case
        "sync/paused"
        "Online_recovery_requested/requested"
        expected_state_009
        expected_effects_049
    ; exact_case
        "sync/paused"
        "E2ee_password_submitted/valid"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "E2ee_password_submitted/invalid-empty"
        expected_state_054
        expected_effects_062
    ; exact_case
        "sync/paused"
        "Local_cache_deletion_requested/current"
        expected_state_038
        expected_effects_051
    ; exact_case
        "sync/paused"
        "Local_cache_deletion_requested/unknown"
        expected_state_009
        expected_effects_052
    ; exact_case
        "sync/paused"
        "Foreground_changed/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Foreground_changed/background"
        expected_state_011
        expected_effects_068
    ; exact_case
        "sync/paused"
        "Foreground_changed/foreground"
        expected_state_009
        expected_effects_064
    ; exact_case
        "sync/paused"
        "Mirror_inspected/current-available"
        expected_state_009
        expected_effects_054
    ; exact_case
        "sync/paused"
        "Mirror_inspected/current-absent"
        expected_state_009
        expected_effects_049
    ; exact_case
        "sync/paused"
        "Mirror_inspected/stale-absent"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Graph_attached/current"
        expected_state_005
        expected_effects_055
    ; exact_case
        "sync/paused"
        "Graph_attached/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Graph_attachment_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/paused"
        "Graph_attachment_failed/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Local_batch_prepared/current"
        expected_state_009
        expected_effects_057
    ; exact_case
        "sync/paused"
        "Local_batch_prepared/stale"
        expected_state_009
        expected_effects_009
    ; exact_case
        "sync/paused"
        "Local_batch_committed/current"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Local_batch_committed/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Authoritative_batch_inspected/current"
        expected_state_009
        expected_effects_069
    ; exact_case
        "sync/paused"
        "Authoritative_batch_inspected/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Authoritative_batch_applied/current"
        expected_state_007
        expected_effects_066
    ; exact_case
        "sync/paused"
        "Authoritative_batch_applied/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Authoritative_batch_conflicted/current"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Authoritative_batch_conflicted/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Authoritative_batch_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/paused"
        "Authoritative_batch_failed/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Outbox_transition_committed/current"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Outbox_transition_committed/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Outbox_transition_rejected/current"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Outbox_transition_rejected/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Snapshot_activated/current"
        expected_state_009
        expected_effects_059
    ; exact_case
        "sync/paused"
        "Snapshot_activated/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Snapshot_activation_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "sync/paused"
        "Snapshot_activation_failed/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Runner_completed/success"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Runner_completed/failure"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Snapshot_download_progress/bounded"
        expected_state_009
        expected_effects_010
    ; exact_case
        "sync/paused"
        "Websocket_opened/current"
        expected_state_006
        expected_effects_070
    ; exact_case
        "sync/paused"
        "Websocket_opened/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Websocket_message/current"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Websocket_message/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Websocket_protocol_error/current"
        expected_state_061
        expected_effects_071
    ; exact_case
        "sync/paused"
        "Websocket_protocol_error/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Websocket_closed/current"
        expected_state_063
        expected_effects_072
    ; exact_case
        "sync/paused"
        "Websocket_closed/stale"
        expected_state_009
        expected_effects_003
    ; exact_case
        "sync/paused"
        "Shutdown/requested"
        expected_state_009
        expected_effects_032
    ; exact_case
        "sync/failed"
        "Restore_local_account/valid"
        expected_state_015
        expected_effects_023
    ; exact_case
        "sync/failed"
        "Account_authenticated/sign-in"
        expected_state_023
        expected_effects_024
    ; exact_case
        "sync/failed"
        "Account_authenticated/sign-out"
        expected_state_017
        expected_effects_025
    ; exact_case
        "sync/failed"
        "Local_feed_acknowledged/acknowledged"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Timeline_presented/presented"
        expected_state_081
        expected_effects_081
    ; exact_case
        "sync/failed"
        "Token_provided/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Token_provided/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Token_rejected/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Token_rejected/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Graph_selected/catalog-member"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Graph_selected/unknown"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Graph_picker_requested/requested"
        expected_state_082
        expected_effects_082
    ; exact_case
        "sync/failed"
        "Catalog_refresh_requested/requested"
        expected_state_083
        expected_effects_083
    ; exact_case
        "sync/failed"
        "Online_recovery_requested/requested"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "E2ee_password_submitted/valid"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "E2ee_password_submitted/invalid-empty"
        expected_state_026
        expected_effects_031
    ; exact_case
        "sync/failed"
        "Local_cache_deletion_requested/current"
        expected_state_010
        expected_effects_019
    ; exact_case
        "sync/failed"
        "Local_cache_deletion_requested/unknown"
        expected_state_010
        expected_effects_020
    ; exact_case
        "sync/failed"
        "Foreground_changed/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Foreground_changed/background"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Foreground_changed/foreground"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Mirror_inspected/current-available"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Mirror_inspected/current-absent"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Mirror_inspected/stale-absent"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Graph_attached/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Graph_attached/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Graph_attachment_failed/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Graph_attachment_failed/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Local_batch_prepared/current"
        expected_state_010
        expected_effects_008
    ; exact_case
        "sync/failed"
        "Local_batch_prepared/stale"
        expected_state_010
        expected_effects_009
    ; exact_case
        "sync/failed"
        "Local_batch_committed/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Local_batch_committed/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Authoritative_batch_inspected/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Authoritative_batch_inspected/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Authoritative_batch_applied/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Authoritative_batch_applied/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Authoritative_batch_conflicted/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Authoritative_batch_conflicted/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Authoritative_batch_failed/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Authoritative_batch_failed/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Outbox_transition_committed/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Outbox_transition_committed/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Outbox_transition_rejected/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Outbox_transition_rejected/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Snapshot_activated/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Snapshot_activated/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Snapshot_activation_failed/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Snapshot_activation_failed/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Runner_completed/success"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Runner_completed/failure"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Snapshot_download_progress/bounded"
        expected_state_010
        expected_effects_010
    ; exact_case
        "sync/failed"
        "Websocket_opened/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Websocket_opened/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Websocket_message/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Websocket_message/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Websocket_protocol_error/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Websocket_protocol_error/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Websocket_closed/current"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Websocket_closed/stale"
        expected_state_010
        expected_effects_003
    ; exact_case
        "sync/failed"
        "Shutdown/requested"
        expected_state_010
        expected_effects_032
    ; exact_case
        "lifecycle/backgrounded"
        "Restore_local_account/valid"
        expected_state_033
        expected_effects_084
    ; exact_case
        "lifecycle/backgrounded"
        "Account_authenticated/sign-in"
        expected_state_034
        expected_effects_085
    ; exact_case
        "lifecycle/backgrounded"
        "Account_authenticated/sign-out"
        expected_state_035
        expected_effects_086
    ; exact_case
        "lifecycle/backgrounded"
        "Local_feed_acknowledged/acknowledged"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Timeline_presented/presented"
        expected_state_084
        expected_effects_087
    ; exact_case
        "lifecycle/backgrounded"
        "Token_provided/current"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Token_provided/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Token_rejected/current"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Token_rejected/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Graph_selected/catalog-member"
        expected_state_086
        expected_effects_088
    ; exact_case
        "lifecycle/backgrounded"
        "Graph_selected/unknown"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Graph_picker_requested/requested"
        expected_state_040
        expected_effects_047
    ; exact_case
        "lifecycle/backgrounded"
        "Catalog_refresh_requested/requested"
        expected_state_087
        expected_effects_089
    ; exact_case
        "lifecycle/backgrounded"
        "Online_recovery_requested/requested"
        expected_state_011
        expected_effects_049
    ; exact_case
        "lifecycle/backgrounded"
        "E2ee_password_submitted/valid"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "E2ee_password_submitted/invalid-empty"
        expected_state_054
        expected_effects_062
    ; exact_case
        "lifecycle/backgrounded"
        "Local_cache_deletion_requested/current"
        expected_state_038
        expected_effects_051
    ; exact_case
        "lifecycle/backgrounded"
        "Local_cache_deletion_requested/unknown"
        expected_state_011
        expected_effects_052
    ; exact_case
        "lifecycle/backgrounded"
        "Foreground_changed/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Foreground_changed/background"
        expected_state_011
        expected_effects_068
    ; exact_case
        "lifecycle/backgrounded"
        "Foreground_changed/foreground"
        expected_state_011
        expected_effects_064
    ; exact_case
        "lifecycle/backgrounded"
        "Mirror_inspected/current-available"
        expected_state_011
        expected_effects_054
    ; exact_case
        "lifecycle/backgrounded"
        "Mirror_inspected/current-absent"
        expected_state_011
        expected_effects_049
    ; exact_case
        "lifecycle/backgrounded"
        "Mirror_inspected/stale-absent"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Graph_attached/current"
        expected_state_005
        expected_effects_055
    ; exact_case
        "lifecycle/backgrounded"
        "Graph_attached/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Graph_attachment_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "lifecycle/backgrounded"
        "Graph_attachment_failed/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Local_batch_prepared/current"
        expected_state_011
        expected_effects_057
    ; exact_case
        "lifecycle/backgrounded"
        "Local_batch_prepared/stale"
        expected_state_011
        expected_effects_009
    ; exact_case
        "lifecycle/backgrounded"
        "Local_batch_committed/current"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Local_batch_committed/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Authoritative_batch_inspected/current"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Authoritative_batch_inspected/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Authoritative_batch_applied/current"
        expected_state_007
        expected_effects_066
    ; exact_case
        "lifecycle/backgrounded"
        "Authoritative_batch_applied/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Authoritative_batch_conflicted/current"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Authoritative_batch_conflicted/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Authoritative_batch_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "lifecycle/backgrounded"
        "Authoritative_batch_failed/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Outbox_transition_committed/current"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Outbox_transition_committed/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Outbox_transition_rejected/current"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Outbox_transition_rejected/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Snapshot_activated/current"
        expected_state_011
        expected_effects_059
    ; exact_case
        "lifecycle/backgrounded"
        "Snapshot_activated/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Snapshot_activation_failed/current"
        expected_state_057
        expected_effects_065
    ; exact_case
        "lifecycle/backgrounded"
        "Snapshot_activation_failed/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Runner_completed/success"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Runner_completed/failure"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Snapshot_download_progress/bounded"
        expected_state_011
        expected_effects_010
    ; exact_case
        "lifecycle/backgrounded"
        "Websocket_opened/current"
        expected_state_006
        expected_effects_070
    ; exact_case
        "lifecycle/backgrounded"
        "Websocket_opened/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Websocket_message/current"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Websocket_message/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Websocket_protocol_error/current"
        expected_state_061
        expected_effects_071
    ; exact_case
        "lifecycle/backgrounded"
        "Websocket_protocol_error/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Websocket_closed/current"
        expected_state_063
        expected_effects_072
    ; exact_case
        "lifecycle/backgrounded"
        "Websocket_closed/stale"
        expected_state_011
        expected_effects_003
    ; exact_case
        "lifecycle/backgrounded"
        "Shutdown/requested"
        expected_state_011
        expected_effects_090
    ; exact_case
        "lifecycle/closed"
        "Restore_local_account/valid"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Account_authenticated/sign-in"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Account_authenticated/sign-out"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Local_feed_acknowledged/acknowledged"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Timeline_presented/presented"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Token_provided/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Token_provided/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Token_rejected/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Token_rejected/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Graph_selected/catalog-member"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Graph_selected/unknown"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Graph_picker_requested/requested"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Catalog_refresh_requested/requested"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Online_recovery_requested/requested"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "E2ee_password_submitted/valid"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "E2ee_password_submitted/invalid-empty"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Local_cache_deletion_requested/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Local_cache_deletion_requested/unknown"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Foreground_changed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Foreground_changed/background"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Foreground_changed/foreground"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Mirror_inspected/current-available"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Mirror_inspected/current-absent"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Mirror_inspected/stale-absent"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Graph_attached/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Graph_attached/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Graph_attachment_failed/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Graph_attachment_failed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Local_batch_prepared/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Local_batch_prepared/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Local_batch_committed/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Local_batch_committed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Authoritative_batch_inspected/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Authoritative_batch_inspected/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Authoritative_batch_applied/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Authoritative_batch_applied/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Authoritative_batch_conflicted/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Authoritative_batch_conflicted/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Authoritative_batch_failed/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Authoritative_batch_failed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Outbox_transition_committed/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Outbox_transition_committed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Outbox_transition_rejected/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Outbox_transition_rejected/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Snapshot_activated/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Snapshot_activated/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Snapshot_activation_failed/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Snapshot_activation_failed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Runner_completed/success"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Runner_completed/failure"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Snapshot_download_progress/bounded"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Websocket_opened/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Websocket_opened/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Websocket_message/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Websocket_message/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Websocket_protocol_error/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Websocket_protocol_error/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Websocket_closed/current"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Websocket_closed/stale"
        expected_state_007
        expected_effects_003
    ; exact_case
        "lifecycle/closed"
        "Shutdown/requested"
        expected_state_007
        expected_effects_003
    ]
  in
  let duplicates values =
    values
    |> List.sort String.compare
    |> List.fold_left
         (fun (previous, duplicates) value ->
            match previous with
            | Some previous when String.equal previous value ->
              Some value, value :: duplicates
            | Some _ | None -> Some value, duplicates)
         (None, [])
    |> snd
    |> List.sort_uniq String.compare
  in
  let checkpoint_names =
    List.map (fun (checkpoint : checkpoint) -> checkpoint.name) checkpoints
  in
  let event_names = List.map (fun (event : event_case) -> event.name) events in
  Alcotest.(check (list string))
    "checkpoint names are unique"
    []
    (duplicates checkpoint_names);
  Alcotest.(check (list string)) "event-case names are unique" [] (duplicates event_names);
  let covered_constructor_names =
    events
    |> List.map (fun event -> event.event_constructor)
    |> List.sort_uniq String.compare
  in
  let unavailable_constructor_names = List.map fst intentionally_unconstructible_events in
  Alcotest.(check (list string))
    "every event constructor is covered or explicitly unavailable"
    (List.sort String.compare expected_event_constructor_names)
    (List.sort String.compare (covered_constructor_names @ unavailable_constructor_names));
  let declared_pairs =
    List.concat_map
      (fun checkpoint_name ->
         List.map (fun event_name -> checkpoint_name ^ " x " ^ event_name) event_names)
      checkpoint_names
    |> List.sort String.compare
  in
  let case_pairs =
    List.map
      (fun transition_case ->
         transition_case.origin.name ^ " x " ^ transition_case.event.name)
      transition_cases
  in
  Alcotest.(check (list string))
    "every checkpoint/event pair has exactly one transition case"
    []
    (duplicates case_pairs);
  Alcotest.(check (list string))
    "transition cases contain exactly the declared matrix"
    declared_pairs
    (List.sort String.compare case_pairs);
  List.iter
    (fun (checkpoint : checkpoint) ->
       let actual = view_state checkpoint.core in
       if actual <> checkpoint.expected_view
       then
         fail
           "checkpoint %s changed %s; expected %s but got %s"
           checkpoint.name
           (first_state_difference checkpoint.expected_view actual)
           (show_state_view checkpoint.expected_view)
           (show_state_view actual))
    checkpoints;
  List.iter
    (fun transition_case ->
       let cell = transition_case.origin.name ^ " x " ^ transition_case.event.name in
       let checkpoint_core = transition_case.origin.core in
       let state_before = view_state checkpoint_core in
       let first =
         try Core.step checkpoint_core transition_case.event.event with
         | exn -> fail "%s raised %s" cell (Printexc.to_string exn)
       in
       let actual_next = view_state first.next in
       if actual_next <> transition_case.expected_next
       then
         fail
           "%s changed %s; expected %s but got %s"
           cell
           (first_state_difference transition_case.expected_next actual_next)
           (show_state_view transition_case.expected_next)
           (show_state_view actual_next);
       let actual_effects = List.map view_instruction first.effects in
       if actual_effects <> transition_case.expected_effects
       then
         fail
           "%s %s"
           cell
           (first_effect_difference transition_case.expected_effects actual_effects);
       let state_after = view_state checkpoint_core in
       if state_after <> state_before
       then
         fail
           "%s mutated its input Core.t at %s; before %s but after %s"
           cell
           (first_state_difference state_before state_after)
           (show_state_view state_before)
           (show_state_view state_after);
       let replay =
         try Core.step checkpoint_core transition_case.event.event with
         | exn -> fail "%s replay raised %s" cell (Printexc.to_string exn)
       in
       let replay_next = view_state replay.next in
       let replay_effects = List.map view_instruction replay.effects in
       if replay_next <> actual_next
       then
         fail
           "%s replay changed %s; first %s but replay %s"
           cell
           (first_state_difference actual_next replay_next)
           (show_state_view actual_next)
           (show_state_view replay_next);
       if replay_effects <> actual_effects
       then
         fail "%s replay %s" cell (first_effect_difference actual_effects replay_effects))
    transition_cases
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
      "exact pure reducer transition cases"
      `Quick
      test_exact_pure_reducer_transition_cases
  ]
;;
