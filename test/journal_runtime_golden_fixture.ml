open Logseq_db_types.Mutation
module Generator = Logseq_db_worker_fixture_generator.Fixture_generator
module Engine = Logseq_db_worker.Engine
module Graph = Logseq_db_types.Graph_types

let fail format = Printf.ksprintf failwith format
let uuid value = Graph.Uuid.of_string value |> Result.get_ok
let journal_page = uuid "00000001-2026-0812-0000-000000000000"
let historical_journal_page = uuid "00000001-2026-0811-0000-000000000000"
let block_uuid index = uuid (Printf.sprintf "90000000-0000-4000-a000-%012d" index)

let context engine mutation_id =
  { mutation_id = uuid mutation_id; expected_basis = Option.get (Engine.basis engine) }
;;

let apply engine checkpoint mutation =
  let identity = Logseq_db_types.Mutation.identify mutation in
  let prepared =
    Engine.prepare_managed_mutation engine ~identity mutation
    |> Result.fold ~ok:Fun.id ~error:(fail "golden mutation prepare failed: %s")
  in
  let expected_precondition =
    Engine.authoritative_precondition engine
    |> Result.fold ~ok:Fun.id ~error:(fail "golden precondition failed: %s")
  in
  match
    Engine.apply_authoritative
      engine
      ~expected_precondition
      [ Engine.prepared_mutation_operations prepared ]
      ~projection_transactions:[]
      ~checkpoint
      ~outbox_records:[]
  with
  | Ok _ -> ()
  | Error Authoritative_conflict -> fail "golden authoritative commit conflicted"
  | Error (Authoritative_apply_failed message) ->
    fail "golden authoritative commit failed: %s" message
;;

let ensure_journal_page engine checkpoint ~day ~page ~mutation_id =
  apply
    engine
    checkpoint
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
          }))
;;

let insert engine checkpoint now_ms ~index ~minute ~parent ~source =
  now_ms := Int64.add 1_786_485_600_000L (Int64.of_int (minute * 60_000));
  apply
    engine
    checkpoint
    (Structural
       (Insert_blocks
          { roots = [ { uuid = block_uuid index; title = source; children = [] } ]
          ; position = Relative (Last_child parent)
          ; context =
              context engine (Printf.sprintf "90000000-0000-4000-9000-%012d" index)
          }))
;;

let set_status engine checkpoint now_ms ~index ~minute status =
  now_ms := Int64.add 1_786_485_600_000L (Int64.of_int (minute * 60_000));
  apply
    engine
    checkpoint
    (Property
       (Set_property
          { block = block_uuid index
          ; property = Property_by_ident "logseq.property/status"
          ; value = Default_value status
          ; context =
              context engine (Printf.sprintf "91000000-0000-4000-9000-%012d" index)
          }))
;;

let seed generated =
  let database_path = Filename.concat generated.Generator.graph_dir "db.sqlite" in
  let checkpoint =
    Logseq_db_storage.Sync_checkpoint_store.read_path database_path |> Result.get_ok
  in
  let now_ms = ref 1_786_485_600_000L in
  let dependencies : Engine.dependencies =
    { clocks = { epoch_ms = (fun () -> !now_ms); monotonic_ns = (fun () -> 1_000_000L) }
    ; cursor_authentication_key = Bytes.make 32 'g'
    }
  in
  let attachment =
    Engine.
      { graph_id = generated.graph_id
      ; graph_name = "golden-source"
      ; graph_dir = generated.graph_dir
      ; database_path
      ; checkpoint
      }
  in
  let engine =
    Engine.open_
      ~dependencies
      ~response_budget_bytes:Logseq_db_worker.Protocol.maximum_response_bytes
      attachment
    |> Result.get_ok
  in
  Fun.protect
    ~finally:(fun () ->
      match Engine.close engine with
      | Ok () -> ()
      | Error message -> fail "golden engine close failed: %s" message)
    (fun () ->
       ensure_journal_page
         engine
         checkpoint
         ~day:20260812
         ~page:journal_page
         ~mutation_id:"90000000-0000-4000-9000-000000000000";
       ensure_journal_page
         engine
         checkpoint
         ~day:20260811
         ~page:historical_journal_page
         ~mutation_id:"90000000-0000-4000-9000-000000000001";
       insert
         engine
         checkpoint
         now_ms
         ~index:1
         ~minute:1_297
         ~parent:journal_page
         ~source:"混合脚本 Journal 2026 条目";
       insert
         engine
         checkpoint
         now_ms
         ~index:2
         ~minute:1_298
         ~parent:(block_uuid 1)
         ~source:"Increase block row height";
       insert
         engine
         checkpoint
         now_ms
         ~index:3
         ~minute:1_299
         ~parent:(block_uuid 1)
         ~source:"Show parent and child preview";
       insert
         engine
         checkpoint
         now_ms
         ~index:4
         ~minute:1_300
         ~parent:(block_uuid 1)
         ~source:"Keep bounded virtualization";
       insert
         engine
         checkpoint
         now_ms
         ~index:5
         ~minute:1_157
         ~parent:journal_page
         ~source:"Review Bonsai state model";
       insert
         engine
         checkpoint
         now_ms
         ~index:6
         ~minute:1_158
         ~parent:(block_uuid 5)
         ~source:"Keep bounded virtualization";
       insert
         engine
         checkpoint
         now_ms
         ~index:7
         ~minute:1_102
         ~parent:journal_page
         ~source:"Test on iPhone";
       insert
         engine
         checkpoint
         now_ms
         ~index:8
         ~minute:1_103
         ~parent:(block_uuid 7)
         ~source:"Verify Dynamic Type";
       insert
         engine
         checkpoint
         now_ms
         ~index:9
         ~minute:1_048
         ~parent:journal_page
         ~source:"Capture interaction notes";
       insert
         engine
         checkpoint
         now_ms
         ~index:10
         ~minute:1_049
         ~parent:(block_uuid 9)
         ~source:"Prefer one clear tap target";
       insert
         engine
         checkpoint
         now_ms
         ~index:11
         ~minute:900
         ~parent:journal_page
         ~source:"Todo rail";
       set_status engine checkpoint now_ms ~index:11 ~minute:900 "Todo";
       insert
         engine
         checkpoint
         now_ms
         ~index:12
         ~minute:901
         ~parent:journal_page
         ~source:"Doing line one\nDoing line two";
       set_status engine checkpoint now_ms ~index:12 ~minute:901 "Doing";
       insert
         engine
         checkpoint
         now_ms
         ~index:13
         ~minute:902
         ~parent:journal_page
         ~source:"Done line one\nDone line two\nDone line three";
       set_status engine checkpoint now_ms ~index:13 ~minute:902 "Done";
       insert
         engine
         checkpoint
         now_ms
         ~index:14
         ~minute:903
         ~parent:journal_page
         ~source:
           "Later line one\n\
            Later line two\n\
            Later line three\n\
            Later line four\n\
            Later line five";
       set_status engine checkpoint now_ms ~index:14 ~minute:903 "Backlog";
       insert
         engine
         checkpoint
         now_ms
         ~index:15
         ~minute:840
         ~parent:historical_journal_page
         ~source:"Historical hierarchy row")
;;

let () =
  if Array.length Sys.argv <> 2
  then fail "usage: journal_runtime_golden_fixture SUPPORT_ROOT";
  let support_root = Unix.realpath Sys.argv.(1) in
  match Generator.create_unencrypted_warm_start ~support_root with
  | Error message -> fail "%s" message
  | Ok generated ->
    seed generated;
    Generator.to_yojson generated |> Yojson.Safe.to_string |> print_endline
;;
