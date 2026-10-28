let server_cursor_of_int value =
  Logseq_db_types.Server_cursor.of_int64 (Int64.of_int value) |> Result.get_ok
;;

module Graph_service = Logseq_db_worker_lui.Logseq_db_worker_lui_service

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let sample : Journal_startup.t =
  Logseq_db_worker.Config.create
    ~application_support_directory:"/tmp/support"
    ~target:(Managed_sync { base_url = "https://api.logseq.io" })
    ~compatibility_profile:Logseq_65_33_or_newer
    ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
    ~default_page_size:Logseq_db_worker.Protocol.default_page_size
  |> Result.get_ok
;;

let encode_exn value =
  match Journal_startup.encode value with
  | Ok bytes -> bytes
  | Error error ->
    fail "unexpected encode error: %s" (Journal_startup.Error.to_string error)
;;

let decode_exn bytes =
  match Journal_startup.decode bytes with
  | Ok value -> value
  | Error error ->
    fail "unexpected decode error: %s" (Journal_startup.Error.to_string error)
;;

let require_decode_error bytes =
  match Journal_startup.decode bytes with
  | Error _ -> ()
  | Ok _ -> fail "expected startup decode error"
;;

let test_exact_codec_and_round_trip () =
  let encoded = encode_exn sample in
  require (Bytes.sub_string encoded 0 4 = "LDB1") "startup magic changed";
  require
    (Int32.to_int (Bytes.get_int32_le encoded 4) = Bytes.length encoded - 8)
    "startup JSON length changed";
  let json = Bytes.sub_string encoded 8 (Bytes.length encoded - 8) in
  require (not (String.contains json '\000')) "startup JSON contains NUL";
  let decoded = decode_exn encoded in
  require
    (String.equal
       decoded.application_support_directory
       sample.application_support_directory)
    "application-support directory changed";
  match decoded.target with
  | Managed_sync { base_url } ->
    require (String.equal base_url "https://api.logseq.io") "managed sync origin changed"
;;

let test_bounded_rejection () =
  let encoded = encode_exn sample in
  require_decode_error Bytes.empty;
  require_decode_error (Bytes.make ((1024 * 1024) + 1) '\000');
  require_decode_error (Bytes.sub encoded 0 7);
  let bad_magic = Bytes.copy encoded in
  Bytes.set bad_magic 0 'X';
  require_decode_error bad_magic;
  require_decode_error (Bytes.cat encoded (Bytes.of_string "x"));
  let bad_json = Bytes.copy encoded in
  Bytes.set bad_json 8 '\xff';
  require_decode_error bad_json
;;

let graph_id =
  Logseq_db_types.Graph_types.Uuid.of_string "20000000-0000-4000-8000-000000000002"
  |> Result.get_ok
;;

let startup_snapshot
      ?(sync_phase = Graph_service.Offline)
      ?(authenticated = true)
      ?(catalog_loading = false)
      ?(awaiting_selection = false)
      ?(restoring_local = false)
      ?(bootstrapping = false)
      ?(awaiting_e2ee_password = false)
      ?failure
      ?(graph_generation = 7)
      ?(timeline_presentation_pending = false)
      ()
  =
  Graph_service.
    { sync_phase
    ; catalog = []
    ; resident_graphs=[];resident_scopes=[]
    ; selected_graph = Some graph_id
    ; applied_server_t = Some (server_cursor_of_int 11)
    ; unlock = Logseq_sync_pure_reducer.Core.Unlock_inactive
    ; timeline_presentation_pending
    ; startup =
        { authenticated
        ; local_access = Graph_service.Local_pending
        ; network_phase = Graph_service.Local_only
        ; catalog_loading
        ; awaiting_selection
        ; restoring_local
        ; bootstrapping
        ; awaiting_e2ee_password
        ; failure
        ; account_generation = 3
        ; graph_generation
        ; presentation_generation = 5
        }
    ; local_deletion = None
    ; last_error_attention = None
    ; last_error = Option.map (fun _ -> "startup failed") failure
    }
;;

let graph_state ?(generation = 7) ?(phase = Logseq_db_worker.Graph_open) ?error () =
  Logseq_db_worker.{ generation; graph_id = Some graph_id; phase; error }
;;

let worker_error message =
  Logseq_db_worker.Error.create
    ~code:Logseq_db_worker.Error.Closed_session
    ~message
    ~details:[]
  |> Result.get_ok
;;

let require_startup_phase expected snapshot graph message =
  let actual = Journal_startup.derive ~snapshot ~graph in
  require (actual.Journal_startup.phase = expected) "%s" message;
  actual
;;

let test_startup_phase_is_owned_by_ui_domain () =
  ignore
    (require_startup_phase
       Journal_startup.Signed_out
       (startup_snapshot ~authenticated:false ())
       (graph_state ~phase:Graph_closed ())
       "signed-out startup was not derived");
  ignore
    (require_startup_phase
       Loading_catalog
       (startup_snapshot ~catalog_loading:true ())
       (graph_state ~phase:Graph_closed ())
       "catalog startup was not derived");
  ignore
    (require_startup_phase
       Awaiting_selection
       (startup_snapshot ~awaiting_selection:true ())
       (graph_state ~phase:Graph_closed ())
       "selection startup was not derived");
  ignore
    (require_startup_phase
       Restoring_local
       (startup_snapshot ~restoring_local:true ~timeline_presentation_pending:true ())
       (graph_state ())
       "local restore startup was not derived");
  ignore
    (require_startup_phase
       Bootstrapping
       (startup_snapshot ~bootstrapping:true ())
       (graph_state ~phase:Graph_closed ())
       "bootstrap startup was not derived");
  ignore
    (require_startup_phase
       Awaiting_e2ee_password
       (startup_snapshot ~awaiting_e2ee_password:true ())
       (graph_state ~phase:Graph_closed ())
       "E2EE startup was not derived")
;;

let test_ready_is_independent_of_sync_activity () =
  List.iter
    (fun sync_phase ->
       ignore
         (require_startup_phase
            Journal_startup.Ready
            (startup_snapshot ~sync_phase ())
            (graph_state ())
            "open presented graph did not remain ready"))
    Graph_service.[ Offline; Connecting; Pulling; Submitting; Current; Paused ];
  ignore
    (require_startup_phase
       Journal_startup.Restoring_local
       (startup_snapshot ~sync_phase:Current ())
       (graph_state ~phase:Graph_closed ())
       "Current sync incorrectly implied an open graph");
  ignore
    (require_startup_phase
       Journal_startup.Restoring_local
       (startup_snapshot ~sync_phase:Current ~timeline_presentation_pending:true ())
       (graph_state ())
       "Current sync incorrectly bypassed presentation")
;;

let test_stale_graph_generation_and_structured_failures () =
  ignore
    (require_startup_phase
       Journal_startup.Restoring_local
       (startup_snapshot ())
       (graph_state ~generation:6 ())
       "stale graph generation made startup ready");
  let state =
    require_startup_phase
      Journal_startup.Failed
      (startup_snapshot ())
      (graph_state ~phase:Graph_failed ~error:(worker_error "engine unavailable") ())
      "graph failure did not fail startup"
  in
  match state.error with
  | Some { owner = Journal_startup.Graph; message; recovery = Some Retry_graph_open } ->
    require (String.equal message "engine unavailable") "graph error message changed"
  | None | Some _ -> fail "graph failure did not expose structured recovery"
;;

let test_noncurrent_deletion_keeps_active_graph_ready () =
  List.iter (fun local_deletion ->
    let snapshot = { (startup_snapshot ()) with local_deletion = Some local_deletion } in
    let derived = Journal_startup.derive ~snapshot ~graph:(graph_state ()) in
    require (derived.phase = Journal_startup.Ready)
      "non-current deletion displaced the active graph")
    [ Graph_service.Deletion_in_progress Deleting_mirror; Deletion_failed Deleting_mirror ]
;;

let test_stable_startup_presentation () =
  let open Journal_startup in
  let module P = Journal_startup.Presentation in
  let observe ?manager ?(graph=graph_state ()) ?(graph_ready=false)
      ?(feed_loaded=false) ?(password_pending=false) ?(graph_error=false) t =
    P.step t (Observe {manager;graph;graph_ready;feed_loaded;password_pending;graph_error}) in
  let timer t = Option.get (P.loading_request t) in
  let account t result = P.step t (Account (P.account_ticket t,result)) in
  let cases=[
    "anonymous local restore is not signed out",(fun () ->
      let phase=Journal_startup.derive ~snapshot:(startup_snapshot ~authenticated:false ~restoring_local:true ())
          ~graph:(graph_state ~phase:Graph_closed ()) in
      require (phase.phase=Restoring_local) "local restore flashes signed-out UI";
      let phase=Journal_startup.derive ~snapshot:(startup_snapshot ~authenticated:false ~failure:During_local_restore ())
          ~graph:(graph_state ~phase:Graph_closed ()) in
      require (phase.phase=Failed) "anonymous restore failure hides recovery");
    "initial and unresolved account stay blank",(fun () ->
      let t=P.create () in
      require (P.screen t=Waiting && not(P.loading_indicator t) && P.loading_request t<>None)
        "initial startup mounts transient Timeline or immediate spinner";
      let t=observe ~manager:(startup_snapshot ~authenticated:false ()) ~graph:(graph_state ~phase:Graph_closed ()) t in
      require (P.screen t=Waiting) "account discovery flashes sign-in";
      let t=account t Local in
      let t=observe ~manager:(startup_snapshot ~authenticated:false ~restoring_local:true ()) ~graph:(graph_state ~phase:Graph_closed ()) t in
      require (P.screen t=Waiting) "local binding restore flashes intermediate page");
    "one 100ms grace spans catalog restore and first feed",(fun () ->
      let t=observe ~manager:(startup_snapshot ~catalog_loading:true ()) ~graph:(graph_state ~phase:Graph_closed ()) (P.create ()) in
      let key=timer t in
      let early=P.step t (Elapsed(key,0.099)) in
      require (not(P.loading_indicator early)) "99ms shows loading";
      require (P.step early (Elapsed(key,0.099999999))==early)
        "one nanosecond before 100ms shows loading";
      let t=observe ~manager:(startup_snapshot ~restoring_local:true ()) early in
      require (timer t=key) "busy phase restarts grace";
      let slow=P.step t (Elapsed(key,0.1)) in
      require (P.screen slow=Waiting && P.loading_indicator slow) "100ms waiting has no loading";
      require (P.step slow (Elapsed(key,0.2))==slow) "duplicate elapsed changes owner";
      let ready=observe ~manager:(startup_snapshot ()) ~graph_ready:true ~feed_loaded:true slow in
      require (P.screen ready=Timeline && not(P.loading_indicator ready)) "ready body retains loading";
      require (P.step ready (Elapsed(key,2.))==ready) "late timer changes ready Timeline");
    "Graph_open waits for first feed and an empty feed completes",(fun () ->
      let t=observe ~manager:(startup_snapshot ()) ~graph_ready:true (P.create ()) in
      require (P.screen t=Waiting) "Graph_open mounts feed's transient loading page";
      let ready=observe ~manager:(startup_snapshot ~timeline_presentation_pending:true ())
        ~graph_ready:true ~feed_loaded:true t in
      require (P.screen ready=Timeline) "presentation handshake or empty feed deadlocks Timeline";
      let refreshing=observe ~manager:(startup_snapshot ~sync_phase:Pulling ~catalog_loading:true ())
        ~graph_ready:true ~feed_loaded:true ready in
      require (P.screen refreshing=Timeline) "cached background refresh hides existing content");
    "required input and errors remain immediately available",(fun () ->
      let t=account (P.create ()) No_user in
      require (match P.screen t with Interaction {phase=Signed_out;_}->true|_->false) "signed-out result is hidden";
      List.iter(fun phase ->
        let snapshot=match phase with
          | Awaiting_selection -> startup_snapshot ~awaiting_selection:true ()
          | Awaiting_e2ee_password -> startup_snapshot ~awaiting_e2ee_password:true ()
          | _ -> startup_snapshot ~failure:During_bootstrap () in
        let t=observe ~manager:snapshot ~graph:(graph_state ~phase:Graph_closed ()) (P.create ()) in
        require (match P.screen t with Interaction s->s.phase=phase|_->false) "required input/failure is masked";
        require (not(P.loading_indicator t)) "required input is covered by startup loading")
        [Awaiting_selection;Awaiting_e2ee_password;Failed]);
    "unlock submission retains its form and does not remount busy page",(fun () ->
      let t=observe ~manager:(startup_snapshot ~awaiting_e2ee_password:true ())
        ~graph:(graph_state ~phase:Graph_closed ()) (P.create ()) in
      let pending=observe ~manager:(startup_snapshot ~bootstrapping:true ())
        ~graph:(graph_state ~phase:Graph_closed ()) ~password_pending:true t in
      require (match P.screen pending with Interaction {phase=Awaiting_e2ee_password;_}->true|_->false)
        "password submission flashes a different waiting page");
    "account lookup failure Retry and stale replies",(fun () ->
      let initial=P.create () in let old=P.account_ticket initial in
      let failed=P.step initial (Account_error old) in
      require (P.screen failed=Account_failure) "lookup failure has no explicit recovery";
      let retry=P.step failed Retry in
      require (P.screen retry=Waiting && not(P.loading_indicator retry) && P.account_ticket retry<>old)
        "Retry does not start fresh discovery/grace";
      require (P.step retry (Account(old,No_user))==retry) "old account result replaces retry";
      require (P.step retry (Account_error old)==retry) "old lookup failure replaces retry");
    "local offline recovery is independent of online auth and assets",(fun () ->
      let t=account (P.create ()) Local in
      let t=P.step t (Account_error(P.account_ticket t)) in
      let ready=observe ~manager:(startup_snapshot ~sync_phase:Offline ())
        ~graph_ready:true ~feed_loaded:true t in
      require (P.screen ready=Timeline) "valid cached Timeline waits for online auth/assets");
    "graph replacement rejects old ready data and old timer",(fun () ->
      let ready=observe ~manager:(startup_snapshot ()) ~graph_ready:true ~feed_loaded:true (P.create ()) in
      let other={ (startup_snapshot ~graph_generation:8 ()) with selected_graph=Some graph_id } in
      let waiting=observe ~manager:other ~graph:(graph_state ~generation:7 ())
        ~graph_ready:true ~feed_loaded:true ready in
      require (P.screen waiting=Waiting) "stale graph falsely publishes ready data";
      let key=timer waiting in
      let picker=observe ~manager:(startup_snapshot ~awaiting_selection:true ~graph_generation:8 ())
        ~graph:(graph_state ~phase:Graph_closed ~generation:8 ()) waiting in
      let fresh=observe ~manager:(startup_snapshot ~graph_generation:9 ~restoring_local:true ())
        ~graph:(graph_state ~phase:Graph_opening ~generation:9 ()) picker in
      require (timer fresh<>key && P.step fresh (Elapsed(key,1.))==fresh)
        "old graph journey timer enables new loading");
    "background interruption fences elapsed and resumes a fresh grace",(fun () ->
      let t=observe ~manager:(startup_snapshot ~restoring_local:true ()) (P.create ()) in
      let old=timer t in let inactive=P.step t (Foreground false) in
      require (P.loading_request inactive=None && P.step inactive (Elapsed(old,1.))==inactive)
        "background keeps an active loading timer";
      let resumed=P.step inactive (Foreground true) in
      require (timer resumed<>old && not(P.loading_indicator resumed)) "resume reuses old grace";
      require (P.step resumed (Elapsed(old,3600.))==resumed) "late background timer changes resume";
      let key=timer resumed in
      require (P.step resumed (Elapsed(key,0.099999999))==resumed)
        "resume counts suspended time towards its fresh grace";
      require (P.loading_indicator (P.step resumed (Elapsed(key,0.1))))
        "resume does not show loading after its fresh 100ms grace");
    "negative/NaN elapsed and explicit signout are safe",(fun () ->
      let t=observe ~manager:(startup_snapshot ~restoring_local:true ()) (P.create ()) in
      let key=timer t in
      require (P.step t (Elapsed(key,-1.))==t && P.step t (Elapsed(key,nan))==t) "invalid elapsed changes owner";
      let signed=P.step t P.Signed_out in
      require (match P.screen signed with Interaction {phase=Signed_out;_}->true|_->false) "signout entry is hidden";
      require (P.step signed (Elapsed(key,2.))==signed) "signout leaves stale timer active")
  ] in
  let failures=ref [] in
  List.iter(fun(name,test)->try test () with error->
    Printf.eprintf "STARTUP_RED %s: %s\n%!" name (Printexc.to_string error);failures:=name::!failures) cases;
  require (!failures=[]) "Startup regressions: %s" (String.concat ", " (List.rev !failures))
;;

(* Startup recovery projection owns action choice, not Core challenge storage. *)
let test_e2ee_recovery_requires_a_prepared_challenge () =
  List.iter (fun ready ->
    let state = Journal_startup.derive
      ~snapshot:(startup_snapshot ~failure:During_e2ee ~awaiting_e2ee_password:ready ())
      ~graph:(graph_state ~phase:Graph_closed ()) in
    require (state.phase = Failed) "E2EE failure was hidden";
    let expected = if ready then Journal_startup.Submit_e2ee_password
      else Journal_startup.Begin_online_recovery in
    require (Option.bind state.error (fun error -> error.Journal_startup.recovery)
      = Some expected) "E2EE recovery offers password without a prepared challenge") [false;true]
;;

let test_online_key_recovery_can_present_its_password_challenge () =
  List.iter (fun failed ->
    let snapshot=startup_snapshot ~awaiting_e2ee_password:true ?failure:(if failed then Some Graph_service.During_e2ee else None) () in
    let snapshot={snapshot with startup={snapshot.startup with
      local_access=Graph_service.Local_unavailable Graph_service.Local_key_unavailable;
      network_phase=Graph_service.Online_by_user}} in
    let derived=Journal_startup.derive ~snapshot ~graph:(graph_state ~phase:Graph_closed ()) in
    if failed then
      require (Option.bind derived.error (fun e->e.Journal_startup.recovery)=Some Journal_startup.Submit_e2ee_password)
        "failed prepared challenge must still permit password retry"
    else require (derived.phase=Journal_startup.Awaiting_e2ee_password)
      "explicit recovery must show its prepared password challenge"
  ) [false;true]
;;

let test_local_timeline_does_not_require_online_authentication () =
  let snapshot = startup_snapshot ~authenticated:false ~timeline_presentation_pending:true () in
  let snapshot = {snapshot with startup={snapshot.startup with local_access=Graph_service.Local_available}} in
  let module P = Journal_startup.Presentation in
  let t = P.create () in
  let t = P.step t (Account(P.account_ticket t,Local)) in
  let t = P.step t (Observe {manager=Some snapshot;graph=graph_state ();graph_ready=true;
    feed_loaded=true;password_pending=false;graph_error=false}) in
  require (P.screen t=P.Timeline) "usable local graph must render before authentication/appearance";
  let unavailable = {snapshot with startup={snapshot.startup with
    local_access=Graph_service.Local_unavailable Graph_service.Local_mirror_unavailable;
    restoring_local=false}} in
  let t = P.step t (Observe {manager=Some unavailable;graph=graph_state ~phase:Graph_closed ();
    graph_ready=false;feed_loaded=false;password_pending=false;graph_error=false}) in
  require (match P.screen t with Interaction {phase=Failed;_}->true|_->false)
    "missing mirror must stop loading"
;;

let () =
  test_online_key_recovery_can_present_its_password_challenge ();
  test_local_timeline_does_not_require_online_authentication ();
  test_e2ee_recovery_requires_a_prepared_challenge ();
  test_stable_startup_presentation ();
  test_noncurrent_deletion_keeps_active_graph_ready ();
  test_exact_codec_and_round_trip ();
  test_bounded_rejection ();
  test_startup_phase_is_owned_by_ui_domain ();
  test_ready_is_independent_of_sync_activity ();
  test_stale_graph_generation_and_structured_failures ()
;;
