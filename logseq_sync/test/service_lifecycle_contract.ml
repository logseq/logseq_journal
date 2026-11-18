module State = Logseq_sync_service_lifecycle

let accepted = function
  | Ok state -> state
  | Error _ -> Alcotest.fail "expected accepted close"
;;

let test_reentrant_preserves_right () =
  let state = State.initial in
  Alcotest.(check bool)
    "reentrant rejected"
    true
    (State.request_close ~inside_callback:true state = Error State.Reentrant);
  let closing = State.request_close ~inside_callback:false state |> accepted in
  Alcotest.(check bool) "right preserved" true (State.lifecycle closing = State.Closing)
;;

let test_close_once () =
  let closing = State.request_close ~inside_callback:false State.initial |> accepted in
  Alcotest.(check bool)
    "repeat during close fails"
    true
    (State.request_close ~inside_callback:false closing = Error State.Already_called);
  let closed = State.complete closing in
  Alcotest.(check bool)
    "repeat after retirement fails"
    true
    (State.request_close ~inside_callback:false closed = Error State.Already_called)
;;

let test_failed_cleanup_does_not_restore_right () =
  let closing = State.request_close ~inside_callback:false State.initial |> accepted in
  let failed = State.begin_cleanup closing in
  Alcotest.(check bool)
    "failure stays closing"
    true
    (State.lifecycle failed = State.Closing);
  Alcotest.(check bool)
    "no implicit repair retry"
    true
    (State.request_close ~inside_callback:false failed = Error State.Already_called)
;;

let test_owner_cleanup_preserves_close_right () =
  let closing = State.begin_cleanup State.initial in
  let accepted = State.request_close ~inside_callback:false closing |> accepted in
  Alcotest.(check bool)
    "owner cleanup does not consume caller right"
    true
    (State.lifecycle accepted = State.Closing)
;;

let test_reentrant_precedence () =
  let closing = State.request_close ~inside_callback:false State.initial |> accepted in
  Alcotest.(check bool)
    "callback check precedes close right"
    true
    (State.request_close ~inside_callback:true closing = Error State.Reentrant)
;;

let test_closed_late_close () =
  let retired = State.complete (State.begin_cleanup State.initial) in
  let closed = State.request_close ~inside_callback:false retired |> accepted in
  Alcotest.(check bool)
    "retirement stays terminal"
    true
    (State.lifecycle closed = State.Closed)
;;

let () =
  Alcotest.run
    "service lifecycle"
    [ ( "close ownership"
      , List.map
          (fun (name, test) -> Alcotest.test_case name `Quick test)
          [ "reentrant preserves right", test_reentrant_preserves_right
          ; "strict once only", test_close_once
          ; ( "failed cleanup retains right consumption"
            , test_failed_cleanup_does_not_restore_right )
          ; "owner cleanup", test_owner_cleanup_preserves_close_right
          ; "reentrant precedence", test_reentrant_precedence
          ; "late close", test_closed_late_close
          ] )
    ]
;;
