module Effects = struct
  type error = string
  type cold
  type ready

  type (_, _, _, _) operation =
    | Restore : (cold, ready, cold, unit) operation
    | Persist : string -> (ready, ready, ready, string) operation
    | Send : string -> (ready, ready, ready, unit) operation
end

module Program = Logseq_sync_indexed_program.Make (Effects)
open Effects

let check = Alcotest.(check (list string))

let workflow () =
  Program.perform
    Restore
    ~success:(fun () ->
      Program.bind
        (Program.perform
           (Persist "exact-wire")
           ~success:Program.return
           ~failure:Program.abort)
        (fun wire ->
           Program.perform (Send wire) ~success:Program.return ~failure:Program.abort))
    ~failure:Program.abort
;;

let run ~persist_error program =
  let rec loop
    : type before after value.
      string list
      -> (before, after, value) Program.t
      -> string list * (value, string) result
    =
    fun trace program ->
    match Program.view program with
    | Program.Return value -> List.rev trace, Ok value
    | Program.Abort error -> List.rev trace, Error error
    | Program.Perform (operation, success, failure) ->
      (match operation with
       | Restore -> loop ("restore" :: trace) (success ())
       | Persist wire ->
         let trace = ("persist:" ^ wire) :: trace in
         (match persist_error with
          | None -> loop trace (success wire)
          | Some error -> loop trace (failure error))
       | Send wire -> loop (("send:" ^ wire) :: trace) (success ()))
  in
  loop [] program
;;

let test_persist_before_send () =
  let trace, result = run ~persist_error:None (workflow ()) in
  check "ordered effects" [ "restore"; "persist:exact-wire"; "send:exact-wire" ] trace;
  Alcotest.(check bool) "completed" true (result = Ok ())
;;

let test_persist_failure () =
  let trace, result = run ~persist_error:(Some "disk full") (workflow ()) in
  check "no send on failed persistence" [ "restore"; "persist:exact-wire" ] trace;
  Alcotest.(check (result unit string)) "original cause" (Error "disk full") result
;;

let test_bind_failure () =
  let invoked = ref false in
  let program =
    Program.bind (Program.abort "original") (fun () ->
      invoked := true;
      Program.return ())
  in
  let _, result = run ~persist_error:None program in
  Alcotest.(check bool) "continuation not run" false !invoked;
  Alcotest.(check (result unit string)) "abort preserved" (Error "original") result
;;

let test_association () =
  let first =
    Program.perform (Persist "one") ~success:Program.return ~failure:Program.abort
  in
  let second wire =
    Program.perform
      (Persist (wire ^ "/two"))
      ~success:Program.return
      ~failure:Program.abort
  in
  let third wire =
    Program.perform (Send wire) ~success:Program.return ~failure:Program.abort
  in
  let left = Program.bind (Program.bind first second) third in
  let right = Program.bind first (fun value -> Program.bind (second value) third) in
  let left_trace, left_result = run ~persist_error:None left in
  let right_trace, right_result = run ~persist_error:None right in
  check "association preserves effects" left_trace right_trace;
  Alcotest.(check (result unit string))
    "association preserves result"
    left_result
    right_result
;;

let test_deep_left_bind () =
  let program = ref (Program.return 0) in
  for _ = 1 to 100_000 do
    program := Program.bind !program (fun value -> Program.return (value + 1))
  done;
  match Program.view !program with
  | Program.Return value -> Alcotest.(check int) "stack safe normalization" 100_000 value
  | Program.Abort error -> Alcotest.fail error
  | Program.Perform _ -> Alcotest.fail "unexpected effect"
;;

let test_lazy_continuations () =
  let called = ref false in
  let program =
    Program.bind (Program.return ()) (fun () ->
      called := true;
      Program.return ())
  in
  Alcotest.(check bool) "construction is lazy" false !called;
  ignore (Program.view program);
  Alcotest.(check bool) "view runs pure continuation" true !called
;;

let () =
  Alcotest.run
    "indexed program"
    [ ( "composition"
      , List.map
          (fun (name, test) -> Alcotest.test_case name `Quick test)
          [ "persist before send", test_persist_before_send
          ; "failed persistence", test_persist_failure
          ; "abort bypasses bind", test_bind_failure
          ; "association", test_association
          ; "deep left bind", test_deep_left_bind
          ; "lazy construction", test_lazy_continuations
          ] )
    ]
;;
