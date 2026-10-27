let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error message -> fail "unexpected platform error: %s" message
;;

let envelope ?(runtime_generation = 0L) ?(graph_generation = 0L) tag payload =
  let bytes = Bytes.make (32 + Bytes.length payload) '\000' in
  Bytes.blit_string "LJP2" 0 bytes 0 4;
  Bytes.set_uint16_le bytes 4 2;
  Bytes.set_uint16_le bytes 6 tag;
  Bytes.set_int64_le bytes 8 runtime_generation;
  Bytes.set_int64_le bytes 16 graph_generation;
  Bytes.set_int32_le bytes 24 (Int32.of_int (Bytes.length payload));
  Bytes.blit payload 0 bytes 32 (Bytes.length payload);
  bytes
;;

let lifecycle_packet ~kind ~generation =
  let payload = Bytes.make 16 '\000' in
  Bytes.blit_string "LJP1" 0 payload 0 4;
  Bytes.set_uint16_le payload 4 1;
  Bytes.set_uint16_le payload 6 kind;
  Bytes.set_int64_le payload 8 generation;
  envelope 15 payload
;;

let test_auth_capability_envelopes_are_bounded_and_protocol_free () =
  require
    (Bytes.get_uint16_le Journal_platform.authenticated_user_request 6 = 6)
    "authenticated-user request tag differs";
  let authenticated =
    envelope 7 (Bytes.of_string {|{"userId":"cognito-user-1"}|})
    |> Journal_platform.decode_authenticated_user
    |> require_ok
  in
  require (authenticated = Some "cognito-user-1") "authenticated-user response changed";
  require
    (Journal_platform.decode_authenticated_user
       (envelope 7 (Bytes.of_string {|{"userId":null}|})) = Ok None)
    "explicit absent authenticated user was rejected";
  let token =
    envelope
      9
      (Bytes.of_string {|{"challengeId":"challenge-1","token":"fresh-id-token"}|})
    |> Journal_platform.decode_id_token_response ~challenge_id:"challenge-1"
    |> require_ok
  in
  require (String.equal token "fresh-id-token") "fresh ID token response changed"
;;

let test_scoped_authentication_preserves_identity () =
  let packet = envelope 7 (Bytes.of_string
    {|{"userId":"synthetic-user","startupScope":{"accountGeneration":1,"presentationGeneration":2}}|}) in
  require (Journal_platform.decode_authenticated_user packet = Ok (Some "synthetic-user"))
    "native scoped authentication loses its verified user";
  require (Journal_platform.decode_authenticated_scope packet =
    Ok {Logseq_sync_pure_reducer.Core.account_generation=1; presentation_generation=2})
    "native scoped authentication loses its startup identity"
;;

let test_sign_out_capability_is_bounded_and_acknowledged () =
  require
    (Bytes.length Journal_platform.sign_out_request = 32
     && Bytes.get_uint16_le Journal_platform.sign_out_request 6 = 10)
    "sign-out request envelope changed";
  envelope 11 (Bytes.of_string {|{"signedOut":true}|})
  |> Journal_platform.decode_sign_out_response
  |> require_ok;
  require
    (Result.is_error
       (Journal_platform.decode_sign_out_response
          (envelope 11 (Bytes.of_string {|{"signedOut":false}|}))))
    "failed sign-out acknowledgement was accepted"
;;

let test_local_account_binding_is_bounded_and_origin_scoped () =
  require
    (Bytes.length Journal_platform.local_account_binding_request = 32
     && Bytes.get_uint16_le Journal_platform.local_account_binding_request 6 = 20)
    "local-account-binding request envelope changed";
  let binding =
    envelope
      21
      (Bytes.of_string
         {|{"userId":"cognito-user-1","managedSyncOrigin":"https://api.logseq.io"}|})
    |> Journal_platform.decode_local_account_binding
    |> require_ok
  in
  (match binding with
   | Some binding ->
     require (String.equal binding.user_id "cognito-user-1") "binding user changed";
     require
       (String.equal binding.managed_sync_origin "https://api.logseq.io")
       "binding origin changed"
   | None -> fail "valid local account binding decoded as absent");
  require
    (Journal_platform.decode_local_account_binding
       (envelope 21 (Bytes.of_string {|{"userId":null,"managedSyncOrigin":null}|}))
     = Ok None)
    "absent local account binding was rejected";
  require
    (Result.is_error
       (Journal_platform.decode_local_account_binding
          (envelope
             21
             (Bytes.of_string
                {|{"userId":"cognito-user-1","managedSyncOrigin":"http://api.logseq.io"}|}))))
    "insecure managed-sync origin was accepted"
;;

let test_timeline_presentation_handshake_is_bounded () =
  let request = Journal_platform.timeline_presented_request in
  require (Bytes.get_uint16_le request 6 = 22) "Timeline request tag changed";
  require (Bytes.length request = 32) "Timeline request payload is not empty";
  envelope 23 (Bytes.of_string {|{"presented":true}|})
  |> Journal_platform.decode_timeline_presented
  |> require_ok;
  require
    (Result.is_error
       (Journal_platform.decode_timeline_presented
          (envelope 23 (Bytes.of_string {|{"presented":false}|}))))
    "negative Timeline presentation acknowledgement was accepted"
;;

let test_termination_handshake_is_bounded_and_acknowledged () =
  require
    (Journal_platform.is_prepare_to_terminate_event (envelope 12 Bytes.empty))
    "prepare-to-terminate event was rejected";
  require
    (not
       (Journal_platform.is_prepare_to_terminate_event
          (envelope 12 (Bytes.of_string "unexpected"))))
    "prepare-to-terminate event accepted a payload";
  require
    (Bytes.length Journal_platform.termination_ready_request = 32
     && Bytes.get_uint16_le Journal_platform.termination_ready_request 6 = 13)
    "termination-ready request envelope changed";
  envelope 14 (Bytes.of_string {|{"ready":true}|})
  |> Journal_platform.decode_termination_ready_response
  |> require_ok
;;

let test_network_lifecycle_epochs_are_bounded_and_typed () =
  (match
     lifecycle_packet ~kind:1 ~generation:7L
     |> Journal_platform.decode_network_lifecycle
     |> require_ok
   with
   | Journal_platform.Backgrounded { generation = 7L } -> ()
   | Backgrounded _ | Foreground_resumed _ -> fail "background lifecycle changed");
  (match
     lifecycle_packet ~kind:2 ~generation:7L
     |> Journal_platform.decode_network_lifecycle
     |> require_ok
   with
   | Journal_platform.Foreground_resumed { generation = 7L } -> ()
   | Backgrounded _ | Foreground_resumed _ -> fail "foreground lifecycle changed");
  [ lifecycle_packet ~kind:0 ~generation:7L
  ; lifecycle_packet ~kind:3 ~generation:7L
  ; lifecycle_packet ~kind:1 ~generation:(-1L)
  ; envelope 15 Bytes.empty
  ]
  |> List.iter (fun packet ->
    require
      (Result.is_error (Journal_platform.decode_network_lifecycle packet))
      "invalid network lifecycle packet was accepted")
;;

let test_clipboard_is_bounded_and_acknowledged () =
  List.iter
    (fun text ->
       let request = Journal_platform.copy_text_request ~text |> require_ok in
       require (Bytes.get_uint16_le request 6 = 28) "clipboard request tag differs";
       let payload =
         Bytes.sub_string request 32 (Bytes.length request - 32)
         |> Yojson.Safe.from_string
         |> Yojson.Safe.Util.member "text"
         |> Yojson.Safe.Util.to_string
       in
       require (payload = text) "clipboard text was altered")
    [ ""; "Root\n  - 中文😀" ];
  require
    (Result.is_error
       (Journal_platform.copy_text_request ~text:(String.make (256 * 1024) '\n')))
    "oversized clipboard envelope was accepted";
  envelope 29 (Bytes.of_string {|{"copied":true}|})
  |> Journal_platform.decode_copy_text_response
  |> require_ok;
  require
    (Result.is_error
       (Journal_platform.decode_copy_text_response
          (envelope 29 (Bytes.of_string {|{"copied":false}|}))))
    "failed clipboard write was accepted"
;;

let test_generated_native_decoders_reject_untyped_payloads () =
  require
    (Result.is_error
       (Journal_environment.decode_json
          (`Assoc
             [ "brightness", `String "light"; "platform", `String "ios"
             ; "accessibleNavigation", `Bool false; "highContrast", `Bool false
             ; "unsupported", `Bool true ])))
    "environment accepted an unknown generated-record field";
  require
    (Result.is_error (Journal_asset_import.decode_event {|{"action":"unavailable"}|}))
    "picker accepted unavailable without its required reason";
  require
    (Result.is_error
       (Journal_asset_import.decode_event {|{"action":"picked-batch","items":[],"request":{"id":"7"}}|}))
    "picker accepted a malformed request identity"
;;

let test_generated_environment_roundtrip () =
  List.iter
    (fun (brightness : Journal_environment.brightness) ->
       let snapshot : Journal_environment.snapshot =
         { brightness; platform = "ios"; accessible_navigation = true; high_contrast = false }
       in
       require
         (Journal_environment.decode_json (Journal_environment.encode_json snapshot) = Ok snapshot)
         "environment did not roundtrip")
    [ Light; Dark ]
;;

let test_generated_picker_preserves_uuid_validation () =
  let payload =
    {|{"action":"picked","selection":{"operation":"invalid","asset":"11111111-1111-4111-8111-111111111111","localMutation":"22222222-2222-4222-8222-222222222222","metadataMutation":"33333333-3333-4333-8333-333333333333","path":"/tmp/pick.png","title":"pick","type":"png"}}|}
  in
  require (Result.is_error (Journal_asset_import.decode_event payload))
    "generated picker decoder bypassed UUID validation";
  require
    (Result.is_error (Journal_asset_import.decode_event {|{"action":"picked-batch","items":[{}]}|}))
    "generated picker decoder accepted an invalid batch member"
;;

(* Account JSON is owned by the platform byte decoder. The startup reducer only
   sees its result and cannot reproduce omitted fields without injecting that result. *)
let test_account_fields_are_required () =
  let accepted tag decode sources =
    List.filter_map
      (fun source ->
         if Result.is_error (decode (envelope tag (Bytes.of_string source))) then None
         else Some (Printf.sprintf "tag %d %s" tag source)) sources
  in
  let malformed =
    accepted 7 Journal_platform.decode_authenticated_user [ "{}" ]
    @ accepted 21 Journal_platform.decode_local_account_binding
        [ "{}"; {|{"userId":null}|}; {|{"managedSyncOrigin":null}|}
        ; {|{"userId":"cognito-user-1"}|}
        ; {|{"managedSyncOrigin":"https://api.logseq.io"}|} ]
  in
  require (malformed = []) "missing account fields accepted: %s"
    (String.concat "; " malformed)
;;

type requests_fixture =
  { owner : Journal_platform_requests.t
  ; queue : (unit -> unit) Queue.t
  ; scope : Logseq_db_worker_lui.Logseq_db_worker_lui_service.startup_scope ref
  ; running : bool ref
  ; emitted : bytes list ref
  ; responses : (int * Journal_platform_requests.response) list ref
  ; decoded : string list ref
  ; emit_hook : (bytes -> unit) ref
  }

let requests_fixture () =
  let queue = Queue.create () in
  let scope : Logseq_db_worker_lui.Logseq_db_worker_lui_service.startup_scope ref =
    ref ({account_generation=1;presentation_generation=2} : Journal_platform_requests.scope) in
  let running = ref true and emitted = ref [] and responses = ref [] and decoded = ref [] in
  let emit_hook = ref (fun _ -> ()) in
  let owner = Journal_platform_requests.create
    ~emit:(fun bytes -> emitted := !emitted @ [bytes]; !emit_hook bytes)
    ~enqueue:(fun work -> Queue.add work queue)
    ~is_running:(fun () -> !running) ~current_scope:(fun () -> !scope)
    ~send_response:(fun tag result -> responses := !responses @ [tag,result])
    ~decode_failure:(fun reason -> decoded := !decoded @ [reason]) in
  {owner;queue;scope;running;emitted;responses;decoded;emit_hook}
;;

let drain_requests fixture =
  let rec loop () = match Queue.take_opt fixture.queue with
    | None -> () | Some work -> work ();loop () in
  loop ()
;;

let request_packet tag =
  let packet = Bytes.make 8 '\000' in
  Bytes.set_uint16_le packet 6 tag;packet
;;

let test_platform_requests_lifecycle () =
  let module R = Journal_platform_requests in
  let failures = ref [] in
  let check name f = try f () with error ->
    Printf.eprintf "PLATFORM_OWNER_RED %s: %s\n%!" name (Printexc.to_string error);
    failures := name :: !failures in
  check "response tag mapping and registration before host emit" (fun () ->
    List.iter (fun (request_tag,response_tag) ->
      let f = requests_fixture () in
      let delivered = ref false in
      f.emit_hook := (fun _ -> require
        (R.resolve f.owner ~response_tag (Ok Bytes.empty)) "host observed unregistered continuation");
      R.emit f.owner ~on_result:(fun _ -> delivered := true) (request_packet request_tag);
      require !delivered "tag mapping did not deliver")
      [6,7;8,9;10,11;13,14;20,21;22,23;25,26;28,29;30,31;32,33;77,77]);
  check "short packet still emits without registering" (fun () ->
    let f = requests_fixture () in
    R.emit f.owner ~on_result:(fun _ -> fail "short packet registered") (Bytes.of_string "tiny");
    require (List.length !(f.emitted)=1) "short packet was not emitted";
    require (not (R.resolve f.owner ~response_tag:7 (Ok Bytes.empty))) "short packet acquired owner");
  check "same tag replaces previous continuation" (fun () ->
    let f = requests_fixture () in let seen = ref [] in
    R.emit f.owner ~on_result:(fun _ -> seen := !seen @ [1]) (request_packet 6);
    R.emit f.owner ~on_result:(fun _ -> seen := !seen @ [2]) (request_packet 6);
    require (R.resolve f.owner ~response_tag:7 (Ok Bytes.empty)) "replacement missing";
    require (!seen=[2]) "old continuation ran");
  check "remove before callback preserves callback re-emission" (fun () ->
    let f = requests_fixture () in let seen = ref [] in
    R.emit f.owner ~on_result:(fun _ ->
      seen := !seen @ [1];
      R.emit f.owner ~on_result:(fun _ -> seen := !seen @ [2]) (request_packet 6)) (request_packet 6);
    require (R.resolve f.owner ~response_tag:7 (Ok Bytes.empty)) "first callback missing";
    require (R.resolve f.owner ~response_tag:7 (Ok Bytes.empty)) "new callback was removed";
    require (!seen=[1;2]) "callback order changed";
    require (not (R.resolve f.owner ~response_tag:7 (Ok Bytes.empty))) "completed callback retained");
  check "legacy failure queues response rather than calling continuation" (fun () ->
    let f = requests_fixture () in let calls = ref 0 in
    R.emit f.owner ~on_result:(fun _ -> incr calls) (request_packet 6);
    R.fail f.owner ~request_tag:6 ~reason:"native.platform.cancelled" ~supplied_scope:None;
    require (Queue.length f.queue=1 && !calls=0) "failure bypassed pump";
    drain_requests f;
    require (!(f.responses)=[7,Error "native.platform.cancelled"] && !calls=0)
      "failure did not dispatch original completion";
    require (R.resolve f.owner ~response_tag:7 (Error "native.platform.cancelled") && !calls=1)
      "queued response did not resolve owner");
  check "queued failure cannot resolve replacement callback" (fun () ->
    let f = requests_fixture () in
    let old_calls = ref 0 and new_calls = ref 0 in
    R.emit f.owner ~on_result:(fun _ -> incr old_calls) (request_packet 6);
    R.fail f.owner ~request_tag:6 ~reason:"old" ~supplied_scope:None;
    require (Queue.length f.queue=1) "failure was not queued";
    R.emit f.owner ~on_result:(fun _ -> incr new_calls) (request_packet 6);
    drain_requests f;
    require (!(f.responses)=[]) "old failure acquired replacement owner");
  check "scope changes while queued retire failure" (fun () ->
    let f = requests_fixture () in
    R.emit f.owner ~on_result:(fun _ -> ()) (request_packet 6);
    R.fail f.owner ~request_tag:6 ~reason:"old" ~supplied_scope:(Some (1L,2L));
    require (Queue.length f.queue=1) "matching failure was not queued";
    f.scope := {!(f.scope) with presentation_generation=3};drain_requests f;
    require (!(f.responses)=[]) "retired scope received failure");
  check "supplied scope mismatch never queues" (fun () ->
    let f = requests_fixture () in
    R.emit f.owner ~on_result:(fun _ -> ()) (request_packet 6);
    R.fail f.owner ~request_tag:6 ~reason:"wrong" ~supplied_scope:(Some (9L,2L));
    require (Queue.length f.queue=0) "wrong host scope queued work");
  check "stopped app ignores already queued failure" (fun () ->
    let f = requests_fixture () in
    R.emit f.owner ~on_result:(fun _ -> ()) (request_packet 6);
    R.fail f.owner ~request_tag:6 ~reason:"old" ~supplied_scope:None;
    require (Queue.length f.queue=1) "failure not queued";
    f.running := false;drain_requests f;
    require (!(f.responses)=[]) "stopped app received completion");
  check "tag zero decode failure preserves special dispatch" (fun () ->
    let f = requests_fixture () in
    R.fail f.owner ~request_tag:0 ~reason:"malformed" ~supplied_scope:None;
    require (Queue.length f.queue=1) "decode failure not queued";
    drain_requests f;
    require (!(f.decoded)=["malformed"] && !(f.responses)=[]) "decode failure acquired continuation");
  check "successful response keeps existing unfenced behavior" (fun () ->
    let f = requests_fixture () in let delivered = ref false in
    R.emit f.owner ~on_result:(fun _ -> delivered:=true) (request_packet 6);
    f.scope := {!(f.scope) with account_generation=9};
    require (R.resolve f.owner ~response_tag:7 (Ok Bytes.empty) && !delivered)
      "successful response gained a new scope fence");
  check "callback exception cannot retain old registration" (fun () ->
    let f = requests_fixture () in let expected = Failure "callback sentinel" in
    R.emit f.owner ~on_result:(fun _ -> raise expected) (request_packet 6);
    let caught = try ignore(R.resolve f.owner ~response_tag:7 (Ok Bytes.empty));false
      with actual when actual==expected -> true in
    require caught "callback exception changed";
    require (not(R.resolve f.owner ~response_tag:7 (Ok Bytes.empty))) "throwing callback retained");
  require (!failures=[]) "%d platform owner cases failed" (List.length !failures)
;;

let tests =
  [ "platform continuation lifecycle", test_platform_requests_lifecycle
  ; "scoped authenticated identity", test_scoped_authentication_preserves_identity
  ; "required account fields", test_account_fields_are_required
  ; "generated native decoders", test_generated_native_decoders_reject_untyped_payloads
  ; "generated environment roundtrip", test_generated_environment_roundtrip
  ; "generated picker UUIDs", test_generated_picker_preserves_uuid_validation
  ; "clipboard text", test_clipboard_is_bounded_and_acknowledged
  ; ( "bounded auth capability"
    , test_auth_capability_envelopes_are_bounded_and_protocol_free )
  ; "sign-out capability", test_sign_out_capability_is_bounded_and_acknowledged
  ; "local account binding", test_local_account_binding_is_bounded_and_origin_scoped
  ; "Timeline presentation handshake", test_timeline_presentation_handshake_is_bounded
  ; "termination handshake", test_termination_handshake_is_bounded_and_acknowledged
  ; "network lifecycle epochs", test_network_lifecycle_epochs_are_bounded_and_typed
  ]
;;

let () =
  List.iter
    (fun (name, test) ->
       Printf.printf "running %s\n%!" name;
       test ())
    tests
;;
