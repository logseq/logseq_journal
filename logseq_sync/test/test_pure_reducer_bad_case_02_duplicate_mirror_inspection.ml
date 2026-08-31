(* Scenario: Mirror_inspected is delivered again after the graph is already attached.
   Expected: the reducer treats the duplicate callback as a no-op. *)

module Core = Logseq_sync_pure_reducer.Core

let fail format = Printf.ksprintf (fun message -> Alcotest.fail message) format

let limits () =
  Core.limits
    ~maximum_response_bytes:Logseq_db_types.Limits.maximum_response_bytes
    ~maximum_artifact_bytes:(1024 * 1024 * 1024)
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

let checkpoint =
  Logseq_db_types.Sync_checkpoint.create
    ~graph_id
    ~schema:Logseq_db_types.Graph_types.{ major = 1; minor = 0 }
    ~applied_server_t:0
    ~checksum:"0000000000000000"
  |> Result.get_ok
;;

let account_scope : Core.account_scope =
  { managed_sync_origin = Uri.of_string "https://api.logseq.io"
  ; user_id = "user-1"
  ; account_generation = 1
  ; presentation_generation = 1
  ; lifecycle_generation = 0L
  }
;;

let graph_scope : Core.graph_scope =
  { account = account_scope; graph_id; graph_generation = 2 }
;;

let expected_attached_state : Core.state =
  { snapshot =
      { sync_phase = Connecting
      ; catalog = [ graph ]
      ; selected_graph = Some graph_id
      ; applied_server_t = Some 0
      ; timeline_presentation_pending = true
      ; startup =
          { authenticated = true
          ; catalog_loading = false
          ; awaiting_selection = false
          ; restoring_local = false
          ; bootstrapping = false
          ; awaiting_e2ee_password = false
          ; failure = None
          ; account_generation = 1
          ; graph_generation = 2
          ; presentation_generation = 1
          }
      ; last_error = None
      }
  ; diagnostics = { groups = []; history = [] }
  }
;;

let authenticated_catalog () =
  let authenticated =
    Core.step (initial ()) (Account_authenticated { user_id = Some "user-1" })
  in
  let token =
    match authenticated.effects with
    | [ Publish (State_changed _); Publish (Token_requested request) ] -> request
    | _ -> fail "BC02 setup authentication emitted unexpected effects"
  in
  let authorized =
    Core.step authenticated.next (Token_provided (token, "catalog-token"))
  in
  let completion =
    match authorized.effects with
    | [ Run (Request (ticket, Fetch_catalog _)) ] ->
      Core.Runner_completed (Core.Completion (ticket, Ok [ graph ]))
    | _ -> fail "BC02 setup catalog authorization emitted unexpected effects"
  in
  Core.step authorized.next completion
;;

let attached_graph () =
  let catalogued = authenticated_catalog () in
  let selected = Core.step catalogued.next (Graph_selected graph_id) in
  let mirror_request =
    match selected.effects with
    | [ Delegate (Inspect_mirror request)
      ; Publish (State_changed _)
      ; Run (Request (_, Save_catalog _))
      ] -> request
    | _ -> fail "BC02 setup graph selection emitted unexpected effects"
  in
  let open_request : Core.graph_open_request =
    { graph = mirror_request.graph
    ; graph_directory = "/worker/bad-case-02"
    ; database_path = "/worker/bad-case-02/db.sqlite"
    ; checkpoint
    ; scope = mirror_request.scope
    }
  in
  let inspected =
    Core.step selected.next (Mirror_inspected (Mirror_available open_request))
  in
  let attach_request =
    match inspected.effects with
    | [ Delegate (Attach_graph request) ] -> request
    | _ -> fail "BC02 setup mirror inspection emitted unexpected effects"
  in
  let attached =
    Core.step
      inspected.next
      (Graph_attached
         { scope = attach_request.scope
         ; checkpoint = attach_request.checkpoint
         ; outbox_records = []
         })
  in
  (match attached.effects with
   | [ Publish (State_changed _); Publish (Token_requested request) ]
     when Core.token_request_purpose request = Websocket_connect -> ()
   | _ -> fail "BC02 setup graph attachment emitted unexpected effects");
  attached.next, open_request
;;

let test_duplicate_mirror_inspection_is_ignored () =
  let origin, open_request = attached_graph () in
  let origin_before = Core.state origin, Core.admitted_graph_scope origin in
  let event = Core.Mirror_inspected (Mirror_available open_request) in
  let first = Core.step origin event in
  Alcotest.check
    Alcotest.bool
    "BC02 duplicate inspection preserves the exact attached state"
    true
    (Core.state first.next = expected_attached_state);
  Alcotest.check
    Alcotest.bool
    "BC02 duplicate inspection preserves graph admission"
    true
    (Core.admitted_graph_scope first.next = Some graph_scope);
  Alcotest.check
    Alcotest.bool
    "BC02 duplicate inspection emits no second Attach_graph"
    true
    (Core.equal_instructions first.effects []);
  Alcotest.check
    Alcotest.bool
    "BC02 step does not mutate its origin"
    true
    ((Core.state origin, Core.admitted_graph_scope origin) = origin_before);
  let replay = Core.step origin event in
  Alcotest.check
    Alcotest.bool
    "BC02 replay is deterministic"
    true
    (Core.state replay.next = Core.state first.next
     && Core.admitted_graph_scope replay.next = Core.admitted_graph_scope first.next
     && Core.equal_instructions replay.effects first.effects)
;;

let () =
  Alcotest.run
    "pure reducer bad case 02"
    [ ( "pure core bad case"
      , [ Alcotest.test_case
            "duplicate mirror inspection is ignored"
            `Quick
            test_duplicate_mirror_inspection_is_ignored
        ] )
    ]
;;
