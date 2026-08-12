open Datascript

let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let require_ok = function
  | Ok value -> value
  | Error error ->
    fail "unexpected repository error: %s" (Journal_repository.Error.to_string error)
;;

let require_error = function
  | Error _ -> ()
  | Ok _ -> fail "expected repository error"
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_database_path test =
  let root = Filename.temp_file "journal-repository-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Unix.mkdir (Filename.concat root "logseq_journal") 0o700;
  let root = Unix.realpath root in
  let database_path =
    match
      Journal_storage_path.resolve
        ~support_root:root
        ~relative_path:Journal_startup.database_relative_path
    with
    | Ok path -> path
    | Error error ->
      fail "path resolution failed: %s" (Journal_storage_path.Error.to_string error)
  in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () -> test database_path)
;;

let open_store path =
  match Journal_storage.open_store ~canonical_path:path with
  | Ok (store, disposition) -> store, disposition
  | Error error -> fail "store open failed: %s" (Journal_storage.Error.to_string error)
;;

let close_store store =
  match Journal_storage.close store with
  | Ok () -> ()
  | Error error -> fail "store close failed: %s" (Journal_storage.Error.to_string error)
;;

let with_store test =
  with_database_path (fun path ->
    let store, _ = open_store path in
    Fun.protect ~finally:(fun () -> close_store store) (fun () -> test store))
;;

let transact store transaction =
  match Journal_storage.transact store transaction with
  | Ok report -> report
  | Error error -> fail "transaction failed: %s" (Journal_storage.Error.to_string error)
;;

let id kind index = Printf.sprintf "20000000-0000-4000-%s-%012d" kind index

let creation_time ?(minute = 0) day =
  let midnight =
    match day with
    | 20260807 -> 1_786_032_000_000L
    | 20260808 -> 1_786_118_400_000L
    | 20260809 -> 1_786_204_800_000L
    | _ -> fail "unsupported creation fixture day %d" day
  in
  Journal_time.create
    ~instant_unix_ms:(Int64.add midnight (Int64.of_int (minute * 60_000)))
    ~local_day:day
    ~local_minute_of_day:minute
    ~time_zone_id:"Asia/Shanghai"
    ~utc_offset_seconds:28_800
  |> function
  | Ok value -> value
  | Error error -> fail "creation fixture failed: %s" error
;;

let capture
      ?(day = 20260809)
      ?(sibling_order = "000000000001")
      ?(source = "Journal source")
      ?(task_state = Journal_model.Not_a_task)
      index
  : Journal_repository.capture
  =
  { mutation_id = id "9000" index
  ; block_id = id "a000" index
  ; sibling_order
  ; source
  ; task_state
  ; creation_time = creation_time day
  }
;;

let find_block store block_id =
  Journal_repository.find_block (Journal_storage.current_db store) ~id:block_id
  |> require_ok
;;

let apply_capture store command =
  (match
     Journal_repository.prepare_capture (Journal_storage.current_db store) command
     |> require_ok
   with
   | Journal_repository.Already_applied _ -> fail "fresh capture was already applied"
   | Apply transaction -> ignore (transact store transaction));
  match find_block store command.block_id with
  | Some block -> block
  | None -> fail "confirmed capture is missing"
;;

let apply_child store command =
  (match
     Journal_repository.prepare_create_child (Journal_storage.current_db store) command
     |> require_ok
   with
   | Journal_repository.Child_already_applied _ -> fail "fresh child was already applied"
   | Create_child transaction -> ignore (transact store transaction));
  match find_block store command.block_id with
  | Some block -> block
  | None -> fail "confirmed child is missing"
;;

let block_ids blocks = List.map Journal_model.id blocks

let delete_command ~mutation_id block : Journal_repository.delete_subtree =
  { mutation_id
  ; block_id = Journal_model.id block
  ; expected_revision = Journal_model.revision block
  }
;;

let prepare_delete store command =
  Journal_repository.prepare_delete_subtree (Journal_storage.current_db store) command
  |> require_ok
;;

let apply_delete store command =
  match prepare_delete store command with
  | Journal_repository.Delete_already_applied -> 0, None
  | Delete_conflict _ -> fail "fresh delete conflicted"
  | Delete_subtree { transaction; deleted_count; parent_block_id } ->
    ignore (transact store transaction);
    deleted_count, parent_block_id
;;

let test_descending_days_and_ascending_compound_block_pages () =
  with_store (fun store ->
    let same_order_high = capture ~sibling_order:"a" 12 in
    let same_order_low = capture ~sibling_order:"a" 11 in
    let later_order = capture ~sibling_order:"b" 13 in
    let older = capture ~day:20260808 14 in
    let oldest = capture ~day:20260807 15 in
    List.iter
      (fun command -> ignore (apply_capture store command))
      [ later_order; same_order_high; oldest; same_order_low; older ];
    let pages, has_more =
      Journal_repository.recent_pages
        (Journal_storage.current_db store)
        ~before_day:None
        ~limit:2
      |> require_ok
    in
    require
      (List.map (fun page -> page.Journal_repository.day) pages = [ 20260809; 20260808 ])
      "journal days are not reverse chronological";
    require has_more "bounded day page lost its continuation";
    let older_pages, older_has_more =
      Journal_repository.recent_pages
        (Journal_storage.current_db store)
        ~before_day:(Some 20260808)
        ~limit:2
      |> require_ok
    in
    require
      (List.map (fun page -> page.Journal_repository.day) older_pages = [ 20260807 ])
      "exclusive day cursor returned the wrong page";
    require (not older_has_more) "last day page incorrectly has more";
    let first =
      Journal_repository.load_day_blocks
        (Journal_storage.current_db store)
        ~day:20260809
        ~after:None
        ~limit:2
      |> require_ok
    in
    require
      (block_ids first.blocks = [ same_order_low.block_id; same_order_high.block_id ])
      "equal sibling orders did not use stable-ID tie-breaking";
    let cursor =
      match first.continuation with
      | Some cursor -> cursor
      | None -> fail "bounded block page lost its compound cursor"
    in
    let second =
      Journal_repository.load_day_blocks
        (Journal_storage.current_db store)
        ~day:20260809
        ~after:(Some cursor)
        ~limit:2
      |> require_ok
    in
    require
      (block_ids second.blocks = [ later_order.block_id ])
      "block cursor skipped or repeated rows";
    require (second.continuation = None) "final block page retained a continuation";
    let empty =
      Journal_repository.load_day_blocks
        (Journal_storage.current_db store)
        ~day:20260806
        ~after:None
        ~limit:4
      |> require_ok
    in
    require (empty.blocks = [] && empty.continuation = None) "missing day was not empty")
;;

let test_direct_children_are_paged_and_deleted_parents_are_rejected () =
  with_store (fun store ->
    let parent_command = capture ~day:20260808 ~task_state:Journal_model.Todo 21 in
    let parent = apply_capture store parent_command in
    let child index sibling_order expected_parent_revision
      : Journal_repository.create_child
      =
      { mutation_id = id "9000" index
      ; block_id = id "a000" index
      ; parent_block_id = Journal_model.id parent
      ; expected_parent_revision
      ; sibling_order
      ; source = Printf.sprintf "Child %d" index
      ; task_state = Journal_model.Not_a_task
      ; creation_time = creation_time ~minute:index 20260809
      }
    in
    let high = child 23 "same" 1 in
    let confirmed_high = apply_child store high in
    require
      (Journal_model.journal_day confirmed_high = 20260808)
      "child moved away from its parent journal page";
    require
      (Journal_time.local_day (Journal_model.creation_time confirmed_high) = 20260809)
      "child creation day snapshot was rewritten to the parent day";
    let low = child 22 "same" 2 in
    ignore (apply_child store low);
    let later = child 24 "z" 3 in
    ignore (apply_child store later);
    let page =
      Journal_repository.load_children
        (Journal_storage.current_db store)
        ~parent_id:parent_command.block_id
        ~after:None
        ~limit:2
      |> require_ok
    in
    require
      (block_ids page.blocks = [ low.block_id; high.block_id ])
      "direct children did not use compound order";
    let cursor = Option.get page.continuation in
    let tail =
      Journal_repository.load_children
        (Journal_storage.current_db store)
        ~parent_id:parent_command.block_id
        ~after:(Some cursor)
        ~limit:2
      |> require_ok
    in
    require (block_ids tail.blocks = [ later.block_id ]) "child continuation is wrong";
    let detail =
      Journal_repository.load_detail
        (Journal_storage.current_db store)
        ~block_id:parent_command.block_id
        ~after:None
        ~limit:2
      |> require_ok
    in
    require (Journal_model.child_count detail.root = 3) "parent child count is stale";
    ignore
      (transact
         store
         [ RetractEntity
             (Lookup_ref (Journal_schema.Attr.block_id, Uuid parent_command.block_id))
         ]);
    require_error
      (Journal_repository.load_children
         (Journal_storage.current_db store)
         ~parent_id:parent_command.block_id
         ~after:None
         ~limit:2))
;;

let test_mutations_are_idempotent_revision_fenced_and_durable () =
  with_database_path (fun path ->
    let store, _ = open_store path in
    let command =
      capture ~source:"Original #tag @mention 👩🏽‍💻" ~task_state:Journal_model.Todo 31
    in
    let original = apply_capture store command in
    require (Journal_model.revision original = 1) "capture revision is not 1";
    (match
       Journal_repository.prepare_capture (Journal_storage.current_db store) command
       |> require_ok
     with
     | Journal_repository.Already_applied block ->
       require
         (String.equal (Journal_model.id block) command.block_id)
         "duplicate capture changed identity"
     | Apply _ -> fail "duplicate capture was not idempotent");
    let update : Journal_repository.update_source =
      { mutation_id = id "9000" 32
      ; block_id = command.block_id
      ; expected_revision = 1
      ; source = "Edited e\204\129 עברית العربية"
      }
    in
    (match
       Journal_repository.prepare_update_source (Journal_storage.current_db store) update
       |> require_ok
     with
     | Update_block transaction -> ignore (transact store transaction)
     | Update_already_applied _ | Update_conflict _ -> fail "fresh edit did not apply");
    (match
       Journal_repository.prepare_update_source (Journal_storage.current_db store) update
       |> require_ok
     with
     | Update_already_applied block ->
       require (Journal_model.revision block = 2) "duplicate edit returned wrong revision"
     | Update_block _ | Update_conflict _ -> fail "duplicate edit was not idempotent");
    let stale : Journal_repository.update_source =
      { mutation_id = id "9000" 33
      ; block_id = command.block_id
      ; expected_revision = 1
      ; source = "Stale edit"
      }
    in
    (match
       Journal_repository.prepare_update_source (Journal_storage.current_db store) stale
       |> require_ok
     with
     | Update_conflict block ->
       require (Journal_model.revision block = 2) "conflict returned stale block"
     | Update_already_applied _ | Update_block _ ->
       fail "stale edit bypassed revision CAS");
    let task : Journal_repository.set_task_state =
      { mutation_id = id "9000" 34
      ; block_id = command.block_id
      ; expected_revision = 2
      ; task_state = Journal_model.Done
      }
    in
    (match
       Journal_repository.prepare_set_task_state (Journal_storage.current_db store) task
       |> require_ok
     with
     | Update_block transaction -> ignore (transact store transaction)
     | Update_already_applied _ | Update_conflict _ ->
       fail "task transition did not apply");
    let confirmed = Option.get (find_block store command.block_id) in
    require
      (Journal_model.task_state confirmed = Journal_model.Done)
      "task state was not persisted";
    require (Journal_model.revision confirmed = 3) "task revision did not advance";
    require
      (Journal_time.equal (Journal_model.creation_time confirmed) command.creation_time)
      "mutation rewrote immutable creation time";
    close_store store;
    let reopened, disposition = open_store path in
    require (disposition = Journal_storage.Restored) "store did not reopen";
    let durable = Option.get (find_block reopened command.block_id) in
    require
      (String.equal (Journal_model.source durable) update.source)
      "edited source was not durable";
    require
      (Journal_model.task_state durable = Journal_model.Done)
      "task state was not durable";
    require
      (Journal_time.equal (Journal_model.creation_time durable) command.creation_time)
      "creation time did not survive restart";
    close_store reopened)
;;

let test_literal_source_round_trips_without_repository_truncation () =
  with_store (fun store ->
    let sources =
      [ "#tag @mention"; "e\204\129"; "עברית العربية"; "👨‍👩‍👧‍👦"; String.make 65_536 'x' ]
    in
    List.iteri
      (fun offset source ->
         let command =
           capture ~sibling_order:(Printf.sprintf "%08d" offset) ~source (100 + offset)
         in
         let block = apply_capture store command in
         require
           (String.equal (Journal_model.source block) source)
           "repository changed literal source")
      sources;
    [ capture ~source:"" 200
    ; capture ~source:"contains\000nul" 201
    ; capture ~source:(String.make 65_537 'x') 202
    ]
    |> List.iter (fun command ->
      require_error
        (Journal_repository.prepare_capture (Journal_storage.current_db store) command)))
;;

let test_query_bounds_and_invalid_cursors_are_rejected () =
  with_store (fun store ->
    let database = Journal_storage.current_db store in
    require_error (Journal_repository.recent_pages database ~before_day:None ~limit:0);
    require_error (Journal_repository.recent_pages database ~before_day:None ~limit:32);
    require_error
      (Journal_repository.load_day_blocks database ~day:20260809 ~after:None ~limit:0);
    require_error
      (Journal_repository.load_day_blocks database ~day:20260809 ~after:None ~limit:65);
    require_error
      (Journal_repository.load_day_blocks
         database
         ~day:20260809
         ~after:(Some { after_sibling_order = ""; after_block_id = id "a000" 1 })
         ~limit:1);
    require_error
      (Journal_repository.load_children
         database
         ~parent_id:"not-a-uuid"
         ~after:None
         ~limit:1))
;;

let test_delete_subtree_is_recursive_atomic_and_preserves_unrelated_data () =
  with_store (fun store ->
    let root_command = capture ~sibling_order:"a" 300 in
    let sibling_command = capture ~sibling_order:"z" 301 in
    let older_command = capture ~day:20260808 302 in
    let root = apply_capture store root_command in
    ignore (apply_capture store sibling_command);
    ignore (apply_capture store older_command);
    let child index parent expected_parent_revision order
      : Journal_repository.create_child
      =
      { mutation_id = id "9000" index
      ; block_id = id "a000" index
      ; parent_block_id = Journal_model.id parent
      ; expected_parent_revision
      ; sibling_order = order
      ; source = Printf.sprintf "Delete fixture %d" index
      ; task_state = Journal_model.Not_a_task
      ; creation_time = creation_time ~minute:(index mod 1_440) 20260809
      }
    in
    let first = apply_child store (child 303 root 1 "a") in
    ignore (apply_child store (child 304 root 2 "b"));
    ignore (apply_child store (child 305 first 1 "a"));
    let root = Option.get (find_block store root_command.block_id) in
    let mutation_id = id "9000" 306 in
    let deleted_count, parent_block_id =
      apply_delete store (delete_command ~mutation_id root)
    in
    require (deleted_count = 4) "recursive delete reported %d entities" deleted_count;
    require (parent_block_id = None) "top-level delete returned a Block parent";
    List.iter
      (fun block_id ->
         require (find_block store block_id = None) "subtree member survived")
      [ root_command.block_id; id "a000" 303; id "a000" 304; id "a000" 305 ];
    require
      (Option.is_some (find_block store sibling_command.block_id))
      "sibling was deleted";
    require
      (Option.is_some (find_block store older_command.block_id))
      "older day was deleted";
    let pages, _ =
      Journal_repository.recent_pages
        (Journal_storage.current_db store)
        ~before_day:None
        ~limit:31
      |> require_ok
    in
    require (List.length pages = 2) "delete removed a journal page";
    match prepare_delete store (delete_command ~mutation_id root) with
    | Journal_repository.Delete_already_applied -> ()
    | Delete_conflict _ | Delete_subtree _ -> fail "missing root was not idempotent")
;;

let test_delete_child_updates_parent_and_conflicts_are_non_mutating () =
  with_store (fun store ->
    let parent_command = capture 320 in
    ignore (apply_capture store parent_command);
    let child_command : Journal_repository.create_child =
      { mutation_id = id "9000" 321
      ; block_id = id "a000" 321
      ; parent_block_id = parent_command.block_id
      ; expected_parent_revision = 1
      ; sibling_order = "a"
      ; source = "Child to delete"
      ; task_state = Journal_model.Not_a_task
      ; creation_time = creation_time 20260809
      }
    in
    let child = apply_child store child_command in
    let stale =
      { (delete_command ~mutation_id:(id "9000" 322) child) with expected_revision = 9 }
    in
    (match prepare_delete store stale with
     | Journal_repository.Delete_conflict latest ->
       require (Journal_model.revision latest = 1) "conflict returned wrong root"
     | Delete_already_applied | Delete_subtree _ -> fail "stale delete did not conflict");
    require
      (Option.is_some (find_block store child_command.block_id))
      "conflict mutated storage";
    let mutation_id = id "9000" 323 in
    let deleted_count, parent_id =
      apply_delete store (delete_command ~mutation_id child)
    in
    require (deleted_count = 1) "leaf delete reported the wrong count";
    require (parent_id = Some parent_command.block_id) "delete omitted its Block parent";
    let updated_parent = Option.get (find_block store parent_command.block_id) in
    require (Journal_model.revision updated_parent = 3) "parent revision did not advance";
    require (Journal_model.child_count updated_parent = 0) "parent child count is stale";
    require
      (String.equal (Journal_model.last_mutation_id updated_parent) mutation_id)
      "parent mutation ID did not record delete")
;;

let test_delete_preflight_rejects_invalid_cross_page_and_cyclic_structure () =
  with_store (fun store ->
    let root = apply_capture store (capture 340) in
    let other = apply_capture store (capture ~day:20260808 341) in
    let child_command : Journal_repository.create_child =
      { mutation_id = id "9000" 342
      ; block_id = id "a000" 342
      ; parent_block_id = Journal_model.id root
      ; expected_parent_revision = 1
      ; sibling_order = "a"
      ; source = "Corruptible child"
      ; task_state = Journal_model.Not_a_task
      ; creation_time = creation_time 20260809
      }
    in
    let child = apply_child store child_command in
    let db = Journal_storage.current_db store in
    [ { Journal_repository.mutation_id = "bad"
      ; block_id = Journal_model.id root
      ; expected_revision = 2
      }
    ; { mutation_id = id "9000" 343; block_id = "bad"; expected_revision = 2 }
    ; { mutation_id = id "9000" 344
      ; block_id = Journal_model.id root
      ; expected_revision = 0
      }
    ]
    |> List.iter (fun command ->
      require_error (Journal_repository.prepare_delete_subtree db command));
    ignore
      (transact
         store
         [ Add
             ( Lookup_ref (Journal_schema.Attr.block_id, Uuid (Journal_model.id child))
             , Journal_schema.Attr.block_page
             , Ref_to
                 (Lookup_ref
                    (Journal_schema.Attr.page_id, Uuid (Journal_model.page_id other))) )
         ]);
    require_error
      (Journal_repository.prepare_delete_subtree
         (Journal_storage.current_db store)
         (delete_command
            ~mutation_id:(id "9000" 345)
            (Option.get (find_block store (Journal_model.id root)))));
    ignore
      (transact
         store
         [ Add
             ( Lookup_ref (Journal_schema.Attr.block_id, Uuid (Journal_model.id child))
             , Journal_schema.Attr.block_page
             , Ref_to
                 (Lookup_ref
                    (Journal_schema.Attr.page_id, Uuid (Journal_model.page_id root))) )
         ; Add
             ( Lookup_ref (Journal_schema.Attr.block_id, Uuid (Journal_model.id root))
             , Journal_schema.Attr.block_parent
             , Ref_to
                 (Lookup_ref (Journal_schema.Attr.block_id, Uuid (Journal_model.id child)))
             )
         ]);
    require_error
      (Journal_repository.prepare_delete_subtree
         (Journal_storage.current_db store)
         (delete_command
            ~mutation_id:(id "9000" 346)
            (Option.get (find_block store (Journal_model.id root))))))
;;

let () =
  test_descending_days_and_ascending_compound_block_pages ();
  test_direct_children_are_paged_and_deleted_parents_are_rejected ();
  test_mutations_are_idempotent_revision_fenced_and_durable ();
  test_literal_source_round_trips_without_repository_truncation ();
  test_query_bounds_and_invalid_cursors_are_rejected ();
  test_delete_subtree_is_recursive_atomic_and_preserves_unrelated_data ();
  test_delete_child_updates_parent_and_conflicts_are_non_mutating ();
  test_delete_preflight_rejects_invalid_cross_page_and_cyclic_structure ()
;;
