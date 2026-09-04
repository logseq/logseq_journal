module Graph_service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let envelope tag payload =
  let bytes = Bytes.make (32 + Bytes.length payload) '\000' in
  Bytes.blit_string "LJP2" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 2;
  Bytes.set_uint16_le bytes 6 tag;
  Bytes.set_int32_le bytes 24 (Int32.of_int (Bytes.length payload));
  Bytes.blit payload 0 bytes 32 (Bytes.length payload);
  bytes
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

let test_application_platform_calendar_codec () =
  require
    (Bytes.length Journal_platform.get_calendar_request = 32
     && Bytes.sub_string Journal_platform.get_calendar_request 0 4 = "LJP2")
    "application calendar request envelope changed";
  let locale = "en_US" in
  let time_zone = "Europe/Paris" in
  let bytes = Bytes.make (56 + String.length locale + String.length time_zone) '\000' in
  Bytes.blit_string "LJP1" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 1;
  Bytes.set_uint16_le bytes 6 3;
  Bytes.set_uint16_le bytes 8 2;
  Bytes.set_uint16_le bytes 10 (String.length locale);
  Bytes.set_uint16_le bytes 12 (String.length time_zone);
  Bytes.set_int64_le bytes 16 1_786_055_400_000L;
  Bytes.set_int32_le bytes 24 (Int32.of_int 20260807);
  Bytes.set_uint16_le bytes 28 30;
  Bytes.set_int32_le bytes 32 (Int32.of_int 7200);
  Bytes.set_int64_le bytes 40 8L;
  Bytes.set_int64_le bytes 48 4L;
  Bytes.blit_string locale 0 bytes 56 (String.length locale);
  Bytes.blit_string
    time_zone
    0
    bytes
    (56 + String.length locale)
    (String.length time_zone);
  match Journal_platform.decode_calendar (envelope 3 bytes) with
  | Error error -> fail "platform calendar decode failed: %s" error
  | Ok decoded ->
    require (decoded.snapshot.local_day = 20260807) "calendar day changed";
    require (Int64.equal decoded.snapshot.generation 8L) "calendar generation changed"
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
    ; selected_graph = Some graph_id
    ; applied_server_t = Some 11
    ; timeline_presentation_pending
    ; startup =
        { authenticated
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

let () =
  test_exact_codec_and_round_trip ();
  test_bounded_rejection ();
  test_application_platform_calendar_codec ();
  test_startup_phase_is_owned_by_ui_domain ();
  test_ready_is_independent_of_sync_activity ();
  test_stale_graph_generation_and_structured_failures ()
;;
