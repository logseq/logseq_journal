let fail format = Printf.ksprintf failwith format

let require_ok to_string = function
  | Ok value -> value
  | Error error -> fail "%s" (to_string error)
;;

let creation_time ~instant_unix_ms ~day ~minute =
  Journal_time.create
    ~instant_unix_ms
    ~local_day:day
    ~local_minute_of_day:minute
    ~time_zone_id:"Europe/Paris"
    ~utc_offset_seconds:7_200
  |> function
  | Ok value -> value
  | Error error -> fail "golden creation time failed: %s" error
;;

let capture
      ?(task_state = Journal_model.Not_a_task)
      ~index
      ~day
      ~source
      ~instant_unix_ms
      ~minute
      ()
  : Journal_repository.capture
  =
  { mutation_id = Printf.sprintf "90000000-0000-4000-9000-%012d" index
  ; block_id = Printf.sprintf "90000000-0000-4000-a000-%012d" index
  ; sibling_order = Printf.sprintf "%012d" index
  ; source
  ; task_state
  ; creation_time = creation_time ~instant_unix_ms ~day ~minute
  }
;;

let apply_capture store command =
  match Journal_repository.prepare_capture (Journal_storage.current_db store) command with
  | Error error ->
    fail "golden capture failed: %s" (Journal_repository.Error.to_string error)
  | Ok (Journal_repository.Already_applied block) -> block
  | Ok (Journal_repository.Apply transaction) ->
    ignore
      (require_ok
         Journal_storage.Error.to_string
         (Journal_storage.transact store transaction));
    (match
       require_ok
         Journal_repository.Error.to_string
         (Journal_repository.find_block
            (Journal_storage.current_db store)
            ~id:command.block_id)
     with
     | Some block -> block
     | None -> fail "golden capture disappeared after commit")
;;

let apply_child store (command : Journal_repository.create_child) =
  match
    Journal_repository.prepare_create_child (Journal_storage.current_db store) command
  with
  | Error error ->
    fail "golden child failed: %s" (Journal_repository.Error.to_string error)
  | Ok (Journal_repository.Child_already_applied _) -> ()
  | Ok (Journal_repository.Create_child transaction) ->
    ignore
      (require_ok
         Journal_storage.Error.to_string
         (Journal_storage.transact store transaction))
;;

let () =
  if Array.length Sys.argv <> 2
  then fail "usage: journal_runtime_golden_fixture SUPPORT_ROOT";
  let support_root = Unix.realpath Sys.argv.(1) in
  let path =
    Journal_storage_path.resolve
      ~support_root
      ~relative_path:Journal_startup.database_relative_path
    |> require_ok Journal_storage_path.Error.to_string
  in
  let store, _ =
    Journal_storage.open_store ~canonical_path:path
    |> require_ok Journal_storage.Error.to_string
  in
  Fun.protect
    ~finally:(fun () ->
      require_ok Journal_storage.Error.to_string (Journal_storage.close store))
    (fun () ->
       let capture_row ?task_state ~index ~day ~minute ~source () =
         let midnight =
           match day with
           | 20260805 -> 1_785_880_800_000L
           | 20260806 -> 1_785_967_200_000L
           | 20260807 -> 1_786_053_600_000L
           | _ -> fail "unsupported golden day: %d" day
         in
         apply_capture
           store
           (capture
              ?task_state
              ~index
              ~day
              ~source
              ~instant_unix_ms:Int64.(add midnight (of_int (minute * 60_000)))
              ~minute
              ())
       in
       let parent =
         capture_row
           ~task_state:Journal_model.Todo
           ~index:1
           ~day:20260807
           ~minute:541
           ~source:"Timeline golden task"
           ()
       in
       ignore
         (capture_row
            ~index:2
            ~day:20260807
            ~minute:542
            ~source:
              "A deliberately long literal source with #plain-tag @plain-mention and no styled pills or attachment thumbnail"
            ());
       apply_child
         store
         { mutation_id = "90000000-0000-4000-9000-000000000003"
         ; block_id = "90000000-0000-4000-a000-000000000003"
         ; parent_block_id = Journal_model.id parent
         ; expected_parent_revision = 1
         ; sibling_order = "000000000003"
         ; source = "Timeline golden direct child"
         ; task_state = Journal_model.Not_a_task
         ; creation_time =
             creation_time
               ~instant_unix_ms:1_786_086_180_000L
               ~day:20260807
               ~minute:543
         };
       ignore
         (capture_row
            ~task_state:Journal_model.Done
            ~index:4
            ~day:20260807
            ~minute:600
            ~source:"Completed reference task"
            ());
       ignore
         (capture_row
            ~index:5
            ~day:20260807
            ~minute:630
            ~source:"Mention-like source for @alex"
            ());
       ignore
         (capture_row
            ~index:6
            ~day:20260807
            ~minute:690
            ~source:"Tag-like source for #journal"
            ());
       ignore
         (capture_row
            ~index:7
            ~day:20260807
            ~minute:1_439
            ~source:"Timeline golden today boundary 👩🏽‍💻"
            ());
       ignore
         (capture_row
            ~index:8
            ~day:20260806
            ~minute:1
            ~source:"Timeline golden older boundary"
            ());
       ignore
         (capture_row
            ~task_state:Journal_model.Todo
            ~index:9
            ~day:20260806
            ~minute:480
            ~source:"Previous-day todo"
            ());
       ignore
         (capture_row
            ~index:10
            ~day:20260806
            ~minute:630
            ~source:"Previous-day plain row"
            ());
       ignore
         (capture_row
            ~index:11
            ~day:20260806
            ~minute:1_439
            ~source:"Previous-day final boundary"
            ());
       ignore
         (capture_row
            ~index:12
            ~day:20260805
            ~minute:420
            ~source:"Second-previous-day emoji 🌿"
            ());
       ignore
         (capture_row
            ~index:13
            ~day:20260805
            ~minute:720
            ~source:"Second-previous-day normal row"
            ());
       ignore
         (capture_row
            ~index:14
            ~day:20260805
            ~minute:1_320
            ~source:"Timeline golden final row"
            ()))
;;
