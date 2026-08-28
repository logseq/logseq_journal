open Logseq_db_types.Mutation
module Adapter_fixture = Logseq_db_worker_test_support.Adapter_fixture
module Engine = Logseq_db_worker.Engine
module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol

let fail format = Printf.ksprintf failwith format
let uuid value = Graph.Uuid.of_string value |> Result.get_ok

let execute engine ~request_id mutation =
  let request =
    Protocol.{ api_version; request_id = uuid request_id; command = Mutate mutation }
  in
  match Engine.execute engine request with
  | Succeeded { success = Mutation_result result; _ } -> result
  | Succeeded _ -> fail "golden mutation returned a read response"
  | Failed failure ->
    fail "golden mutation failed: %s" (Logseq_db_worker.Error.message failure.error)
;;

let with_engine config ~epoch_ms run =
  let dependencies : Engine.dependencies =
    { clocks = { epoch_ms = (fun () -> epoch_ms); monotonic_ns = (fun () -> 1_000_000L) }
    ; cursor_authentication_key = Bytes.make 32 'g'
    }
  in
  let engine = Engine.open_ ~dependencies config |> Result.get_ok in
  Fun.protect
    ~finally:(fun () ->
      match Engine.close engine with
      | Ok () -> ()
      | Error message -> fail "golden engine close failed: %s" message)
    (fun () -> run engine)
;;

let context engine mutation_id =
  Logseq_db_types.Mutation.
    { mutation_id = uuid mutation_id
    ; expected_basis = Option.value (Engine.basis engine) ~default:0L
    }
;;

let journal_page = uuid "00000001-2026-0812-0000-000000000000"
let historical_journal_page = uuid "00000001-2026-0811-0000-000000000000"

let ensure_journal_page engine ~day ~page ~request_id ~mutation_id =
  ignore
    (execute
       engine
       ~request_id
       (Page
          (Create_page
             { title =
                 Printf.sprintf
                   "%04d-%02d-%02d"
                   (day / 10_000)
                   (day / 100 mod 100)
                   (day mod 100)
             ; kind = Create_journal_page { journal_day = day; supplied_uuid = Some page }
             ; context = context engine mutation_id
             })))
;;

let ensure_journal config =
  with_engine config ~epoch_ms:1_786_485_600_000L (fun engine ->
    ensure_journal_page
      engine
      ~day:20260812
      ~page:journal_page
      ~request_id:"90000000-0000-4000-8000-000000000000"
      ~mutation_id:"90000000-0000-4000-9000-000000000000";
    ensure_journal_page
      engine
      ~day:20260811
      ~page:historical_journal_page
      ~request_id:"90000000-0000-4000-8000-000000000001"
      ~mutation_id:"90000000-0000-4000-9000-000000000001")
;;

let block_uuid index = uuid (Printf.sprintf "90000000-0000-4000-a000-%012d" index)

let insert config ~index ~minute ~parent ~source =
  let epoch_ms = Int64.add 1_786_485_600_000L (Int64.of_int (minute * 60_000)) in
  with_engine config ~epoch_ms (fun engine ->
    ignore
      (execute
         engine
         ~request_id:(Printf.sprintf "90000000-0000-4000-8000-%012d" index)
         (Structural
            (Insert_blocks
               { roots = [ { uuid = block_uuid index; title = source; children = [] } ]
               ; position = Relative (Last_child parent)
               ; context =
                   context engine (Printf.sprintf "90000000-0000-4000-9000-%012d" index)
               }))))
;;

let set_status config ~index ~minute status =
  let epoch_ms = Int64.add 1_786_485_600_000L (Int64.of_int (minute * 60_000)) in
  with_engine config ~epoch_ms (fun engine ->
    ignore
      (execute
         engine
         ~request_id:(Printf.sprintf "91000000-0000-4000-8000-%012d" index)
         (Property
            (Set_property
               { block = block_uuid index
               ; property = Property_by_ident "logseq.property/status"
               ; value = Default_value status
               ; context =
                   context engine (Printf.sprintf "91000000-0000-4000-9000-%012d" index)
               }))))
;;

let () =
  if Array.length Sys.argv <> 2
  then fail "usage: journal_runtime_golden_fixture SUPPORT_ROOT";
  let support_root = Unix.realpath Sys.argv.(1) in
  let sources = Filename.concat support_root "sources" in
  Unix.mkdir sources 0o700;
  let source_graph_dir = Adapter_fixture.create_oracle_graph sources "golden-source" in
  let token =
    match
      Cli_command.create_snapshot
        ~application_support_directory:support_root
        ~source_graph_dir
    with
    | Ok token -> token
    | Error message -> fail "unable to publish golden snapshot: %s" message
  in
  let config = Adapter_fixture.config support_root token in
  ensure_journal config;
  insert config ~index:1 ~minute:1_297 ~parent:journal_page ~source:"混合脚本 Journal 2026 条目";
  insert
    config
    ~index:2
    ~minute:1_298
    ~parent:(block_uuid 1)
    ~source:"Increase block row height";
  insert
    config
    ~index:3
    ~minute:1_299
    ~parent:(block_uuid 1)
    ~source:"Show parent and child preview";
  insert
    config
    ~index:4
    ~minute:1_300
    ~parent:(block_uuid 1)
    ~source:"Keep bounded virtualization";
  insert
    config
    ~index:5
    ~minute:1_157
    ~parent:journal_page
    ~source:"Review Bonsai state model";
  insert
    config
    ~index:6
    ~minute:1_158
    ~parent:(block_uuid 5)
    ~source:"Keep bounded virtualization";
  insert config ~index:7 ~minute:1_102 ~parent:journal_page ~source:"Test on iPhone";
  insert
    config
    ~index:8
    ~minute:1_103
    ~parent:(block_uuid 7)
    ~source:"Verify Dynamic Type";
  insert
    config
    ~index:9
    ~minute:1_048
    ~parent:journal_page
    ~source:"Capture interaction notes";
  insert
    config
    ~index:10
    ~minute:1_049
    ~parent:(block_uuid 9)
    ~source:"Prefer one clear tap target";
  insert config ~index:11 ~minute:900 ~parent:journal_page ~source:"Todo rail";
  set_status config ~index:11 ~minute:900 "Todo";
  insert
    config
    ~index:12
    ~minute:901
    ~parent:journal_page
    ~source:"Doing line one\nDoing line two";
  set_status config ~index:12 ~minute:901 "Doing";
  insert
    config
    ~index:13
    ~minute:902
    ~parent:journal_page
    ~source:"Done line one\nDone line two\nDone line three";
  set_status config ~index:13 ~minute:902 "Done";
  insert
    config
    ~index:14
    ~minute:903
    ~parent:journal_page
    ~source:
      "Later line one\nLater line two\nLater line three\nLater line four\nLater line five";
  set_status config ~index:14 ~minute:903 "Backlog";
  insert
    config
    ~index:15
    ~minute:840
    ~parent:historical_journal_page
    ~source:"Historical hierarchy row";
  print_endline (Graph.Uuid.to_string token)
;;
