module W = Journal_worker_coordination.Worker_api
module C = Journal_worker_coordination.Worker_pure_coordinator
module P = Logseq_db_worker.Protocol
module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Id = Logseq_db_worker_lui.Journal_worker_ids
module Sync = Logseq_sync_pure_reducer.Core

let check condition message = if not condition then failwith message
let uuid s = W.Uuid.of_string s |> Result.get_ok
let graph = uuid "98000000-0000-4000-8000-000000000001"
let client = uuid "98000000-0000-4000-8000-000000000002"

let fixture = Coordination_test_fixture.fixture

let ready binding projection =
  let state = (C.step (C.initial ~client_id:client) (C.Worker_bound binding)).next in
  (C.step state (C.Bootstrap_received (binding, W.Ready projection))).next
;;

let test_query_origin_boundary () =
  let issuer, raw, projection, session = fixture 310L in
  let module I = (val issuer : W.ISSUER) in
  let state = (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next in
  let owner = Option.get raw.baseline.state.sync.selected in
  let ticket, waiting =
    C.plan_query state ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  check
    (C.query_origin (C.view waiting.next) ticket = None)
    "queued read fabricated execution origin";
  let sent = C.step waiting.next (C.Bootstrap_received (I.binding, W.Ready projection)) in
  (match C.query_origin (C.view sent.next) ticket with
   | Some (actual, budget) ->
     check (W.equal_session actual session) "queued read origin changed session";
     check
       (W.validate_request actual (W.Query (budget, W.Graph_info)) = Ok ())
       "origin budget differs from actual Send"
   | None -> failwith "actual Send lost execution origin");
  check
    (C.validate_session
       ~owner:{ owner with graph_id = uuid "98000000-0000-4000-8000-000000000099" }
       sent.next
       session
     = Error W.Revoked_session)
    "foreign business graph accepted cached execution origin";
  check
    (C.validate_session sent.next session = Ok ())
    "Open origin cannot resume cached data";
  let _, closing =
    C.prepare_host_change sent.next (W.Graph_will_close (W.graph_id session))
    |> Result.get_ok
  in
  check
    (C.validate_session closing.next session = Error W.Host_change_in_progress)
    "handoff fence allowed cached read";
  let forgotten = C.step sent.next (C.Forget ticket) in
  check
    (C.query_origin (C.view forgotten.next) ticket = None)
    "forgotten ticket retained public origin";
  check
    (C.query_origin (C.view sent.next) ticket <> None)
    "origin lookup mutated preceding state"
;;

let test_bootstrap_validation () =
  let issuer, raw, projection, _ = fixture 101L in
  let module I = (val issuer : W.ISSUER) in
  let empty =
    { raw with
      baseline =
        { raw.baseline with
          version = 0L
        ; state =
            { sync =
                { raw.baseline.state.sync with
                  account = None
                ; desired_residents = []
                ; residents = []
                ; selected = None
                }
            ; residents = []
            }
        }
    }
  in
  (match I.bootstrap (S.Coordination_registered empty) with
   | Ok (W.Ready current) ->
     check (W.equal_projection current projection) "old baseline replaced Ready"
   | _ -> failwith "old not-ready/revocation beat newer Ready");
  let malformed =
    [ (fun (b : S.coordination_baseline) ->
        { b with limits = { b.limits with change_max_bytes = 0 } })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  residents = b.baseline.state.residents @ b.baseline.state.residents
                }
            }
        })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  sync = { b.baseline.state.sync with desired_residents = [] }
                }
            }
        })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  residents =
                    List.map
                      (fun (scope, g) ->
                         scope, { g with Logseq_db_worker.generation = 8 })
                      b.baseline.state.residents
                }
            }
        })
    ; (fun b ->
        { b with
          baseline =
            { b.baseline with
              state =
                { b.baseline.state with
                  sync =
                    { b.baseline.state.sync with
                      selected =
                        Option.map
                          (fun (owner : S.timeline_scope) ->
                             { owner with graph_generation = 8 })
                          b.baseline.state.sync.selected
                    }
                }
            }
        })
    ]
  in
  List.iteri
    (fun n corrupt ->
       let issuer, raw, _, _ = fixture (Int64.of_int (200 + n)) in
       let module I = (val issuer : W.ISSUER) in
       let bad = corrupt { raw with baseline = { raw.baseline with version = 2L } } in
       match I.bootstrap (S.Coordination_registered bad) with
       | Error (W.Protocol_mismatch _) -> ()
       | _ -> failwith "malformed baseline issued authority")
    malformed
;;

type action =
  | Plan
  | Admit of int
  | Answer of int
  | Cancel of int
  | Forget of int
  | Refuse of int
  | Retry
  | Old_baseline
  | Stop
  | Release_ack

let show = function
  | Plan -> "plan"
  | Admit n -> "admit" ^ string_of_int n
  | Answer n -> "answer" ^ string_of_int n
  | Cancel n -> "cancel" ^ string_of_int n
  | Forget n -> "forget" ^ string_of_int n
  | Refuse n -> "refuse" ^ string_of_int n
  | Retry -> "retry"
  | Old_baseline -> "old"
  | Stop -> "stop"
  | Release_ack -> "release-ack"
;;

let remove_chunk values start count =
  List.filteri (fun i _ -> i < start || i >= start + count) values
;;

let shrink fails trace =
  let rec go trace chunk =
    if chunk = 0
    then trace
    else (
      let rec find offset =
        if offset >= List.length trace
        then go trace (chunk / 2)
        else (
          let candidate = remove_chunk trace offset chunk in
          if fails candidate then go candidate chunk else find (offset + 1))
      in
      find 0)
  in
  go trace (max 1 (List.length trace / 2))
;;

let test_pure_properties () =
  let issuer, _, projection, session = fixture 400L in
  let module I = (val issuer : W.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:10 ~maximum_bytes:65536 |> Result.get_ok
  in
  let run trace =
    let state = ref (ready I.binding projection)
    and tickets = ref [] in
    let step event =
      let before = C.view !state in
      let a = C.step !state event
      and b = C.step !state event in
      check
        (C.equal_view (C.view a.next) (C.view b.next))
        "same pure input produced different state";
      check (C.equal_view before (C.view !state)) "step mutated its input snapshot";
      check (List.length a.instructions < 1000) "unbounded instruction batch";
      state := a.next
    in
    let with_ticket n f =
      match List.nth_opt !tickets (n mod 8) with
      | None -> ()
      | Some ticket -> f ticket
    in
    List.iter
      (function
        | Plan ->
          (match C.request !state session (W.Query (budget, W.Graph_info)) with
           | Error _ -> ()
           | Ok (ticket, a) ->
             let _, b =
               C.request !state session (W.Query (budget, W.Graph_info)) |> Result.get_ok
             in
             check
               (C.equal_view (C.view a.next) (C.view b.next))
               "planning is nondeterministic";
             tickets := ticket :: List.filteri (fun i _ -> i < 7) !tickets;
             state := a.next)
        | Admit n ->
          with_ticket n (fun ticket ->
            step
              (C.Admitted (ticket, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 1)))))
        | Answer n ->
          with_ticket n (fun ticket ->
            step (C.Completed (ticket, W.Interrupted W.Cancelled));
            let once = C.view !state in
            step (C.Completed (ticket, W.Answered (Error (W.Service_failed "duplicate"))));
            check (C.equal_view once (C.view !state)) "terminal delivered more than once")
        | Cancel n -> with_ticket n (fun ticket -> step (C.Cancel ticket))
        | Forget n ->
          with_ticket n (fun ticket ->
            step (C.Forget ticket);
            check (C.reply (C.view !state) ticket = None) "forgotten result resurfaced")
        | Refuse n ->
          with_ticket n (fun ticket -> step (C.Admission_refused (ticket, W.Full)))
        | Retry ->
          step C.Retry_bootstrap;
          check
            (Result.is_error (C.request !state session (W.Query (budget, W.Graph_info))))
            "retry retained session admission"
        | Old_baseline ->
          step (C.Bootstrap_received (I.binding, W.Ready projection));
          if C.shutdown_state (C.view !state) <> C.Active
          then
            check
              (C.projection (C.view !state) = None)
              "old baseline revived draining session"
        | Stop ->
          step C.Shutdown_requested;
          check
            (Result.is_error (C.request !state session (W.Query (budget, W.Graph_info))))
            "shutdown retained admission"
        | Release_ack -> step (C.Binding_release_completed (I.binding, Ok ())))
      trace
  in
  let fails trace =
    try
      run trace;
      false
    with
    | _ -> true
  in
  (* Prefixes exercise valid admission, reversed delivery and cancellation races.
     The suffix generator also injects duplicate/foreign/obsolete orderings. *)
  let prefixes =
    [ [ Plan; Admit 0; Answer 0 ]
    ; [ Plan; Answer 0; Admit 0 ]
    ; [ Plan; Cancel 0; Admit 0; Answer 0 ]
    ; [ Plan; Forget 0; Admit 0; Answer 0; Stop; Release_ack ]
    ; [ Plan; Answer 0; Refuse 0; Stop; Release_ack ]
    ]
  in
  List.iter run prefixes;
  for seed = 0 to 499 do
    let random = Random.State.make [| 0x51ec; seed |] in
    let pick () =
      let n = Random.State.int random 8 in
      match Random.State.int random 11 with
      | 0 -> Plan
      | 1 -> Admit n
      | 2 -> Answer n
      | 3 -> Cancel n
      | 4 -> Forget n
      | 5 -> Refuse n
      | 6 -> Retry
      | 7 -> Old_baseline
      | 8 -> Stop
      | 9 -> Release_ack
      | _ -> Plan
    in
    let trace =
      List.nth prefixes (seed mod List.length prefixes) @ List.init 60 (fun _ -> pick ())
    in
    if fails trace
    then (
      let reduced = shrink fails trace in
      failwith
        (Printf.sprintf
           "property seed=%d minimal=[%s]"
           seed
           (String.concat ";" (List.map show reduced))))
  done
;;

let test_cleanup_admission_edges () =
  let issuer, _, projection, session = fixture 500L in
  let module I = (val issuer : W.ISSUER) in
  let bound = (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next in
  let admitted =
    (C.step bound (C.Bootstrap_admitted (I.binding, Id.Worker.Request_id.one))).next
  in
  let stopping = (C.step admitted C.Shutdown_requested).next in
  let acknowledged =
    (C.step stopping (C.Binding_release_completed (I.binding, Ok ()))).next
  in
  check
    (C.shutdown_state (C.view acknowledged) = C.Draining)
    "shutdown ignored an outstanding bootstrap reply";
  let done_state =
    (C.step acknowledged (C.Bootstrap_received (I.binding, W.Ready projection))).next
  in
  check
    (C.shutdown_state (C.view done_state) = C.Stopped)
    "bootstrap completion did not settle draining owner";
  let stopping = (C.step (ready I.binding projection) C.Shutdown_requested).next in
  let failed =
    (C.step stopping (C.Binding_release_not_admitted (I.binding, W.Stopping))).next
  in
  check
    (match C.shutdown_state (C.view failed) with
     | C.Shutdown_failed _ -> true
     | _ -> false)
    "stopping transport left cleanup silently Draining";
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let ticket, planned =
    C.request (ready I.binding projection) session (W.Query (budget, W.Graph_info))
    |> Result.get_ok
  in
  let early =
    (C.step planned.next (C.Completed (ticket, W.Interrupted W.Cancelled))).next
  in
  let refused = (C.step early (C.Admission_refused (ticket, W.Full))).next in
  let stopping = (C.step refused C.Shutdown_requested).next in
  let stopped = (C.step stopping (C.Binding_release_completed (I.binding, Ok ()))).next in
  check
    (C.shutdown_state (C.view stopped) = C.Stopped)
    "refused request retained an unowned early result"
;;

let test_reads_wait_for_verified_baseline () =
  let issuer, raw, projection, _ = fixture 301L in
  let module I = (val issuer : W.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let bound = (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next in
  let ticket, waiting =
    C.plan_query
      bound
      ~owner
      ~maximum_items:64
      ~maximum_bytes:P.maximum_response_bytes
      W.Graph_info
    |> Result.get_ok
  in
  let sends instructions =
    List.fold_left
      (fun n -> function
         | C.Send _ -> n + 1
         | _ -> n)
      0
      instructions
  in
  check (sends waiting.instructions = 0) "query sent before verified baseline";
  let opened =
    C.step waiting.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check (sends opened.instructions = 1) "verified Open did not dispatch queued query";
  let duplicate = C.step opened.next (C.Projection_received projection) in
  check (sends duplicate.instructions = 0) "duplicate baseline dispatched query twice";
  (* Host messages may run while a newer baseline is only queued. Absence
     from the old snapshot is not evidence that the new generation retired. *)
  let future_owner = { owner with graph_generation = owner.graph_generation + 1 } in
  let future, future_waiting =
    C.plan_query
      (ready I.binding projection)
      ~owner:future_owner
      ~maximum_items:1
      ~maximum_bytes:65536
      W.Graph_info
    |> Result.get_ok
  in
  check
    (C.reply (C.view future_waiting.next) future = None)
    "future owner was rejected by stale baseline";
  let drained = C.step future_waiting.next C.Drain in
  check
    (sends drained.instructions = 0 && C.reply (C.view drained.next) future = None)
    "a queued future owner either sent early or was falsely retired";
  let update_scope (scope : S.asset_scope) =
    { scope with graph_generation = future_owner.graph_generation }
  in
  let raw_future =
    { raw with
      baseline =
        { raw.baseline with
          version = 2L
        ; state =
            { sync =
                { raw.baseline.state.sync with
                  selected = Some future_owner
                ; residents =
                    List.map
                      (fun (scope, state) -> update_scope scope, state)
                      raw.baseline.state.sync.residents
                }
            ; residents =
                List.map
                  (fun (scope, state) ->
                     ( update_scope scope
                     , { state with
                         Logseq_db_worker.generation = future_owner.graph_generation
                       } ))
                  raw.baseline.state.residents
            }
        }
    }
  in
  let future_projection =
    match I.bootstrap (S.Coordination_registered raw_future) with
    | Ok (W.Ready projection) -> projection
    | _ -> failwith "future fixture baseline rejected"
  in
  let arrived = C.step drained.next (C.Projection_received future_projection) in
  check
    (sends arrived.instructions = 1)
    "future owner did not send after matching baseline";
  let cancelled = C.step waiting.next (C.Cancel ticket) in
  check
    (C.reply (C.view cancelled.next) ticket = Some (W.Interrupted W.Cancelled))
    "unsent cancellation did not settle locally";
  let late =
    C.step cancelled.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check (sends late.instructions = 0) "cancelled waiting query was resurrected";
  let wrong = { owner with graph_generation = owner.graph_generation - 1 } in
  let stale, waiting =
    C.plan_query bound ~owner:wrong ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  let opened =
    C.step waiting.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check (sends opened.instructions = 0) "stale host identity minted a session";
  check
    (C.reply (C.view opened.next) stale = Some (W.Answered (Error W.Revoked_session)))
    "replaced scope left queued read waiting forever";
  let waiting =
    snd
      (C.plan_query bound ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
       |> Result.get_ok)
  in
  let shutdown = C.step waiting.next C.Shutdown_requested in
  let stopped = C.step shutdown.next (C.Binding_release_completed (I.binding, Ok ())) in
  let stopped =
    C.step stopped.next (C.Bootstrap_received (I.binding, W.Ready projection))
  in
  check
    (C.shutdown_state (C.view stopped.next) = C.Stopped)
    "unsent query prevented registration cleanup";
  check (sends stopped.instructions = 0) "shutdown sent a queued query"
;;

let test_opening_query_retires_on_removal () =
  let issuer, raw, _, _ = fixture 303L in
  let module I = (val issuer : W.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let opening =
    { raw with
      baseline =
        { raw.baseline with
          version = 2L
        ; state =
            { raw.baseline.state with
              residents =
                List.map
                  (fun (scope, state) ->
                     scope, { state with Logseq_db_worker.phase = Graph_opening })
                  raw.baseline.state.residents
            }
        }
    }
  in
  let project value =
    match I.bootstrap (S.Coordination_registered value) with
    | Ok (W.Ready projection) -> projection
    | _ -> failwith "opening/removal baseline fixture failed"
  in
  let opening = project opening in
  let ticket, waiting =
    C.plan_query
      (ready I.binding opening)
      ~owner
      ~maximum_items:1
      ~maximum_bytes:65536
      W.Graph_info
    |> Result.get_ok
  in
  check (C.reply (C.view waiting.next) ticket = None) "Opening query did not wait";
  let empty =
    project
      { raw with
        baseline =
          { raw.baseline with
            version = 3L
          ; state =
              { sync =
                  { raw.baseline.state.sync with
                    desired_residents = []
                  ; residents = []
                  ; selected = None
                  }
              ; residents = []
              }
          }
      }
  in
  let removed = C.step waiting.next (C.Projection_received empty) in
  check
    (C.reply (C.view removed.next) ticket = Some (W.Answered (Error W.Revoked_session)))
    "removed Opening owner retained its waiting query";
  let late, planned =
    C.plan_query removed.next ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  check
    (C.reply (C.view planned.next) late = Some (W.Answered (Error W.Revoked_session)))
    "late request for a known removed owner waited forever"
;;

let test_queued_query_properties () =
  let issuer, raw, first, _ = fixture 302L in
  let module I = (val issuer : W.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let later_owner = { owner with graph_generation = owner.graph_generation + 1 } in
  let later_scope (scope : S.asset_scope) =
    { scope with graph_generation = later_owner.graph_generation }
  in
  let later_raw =
    { raw with
      baseline =
        { raw.baseline with
          version = 2L
        ; state =
            { sync =
                { raw.baseline.state.sync with
                  selected = Some later_owner
                ; residents =
                    List.map
                      (fun (scope, state) -> later_scope scope, state)
                      raw.baseline.state.sync.residents
                }
            ; residents =
                List.map
                  (fun (scope, state) ->
                     ( later_scope scope
                     , { state with
                         Logseq_db_worker.generation = later_owner.graph_generation
                       } ))
                  raw.baseline.state.residents
            }
        }
    }
  in
  let later =
    match I.bootstrap (S.Coordination_registered later_raw) with
    | Ok (W.Ready value) -> value
    | _ -> failwith "later queued-query fixture rejected"
  in
  let run trace =
    let state =
      ref (C.step (C.initial ~client_id:client) (C.Worker_bound I.binding)).next
    in
    let tickets = ref []
    and expected = Hashtbl.create 128
    and sends = Hashtbl.create 128
    and forbidden = Hashtbl.create 128 in
    let apply (transition : C.transition) =
      List.iter
        (function
          | C.Send (ticket, session, operation) ->
            (match operation with
             | W.Query (budget,_) ->
               (match C.query_origin (C.view transition.next) ticket with
                | Some (actual,actual_budget) -> check (W.equal_session actual session && actual_budget=budget)
                    "queued property: origin differs from actual Send"
                | None->failwith "queued property: dispatched read lacks origin")
             | _ -> ());
            check (C.validate_session transition.next session=Ok ()) "dispatched query session is fenced";
            let id = C.ticket_id ticket in
            check (not (Hashtbl.mem forbidden id)) "cancelled unsent read was dispatched";
            check (not (Hashtbl.mem sends id)) "queued read sent more than once";
            check
              (W.matches_scope session (Hashtbl.find expected id))
              "queued read used foreign scope";
            check
              (Option.fold
                 ~none:false
                 ~some:(fun projection ->
                   List.exists
                     (fun resident ->
                        resident.W.phase = W.Open
                        && W.equal_session session resident.session)
                     (W.residents projection))
                 (C.projection (C.view transition.next)))
              "queued read bypassed verified Open session";
            Hashtbl.replace sends id ()
          | _ -> ())
        transition.C.instructions;
      check
        (List.length transition.instructions < 1000)
        "queued read emitted unbounded batch";
      state := transition.next
    in
    let step event =
      let before = C.view !state in
      let a = C.step !state event
      and b = C.step !state event in
      check
        (C.equal_view (C.view a.next) (C.view b.next))
        "queued steps were nondeterministic";
      check (C.equal_view before (C.view !state)) "queued step mutated prior state";
      apply a
    in
    let ticket n f =
      match List.nth_opt !tickets (n mod 8) with
      | None -> ()
      | Some value -> f value
    in
    List.iter
      (fun (op, n) ->
         match op with
         | 0 ->
           let target =
             match n mod 3 with
             | 0 -> owner
             | 1 -> later_owner
             | _ -> { owner with graph_generation = owner.graph_generation - 1 }
           in
           (match
              C.plan_query
                !state
                ~owner:target
                ~maximum_items:1
                ~maximum_bytes:65536
                W.Graph_info
            with
            | Error _ -> ()
            | Ok (ticket, transition) ->
              Hashtbl.replace expected (C.ticket_id ticket) target;
              tickets := ticket :: List.filteri (fun i _ -> i < 7) !tickets;
              apply transition)
         | 1 -> step (C.Projection_received (if n mod 2 = 0 then first else later))
         | 2 ->
           ticket n (fun value ->
             step
               (C.Admitted (value, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 1)))))
         | 3 ->
           ticket n (fun value ->
             step (C.Completed (value, W.Interrupted W.Cancelled));
             let once = C.view !state in
             step (C.Completed (value, W.Answered (Error (W.Service_failed "duplicate"))));
             check (C.equal_view once (C.view !state)) "queued terminal consumed twice")
         | 4 | 5 ->
           ticket n (fun value ->
             if not (Hashtbl.mem sends (C.ticket_id value))
             then Hashtbl.replace forbidden (C.ticket_id value) ();
             step (if op = 4 then C.Cancel value else C.Forget value))
         | 6 -> step C.Drain
         | 7 -> step C.Shutdown_requested
         | 8 -> step C.Retry_bootstrap
         | 9 -> step (C.Binding_release_completed (I.binding, Ok ()))
         | 10 -> ticket n (fun value -> step (C.Admission_refused (value, W.Full)))
         | _ ->
           step
             (C.Bootstrap_received
                (I.binding, W.Ready (if n mod 2 = 0 then first else later))))
      trace
  in
  let prefixes =
    [ [ 0, 1; 1, 0; 6, 0; 2, 0; 3, 0; 1, 1; 2, 0; 3, 0 ]
    ; [ 0, 0; 4, 0; 1, 0 ]
    ; [ 0, 1; 5, 0; 1, 1 ]
    ; [ 0, 1; 7, 0; 9, 0; 11, 1 ]
    ]
  in
  List.iter run prefixes;
  for seed = 0 to 249 do
    let random = Random.State.make [| 0x0c001; seed |] in
    let prefix = List.nth prefixes (seed mod List.length prefixes) in
    let trace =
      prefix
      @ List.init 96 (fun _ -> Random.State.int random 16, Random.State.int random 8)
    in
    let fails trace =
      try
        run trace;
        false
      with
      | _ -> true
    in
    if fails trace
    then (
      let minimal = shrink fails trace in
      failwith
        (Printf.sprintf
           "queued-query seed=%d shrunk=%s"
           seed
           (String.concat
              ","
              (List.map (fun (op, n) -> Printf.sprintf "%d:%d" op n) minimal))))
  done
;;

let test_compressed_response_ownership () =
  let module O = C.Response_ownership in
  let id n = Id.Worker.Request_id.of_int64 (Int64.of_int n) in
  let history = ref O.empty in
  for n = 1 to 16384 do
    history := O.add !history (id n)
  done;
  check (O.spans !history = 1) "completed sequential requests expanded ownership history";
  List.iter
    (fun n -> check (O.mem !history (id n)) "old owned response lost disposition")
    [ 1; 4096; 8192; 16384 ];
  for seed = 0 to 99 do
    let random = Random.State.make [| 0x0a11; seed |]
    and expected = Array.make 128 false in
    let history = ref O.empty in
    for _ = 0 to 255 do
      let n = Random.State.int random 128 in
      expected.(n) <- true;
      history := O.add !history (id (n + 1));
      Array.iteri
        (fun n owned ->
           check
             (O.mem !history (id (n + 1)) = owned)
             "interval ownership swallowed a legacy gap")
        expected
    done
  done
;;

let test_durable_mutation_properties () =
  let issuer, _, projection, session = fixture 1901L in
  let module I = (val issuer : W.ISSUER) in
  let intent =
    W.mutation_intent
      session
      ~mutation_id:(uuid "98000000-0000-4000-8000-000000000091")
      (W.Save_block
         { block = graph
         ; title = "stable durable choice"
         ; preconditions =
             { blocks = [ graph, "block-state:v1:synthetic" ]; pages = []; scopes = [] }
         })
    |> Result.get_ok
  in
  let wire = W.encode_mutation_intent intent in
  let run trace =
    let state = ref (ready I.binding projection)
    and tickets = ref []
    and committed = ref false
    and original_point = ref None in
    let apply event =
      let before = C.view !state in
      let first = C.step !state event
      and second = C.step !state event in
      check
        (C.equal_view (C.view first.next) (C.view second.next))
        "durable step is nondeterministic";
      check (C.equal_view before (C.view !state)) "durable step modified shared input";
      state := first.next;
      check
        (W.encode_mutation_intent intent = wire)
        "unknown write changed durable payload";
      (match C.intent_progress (C.view !state) intent with
       | Some (W.Committed_pending_presentation receipt) ->
         check
           (W.encode_mutation_intent (W.receipt_intent receipt) = wire)
           "foreign receipt poisoned durable identity";
         let point = W.receipt_revisions receipt in
         (match !original_point with
          | None -> original_point := Some point
          | Some original ->
            check (point = original) "later completion replaced original commit point")
       | _ -> ());
      if !committed
      then (
        match C.intent_progress (C.view !state) intent with
        | Some (W.Committed_pending_presentation _ | W.Confirmed _) -> ()
        | _ -> failwith "committed evidence regressed or vanished")
    in
    let with_ticket n f = Option.iter f (List.nth_opt !tickets (n mod 8)) in
    List.iter
      (fun (action, n) ->
         match action with
         | 0 ->
           (match C.request !state session (W.Mutate intent) with
            | Ok (ticket, transition) ->
              state := transition.next;
              tickets := ticket :: List.take 7 !tickets
            | Error _ -> ())
         | 1 ->
           with_ticket n (fun ticket ->
             apply
               (C.Admitted (ticket, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 100)))))
         | 2 ->
           with_ticket n (fun ticket ->
             apply (C.Completed (ticket, W.Interrupted W.Cancelled)))
         | 3 -> with_ticket n (fun ticket -> apply (C.Cancel ticket))
         | 4 -> with_ticket n (fun ticket -> apply (C.Forget ticket))
         | 5 -> with_ticket n (fun ticket -> apply (C.Admission_refused (ticket, W.Full)))
         | 6 ->
           with_ticket n (fun ticket ->
             apply (C.Completed (ticket, W.Answered (Ok W.Outcome_unknown))))
         | 7 | 9 | 10 ->
           with_ticket n (fun ticket ->
             let receipt_intent =
               if action <> 9
               then intent
               else
                 W.mutation_intent
                   session
                   ~mutation_id:(uuid "98000000-0000-4000-8000-000000000092")
                   (W.Save_block
                      { block = graph
                      ; title = "unrelated durable choice"
                      ; preconditions =
                          { blocks = [ graph, "block-state:v1:synthetic" ]
                          ; pages = []
                          ; scopes = []
                          }
                      })
                 |> Result.get_ok
             in
             let request_id =
               match
                 I.request session ~request_id:(C.ticket_id ticket) (W.Mutate intent)
               with
               | Ok (S.Coordination_mutation { request_id; _ }) -> request_id
               | _ -> assert false
             in
             let response =
               P.V2_response
                 { api_version = P.api_version
                 ; request_id
                 ; outcome =
                     P.V2_mutation_committed
                       { mutation_id = W.mutation_intent_id receipt_intent
                       ; status = P.V2_applied
                       ; generation = "generation:v1:1:1"
                       ; before_projection_revision = "projection:v1:0"
                       ; after_projection_revision =
                           (if action = 10 then "projection:v1:2" else "projection:v1:1")
                       }
                 }
             in
             let receipt =
               I.mutation_receipt
                 session
                 ~request_id:(C.ticket_id ticket)
                 ~intent:receipt_intent
                 response
               |> Result.get_ok
             in
             apply
               (C.Completed
                  (ticket, W.Answered (Ok (W.Committed_pending_presentation receipt))));
             match C.intent_progress (C.view !state) intent with
             | Some (W.Committed_pending_presentation _ | W.Confirmed _) ->
               committed := true
             | _ -> ())
         | _ ->
           with_ticket n (fun ticket ->
             apply
               (C.Completed
                  ( ticket
                  , W.Answered (Ok (W.Rejected (W.Invalid_input "known rejection"))) ))))
      trace
  in
  let prefixes =
    [ [ 0, 0; 1, 0; 9, 0 ]
    ; [ 0, 0; 1, 0; 7, 0; 0, 0; 1, 0; 10, 0 ]
    ; [ 0, 0; 1, 0; 3, 0; 7, 0; 4, 0 ]
    ; [ 0, 0; 7, 0; 1, 0; 6, 0 ]
    ; [ 0, 0; 1, 0; 7, 0; 0, 0; 1, 0; 8, 0; 7, 1 ]
    ; [ 0, 0; 4, 0; 1, 0; 7, 0 ]
    ]
  in
  let fails trace =
    try
      run trace;
      false
    with
    | _ -> true
  in
  List.iter run prefixes;
  for seed = 0 to 249 do
    let random = Random.State.make [| 0xd0a; seed |] in
    let trace =
      List.nth prefixes (seed mod List.length prefixes)
      @ List.init 80 (fun _ -> Random.State.int random 11, Random.State.int random 8)
    in
    if fails trace
    then (
      let reduced = shrink fails trace in
      failwith
        (Printf.sprintf
           "durable seed=%d shrunk=%s"
           seed
           (String.concat
              ";"
              (List.map (fun (a, n) -> Printf.sprintf "%d/%d" a n) reduced))))
  done
;;

let test_durable_readback_reservation () =
  let issuer, _, projection, session = fixture 1902L in
  let module I = (val issuer : W.ISSUER) in
  let state = ref (ready I.binding projection)
  and admitted = ref 0 in
  for n = 1 to 128 do
    let intent =
      W.mutation_intent
        session
        ~mutation_id:(uuid (Printf.sprintf "98000000-0000-4000-8000-%012d" (1000 + n)))
        (W.Save_block
           { block = graph
           ; title = "bounded readback reservation"
           ; preconditions =
               { blocks = [ graph, "block-state:v1:synthetic" ]; pages = []; scopes = [] }
           })
      |> Result.get_ok
    in
    match C.request !state session (W.Mutate intent) with
    | Error _ -> ()
    | Ok (_, transition) ->
      incr admitted;
      state := transition.next
  done;
  check (!admitted > 0) "durable capacity admitted no legitimate operation";
  check
    (!admitted * P.maximum_response_bytes <= 16777216)
    "bounded intent keys admitted unreserved confirmation snapshots"
;;

let test_recovery_cursor_and_capacity_bounds () =
  let module Wire=Logseq_db_worker_contract.Mutation_pure_wire in
  let issuer,_,projection,session=fixture 1906L in
  let module I=(val issuer:W.ISSUER) in
  let make n=W.mutation_intent session ~mutation_id:(uuid(Printf.sprintf "98000000-0000-4000-8000-%012d" (2000+n)))
    (W.Save_block{block=graph;title="bounded recovered item";
      preconditions={blocks=[graph,"block-state:v1:synthetic"];pages=[];scopes=[]}}) |> Result.get_ok in
  let item n=Wire.{intent=Bytes.to_string(W.encode_mutation_intent(make n));outcome=Unknown} in
  let id=W.request_id(uuid "98000000-0000-4000-8000-000000001906") in
  let request_id=uuid "98000000-0000-4000-8000-000000001906" in
  let operation=W.Recover_mutations{after=None;maximum_items=1;maximum_bytes=W.maximum_mutation_recovery_bytes} in
  let raw items next=S.Coordination_mutations_recovered{request_id;page=Wire.{items;next}} in
  let page=match I.reply session ~request_id:id operation(raw(Rrbvec.singleton(item 1))(Some 1L)) with
    | Ok(W.Answered(Ok page))->page|_->failwith "valid recovery cursor codec failed" in
  check(W.validate_request session(W.Recover_mutations{after=page.next;maximum_items=1;maximum_bytes=W.maximum_mutation_recovery_bytes})=Ok())
    "sealed recovery cursor lost same-budget ownership";
  check(Result.is_error(W.validate_request session(W.Recover_mutations{after=page.next;maximum_items=2;
    maximum_bytes=W.maximum_mutation_recovery_bytes}))) "recovery cursor adopted a new item budget";
  let _,_,_,other=fixture 1907L in
  check(Result.is_error(W.validate_request other(W.Recover_mutations{after=page.next;maximum_items=1;
    maximum_bytes=W.maximum_mutation_recovery_bytes}))) "foreign session adopted recovery cursor";
  check(Result.is_error(I.reply session ~request_id:id operation(raw Rrbvec.empty(Some 1L)))) "empty More became recovery completeness";
  let after=W.Recover_mutations{after=page.next;maximum_items=1;maximum_bytes=W.maximum_mutation_recovery_bytes} in
  check(Result.is_error(I.reply session ~request_id:id after(raw(Rrbvec.singleton(item 1))(Some 1L))))
    "recovery cursor repeated without progress";
  let many=W.Recover_mutations{after=None;maximum_items=70;maximum_bytes=W.maximum_mutation_recovery_bytes} in
  check(Result.is_error(I.reply session ~request_id:id many(raw(Rrbvec.of_list[item 1;item 1])None)))
    "duplicate recovered mutation identity was accepted";
  let oversized=Wire.{intent=(item 1).intent;outcome=Rejected(P.V2_response{api_version=P.api_version;
    request_id;outcome=V2_failed{code="conflict";message=String.make P.maximum_response_bytes 'x'}})} in
  check(Result.is_error(I.reply session ~request_id:id operation(raw(Rrbvec.singleton oversized)None)))
    "recovered rejection bypassed its reserved protocol-result budget";
  let ticket,planned=C.request(ready I.binding projection)session many |> Result.get_ok in
  let request_id=match I.request session ~request_id:(C.ticket_id ticket)many with
    | Ok(S.Coordination_recover_mutations{request_id;_})->request_id|_->assert false in
  let page=match I.reply session ~request_id:(C.ticket_id ticket)many
    (S.Coordination_mutations_recovered{request_id;page=Wire.{items=Rrbvec.init 70 item;next=None}}) with
    | Ok(W.Answered(Ok page))->page|_->failwith "valid bounded storage page failed codec" in
  let state=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.of_int64 30L))).next in
  let state=(C.step state(C.Completed(ticket,W.Answered(Ok page)))).next in
  check(match C.reply(C.view state)ticket with Some(W.Answered(Error _))->true|_->false)
    "over-capacity recovery silently skipped entries";
  for n=0 to 69 do check(C.intent_progress(C.view state)(make n)=None) "failed recovery partially adopted its page" done
;;

let test_durable_recovery_and_ack_purity () =
  let module Wire=Logseq_db_worker_contract.Mutation_pure_wire in
  let issuer,_,projection,session=fixture 1903L in
  let module I=(val issuer:W.ISSUER) in
  let intent=W.mutation_intent session ~mutation_id:(uuid "98000000-0000-4000-8000-000000001903")
    (W.Save_block{block=graph;title="recovered choice";
      preconditions={blocks=[graph,"block-state:v1:synthetic"];pages=[];scopes=[]}}) |> Result.get_ok in
  let operation=W.Recover_mutations{after=None;maximum_items=8;maximum_bytes=W.maximum_mutation_recovery_bytes} in
  let answer ticket progress =
    let request_id=match I.request session ~request_id:(C.ticket_id ticket) operation with
      | Ok(S.Coordination_recover_mutations{request_id;_})->request_id|_->failwith "recovery codec request" in
    let outcome=if progress then Wire.Rejected(P.V2_response{api_version=P.api_version;request_id;
      outcome=V2_failed{code="conflict";message="known not applied"}}) else Wire.Unknown in
    match I.reply session ~request_id:(C.ticket_id ticket) operation
      (S.Coordination_mutations_recovered{request_id;page=Wire.{items=Rrbvec.singleton
        {intent=Bytes.to_string(W.encode_mutation_intent intent);outcome};next=None}}) with
    | Ok(W.Answered(Ok page))->page|_->failwith "recovery codec response" in
  let state=ref(ready I.binding projection) in
  check(Result.is_error(C.request !state session(W.Acknowledge_intent intent))) "unknown intent admitted ACK";
  let ticket,planned=match C.request !state session operation with
    | Ok value->value|Error _->failwith "typed durable recovery has no pure planning" in
  state:=planned.next;
  check(Result.is_error(C.request !state session operation)) "parallel recovery bypassed response retention bound";
  state:=(C.step !state(C.Admitted(ticket,Id.Worker.Request_id.of_int64 10L))).next;
  state:=(C.step !state(C.Completed(ticket,W.Answered(Ok(answer ticket false))))).next;
  check(C.intent_progress(C.view !state)intent=Some W.Outcome_unknown) "recovery did not retain Unknown";
  check(Result.is_error(C.request !state session(W.Acknowledge_intent intent))) "recovered Unknown admitted ACK";
  state:=(C.step !state(C.Forget ticket)).next;
  let ticket,planned=C.request !state session operation |> Result.get_ok in
  state:=planned.next;
  state:=(C.step !state(C.Admitted(ticket,Id.Worker.Request_id.of_int64 11L))).next;
  state:=(C.step !state(C.Completed(ticket,W.Answered(Ok(answer ticket true))))).next;
  check(match C.intent_progress(C.view !state)intent with Some(W.Rejected _)->true|_->false)
    "known rejection was lost during recovery";
  state:=(C.step !state(C.Forget ticket)).next;
  let stale,planned=C.request !state session operation |> Result.get_ok in
  state:=planned.next;
  state:=(C.step !state(C.Admitted(stale,Id.Worker.Request_id.of_int64 12L))).next;
  let ack,planned=C.request !state session(W.Acknowledge_intent intent) |> Result.get_ok in
  check(match C.ticket_acknowledgement ack with Some(_,None)->true|_->false)
    "known rejection ACK did not carry the pure no-commit decision";
  state:=planned.next;
  state:=(C.step !state(C.Admitted(ack,Id.Worker.Request_id.of_int64 13L))).next;
  state:=(C.step !state(C.Completed(ack,W.Interrupted W.Transport_lost))).next;
  check(C.intent_progress(C.view !state)intent<>None) "interrupted ACK erased durable ownership";
  state:=(C.step !state(C.Forget ack)).next;
  let ack,planned=C.request !state session(W.Acknowledge_intent intent) |> Result.get_ok in
  state:=planned.next;
  state:=(C.step !state(C.Admitted(ack,Id.Worker.Request_id.of_int64 14L))).next;
  state:=(C.step !state(C.Completed(ack,W.Answered(Ok())))).next;
  check(C.intent_progress(C.view !state)intent=None) "true durable ACK did not free coordination capacity";
  state:=(C.step !state(C.Completed(stale,W.Answered(Ok(answer stale true))))).next;
  check(C.intent_progress(C.view !state)intent=None) "old recovery resurrected an acknowledged intent";
  check(match C.reply(C.view !state)stale with Some(W.Answered(Error _))->true|_->false)
    "stale recovery was exposed as a current pending page"
;;

let test_committed_ack_requires_current_confirmation () =
  let issuer,_,projection,session=fixture 1905L in
  let module I=(val issuer:W.ISSUER) in
  let presentation=Option.get(W.selected projection) in
  let intent=W.mutation_intent session ~mutation_id:(uuid "98000000-0000-4000-8000-000000001905")
    (W.Save_block{block=graph;title="confirmed choice";
      preconditions={blocks=[graph,"block-state:v1:synthetic"];pages=[];scopes=[]}}) |> Result.get_ok in
  let ticket,planned=C.request(ready I.binding projection)session(W.Mutate intent) |> Result.get_ok in
  let request_id=match I.request session ~request_id:(C.ticket_id ticket)(W.Mutate intent) with
    | Ok(S.Coordination_mutation{request_id;_})->request_id|_->assert false in
  let receipt=I.mutation_receipt session ~request_id:(C.ticket_id ticket) ~intent
    (P.V2_response{api_version=P.api_version;request_id;outcome=V2_mutation_committed
      {mutation_id=W.mutation_intent_id intent;status=V2_applied;generation="generation:v1:1:1";
       before_projection_revision="projection:v1:0";after_projection_revision="projection:v1:1"}}) |> Result.get_ok in
  let state=(C.step planned.next(C.Admitted(ticket,Id.Worker.Request_id.of_int64 20L))).next in
  let state=(C.step state(C.Completed(ticket,W.Answered(Ok(W.Committed_pending_presentation receipt))))).next in
  check(Result.is_error(C.request state session(W.Acknowledge_intent intent))) "unconfirmed commit admitted ACK";
  let confirmation=I.confirmation session ~presentation receipt(P.V2_response
    {api_version=P.api_version;request_id;outcome=V2_block_summary_outcome
      {lookup=V2_missing_block{uuid=graph;revision="block-state:v1:missing"};page=None;items=[];next_cursor=None;
       scope_revision="scope-revision:v1:missing";generation="generation:v1:1:1";projection_revision="projection:v1:1"}})
    |> Result.get_ok in
  let confirm,planned=C.request state session(W.Confirm(presentation,receipt)) |> Result.get_ok in
  let state=(C.step planned.next(C.Admitted(confirm,Id.Worker.Request_id.of_int64 21L))).next in
  let state=(C.step state(C.Completed(confirm,W.Answered(Ok(W.Confirmed confirmation))))).next in
  let ack,planned=match C.request state session(W.Acknowledge_intent intent) with
    | Ok value->value|Error _->failwith "current Confirmed intent could not plan ACK" in
  check(match C.ticket_acknowledgement ack with Some(actual,Some proof)->
    actual=presentation && W.receipt_revisions proof=W.receipt_revisions receipt|_->false)
    "ACK did not capture exact presentation and original proof";
  let admitted=(C.step planned.next(C.Admitted(ack,Id.Worker.Request_id.of_int64 22L))).next in
  let retired=(C.step admitted C.Shutdown_requested).next in
  let late=(C.step retired(C.Completed(ack,W.Answered(Ok())))).next in
  check(C.intent_progress(C.view late)intent<>None) "old execution ACK erased current recovery ownership";
  let completed=(C.step admitted(C.Completed(ack,W.Answered(Ok())))).next in
  check(C.intent_progress(C.view completed)intent=None) "confirmed ACK retained completed intent";
  let retry,planned=C.request state session(W.Mutate intent) |> Result.get_ok in
  let again,planned=C.request planned.next session(W.Confirm(presentation,receipt)) |> Result.get_ok in
  let other=W.mutation_intent session ~mutation_id:(uuid "98000000-0000-4000-8000-000000001908")
    (W.Save_block{block=graph;title="independent accepted write";
      preconditions={blocks=[graph,"block-state:v1:synthetic"];pages=[];scopes=[]}}) |> Result.get_ok in
  let independent,planned=C.request planned.next session(W.Mutate other) |> Result.get_ok in
  let old_ack,planned=C.request planned.next session(W.Acknowledge_intent intent) |> Result.get_ok in
  let ack,planned=C.request planned.next session(W.Acknowledge_intent intent) |> Result.get_ok in
  let state=(C.step planned.next(C.Admitted(retry,Id.Worker.Request_id.of_int64 23L))).next in
  let state=(C.step state(C.Admitted(again,Id.Worker.Request_id.of_int64 24L))).next in
  let state=(C.step state(C.Admitted(independent,Id.Worker.Request_id.of_int64 25L))).next in
  let state=(C.step state(C.Admitted(old_ack,Id.Worker.Request_id.of_int64 28L))).next in
  let state=(C.step state(C.Admitted(ack,Id.Worker.Request_id.of_int64 26L))).next in
  let acknowledged=(C.step state(C.Completed(ack,W.Answered(Ok())))).next in
  let late=(C.step acknowledged(C.Completed(retry,W.Answered(Ok(W.Committed_pending_presentation receipt))))).next in
  check(C.intent_progress(C.view late)intent=None) "pre-ACK mutation completion resurrected settled intent";
  check(match C.reply(C.view late)retry with Some(W.Answered(Error _))->true|_->false)
    "pre-ACK mutation completion was published as fresh ownership";
  let late=(C.step acknowledged(C.Completed(retry,W.Interrupted W.Transport_lost))).next in
  check(C.intent_progress(C.view late)intent=None) "pre-ACK interruption resurrected Unknown intent";
  let late=(C.step acknowledged(C.Completed(again,W.Answered(Ok(W.Confirmed confirmation))))).next in
  check(C.intent_progress(C.view late)intent=None) "pre-ACK confirmation resurrected settled intent";
  let request_id=match I.request session ~request_id:(C.ticket_id independent)(W.Mutate other) with
    | Ok(S.Coordination_mutation{request_id;_})->request_id|_->assert false in
  let other_receipt=I.mutation_receipt session ~request_id:(C.ticket_id independent) ~intent:other
    (P.V2_response{api_version=P.api_version;request_id;outcome=V2_mutation_committed
      {mutation_id=W.mutation_intent_id other;status=V2_applied;generation="generation:v1:1:1";
       before_projection_revision="projection:v1:1";after_projection_revision="projection:v1:2"}}) |> Result.get_ok in
  let other_done=(C.step acknowledged(C.Completed(independent,W.Answered(Ok(W.Committed_pending_presentation other_receipt))))).next in
  check(match C.intent_progress(C.view other_done)other with Some(W.Committed_pending_presentation _)->true|_->false)
    "ACK of another intent discarded an independent accepted write";
  let fresh,planned=C.request acknowledged session(W.Mutate intent) |> Result.get_ok in
  let fresh_admitted=(C.step planned.next(C.Admitted(fresh,Id.Worker.Request_id.of_int64 27L))).next in
  let fresh_done=(C.step fresh_admitted(C.Completed(fresh,W.Answered(Ok(W.Committed_pending_presentation receipt))))).next in
  check(C.intent_progress(C.view fresh_done)intent<>None) "explicit request planned after ACK was confused with an old completion";
  let stale_ack=(C.step fresh_done(C.Completed(old_ack,W.Answered(Ok())))).next in
  check(C.intent_progress(C.view stale_ack)intent<>None) "old ACK retired a newly reconciled intent lifecycle";
  check(match C.reply(C.view stale_ack)old_ack with Some(W.Answered(Error _))->true|_->false)
    "old ACK was published as the current lifecycle settlement";
  let run actions =
    let state=ref fresh_done in
    List.iter(fun action->
      let event=match action with
        | 0->C.Completed(retry,W.Answered(Ok(W.Committed_pending_presentation receipt)))
        | 1->C.Completed(retry,W.Interrupted W.Transport_lost)
        | 2->C.Cancel retry | 3->C.Forget retry
        | 4->C.Completed(again,W.Answered(Ok(W.Confirmed confirmation)))
        | 5->C.Completed(again,W.Interrupted W.Transport_lost)
        | 6->C.Cancel again | 7->C.Forget again
        | 8->C.Completed(old_ack,W.Answered(Ok()))
        | 9->C.Completed(old_ack,W.Interrupted W.Transport_lost)
        | 10->C.Cancel old_ack | 11->C.Forget old_ack
        | 12->C.Completed(independent,W.Answered(Ok(W.Committed_pending_presentation other_receipt)))
        | _->C.Drain in
      let before=C.view !state in
      let first=C.step !state event and second=C.step !state event in
      check(C.equal_view before(C.view !state)) "retired intent step mutated old view";
      check(C.equal_view(C.view first.next)(C.view second.next)) "retired intent step nondeterministic";
      state:=first.next;
      check(C.intent_progress(C.view !state)intent=Some(W.Committed_pending_presentation receipt))
        "late pre-ACK event replaced the explicitly rebuilt lifecycle";
      check(C.intent_progress(C.view !state)other<>None) "retirement of another intent lost accepted evidence")actions in
  for seed=0 to 199 do
    let random=Random.State.make[|0xAC20;seed|] in
    let prefix=Array.of_list(if seed mod 2=0 then [0;4;8;12] else [1;5;9;12]) in
    for n=Array.length prefix-1 downto 1 do let j=Random.State.int random(n+1) in
      let old=prefix.(n) in prefix.(n)<-prefix.(j);prefix.(j)<-old done;
    let actions=Array.to_list prefix@List.init 64(fun _->Random.State.int random 14) in
    let fails actions=try run actions;false with _->true in
    if fails actions then let minimal=shrink fails actions in
      failwith(Printf.sprintf "retired-intent seed=%d shrunk=%s" seed
        (String.concat ","(List.map string_of_int minimal)))
  done
;;

let test_durable_recovery_ack_properties () =
  let module Wire=Logseq_db_worker_contract.Mutation_pure_wire in
  let issuer,_,projection,session=fixture 1904L in
  let module I=(val issuer:W.ISSUER) in
  let intent=W.mutation_intent session ~mutation_id:(uuid "98000000-0000-4000-8000-000000001904")
    (W.Save_block{block=graph;title="property choice";
      preconditions={blocks=[graph,"block-state:v1:synthetic"];pages=[];scopes=[]}}) |> Result.get_ok in
  let operation=W.Recover_mutations{after=None;maximum_items=1;maximum_bytes=W.maximum_mutation_recovery_bytes} in
  let run trace =
    let state=ref(ready I.binding projection) and reads=ref [] and acks=ref [] and settled=ref false in
    let step event =
      let before=C.view !state in
      let first=C.step !state event and again=C.step !state event in
      check(C.equal_view(C.view first.next)(C.view again.next)) "lifecycle step nondeterministic";
      check(C.equal_view before(C.view !state)) "lifecycle step mutated previous state";
      state:=first.next;
      List.iter(fun ticket->if C.reply(C.view !state)ticket=Some(W.Answered(Ok())) then settled:=true)!acks;
      if !settled then check(C.intent_progress(C.view !state)intent=None) "late event revived acknowledged intent" in
    let read n f=Option.iter f(List.nth_opt !reads(n mod max 1(List.length !reads))) in
    let ack n f=Option.iter f(List.nth_opt !acks(n mod max 1(List.length !acks))) in
    List.iter(fun(op,n)->match op with
      | 0->(match C.request !state session operation with Error _->()|Ok(ticket,next)->
          state:=next.next;reads:=(ticket,!settled)::List.take 7 !reads)
      | 1->read n(fun(ticket,_)->step(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int(100+n)))))
      | 2 | 3->read n(fun(ticket,after_ack)->
          let request_id=match I.request session ~request_id:(C.ticket_id ticket)operation with
            | Ok(S.Coordination_recover_mutations{request_id;_})->request_id|_->assert false in
          let items=if after_ack then Rrbvec.empty else Rrbvec.singleton Wire.{intent=Bytes.to_string(W.encode_mutation_intent intent);
            outcome=(if op=2 then Unknown else Rejected(P.V2_response{api_version=P.api_version;request_id;
              outcome=V2_failed{code="conflict";message="known rejection"}}))} in
          let reply=I.reply session ~request_id:(C.ticket_id ticket)operation
            (S.Coordination_mutations_recovered{request_id;page=Wire.{items;next=None}}) |> Result.get_ok in
          step(C.Completed(ticket,reply)))
      | 4->read n(fun(ticket,_)->step(C.Forget ticket))
      | 5->(match C.request !state session(W.Acknowledge_intent intent) with Error _->()|Ok(ticket,next)->
          check(match C.intent_progress(C.view !state)intent with Some(W.Rejected _)->true|_->false)
            "ACK admitted without known settled evidence";
          state:=next.next;acks:=ticket::List.take 7 !acks)
      | 6->ack n(fun ticket->step(C.Admitted(ticket,Id.Worker.Request_id.of_int64(Int64.of_int(200+n)))))
      | 7->ack n(fun ticket->step(C.Completed(ticket,W.Answered(Ok()))))
      | 8->ack n(fun ticket->step(C.Completed(ticket,W.Interrupted W.Transport_lost)))
      | 9->ack n(fun ticket->step(C.Cancel ticket))
      | 10->ack n(fun ticket->step(C.Forget ticket))
      | _->step C.Drain)trace in
  let prefix=[0,0;1,0;3,0;4,0;0,0;1,0;5,0;6,0;7,0;3,0] in
  for seed=0 to 199 do
    let random=Random.State.make[|0xAC19;seed|] in
    let trace=prefix@List.init 64(fun _->Random.State.int random 12,Random.State.int random 8) in
    let fails trace=try run trace;false with _->true in
    if fails trace then let minimal=shrink fails trace in
      failwith(Printf.sprintf "recovery-ack seed=%d shrunk=%s" seed
        (String.concat ","(List.map(fun(op,n)->Printf.sprintf "%d:%d" op n)minimal)))
  done
;;

let test_observation_planning_is_pure () =
  let issuer, _, projection, session = fixture 720L in
  let module I = (val issuer : W.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let ticket, planned =
    match C.request state session (W.Observe (budget, W.Graph_info)) with
    | Ok value -> value
    | Error _ -> failwith "supported observation was rejected before pure planning"
  in
  check
    (List.exists
       (function
         | C.Send (actual, _, W.Observe _) ->
           W.equal_request_id (C.ticket_id actual) (C.ticket_id ticket)
         | _ -> false)
       planned.instructions)
    "observation planning did not issue its exact typed ticket";
  check
    (C.equal_view (C.view state) (C.view (ready I.binding projection)))
    "observation planning mutated the previous state";
  check
    (C.reply (C.view planned.next) ticket = None)
    "planned registration fabricated a sampled observation"
;;

let pure_observation_response issuer raw session ticket operation epoch revision =
  let module I = (val issuer : W.ISSUER) in
  let registration, owner, observation_id, request_id =
    match
      I.request session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok
    with
    | S.Coordination_observe value ->
      value.registration, value.owner, value.observation_id, value.request.request_id
    | Coordination_refresh_observation value ->
      value.registration, value.owner, value.observation_id, value.request_id
    | _ -> failwith "expected a real observation codec request"
  in
  S.Coordination_observed
    { registration
    ; owner
    ; observation_id
    ; epoch
    ; response =
        P.V2_response
          { api_version = P.api_version
          ; request_id
          ; outcome =
              V2_graph_info_outcome
                { graph_uuid = graph
                ; graph_name = "Pure observation"
                ; schema = { major = 1; minor = 0 }
                ; admission_facts = []
                ; journal_title_format = None
                ; limits = raw.S.limits
                ; generation = "generation:v1:synthetic"
                ; projection_revision = revision
                }
          }
    }
;;

let test_observation_retains_typed_value () =
  let issuer, raw, projection, session = fixture 721L in
  let module I = (val issuer : W.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Observe (budget, W.Graph_info) in
  let ticket, planned = C.request state session operation |> Result.get_ok in
  let response =
    pure_observation_response issuer raw session ticket operation 0L "projection-0"
  in
  let observed =
    match I.reply session ~request_id:(C.ticket_id ticket) operation response with
    | Ok (W.Answered (Ok observed)) -> observed
    | _ -> failwith "valid observed DTO was rejected"
  in
  let admitted = C.step planned.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let completed = C.step admitted.next (C.Completed (ticket, W.Answered (Ok observed))) in
  check
    (C.observed (C.view completed.next) observed.observation = Some observed)
    "coordinator did not retain the exact observed value";
  check
    (C.observed (C.view admitted.next) observed.observation = None)
    "completion changed an earlier immutable observation state";
  let duplicate =
    C.step completed.next (C.Completed (ticket, W.Answered (Ok observed)))
  in
  check
    (C.equal_view (C.view completed.next) (C.view duplicate.next))
    "duplicate observed terminal response was consumed twice"
;;

let test_observation_cancel_requires_ack () =
  let issuer, raw, projection, session = fixture 722L in
  let module I = (val issuer : W.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Observe (budget, W.Graph_info) in
  let ticket, planned = C.request state session operation |> Result.get_ok in
  let response =
    pure_observation_response issuer raw session ticket operation 0L "projection-0"
  in
  let observed =
    match I.reply session ~request_id:(C.ticket_id ticket) operation response with
    | Ok (W.Answered (Ok value)) -> value
    | _ -> failwith "observation fixture"
  in
  let registered = C.step planned.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let completed =
    C.step registered.next (C.Completed (ticket, W.Answered (Ok observed)))
  in
  let forgotten = C.step completed.next (C.Forget ticket) in
  check
    (C.observed (C.view forgotten.next) observed.observation = Some observed)
    "Forget unregistered an observation interest";
  let cancelled = C.step forgotten.next (C.Cancel ticket) in
  check
    (C.observed (C.view cancelled.next) observed.observation = None)
    "Cancel left a retired observation visible";
  check
    (List.exists
       (function
         | C.Release_observation_registration (owner, id) ->
           W.equal_session owner session && W.equal_request_id id (C.ticket_id ticket)
         | _ -> false)
       cancelled.instructions)
    "Cancel did not plan exact resource cleanup";
  let duplicate = C.step cancelled.next (C.Cancel ticket) in
  check
    (not
       (List.exists
          (function
            | C.Release_observation_registration _ -> true
            | _ -> false)
          duplicate.instructions))
    "Cancel duplicated an in-flight cleanup";
  let acknowledged =
    C.step
      duplicate.next
      (C.Observation_release_completed (session, C.ticket_id ticket, Ok ()))
  in
  let late = C.step acknowledged.next (C.Completed (ticket, W.Answered (Ok observed))) in
  check
    (C.observed (C.view late.next) observed.observation = None)
    "late result revived an acknowledged retired observation"
;;

let test_observation_read_failure_and_refresh () =
  let issuer, raw, projection, session = fixture 723L in
  let module I = (val issuer : W.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Observe (budget, W.Graph_info) in
  let ticket, planned = C.request state session operation |> Result.get_ok in
  let response =
    pure_observation_response issuer raw session ticket operation 0L "projection-0"
  in
  let handle, epoch =
    I.observation_registration session ~request_id:(C.ticket_id ticket) operation response
    |> Result.get_ok
  in
  let admitted = C.step planned.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let registered =
    C.step admitted.next (C.Observation_registered (ticket, handle, epoch))
  in
  let failed =
    C.step
      registered.next
      (C.Completed (ticket, W.Answered (Error W.Response_budget_exceeded)))
  in
  check
    (C.observation_handle (C.view failed.next) ticket = Some handle)
    "sample failure erased the acknowledged interest";
  check
    (C.observation_error (C.view failed.next) handle = Some W.Response_budget_exceeded)
    "sample failure disappeared from observation state";
  let forgotten = C.step failed.next (C.Forget ticket) in
  let refreshed, refresh =
    C.request forgotten.next session (W.Refresh handle) |> Result.get_ok
  in
  let response =
    pure_observation_response
      issuer
      raw
      session
      refreshed
      (W.Refresh handle)
      1L
      "projection-1"
  in
  let value =
    match
      I.reply session ~request_id:(C.ticket_id refreshed) (W.Refresh handle) response
    with
    | Ok (W.Answered (Ok value)) -> value
    | _ -> failwith "refresh fixture"
  in
  let admitted = C.step refresh.next (C.Admitted (refreshed, Id.Worker.Request_id.one)) in
  let registered =
    C.step admitted.next (C.Observation_registered (refreshed, handle, value.epoch))
  in
  let completed =
    C.step registered.next (C.Completed (refreshed, W.Answered (Ok value)))
  in
  check
    (C.observed (C.view completed.next) handle = Some value)
    "Refresh failed to update the retained observation";
  check
    (C.observation_error (C.view completed.next) handle = None)
    "successful Refresh retained an obsolete sample error";
  let release, planned =
    match C.request completed.next session (W.Release handle) with
    | Ok value -> value
    | _ -> failwith "registered observation Release was rejected"
  in
  check (C.reply (C.view planned.next) release = None) "Release fabricated an ACK";
  check
    (C.observed (C.view planned.next) handle = None)
    "Release still presented retired data";
  let ack =
    C.step
      planned.next
      (C.Observation_release_completed (session, W.observation_id handle, Ok ()))
  in
  check
    (C.reply (C.view ack.next) release = Some (W.Answered (Ok ())))
    "actual release ACK did not settle its unit ticket";
  let again, again_state =
    C.request ack.next session (W.Release handle) |> Result.get_ok
  in
  check
    (C.reply (C.view again_state.next) again = Some (W.Answered (Ok ())))
    "idempotent Release forgot the actual retired-resource ACK"
;;

let test_observation_notice_plans_one_refresh () =
  let issuer, raw, projection, session = fixture 724L in
  let module I = (val issuer : W.ISSUER) in
  let operation =
    W.Observe
      ( W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
      , W.Graph_info )
  in
  let ticket, planned =
    C.request (ready I.binding projection) session operation |> Result.get_ok
  in
  let response =
    pure_observation_response issuer raw session ticket operation 0L "projection-0"
  in
  let value =
    match I.reply session ~request_id:(C.ticket_id ticket) operation response with
    | Ok (W.Answered (Ok value)) -> value
    | _ -> failwith "observation fixture"
  in
  let admitted = C.step planned.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let completed = C.step admitted.next (C.Completed (ticket, W.Answered (Ok value))) in
  let logical =
    match response with
    | S.Coordination_observed v -> v.observation_id
    | _ -> assert false
  in
  let notice epoch =
    I.observation_notices
      (S.Coordination_observations
         (Rrbvec.singleton
            (S.Observation_invalidated
               { registration_id = raw.registration
               ; owner = Option.get raw.baseline.state.sync.selected
               ; observation_id = logical
               ; epoch
               })))
    |> Result.get_ok
    |> fun values -> Option.get (Rrbvec.nth_opt values 0)
  in
  let invalidated = C.step completed.next (C.Observation_notice (notice 1L)) in
  let count transition =
    List.fold_left
      (fun n -> function
         | C.Send (_, _, W.Refresh _) -> n + 1
         | _ -> n)
      0
      transition.C.instructions
  in
  check (count invalidated = 1) "invalidation did not plan one scoped Refresh";
  List.iter
    (function
      | C.Send (refresh, _, W.Refresh _) ->
        let admitted =
          C.step invalidated.next (C.Admitted (refresh, Id.Worker.Request_id.one))
        in
        let failed =
          C.step
            admitted.next
            (C.Completed (refresh, W.Answered (Error W.Response_budget_exceeded)))
        in
        check
          (C.observed (C.view failed.next) value.observation = Some value)
          "Refresh error erased the last good sample";
        check
          (C.observation_error (C.view failed.next) value.observation
           = Some W.Response_budget_exceeded)
          "internal Refresh failure disappeared with its forgotten ticket";
        let stale = C.step failed.next (C.Observation_received value) in
        check
          (C.observation_error (C.view stale.next) value.observation
           = Some W.Response_budget_exceeded)
          "an old retained sample cleared the newer refresh failure";
        check
          (count (C.step failed.next C.Capacity_available) = 0)
          "sample failure busy-retried without a newer invalidation"
      | _ -> ())
    invalidated.instructions;
  let duplicate = C.step invalidated.next (C.Observation_notice (notice 1L)) in
  check (count duplicate = 0) "duplicate invalidation duplicated a Refresh";
  let newer = C.step duplicate.next (C.Observation_notice (notice 2L)) in
  check (count newer = 0) "in-flight refresh was duplicated instead of coalesced";
  let released = C.step newer.next (C.Release value.observation) in
  let late = C.step released.next (C.Observation_notice (notice 3L)) in
  check (count late = 0) "retired interest accepted a late invalidation"
;;

let test_observation_cleanup_failure_waits_for_explicit_retry () =
  let issuer, _, projection, session = fixture 725L in
  let module I = (val issuer : W.ISSUER) in
  let operation =
    W.Observe
      ( W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
      , W.Graph_info )
  in
  let ticket, planned =
    C.request (ready I.binding projection) session operation |> Result.get_ok
  in
  let canceled = C.step planned.next (C.Cancel ticket) in
  let refused =
    C.step
      canceled.next
      (C.Observation_release_not_admitted (session, C.ticket_id ticket, W.Full))
  in
  check
    (not
       (List.exists
          (function
            | C.Release_observation_registration _ -> true
            | _ -> false)
          refused.instructions))
    "Full cleanup immediately retried without a capacity wakeup";
  let capacity = C.step refused.next C.Capacity_available in
  check
    (List.length
       (List.filter
          (function
            | C.Release_observation_registration _ -> true
            | _ -> false)
          capacity.instructions)
     = 1)
    "capacity wakeup did not retry exactly one pending cleanup";
  let error = W.Service_failed "physical cleanup is unavailable" in
  let failed =
    C.step
      canceled.next
      (C.Observation_release_completed (session, C.ticket_id ticket, Error error))
  in
  let capacity = C.step failed.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Release_observation_registration _ -> true
            | _ -> false)
          capacity.instructions))
    "a failed cleanup busy-retried on the runner's own capacity notification";
  let retried = C.step capacity.next (C.Cancel ticket) in
  check
    (List.exists
       (function
         | C.Release_observation_registration _ -> true
         | _ -> false)
       retried.instructions)
    "explicit cleanup retry did not resume the retained resource"
;;

let test_observation_full_batch_does_not_self_wake () =
  let issuer, _, projection, session = fixture 727L in
  let module I = (val issuer : W.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let state = ref (ready I.binding projection)
  and tickets = ref [] in
  for _ = 1 to 256 do
    let ticket, tr =
      C.request !state session (W.Observe (budget, W.Graph_info)) |> Result.get_ok
    in
    state := tr.next;
    tickets := ticket :: !tickets
  done;
  let count tr =
    List.length
      (List.filter
         (function
           | C.Release_observation_registration _ -> true
           | _ -> false)
         tr.C.instructions)
  in
  List.iter (fun ticket -> state := (C.step !state (C.Cancel ticket)).next) !tickets;
  let refuse () =
    List.iter
      (fun ticket ->
         let tr =
           C.step
             !state
             (C.Observation_release_not_admitted (session, C.ticket_id ticket, W.Full))
         in
         check (count tr = 0) "Full cleanup immediately re-entered its own batch";
         state := tr.next)
      !tickets
  in
  refuse ();
  let capacity = C.step !state C.Capacity_available in
  check (count capacity = 128) "cleanup did not bound its capacity-woken retry batch";
  state := capacity.next;
  refuse ();
  let drain = C.step !state C.Drain in
  check
    (count drain = 0
     && not
          (List.exists
             (function
               | C.Schedule_drain -> true
               | _ -> false)
             drain.instructions))
    "internally scheduled Drain repeatedly retried a Full batch without capacity"
;;

let test_observation_focus_and_reopen_fences () =
  let issuer, raw, projection, session = fixture 728L in
  let module I = (val issuer : W.ISSUER) in
  let project raw =
    match I.bootstrap (S.Coordination_registered raw) with
    | Ok (W.Ready p) -> p
    | _ -> failwith "scope fixture"
  in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Observe (budget, W.Graph_info) in
  let ticket, planned =
    C.request (ready I.binding projection) session operation |> Result.get_ok
  in
  let response =
    pure_observation_response issuer raw session ticket operation 0L "initial"
  in
  let value =
    match I.reply session ~request_id:(C.ticket_id ticket) operation response with
    | Ok (W.Answered (Ok v)) -> v
    | _ -> failwith "scope observed fixture"
  in
  let admitted = C.step planned.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let done_ = C.step admitted.next (C.Completed (ticket, W.Answered (Ok value))) in
  let focused =
    project { raw with baseline = { raw.baseline with version = 2L; presentation = 2L } }
  in
  let focused = C.step done_.next (C.Projection_received focused) in
  check
    (C.observed (C.view focused.next) value.observation = Some value)
    "presentation change revoked a resident observation";
  let closed =
    project
      { raw with
        baseline =
          { version = 3L
          ; presentation = 3L
          ; state =
              { sync =
                  { raw.baseline.state.sync with
                    desired_residents = []
                  ; residents = []
                  ; selected = None
                  }
              ; residents = []
              }
          }
      }
  in
  let closed = C.step focused.next (C.Projection_received closed) in
  check
    (C.observed (C.view closed.next) value.observation = None)
    "closed graph retained an observed value";
  check
    (List.exists
       (function
         | C.Release_observation_registration (owner, id) ->
           W.equal_session owner session && W.equal_request_id id (C.ticket_id ticket)
         | _ -> false)
       closed.instructions)
    "close did not retain the exact old resource cleanup owner";
  let bump (scope : S.asset_scope) =
    { scope with graph_generation = scope.graph_generation + 1 }
  in
  let owner = Option.get raw.baseline.state.sync.selected in
  let reopened =
    project
      { raw with
        baseline =
          { version = 4L
          ; presentation = 4L
          ; state =
              { sync =
                  { raw.baseline.state.sync with
                    selected =
                      Some { owner with graph_generation = owner.graph_generation + 1 }
                  ; residents =
                      List.map
                        (fun (scope, state) -> bump scope, state)
                        raw.baseline.state.sync.residents
                  }
              ; residents =
                  List.map
                    (fun (scope, state) ->
                       ( bump scope
                       , { state with
                           Logseq_db_worker.generation =
                             state.Logseq_db_worker.generation + 1
                         } ))
                    raw.baseline.state.residents
              }
          }
      }
  in
  let reopened = C.step closed.next (C.Projection_received reopened) in
  let late = C.step reopened.next (C.Observation_received value) in
  check
    (C.observed (C.view late.next) value.observation = None)
    "old value revived a reopened graph";
  check
    (Result.is_error (C.request late.next session (W.Refresh value.observation)))
    "old observation refreshed the reopened graph";
  let new_session =
    (List.hd (W.residents (Option.get (C.projection (C.view late.next))))).session
  in
  let new_budget =
    W.read_budget new_session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  check
    (Result.is_ok
       (C.request late.next new_session (W.Observe (new_budget, W.Graph_info))))
    "old observation cleanup incorrectly fenced a new graph generation";
  let acknowledged =
    C.step
      late.next
      (C.Observation_release_completed (session, C.ticket_id ticket, Ok ()))
  in
  let repeated = C.step acknowledged.next (C.Observation_received value) in
  check
    (C.observed (C.view repeated.next) value.observation = None)
    "old released value resurfaced"
;;

let test_observation_retirement_capacity_resets_only_after_binding_ack () =
  let issuer, raw, projection, session = fixture 729L in
  let module I = (val issuer : W.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let state = ref (ready I.binding projection)
  and old_value = ref None in
  let step event = state := (C.step !state event).next in
  for n = 1 to 8192 do
    let ticket, tr =
      C.request !state session (W.Observe (budget, W.Graph_info)) |> Result.get_ok
    in
    if n = 1
    then (
      let operation = W.Observe (budget, W.Graph_info) in
      let response =
        pure_observation_response issuer raw session ticket operation 0L "old-binding"
      in
      old_value
      := match I.reply session ~request_id:(C.ticket_id ticket) operation response with
         | Ok (W.Answered (Ok value)) -> Some value
         | _ -> assert false);
    state := tr.next;
    step (C.Admitted (ticket, Id.Worker.Request_id.one));
    step (C.Cancel ticket);
    step (C.Completed (ticket, W.Interrupted W.Cancelled));
    step (C.Forget ticket);
    step (C.Observation_release_completed (session, C.ticket_id ticket, Ok ()))
  done;
  check
    (Result.is_error (C.request !state session (W.Observe (budget, W.Graph_info))))
    "retired ID history exceeded its bound";
  step C.Retry_bootstrap;
  step (C.Binding_release_completed (I.binding, Ok ()));
  let next_issuer, _, next_projection, next_session = fixture 730L in
  let module Next = (val next_issuer : W.ISSUER) in
  step (C.Worker_bound Next.binding);
  step (C.Bootstrap_received (Next.binding, W.Ready next_projection));
  let budget =
    W.read_budget next_session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let _, fresh =
    match C.request !state next_session (W.Observe (budget, W.Graph_info)) with
    | Ok value -> value
    | _ ->
      failwith
        "retired IDs from an acknowledged old binding permanently exhausted new \
         observation capacity"
  in
  state := fresh.next;
  let before = C.view !state in
  let old = Option.get !old_value in
  step (C.Observation_received old);
  step (C.Release old.observation);
  step
    (C.Observation_release_completed (session, W.observation_id old.observation, Ok ()));
  check
    (C.equal_view before (C.view !state))
    "old binding callbacks affected a new interest";
  check
    (Result.is_error (C.request !state next_session (W.Release old.observation)))
    "old handle claimed cleanup authority in the replacement binding"
;;

(* Generate admitted histories plus adversarial delivery orders through the public
   pure boundary. No implementation tables or private handle constructors. *)
let test_observation_properties () =
  let issuer, raw, projection, session = fixture 726L in
  let module I = (val issuer : W.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
  in
  let run trace =
    let state = ref (ready I.binding projection) in
    let attempts : (W.graph_info W.observed C.ticket * W.graph_info W.observed) list ref =
      ref []
    in
    let interests
      : (W.graph_info W.observed C.ticket * W.graph_info W.observation) list ref
      =
      ref []
    in
    let retired = ref []
    and seen = ref []
    and accepted = ref [] in
    let next_epoch = ref 0L in
    let forbid id =
      if not (List.exists (W.equal_request_id id) !retired) then retired := id :: !retired
    in
    let verify () =
      List.iter
        (fun (ticket, handle) ->
           let id = C.ticket_id ticket in
           let value = C.observed (C.view !state) handle in
           if List.exists (W.equal_request_id id) !retired
           then check (value = None) "retired observation revived";
           match value with
           | None -> ()
           | Some value ->
             check
               (W.same_observation value.observation handle <> None)
               "observation changed its sealed owner";
             let previous =
               List.find_map
                 (fun (actual, epoch) ->
                    if W.equal_request_id actual id then Some epoch else None)
                 !seen
             in
             check
               (Option.fold
                  ~none:true
                  ~some:(fun epoch -> W.compare_observation_epoch value.epoch epoch >= 0)
                  previous)
               "observation epoch moved backwards";
             seen
             := (id, value.epoch)
                :: List.filter
                     (fun (actual, _) -> not (W.equal_request_id actual id))
                     !seen)
        !interests
    in
    let record : type a. a C.ticket -> a W.request -> unit =
      fun ticket operation ->
      match operation with
      | W.Observe (_, W.Graph_info) ->
        let response =
          pure_observation_response issuer raw session ticket operation 0L "initial"
        in
        let value =
          match I.reply session ~request_id:(C.ticket_id ticket) operation response with
          | Ok (W.Answered (Ok value)) -> value
          | _ -> failwith "property initial codec"
        in
        attempts := (ticket, value) :: !attempts;
        interests := (ticket, value.observation) :: !interests
      | W.Refresh handle ->
        (match W.observation_query handle with
         | W.Graph_info ->
           next_epoch := Int64.succ !next_epoch;
           let response =
             pure_observation_response
               issuer
               raw
               session
               ticket
               operation
               !next_epoch
               (Int64.to_string !next_epoch)
           in
           let value =
             match
               I.reply session ~request_id:(C.ticket_id ticket) operation response
             with
             | Ok (W.Answered (Ok value)) -> value
             | _ -> failwith "property refresh codec"
           in
           attempts := (ticket, value) :: !attempts
         | _ -> ())
      | _ -> ()
    in
    let apply transition =
      state := transition.C.next;
      List.iter
        (function
          | C.Send (ticket, owner, operation) ->
            check (W.equal_session owner session) "refresh switched its execution owner";
            record ticket operation
          | C.Release_observation_registration (owner, id) ->
            check
              (W.equal_session owner session
               && List.exists
                    (fun (ticket, _) -> W.equal_request_id id (C.ticket_id ticket))
                    !interests)
              "cleanup adopted an unplanned/foreign observation"
          | _ -> ())
        transition.instructions;
      check (List.length transition.instructions < 1000) "observation batch overflow";
      verify ()
    in
    let step event =
      let before = C.view !state in
      let a = C.step !state event
      and b = C.step !state event in
      check
        (C.equal_view (C.view a.next) (C.view b.next))
        "observation step is nondeterministic";
      check (C.equal_view before (C.view !state)) "observation mutated its input view";
      apply a
    in
    let attempt n f =
      match List.nth_opt !attempts (n mod max 1 (List.length !attempts)) with
      | Some x -> f x
      | None -> ()
    in
    let interest n f =
      match List.nth_opt !interests (n mod max 1 (List.length !interests)) with
      | Some x -> f x
      | None -> ()
    in
    List.iter
      (fun (op, n) ->
         match op with
         | 0 ->
           (match C.request !state session (W.Observe (budget, W.Graph_info)) with
            | Ok (_, transition) -> apply transition
            | _ -> ())
         | 1 ->
           attempt n (fun (ticket, _) ->
             accepted := C.ticket_id ticket :: !accepted;
             step
               (C.Admitted (ticket, Id.Worker.Request_id.of_int64 (Int64.of_int (n + 1)))))
         | 2 ->
           attempt n (fun (ticket, value) ->
             step (C.Observation_registered (ticket, value.observation, value.epoch)))
         | 3 ->
           attempt n (fun (ticket, value) ->
             step (C.Completed (ticket, W.Answered (Ok value)));
             let once = C.reply (C.view !state) ticket in
             step (C.Completed (ticket, W.Answered (Ok value)));
             check
               (C.reply (C.view !state) ticket = once)
               "observation terminal consumed twice")
         | 4 ->
           interest n (fun (ticket, _) ->
             forbid (C.ticket_id ticket);
             step (C.Cancel ticket))
         | 5 -> interest n (fun (ticket, _) -> step (C.Forget ticket))
         | 6 ->
           interest n (fun (ticket, _) ->
             let owner = Option.get raw.baseline.state.sync.selected in
             let owner =
               if n mod 4 = 0
               then { owner with graph_generation = owner.graph_generation + 1 }
               else owner
             in
             let wire =
               match
                 I.request
                   session
                   ~request_id:(C.ticket_id ticket)
                   (W.Observe (budget, W.Graph_info))
                 |> Result.get_ok
               with
               | S.Coordination_observe v -> v.observation_id
               | _ -> assert false
             in
             let notices =
               I.observation_notices
                 (S.Coordination_observations
                    (Rrbvec.singleton
                       (S.Observation_invalidated
                          { registration_id = raw.registration
                          ; owner
                          ; observation_id = wire
                          ; epoch = Int64.of_int (n mod 9)
                          })))
               |> Result.get_ok
             in
             Rrbvec.iter (fun notice -> step (C.Observation_notice notice)) notices)
         | 7 ->
           interest n (fun (ticket, handle) ->
             forbid (C.ticket_id ticket);
             step (C.Release handle))
         | 8 ->
           interest n (fun (ticket, _) ->
             step (C.Observation_release_completed (session, C.ticket_id ticket, Ok ())))
         | 9 ->
           attempt n (fun (ticket, _) ->
             if
               List.exists
                 (fun (original, _) ->
                    W.equal_request_id (C.ticket_id original) (C.ticket_id ticket))
                 !interests
               && (not (List.exists (W.equal_request_id (C.ticket_id ticket)) !accepted))
               && C.reply (C.view !state) ticket = None
             then forbid (C.ticket_id ticket);
             step (C.Admission_refused (ticket, W.Full)))
         | 10 ->
           attempt n (fun (ticket, _) ->
             step (C.Completed (ticket, W.Answered (Error W.Response_budget_exceeded))))
         | 11 -> step C.Capacity_available
         | 12 ->
           List.iter (fun (ticket, _) -> forbid (C.ticket_id ticket)) !interests;
           step C.Shutdown_requested
         | 13 -> step (C.Binding_release_completed (I.binding, Ok ()))
         | 14 -> step (C.Bootstrap_received (I.binding, W.Ready projection))
         | 15 ->
           interest n (fun (ticket, _) ->
             step
               (C.Observation_release_not_admitted (session, C.ticket_id ticket, W.Full)))
         | 16 ->
           interest n (fun (ticket, _) ->
             step
               (C.Observation_release_completed
                  (session, C.ticket_id ticket, Error (W.Service_failed "held"))))
         | 17 ->
           interest n (fun (_, handle) ->
             match C.request !state session (W.Refresh handle) with
             | Ok (_, tr) -> apply tr
             | _ -> ())
         | _ -> attempt n (fun (_, value) -> step (C.Observation_received value)))
      trace
  in
  let prefixes =
    [ [ 0, 0; 1, 0; 2, 0; 3, 0; 6, 1; 1, 0; 2, 0; 3, 0 ]
    ; [ 0, 0; 3, 0; 4, 0; 1, 0; 2, 0; 8, 0 ]
    ; [ 0, 0; 2, 0; 10, 0; 1, 0; 5, 0; 17, 0 ]
    ; [ 0, 0; 3, 0; 9, 0; 2, 0; 8, 0 ]
    ; [ 0, 0; 5, 0; 2, 0; 1, 0; 3, 0; 7, 0; 15, 0; 11, 0; 8, 0 ]
    ; [ 0, 0; 1, 0; 2, 0; 3, 0; 12, 0; 13, 0; 14, 0; 3, 0 ]
    ]
  in
  for seed = 0 to 299 do
    let random = Random.State.make [| 0x0b5e7; seed |] in
    let trace =
      List.nth prefixes (seed mod List.length prefixes)
      @ List.init 80 (fun _ ->
        let op = Random.State.int random 19 in
        (if op = 12 && seed mod 3 <> 0 then 6 else op), Random.State.int random 24)
    in
    let fails trace =
      try
        run trace;
        false
      with
      | _ -> true
    in
    if fails trace
    then (
      let minimal = shrink fails trace in
      try run minimal with
      | exn ->
        failwith
          (Printf.sprintf
             "observation property seed=%d minimal=[%s]: %s"
             seed
             (String.concat
                ";"
                (List.map (fun (op, n) -> Printf.sprintf "%d:%d" op n) minimal))
             (Printexc.to_string exn)))
  done
;;

let test_dependency_read_waits_for_capacity () =
  let issuer, raw, projection, session = fixture 745L in
  let module I = (val issuer : W.ISSUER) in
  let owner = Option.get raw.baseline.state.sync.selected in
  let state = ready I.binding projection in
  let ticket, planned =
    C.plan_query_when_available
      state
      ~owner
      ~maximum_items:1
      ~maximum_bytes:65536
      (W.Outline_block { uuid = graph; revision = None })
    |> Result.get_ok
  in
  let full = C.step planned.next (C.Admission_refused (ticket, W.Full)) in
  check
    (C.reply (C.view full.next) ticket = None)
    "Full terminated a logical dependency read";
  let ignored =
    C.step
      full.next
      (C.Completed
         (ticket, W.Answered (Error (W.Service_failed "impossible unadmitted completion"))))
  in
  check
    (C.reply (C.view ignored.next) ticket = None)
    "unadmitted completion escaped capacity waiting";
  let drain = C.step ignored.next C.Drain in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          drain.instructions))
    "Full dependency self-retried on Drain";
  let capacity = C.step drain.next C.Capacity_available in
  check
    (List.exists
       (function
         | C.Send (actual, actual_session, W.Query (_, W.Outline_block _)) ->
           W.equal_request_id (C.ticket_id actual) (C.ticket_id ticket)
           && W.equal_session actual_session session
         | _ -> false)
       capacity.instructions)
    "capacity did not retry the exact dependency ticket and session";
  let duplicate = C.step capacity.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          duplicate.instructions))
    "capacity duplicated an active dependency read";
  let admitted = C.step duplicate.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let contradictory = C.step admitted.next (C.Admission_refused (ticket, W.Full)) in
  check
    (C.reply (C.view contradictory.next) ticket = None)
    "late Full replaced an admitted read";
  let completed =
    C.step
      contradictory.next
      (C.Completed (ticket, W.Answered (Error (W.Service_failed "actual read failure"))))
  in
  check
    (C.reply (C.view completed.next) ticket
     = Some (W.Answered (Error (W.Service_failed "actual read failure"))))
    "capacity waiting hid an actual terminal read failure";
  let cancelled = C.step full.next (C.Cancel ticket) in
  let capacity = C.step cancelled.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          capacity.instructions))
    "cancelled waiting dependency was resent";
  let unavailable = C.step planned.next (C.Admission_refused (ticket, W.Not_ready)) in
  check
    (C.reply (C.view unavailable.next) ticket = Some (W.Not_admitted W.Not_ready))
    "capacity planner hid a non-Full refusal";
  let bump (scope : S.asset_scope) =
    { scope with
      account =
        { scope.account with
          lifecycle_generation = Int64.succ scope.account.lifecycle_generation
        }
    }
  in
  let baseline =
    { raw.baseline with
      version = 2L
    ; state =
        { sync =
            { raw.baseline.state.sync with
              account =
                Option.map
                  (fun (account : Sync.account_scope) ->
                     { account with
                       lifecycle_generation = Int64.succ account.lifecycle_generation
                     })
                  raw.baseline.state.sync.account
            ; residents =
                List.map
                  (fun (scope, value) -> bump scope, value)
                  raw.baseline.state.sync.residents
            }
        ; residents =
            List.map
              (fun (scope, value) -> bump scope, value)
              raw.baseline.state.residents
        }
    }
  in
  let changed =
    match I.bootstrap (S.Coordination_registered { raw with baseline }) with
    | Ok (W.Ready value) -> value
    | _ -> failwith "capacity lifecycle fixture"
  in
  let retired = C.step full.next (C.Projection_received changed) in
  let capacity = C.step retired.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          capacity.instructions))
    "capacity retry borrowed a replacement lifecycle";
  check
    (C.reply (C.view capacity.next) ticket = Some (W.Answered (Error W.Revoked_session)))
    "capacity retry retained a stale execution origin";
  let ordinary, planned =
    C.plan_query state ~owner ~maximum_items:1 ~maximum_bytes:65536 W.Graph_info
    |> Result.get_ok
  in
  let refused = C.step planned.next (C.Admission_refused (ordinary, W.Full)) in
  check
    (C.reply (C.view refused.next) ordinary = Some (W.Not_admitted W.Full))
    "ordinary planner lost its explicit refusal semantics"
;;

let test_live_binding_invalidation_is_pure () =
  let old_issuer, _, old_projection, old_session = fixture 741L in
  let new_issuer, _, new_projection, new_session = fixture 742L in
  let module Old = (val old_issuer : W.ISSUER) in
  let module New = (val new_issuer : W.ISSUER) in
  let initial = ready Old.binding old_projection in
  let invalidated = C.step initial (C.Binding_invalidated Old.binding) in
  check
    (C.validate_session invalidated.next old_session = Error W.Revoked_session)
    "live invalidation left old session data admission open";
  check
    (List.exists
       (function
         | C.Release_binding binding -> W.equal_binding binding Old.binding
         | _ -> false)
       invalidated.instructions)
    "live invalidation did not require actual old registration release";
  let released =
    C.step invalidated.next (C.Binding_release_completed (Old.binding, Ok ()))
  in
  let bound = C.step released.next (C.Worker_bound New.binding) in
  let denied =
    C.step
      bound.next
      (C.Bootstrap_received (New.binding, W.Binding_revoked W.Revoked_session))
  in
  let capacity = C.step denied.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Bind_replacement | C.Bootstrap -> true
            | _ -> false)
          capacity.instructions))
    "replacement authority denial created an automatic registration loop";
  let run trace =
    let state = ref invalidated.next
    and released = ref false
    and replaced = ref false in
    List.iter
      (fun op ->
         let event =
           match op with
           | 0 -> C.Binding_invalidated Old.binding
           | 1 -> C.Projection_received old_projection
           | 2 -> C.Bootstrap_received (Old.binding, W.Ready old_projection)
           | 3 -> C.Capacity_available
           | 4 -> C.Drain
           | 5 -> C.Binding_release_completed (Old.binding, Ok ())
           | 6 -> C.Binding_release_not_admitted (Old.binding, W.Full)
           | 7 -> C.Worker_bound New.binding
           | _ -> C.Bootstrap_received (New.binding, W.Ready new_projection)
         in
         let before = C.view !state in
         let tr = C.step !state event in
         check
           (C.equal_view (C.view !state) before)
           "live invalidation mutated a prior view";
         check
           (C.equal_view (C.view tr.next) (C.view (C.step !state event).next))
           "invalidation ceased to be deterministic";
         List.iter
           (function
             | C.Bind_replacement ->
               check
                 (!released && not !replaced)
                 "replacement escaped one real release ACK";
               replaced := true
             | _ -> ())
           (if op = 5
            then (
              released := true;
              tr.instructions)
            else tr.instructions);
         state := tr.next;
         check
           (C.validate_session !state old_session = Error W.Revoked_session)
           "late old binding revived its session";
         if C.validate_session !state new_session = Ok ()
         then check (!released && !replaced) "fresh session preceded actual replacement")
      trace
  in
  for seed = 0 to 199 do
    let random = Random.State.make [| 0xb1d; seed |] in
    let trace =
      [ 0; 1; 2; 6; 3; 5; 7; 8 ] @ List.init 64 (fun _ -> Random.State.int random 9)
    in
    let fails trace =
      try
        run trace;
        false
      with
      | _ -> true
    in
    if fails trace
    then (
      let minimal = shrink fails trace in
      try run minimal with
      | error ->
        failwith
          (Printf.sprintf
             "binding invalidation seed=%d minimal=[%s]: %s"
             seed
             (String.concat "," (List.map string_of_int minimal))
             (Printexc.to_string error)))
  done
;;

let test_changefeed_planning_owns_its_typed_ticket () =
  let issuer, _, projection, session = fixture 731L in
  let module I = (val issuer : W.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok
  in
  let ticket, planned =
    match
      C.request
        state
        session
        (W.Query
           (budget, W.Changes { generation = "generation:v1:synthetic"; after = None }))
    with
    | Ok value -> value
    | Error _ -> failwith "typed changefeed pull is still rejected before owned planning"
  in
  check
    (List.exists
       (function
         | C.Send (actual, owner, W.Query (_, W.Changes _)) ->
           W.equal_session owner session
           && W.equal_request_id (C.ticket_id actual) (C.ticket_id ticket)
         | _ -> false)
       planned.instructions)
    "Changes did not use its exact pure coordinator ticket";
  check (C.reply (C.view planned.next) ticket = None) "planned Changes fabricated a batch"
;;

let test_changes_serial_and_ack_capacity () =
  let issuer, _, projection, session = fixture 736L in
  let module I = (val issuer : W.ISSUER) in
  let state = ref (ready I.binding projection) in
  let budget =
    W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Query (budget, W.Changes { generation = "g"; after = None }) in
  let first, planned = C.request !state session operation |> Result.get_ok in
  let second, queued = C.request planned.next session operation |> Result.get_ok in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          queued.instructions))
    "same-session Changes dispatched concurrently";
  let failed = C.step queued.next (C.Admission_refused (first, W.Full)) in
  let retry = C.step failed.next C.Capacity_available in
  check
    (List.exists
       (function
         | C.Send (ticket, _, W.Query (_, W.Changes _)) ->
           W.equal_request_id (C.ticket_id ticket) (C.ticket_id second)
         | _ -> false)
       retry.instructions)
    "queued Changes did not progress after the earlier request terminated";
  state := retry.next;
  let request_id =
    match
      I.request session ~request_id:(C.ticket_id second) operation |> Result.get_ok
    with
    | S.Coordination_query value -> value.request.request_id
    | _ -> assert false
  in
  let batch =
    match
      I.reply
        session
        ~request_id:(C.ticket_id second)
        operation
        (S.Graph_response
           (P.V2_response
              { api_version = P.api_version
              ; request_id
              ; outcome =
                  P.V2_changes
                    { generation = "g"
                    ; from_exclusive = None
                    ; through = "zero"
                    ; windows = []
                    ; next = None
                    }
              }))
    with
    | Ok (W.Answered (Ok value)) -> value
    | _ -> failwith "serial Changes fixture"
  in
  state := (C.step !state (C.Admitted (second, Id.Worker.Request_id.one))).next;
  state := (C.step !state (C.Completed (second, W.Answered (Ok batch)))).next;
  let root = uuid "98000000-0000-4000-8000-000000007361" in
  let token, begun = C.begin_change_application !state batch ~root |> Result.get_ok in
  state
  := (C.step begun.next (C.Change_consumer_expanded (token, root, Rrbvec.empty))).next;
  state := (C.step !state (C.Change_consumer_applied (token, root, Ok ()))).next;
  let ack, planned =
    C.request !state session (W.Acknowledge_changes batch) |> Result.get_ok
  in
  let full = C.step planned.next (C.Admission_refused (ack, W.Full)) in
  check
    (C.reply (C.view full.next) ack = None)
    "Full terminated an ACK while retaining its only unapplied chain";
  let drained = C.step full.next C.Drain in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          drained.instructions))
    "Full ACK self-retried without a capacity notification";
  let available = C.step drained.next C.Capacity_available in
  check
    (List.exists
       (function
         | C.Send (ticket, _, W.Acknowledge_changes _) ->
           W.equal_request_id (C.ticket_id ticket) (C.ticket_id ack)
         | _ -> false)
       available.instructions)
    "capacity did not retry the exact unapplied ACK";
  let duplicate = C.step available.next C.Capacity_available in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          duplicate.instructions))
    "capacity duplicated an in-flight ACK";
  let admitted =
    C.step duplicate.next (C.Admitted (ack, Id.Worker.Request_id.of_int64 2L))
  in
  let failed =
    C.step
      admitted.next
      (C.Completed (ack, W.Answered (Error (W.Service_failed "transient ACK failure"))))
  in
  check
    (C.change_application_error (C.view failed.next) batch
     = Some (W.Service_failed "transient ACK failure"))
    "failed ACK left the unapplied chain permanently ready but unrepeatable";
  let retry, planned = C.request failed.next session operation |> Result.get_ok in
  check
    (List.exists
       (function
         | C.Send (ticket, _, W.Query (_, W.Changes _)) ->
           W.equal_request_id (C.ticket_id ticket) (C.ticket_id retry)
         | _ -> false)
       planned.instructions)
    "later refresh could not reread the exact failed ACK chain"
;;

let test_changefeed_ack_requires_owned_delivered_batch () =
  let issuer, _, projection, session = fixture 732L in
  let module I = (val issuer : W.ISSUER) in
  let state = ready I.binding projection in
  let budget =
    W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation =
    W.Query (budget, W.Changes { generation = "generation:v1:synthetic"; after = None })
  in
  let ticket, planned = C.request state session operation |> Result.get_ok in
  let window : P.v2_change_window =
    { id = "window-1"
    ; predecessor = "projection-0"
    ; successor = "projection-1"
    ; block_uuids = [ graph ]
    ; page_uuids = []
    ; structure_interests = []
    }
  in
  let response =
    S.Graph_response
      (P.V2_response
         { api_version = P.api_version
         ; request_id =
             (match
                I.request session ~request_id:(C.ticket_id ticket) operation
                |> Result.get_ok
              with
              | S.Coordination_query v -> v.request.request_id
              | _ -> assert false)
         ; outcome =
             P.V2_changes
               { generation = "generation:v1:synthetic"
               ; from_exclusive = None
               ; through = "window-1"
               ; windows = [ window ]
               ; next = None
               }
         })
  in
  let batch =
    match I.reply session ~request_id:(C.ticket_id ticket) operation response with
    | Ok (W.Answered (Ok batch)) -> batch
    | _ -> failwith "checked Changes batch codec"
  in
  check
    (Result.is_error (C.request planned.next session (W.Acknowledge_changes batch)))
    "a decoded batch was ACKed before coordinator delivery/admission";
  let late, late_plan = C.request planned.next session operation |> Result.get_ok in
  let admitted = C.step late_plan.next (C.Admitted (ticket, Id.Worker.Request_id.one)) in
  let completed = C.step admitted.next (C.Completed (ticket, W.Answered (Ok batch))) in
  let forgotten = C.step completed.next (C.Forget ticket) in
  let root = uuid "98000000-0000-4000-8000-000000007321" in
  let application, begun =
    C.begin_change_application forgotten.next batch ~root |> Result.get_ok
  in
  let pending_ack, pending_plan =
    C.request begun.next session (W.Acknowledge_changes batch) |> Result.get_ok
  in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          pending_plan.instructions))
    "Changes ACK was sent before its consumer root was applied";
  let child = uuid "98000000-0000-4000-8000-000000007322" in
  let early =
    C.step pending_plan.next (C.Change_consumer_applied (application, root, Ok ()))
  in
  check
    (not
       (List.exists
          (function
            | C.Send _ -> true
            | _ -> false)
          early.instructions))
    "UI completion ACKed before the full causal work set was sealed";
  let root_applied =
    C.step
      early.next
      (C.Change_consumer_expanded (application, root, Rrbvec.singleton child))
  in
  check
    (not (C.change_application_ready (C.view root_applied.next) batch))
    "root application ignored its child";
  let failed =
    C.step
      root_applied.next
      (C.Change_consumer_applied (application, child, Error W.Response_budget_exceeded))
  in
  check
    (C.change_application_error (C.view failed.next) batch
     = Some W.Response_budget_exceeded)
    "failed consumer discarded its change window";
  let retry_root = uuid "98000000-0000-4000-8000-000000007323" in
  let retry, restarted =
    C.begin_change_application failed.next batch ~root:retry_root |> Result.get_ok
  in
  let old =
    C.step restarted.next (C.Change_consumer_applied (application, child, Ok ()))
  in
  check
    (not (C.change_application_ready (C.view old.next) batch))
    "old callback applied a retried consumer window";
  let expanded =
    C.step old.next (C.Change_consumer_expanded (retry, retry_root, Rrbvec.empty))
  in
  let applied =
    C.step expanded.next (C.Change_consumer_applied (retry, retry_root, Ok ()))
  in
  check
    (C.change_application_ready (C.view applied.next) batch)
    "complete consumer state was not eligible for ACK";
  check
    (List.exists
       (function
         | C.Send (actual, _, W.Acknowledge_changes _) ->
           W.equal_request_id (C.ticket_id actual) (C.ticket_id pending_ack)
         | _ -> false)
       applied.instructions)
    "queued ACK did not wait for the actual consumer application barrier";
  let forgotten = { forgotten with C.next = applied.next } in
  let ack, ack_plan =
    match C.request forgotten.next session (W.Acknowledge_changes batch) with
    | Ok value -> value
    | _ -> failwith "owned delivered batch cannot plan its typed ACK"
  in
  let resync_admitted =
    C.step ack_plan.next (C.Admitted (ack, Id.Worker.Request_id.one))
  in
  let resync =
    C.step
      resync_admitted.next
      (C.Completed
         (ack, W.Answered (Error (W.Resync_required "authoritative generation changed"))))
  in
  check
    (Result.is_ok
       (C.request
          resync.next
          session
          (W.Query (budget, W.Changes { generation = "fresh-generation"; after = None }))))
    "ACK resync retained an old batch and blocked a fresh baseline";
  let _, ack_command =
    match
      I.request session ~request_id:(C.ticket_id ack) (W.Acknowledge_changes batch)
      |> Result.get_ok
    with
    | S.Coordination_query v -> v.request.request_id, v.request.command
    | _ -> assert false
  in
  let response =
    match ack_command with
    | P.V2_ack_changes value ->
      S.Graph_response
        (P.V2_response
           { api_version = P.api_version
           ; request_id =
               (match
                  I.request
                    session
                    ~request_id:(C.ticket_id ack)
                    (W.Acknowledge_changes batch)
                  |> Result.get_ok
                with
                | S.Coordination_query v -> v.request.request_id
                | _ -> assert false)
           ; outcome =
               P.V2_changes_acknowledged
                 { generation = value.generation; through = value.through }
           })
    | _ -> failwith "ACK codec used a non-ACK command"
  in
  let receipt =
    match
      I.reply session ~request_id:(C.ticket_id ack) (W.Acknowledge_changes batch) response
    with
    | Ok (W.Answered (Ok receipt)) -> receipt
    | _ -> failwith "actual ACK receipt codec"
  in
  let admitted = C.step ack_plan.next (C.Admitted (ack, Id.Worker.Request_id.one)) in
  let completed = C.step admitted.next (C.Completed (ack, W.Answered (Ok receipt))) in
  let forgotten = C.step completed.next (C.Forget ack) in
  check
    (Result.is_ok (C.request forgotten.next session (W.Acknowledge_changes batch)))
    "duplicate ACK lost the exact consumed-window proof";
  let late_admitted =
    C.step forgotten.next (C.Admitted (late, Id.Worker.Request_id.one))
  in
  let stale = C.step late_admitted.next (C.Completed (late, W.Answered (Ok batch))) in
  check
    (match C.reply (C.view stale.next) late with
     | None | Some (W.Answered (Error (W.Stale_read _))) -> true
     | _ -> false)
    "a late pull reintroduced a batch after its ACK completed";
  check
    (Result.is_error
       (C.request
          forgotten.next
          session
          (W.Query
             ( budget
             , W.Changes { generation = batch.generation; after = Some "foreign-window" }
             ))))
    "arbitrary Changes cursor escaped the owned chain"
;;

let test_empty_change_batch_ack_retires_old_reads () =
  let issuer, _, projection, session = fixture 733L in
  let module I = (val issuer : W.ISSUER) in
  let state = ref (ready I.binding projection) in
  let budget =
    W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok
  in
  let apply tr = state := tr.C.next in
  let step event = apply (C.step !state event) in
  let pull after through windows =
    let operation = W.Query (budget, W.Changes { generation = "g"; after }) in
    let ticket, tr = C.request !state session operation |> Result.get_ok in
    apply tr;
    let request_id =
      match
        I.request session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok
      with
      | S.Coordination_query value -> value.request.request_id
      | _ -> assert false
    in
    let batch =
      match
        I.reply
          session
          ~request_id:(C.ticket_id ticket)
          operation
          (S.Graph_response
             (P.V2_response
                { api_version = P.api_version
                ; request_id
                ; outcome =
                    P.V2_changes
                      { generation = "g"
                      ; from_exclusive = after
                      ; through
                      ; windows
                      ; next = None
                      }
                }))
      with
      | Ok (W.Answered (Ok value)) -> value
      | _ -> failwith "empty batch fixture"
    in
    ticket, batch
  in
  let complete (ticket, batch) =
    step (C.Admitted (ticket, Id.Worker.Request_id.one));
    step (C.Completed (ticket, W.Answered (Ok batch)))
  in
  let ack n batch =
    let root = uuid (Printf.sprintf "98000000-0000-4000-8000-%012d" (7330 + n)) in
    let token, tr = C.begin_change_application !state batch ~root |> Result.get_ok in
    apply tr;
    step (C.Change_consumer_expanded (token, root, Rrbvec.empty));
    step (C.Change_consumer_applied (token, root, Ok ()));
    let ticket, tr =
      C.request !state session (W.Acknowledge_changes batch) |> Result.get_ok
    in
    apply tr;
    let request_id =
      match
        I.request session ~request_id:(C.ticket_id ticket) (W.Acknowledge_changes batch)
        |> Result.get_ok
      with
      | S.Coordination_query value -> value.request.request_id
      | _ -> assert false
    in
    let receipt =
      match
        I.reply
          session
          ~request_id:(C.ticket_id ticket)
          (W.Acknowledge_changes batch)
          (S.Graph_response
             (P.V2_response
                { api_version = P.api_version
                ; request_id
                ; outcome =
                    P.V2_changes_acknowledged
                      { generation = batch.W.generation; through = batch.through }
                }))
      with
      | Ok (W.Answered (Ok value)) -> value
      | _ -> failwith "empty batch ACK fixture"
    in
    step (C.Admitted (ticket, Id.Worker.Request_id.one));
    step (C.Completed (ticket, W.Answered (Ok receipt)))
  in
  let window id before after : P.v2_change_window =
    { id
    ; predecessor = before
    ; successor = after
    ; block_uuids = [ graph ]
    ; page_uuids = []
    ; structure_interests = []
    }
  in
  let a = pull None "a" [ window "a" "p0" "p1" ] in
  complete a;
  ack 1 (snd a);
  let b = pull (Some "a") "a" [] in
  let late = pull (Some "a") "a" [] in
  complete b;
  ack 2 (snd b);
  let c = pull (Some "a") "c" [ window "c" "p1" "p2" ] in
  complete c;
  complete late;
  check
    (match C.reply (C.view !state) (fst late) with
     | None | Some (W.Answered (Error (W.Stale_read _))) -> true
     | _ -> false)
    "empty batch ACK did not fence its old read epoch";
  check
    (Result.is_ok (C.request !state session (W.Acknowledge_changes (snd c))))
    "a late empty batch overwrote the later nonempty batch";
  ack 3 (snd c);
  step C.Capacity_available;
  check
    (match C.reply (C.view !state) (fst late) with
     | Some (W.Answered (Error (W.Stale_read _))) -> true
     | _ -> false)
    "obsolete queued continuation demanded a fresh graph baseline instead of retiring \
     only its read";
  let gap = pull (Some "c") "gap" [ window "gap" "unrelated-projection" "p3" ] in
  complete gap;
  check
    (match C.reply (C.view !state) (fst gap) with
     | Some (W.Answered (Error (W.Resync_required _))) -> true
     | _ -> false)
    "cross-batch projection gap was treated as a continuous change chain";
  check
    (Result.is_ok
       (C.request
          !state
          session
          (W.Query (budget, W.Changes { generation = "fresh-generation"; after = None }))))
    "projection gap did not retire its proof for a fresh baseline"
;;

let test_scoped_change_notices_and_lifecycle () =
  let issuer, raw, projection, session = fixture 735L in
  let module I = (val issuer : W.ISSUER) in
  let scope = fst (List.hd raw.baseline.state.residents) in
  let available =
    P.V2_changes_available
      { api_version = P.api_version; generation = "g"; through = "w" }
  in
  let resync =
    P.V2_resync_required_push
      { api_version = P.api_version; generation = "g"; reason = "history gap" }
  in
  let decode scope push =
    I.changefeed_notices (S.Graph_pushes [ scope, push ]) |> Result.get_ok
  in
  let fact = Option.get (Rrbvec.nth_opt (decode scope available) 0) in
  let reset = Option.get (Rrbvec.nth_opt (decode scope resync) 0) in
  let state = ready I.binding projection in
  let seen =
    C.step state (C.Changefeed_notice (fact, Id.Worker.Push_sequence.of_int64 2L))
  in
  let old = C.step seen.next (C.Changefeed_notice (reset, Id.Worker.Push_sequence.one)) in
  check
    (C.equal_view (C.view seen.next) (C.view old.next))
    "stale scoped resync reset a newer producer sequence";
  let bad = { scope with account = { scope.account with user_id = "another-user" } } in
  check
    (Rrbvec.is_empty (decode bad resync))
    "foreign account manufactured a checked change notice";
  let other_life =
    { scope with
      account =
        { scope.account with
          lifecycle_generation = Int64.succ scope.account.lifecycle_generation
        }
    }
  in
  check
    (Rrbvec.is_empty (decode other_life resync))
    "unregistered lifecycle manufactured a checked change notice";
  check
    (I.changefeed_notices (S.Graph_push available) = Ok Rrbvec.empty)
    "unscoped broadcast borrowed the selected session's authority";
  let bump (scope : S.asset_scope) =
    { scope with
      account =
        { scope.account with
          lifecycle_generation = Int64.succ scope.account.lifecycle_generation
        }
    }
  in
  let baseline =
    { raw.baseline with
      version = 2L
    ; state =
        { sync =
            { raw.baseline.state.sync with
              account =
                Option.map
                  (fun (account : Sync.account_scope) ->
                     { account with
                       lifecycle_generation = Int64.succ account.lifecycle_generation
                     })
                  raw.baseline.state.sync.account
            ; residents =
                List.map
                  (fun (scope, state) -> bump scope, state)
                  raw.baseline.state.sync.residents
            }
        ; residents =
            List.map
              (fun (scope, state) -> bump scope, state)
              raw.baseline.state.residents
        }
    }
  in
  let next =
    match I.bootstrap (S.Coordination_registered { raw with baseline }) with
    | Ok (W.Ready value) -> value
    | _ -> failwith "new lifecycle baseline"
  in
  let current = (List.hd (W.residents next)).session in
  check
    ((not (W.equal_session session current)) && W.same_logical_graph session current)
    "physical lifecycle was conflated with durable logical graph identity";
  let changed = C.step seen.next (C.Projection_received next) in
  let late =
    C.step
      changed.next
      (C.Changefeed_notice (reset, Id.Worker.Push_sequence.of_int64 100L))
  in
  check
    (C.equal_view (C.view changed.next) (C.view late.next))
    "old lifecycle notice changed the reopened owner";
  check
    (Rrbvec.is_empty (decode scope resync))
    "old lifecycle decoded under the replacement resident";
  check
    (match
       I.request
         session
         ~request_id:(W.request_id graph)
         (W.Query
            ( W.read_budget session ~maximum_items:1 ~maximum_bytes:65536 |> Result.get_ok
            , W.Graph_info ))
     with
     | Error W.Revoked_session -> true
     | _ -> false)
    "old lifecycle retained data admission"
;;

let test_change_application_properties () =
  let issuer, raw, projection, session = fixture 734L in
  let module I = (val issuer : W.ISSUER) in
  let budget =
    W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok
  in
  let operation = W.Query (budget, W.Changes { generation = "g"; after = None }) in
  let ticket, tr =
    C.request (ready I.binding projection) session operation |> Result.get_ok
  in
  let request_id =
    match
      I.request session ~request_id:(C.ticket_id ticket) operation |> Result.get_ok
    with
    | S.Coordination_query value -> value.request.request_id
    | _ -> assert false
  in
  let batch =
    match
      I.reply
        session
        ~request_id:(C.ticket_id ticket)
        operation
        (S.Graph_response
           (P.V2_response
              { api_version = P.api_version
              ; request_id
              ; outcome =
                  P.V2_changes
                    { generation = "g"
                    ; from_exclusive = None
                    ; through = "w"
                    ; next = None
                    ; windows =
                        [ { id = "w"
                          ; predecessor = "p0"
                          ; successor = "p1"
                          ; block_uuids = [ graph ]
                          ; page_uuids = []
                          ; structure_interests = []
                          }
                        ]
                    }
              }))
    with
    | Ok (W.Answered (Ok value)) -> value
    | _ -> failwith "application property batch fixture"
  in
  let admitted = (C.step tr.next (C.Admitted (ticket, Id.Worker.Request_id.one))).next in
  let start = (C.step admitted (C.Completed (ticket, W.Answered (Ok batch)))).next in
  let closed =
    match
      I.bootstrap
        (S.Coordination_registered
           { raw with
             baseline =
               { version = 2L
               ; presentation = 2L
               ; state =
                   { sync =
                       { raw.baseline.state.sync with
                         desired_residents = []
                       ; residents = []
                       ; selected = None
                       }
                   ; residents = []
                   }
               }
           })
    with
    | Ok (W.Ready value) -> value
    | _ -> failwith "application property close fixture"
  in
  let node n = uuid (Printf.sprintf "98000000-0000-4000-8000-%012d" (7340 + n)) in
  let run trace =
    let state = ref start
    and live = ref true
    and current = ref None
    and serial = ref 0
    and tokens = ref [] in
    let nodes : (bool * bool * bool) option array = Array.make 9 None
    and seen = Array.make 9 false in
    let failed () =
      Array.exists
        (function
          | Some (_, _, true) -> true
          | _ -> false)
        nodes
    in
    let ready () = !current <> None && Array.for_all Option.is_none nodes in
    let verify () =
      check
        (C.change_application_started (C.view !state) batch = (!current <> None))
        "application token was lost or revived";
      check
        (C.change_application_ready (C.view !state) batch = ready ())
        "consumer phase barrier disagrees with independent model";
      check
        (Option.is_some (C.change_application_error (C.view !state) batch) = failed ())
        "consumer failure was lost or invented"
    in
    let apply tr =
      check
        (List.length tr.C.instructions < 1000)
        "unbounded change application instruction batch";
      List.iter
        (function
          | C.Send (_, _, W.Acknowledge_changes _) ->
            check
              (!live && ready ())
              "ACK sent before every consumer expanded and applied/retired"
          | _ -> ())
        tr.instructions;
      state := tr.next;
      verify ()
    in
    let step event =
      let before = C.view !state in
      let a = C.step !state event
      and b = C.step !state event in
      check
        (C.equal_view (C.view a.next) (C.view b.next) && a.instructions = b.instructions)
        "change application step is nondeterministic";
      check
        (C.equal_view before (C.view !state))
        "change application mutated a prior immutable view";
      apply a
    in
    let selected n f =
      match List.nth_opt !tokens (n mod max 1 (List.length !tokens)) with
      | Some (token, index) -> f token (!current = Some index)
      | _ -> ()
    in
    List.iter
      (fun (op, n) ->
         let parent = n mod 9 in
         match op with
         | 0 ->
           let allowed = !live && (!current = None || failed ()) in
           let planned = C.begin_change_application !state batch ~root:(node parent) in
           check
             (Result.is_ok planned = allowed)
             "duplicate/failed application admission disagrees with model";
           (match planned with
            | Ok (token, tr) ->
              let again =
                C.begin_change_application !state batch ~root:(node parent)
                |> Result.get_ok
              in
              check
                (token = fst again
                 && tr.instructions = (snd again).instructions
                 && C.equal_view (C.view tr.next) (C.view (snd again).next))
                "application planning is nondeterministic";
              incr serial;
              current := Some !serial;
              tokens := (token, !serial) :: !tokens;
              Array.fill nodes 0 9 None;
              Array.fill seen 0 9 false;
              nodes.(parent) <- Some (false, false, false);
              seen.(parent) <- true;
              apply tr
            | _ -> ())
         | 1 | 8 ->
           selected n (fun token valid ->
             let children =
               if op = 8 then [] else [ (parent + 1) mod 9; (parent + 2) mod 9 ]
             in
             if valid
             then (
               match nodes.(parent) with
               | Some (false, applied, error) ->
                 List.iter
                   (fun child ->
                      if not seen.(child)
                      then (
                        seen.(child) <- true;
                        nodes.(child) <- Some (false, false, false)))
                   children;
                 nodes.(parent)
                 <- (if applied && not error then None else Some (true, applied, error))
               | _ -> ());
             step
               (C.Change_consumer_expanded
                  (token, node parent, Rrbvec.of_list (List.map node children))))
         | 2 | 3 ->
           selected n (fun token valid ->
             if valid
             then (
               match nodes.(parent) with
               | Some (expanded, applied, error) ->
                 nodes.(parent)
                 <- (if op = 3
                     then Some (expanded, applied, true)
                     else if error
                     then Some (expanded, applied, error)
                     else if expanded
                     then None
                     else Some (false, true, false))
               | _ -> ());
             step
               (C.Change_consumer_applied
                  ( token
                  , node parent
                  , if op = 3 then Error W.Response_budget_exceeded else Ok () )))
         | 4 ->
           selected n (fun token valid ->
             if valid then nodes.(parent) <- None;
             step (C.Change_consumer_retired (token, node parent)))
         | 5 ->
           selected n (fun token valid ->
             if valid then Array.fill nodes 0 9 None;
             step (C.Change_application_retired token))
         | 6 ->
           let planned = C.request !state session (W.Acknowledge_changes batch) in
           check (Result.is_ok planned = !live) "ACK planning borrowed a closed owner";
           (match planned with
            | Ok (_, tr) -> apply tr
            | _ -> ())
         | 7 -> step C.Capacity_available
         | _ ->
           live := false;
           current := None;
           Array.fill nodes 0 9 None;
           step (C.Projection_received closed))
      trace
  in
  let prefixes =
    [ [ 0, 0; 6, 0; 2, 0; 8, 0 ]
    ; [ 0, 0; 1, 0; 3, 1; 0, 2; 2, 1; 8, 2; 2, 2 ]
    ; [ 0, 0; 1, 0; 4, 1; 4, 2; 2, 0; 6, 0 ]
    ; [ 0, 0; 1, 0; 9, 0; 2, 0; 5, 0; 6, 0 ]
    ]
  in
  for seed = 0 to 249 do
    let random = Random.State.make [| 0xa9911; seed |] in
    let trace =
      List.nth prefixes (seed mod List.length prefixes)
      @ List.init 96 (fun _ ->
        let op = Random.State.int random 10 in
        (if op = 9 && seed mod 5 <> 0 then 8 else op), Random.State.int random 27)
    in
    let fails trace =
      try
        run trace;
        false
      with
      | _ -> true
    in
    if fails trace
    then (
      let reduced = shrink fails trace in
      try run reduced with
      | error ->
        failwith
          (Printf.sprintf
             "application property seed=%d minimal=[%s] %s"
             seed
             (String.concat
                ";"
                (List.map (fun (op, n) -> Printf.sprintf "%d:%d" op n) reduced))
             (Printexc.to_string error)))
  done
;;

let () =
  test_recovery_cursor_and_capacity_bounds ();
  test_durable_recovery_and_ack_purity ();
  test_committed_ack_requires_current_confirmation ();
  test_durable_recovery_ack_properties ();
  test_dependency_read_waits_for_capacity ();
  test_live_binding_invalidation_is_pure ();
  test_changes_serial_and_ack_capacity ();
  test_changefeed_planning_owns_its_typed_ticket ();
  test_changefeed_ack_requires_owned_delivered_batch ();
  test_empty_change_batch_ack_retires_old_reads ();
  test_change_application_properties ();
  test_scoped_change_notices_and_lifecycle ();
  test_observation_planning_is_pure ();
  test_observation_retains_typed_value ();
  test_observation_cancel_requires_ack ();
  test_observation_read_failure_and_refresh ();
  test_observation_notice_plans_one_refresh ();
  test_observation_cleanup_failure_waits_for_explicit_retry ();
  test_observation_properties ();
  test_observation_full_batch_does_not_self_wake ();
  test_observation_focus_and_reopen_fences ();
  test_observation_retirement_capacity_resets_only_after_binding_ack ();
  test_query_origin_boundary ();
  test_durable_readback_reservation ();
  test_durable_mutation_properties ();
  test_bootstrap_validation ();
  test_cleanup_admission_edges ();
  test_pure_properties ();
  test_compressed_response_ownership ();
  test_reads_wait_for_verified_baseline ();
  test_queued_query_properties ();
  test_opening_query_retires_on_removal ();
  print_endline
    "Pure coordinator: invariants, 500 lifecycle + 250 queued-read + 250 durable traces, \
     100 ownership + 300 observation + 250 application + 200 live-binding + 200 recovery/ACK + 200 retired-intent traces and shrinking passed"
;;
