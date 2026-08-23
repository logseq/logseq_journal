module T = Logseq_db_worker_test_support.Test_support
module Value = Transit_core.Json
module Codec = Transit_native.Transit.Json
module Snapshot = Logseq_db_worker.Sync_snapshot

let expect_ok label = function
  | Ok value -> value
  | Error message -> T.fail "%s: %s" label message
;;

let expect_error label = function
  | Error _ -> ()
  | Ok _ -> T.fail "%s unexpectedly succeeded" label
;;

let frame value =
  let payload = Codec.to_string value in
  let length = String.length payload in
  let prefix =
    String.init 4 (fun index -> Char.chr ((length lsr ((3 - index) * 8)) land 0xff))
  in
  prefix ^ payload
;;

let fixture () = T.read_json (T.fixture "sync/chat-snapshot-37c034e.json")

let fixture_rows () =
  let open Yojson.Safe.Util in
  fixture ()
  |> member "rows"
  |> to_list
  |> List.map (fun row ->
    let addresses =
      match row |> member "addresses" with
      | `Null -> Value.Null
      | value -> Value.String (to_string value)
    in
    Value.Array
      [ Value.Int (row |> member "addr" |> to_int)
      ; Value.String (row |> member "content" |> to_string)
      ; addresses
      ])
;;

let fixture_wire () = frame (Value.Array (fixture_rows ()))

let fragmented_stream_case () =
  let wire = fixture_wire () in
  let parser = Snapshot.create_parser ~max_frame_bytes:4096 in
  let first = String.sub wire 0 3 in
  let second = String.sub wire 3 11 in
  let rest = String.sub wire 14 (String.length wire - 14) in
  T.require
    (expect_ok "partial prefix" (Snapshot.feed parser first) = [])
    "partial prefix emitted rows";
  T.require
    (expect_ok "partial payload" (Snapshot.feed parser second) = [])
    "partial payload emitted rows";
  let rows = expect_ok "complete frame" (Snapshot.feed parser rest) in
  (match rows with
   | [ root; tail; node ] ->
     T.require (root.addr = 0) "root address changed";
     T.require (tail.addr = 1) "tail address changed";
     T.require (node.addr = 7) "node address changed";
     T.require (node.addresses = Some "[3,4]") "node addresses changed"
   | _ -> T.fail "expected three snapshot rows");
  ignore (expect_ok "complete stream" (Snapshot.finish parser))
;;

let import_validation_case () =
  let parser = Snapshot.create_parser ~max_frame_bytes:4096 in
  let rows = expect_ok "decode fixture" (Snapshot.feed parser (fixture_wire ())) in
  let state = Snapshot.create_import ~expected_rows:3 in
  ignore (expect_ok "accept fixture" (Snapshot.accept_rows state rows));
  let completed = expect_ok "finish import" (Snapshot.finish_import state) in
  T.require (completed.row_count = 3) "row count changed"
;;

let malformed_stream_cases () =
  let incomplete = Snapshot.create_parser ~max_frame_bytes:4096 in
  ignore (expect_ok "incomplete feed" (Snapshot.feed incomplete "\000\000\000"));
  expect_error "incomplete stream" (Snapshot.finish incomplete);
  let oversized = Snapshot.create_parser ~max_frame_bytes:2 in
  expect_error "oversized frame" (Snapshot.feed oversized (fixture_wire ()));
  let malformed = Snapshot.create_parser ~max_frame_bytes:4096 in
  expect_error
    "malformed row"
    (Snapshot.feed malformed (frame (Value.Array [ Value.Bool true ])));
  let negative = Snapshot.create_parser ~max_frame_bytes:4096 in
  expect_error
    "negative row address"
    (Snapshot.feed
       negative
       (frame
          (Value.Array [ Value.Array [ Value.Int (-1); Value.String "[]"; Value.Null ] ])))
;;

let import_rejection_cases () =
  let row addr = Snapshot.{ addr; content = "[]"; addresses = None } in
  let finish rows ~expected_rows =
    let state = Snapshot.create_import ~expected_rows in
    match Snapshot.accept_rows state rows with
    | Error _ as error -> error
    | Ok () -> Snapshot.finish_import state |> Result.map (fun _ -> ())
  in
  expect_error "unordered rows" (finish [ row 1; row 0 ] ~expected_rows:2);
  expect_error "duplicate rows" (finish [ row 0; row 0; row 1 ] ~expected_rows:3);
  expect_error "missing root" (finish [ row 1; row 2 ] ~expected_rows:2);
  expect_error "missing tail" (finish [ row 0; row 2 ] ~expected_rows:2);
  expect_error "wrong count" (finish [ row 0; row 1 ] ~expected_rows:3);
  expect_error "negative row count" (finish [ row 0; row 1 ] ~expected_rows:(-1))
;;

let cases =
  [ T.case "decode fragmented framed snapshot" fragmented_stream_case
  ; T.case "validate snapshot row count" import_validation_case
  ; T.case "reject malformed framed snapshots" malformed_stream_cases
  ; T.case "reject invalid snapshot ordering and row counts" import_rejection_cases
  ]
;;

let () = T.run "sync snapshot" cases
