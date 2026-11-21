module D = Sync_dsl.Core
module Binding = Logseq_sync_execute_owners.Owner_binding

let require_ok = function
  | Ok value -> value
  | Error error -> Alcotest.fail (D.error_message error)
;;

let check_error expected = function
  | Error actual when actual = expected -> ()
  | Error actual -> Alcotest.fail (D.error_message actual)
  | Ok _ -> Alcotest.fail "expected rejection"
;;

let fixture
      ?(prepare = fun () -> ())
      ?(commit = fun () -> ())
      ?(open_committed = fun () -> Ok 41)
      ()
  =
  let preparations = ref 0 in
  let commits = ref 0 in
  let cancellations = ref 0 in
  let opens = ref 0 in
  let backend : (int, int, unit, int) Binding.backend =
    { same_input = ( = )
    ; prepare =
        (fun inspection () ->
          incr preparations;
          Alcotest.(check int) "original inspection" 7 inspection;
          prepare ();
          Ok 8)
    ; commit =
        (fun prepared ->
          incr commits;
          Alcotest.(check int) "original preparation" 8 prepared;
          commit ();
          Ok 9)
    ; cancel =
        (fun prepared ->
          Alcotest.(check int) "original cancellation" 8 prepared;
          incr cancellations)
    ; open_committed =
        (fun inspection ->
          incr opens;
          Alcotest.(check int) "committed inspection" 9 inspection;
          open_committed ())
    }
  in
  Binding.absent 7 backend, preparations, commits, cancellations, opens
;;

let current () = Ok ()

let absent_rejects_reads () =
  let owner, preparations, commits, _, opens = fixture () in
  (match Binding.database owner with
   | Error (D.Storage_failure _) -> ()
   | Error error -> Alcotest.fail (D.error_message error)
   | Ok _ -> Alcotest.fail "absent mirror supplied a database");
  Alcotest.(check int) "no preparation" 0 !preparations;
  Alcotest.(check int) "no commit" 0 !commits;
  Alcotest.(check int) "no open" 0 !opens
;;

let activated_once () =
  let owner, preparations, commits, cancellations, opens = fixture () in
  Alcotest.(check int)
    "opened"
    41
    (require_ok (Binding.activate owner ~check_current:current ()));
  Alcotest.(check int)
    "same binding"
    41
    (require_ok (Binding.activate owner ~check_current:current ()));
  Alcotest.(check int) "one preparation" 1 !preparations;
  Alcotest.(check int) "one commit" 1 !commits;
  Alcotest.(check int) "release staging" 1 !cancellations;
  Alcotest.(check int) "one open" 1 !opens
;;

let revoked_during_prepare () =
  Eio.Switch.run (fun sw ->
    let prepared, resolve_prepared = Eio.Promise.create () in
    let resume, resolve_resume = Eio.Promise.create () in
    let valid = ref true in
    let check_current () = if !valid then Ok () else Error D.Stale_context in
    let owner, _, commits, cancellations, opens =
      fixture
        ~prepare:(fun () ->
          Eio.Promise.resolve resolve_prepared ();
          Eio.Promise.await resume)
        ()
    in
    let result =
      Eio.Fiber.fork_promise ~sw (fun () -> Binding.activate owner ~check_current ())
    in
    Eio.Promise.await prepared;
    valid := false;
    Eio.Promise.resolve resolve_resume ();
    check_error D.Stale_context (Eio.Promise.await_exn result);
    Alcotest.(check int) "no stale commit" 0 !commits;
    Alcotest.(check int) "staging released" 1 !cancellations;
    Alcotest.(check int) "no open" 0 !opens)
;;

let recover_open_without_recommit () =
  let failed = ref true in
  let owner, preparations, commits, cancellations, opens =
    fixture
      ~open_committed:(fun () ->
        if !failed then Error (D.Storage_failure "open interrupted") else Ok 41)
      ()
  in
  check_error
    (D.Storage_failure "open interrupted")
    (Binding.activate owner ~check_current:current ());
  failed := false;
  Alcotest.(check int)
    "recover"
    41
    (require_ok (Binding.activate owner ~check_current:current ()));
  Alcotest.(check int) "no replayed preparation" 1 !preparations;
  Alcotest.(check int) "no replayed commit" 1 !commits;
  Alcotest.(check int) "one staging release" 1 !cancellations;
  Alcotest.(check int) "retry original open" 2 !opens
;;

let revoked_during_open_keeps_binding () =
  let valid = ref true in
  let owner, _, commits, _, _ =
    fixture
      ~open_committed:(fun () ->
        valid := false;
        Ok 41)
      ()
  in
  let check_current () = if !valid then Ok () else Error D.Stale_context in
  check_error D.Stale_context (Binding.activate owner ~check_current ());
  Alcotest.(check int) "committed once" 1 !commits;
  Alcotest.(check int)
    "original binding retained"
    41
    (require_ok (Binding.database owner))
;;

let queued_write_rechecks () =
  Eio.Switch.run (fun sw ->
    let owner = Binding.active 41 in
    let entered, resolve_entered = Eio.Promise.create () in
    let resume, resolve_resume = Eio.Promise.create () in
    let valid = ref true in
    let effects = ref 0 in
    let first =
      Eio.Fiber.fork_promise ~sw (fun () ->
        Binding.with_database owner ~check_current:current (fun _ ->
          Eio.Promise.resolve resolve_entered ();
          Eio.Promise.await resume;
          Ok ()))
    in
    Eio.Promise.await entered;
    let second =
      Eio.Fiber.fork_promise ~sw (fun () ->
        Binding.with_database
          owner
          ~check_current:(fun () -> if !valid then Ok () else Error D.Stale_context)
          (fun _ ->
             incr effects;
             Ok ()))
    in
    Eio.Fiber.yield ();
    valid := false;
    Eio.Promise.resolve resolve_resume ();
    require_ok (Eio.Promise.await_exn first);
    check_error D.Stale_context (Eio.Promise.await_exn second);
    Alcotest.(check int) "rejected before mutation" 0 !effects)
;;

let observation_during_open ~fails () =
  Eio.Switch.run (fun sw ->
    let entered, resolve_entered = Eio.Promise.create () in
    let resume, resolve_resume = Eio.Promise.create () in
    let owner, _, commits, _, opens =
      fixture
        ~open_committed:(fun () ->
          Eio.Promise.resolve resolve_entered ();
          Eio.Promise.await resume;
          if fails then Error (D.Storage_failure "synthetic open failed") else Ok 41)
        ()
    in
    let activation =
      Eio.Fiber.fork_promise ~sw (fun () ->
        Binding.activate owner ~check_current:current ())
    in
    Eio.Promise.await entered;
    let observation =
      Eio.Fiber.fork_promise ~sw (fun () -> Binding.database_if_open owner)
    in
    Eio.Fiber.yield ();
    let premature = Eio.Promise.is_resolved observation in
    Eio.Promise.resolve resolve_resume ();
    let activated = Eio.Promise.await_exn activation in
    let observed = Eio.Promise.await_exn observation in
    Alcotest.(check bool) "observation waits for activation owner" false premature;
    if fails
    then (
      check_error (D.Storage_failure "synthetic open failed") activated;
      check_error (D.Storage_failure "Committed mirror requires open recovery") observed)
    else (
      Alcotest.(check int) "activation" 41 (require_ok activated);
      Alcotest.(check (option int))
        "observed active owner"
        (Some 41)
        (require_ok observed));
    Alcotest.(check int) "one commit" 1 !commits;
    Alcotest.(check int) "one open" 1 !opens)
;;

let differing_activation_rejected () =
  let preparations = ref 0 in
  let backend : (int, int, string, int) Binding.backend =
    { same_input = ( = )
    ; prepare =
        (fun _ _ ->
          incr preparations;
          Ok 8)
    ; commit = (fun _ -> Ok 9)
    ; cancel = (fun _ -> ())
    ; open_committed = (fun _ -> Ok 41)
    }
  in
  let owner = Binding.absent 7 backend in
  ignore (require_ok (Binding.activate owner ~check_current:current "first"));
  check_error D.Stale_context (Binding.activate owner ~check_current:current "second");
  Alcotest.(check int) "original commit retained" 1 !preparations
;;

let () =
  Eio_main.run (fun environment ->
    Alcotest.run
      "Execute owner binding"
      [ ( "binding"
        , List.map
            (fun (name, test) ->
               Alcotest.test_case name `Quick (fun () ->
                 Eio.Time.with_timeout_exn (Eio.Stdenv.clock environment) 5. test))
            [ "absent reads are local", absent_rejects_reads
            ; "activation installs exactly once", activated_once
            ; "revocation after preparation", revoked_during_prepare
            ; "open recovery preserves commit", recover_open_without_recommit
            ; "revoked open retains original binding", revoked_during_open_keeps_binding
            ; "sole queue checks after suspension", queued_write_rechecks
            ; "observation waits for committed open", observation_during_open ~fails:false
            ; ( "failed committed open remains an error"
              , observation_during_open ~fails:true )
            ; "different activation proof rejects", differing_activation_rejected
            ] )
      ])
;;
