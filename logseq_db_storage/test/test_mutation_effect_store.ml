module S = Logseq_db_storage.Mutation_effect_store
module U = Logseq_db_types.Graph_types.Uuid

let ok = function
  | Ok value -> value
  | Error _ -> failwith "intent store failed"
;;

let uuid n =
  U.of_string (Printf.sprintf "99000000-0000-4000-8000-%012d" n) |> Result.get_ok
;;

let namespace = String.make 64 'a'
let other = String.make 64 'b'

let fixture f =
  let path = Filename.temp_file "mutation-intent-synthetic-" ".sqlite" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> f path)
;;

let with_db path f =
  let db = Sqlite3.db_open path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () ->
       ok (S.initialize_database db);
       f db)
;;

let restart_and_identity () =
  fixture (fun path ->
    with_db path (fun db ->
      let stored =
        ok
          (S.prepare db ~namespace ~mutation_id:(uuid 1) ~payload:"complete intent bytes")
      in
      Alcotest.(check bool) "prepare has no invented commit" true (stored.evidence = None);
      let duplicate =
        ok
          (S.prepare db ~namespace ~mutation_id:(uuid 1) ~payload:"complete intent bytes")
      in
      Alcotest.(check int64)
        "same payload retains sequence"
        stored.sequence
        duplicate.sequence;
      Alcotest.(check bool)
        "same ID different payload conflicts"
        true
        (S.prepare db ~namespace ~mutation_id:(uuid 1) ~payload:"changed precondition"
         = Error S.Identity_conflict);
      ignore
        (ok
           (S.commit
              db
              ~namespace
              ~mutation_id:(uuid 1)
              ~payload:"complete intent bytes"
              ~evidence:"original generation/before/after/targets")));
    with_db path (fun db ->
      let stored = ok (S.read db ~namespace ~mutation_id:(uuid 1)) |> Option.get in
      Alcotest.(check (option string))
        "original evidence survives reopening"
        (Some "original generation/before/after/targets")
        stored.evidence;
      Alcotest.(check bool)
        "evidence cannot be replaced by current revision"
        true
        (S.commit
           db
           ~namespace
           ~mutation_id:(uuid 1)
           ~payload:stored.payload
           ~evidence:"later current revision"
         = Error S.Identity_conflict);
      ok
        (S.acknowledge
           db
           ~namespace
           ~mutation_id:(uuid 1)
           ~evidence:"original generation/before/after/targets");
      Alcotest.(check int)
        "acknowledged item leaves recovery"
        0
        (List.length (ok (S.pending db ~namespace ~after:None ~limit:8)).items);
      Alcotest.(check (option string))
        "ack retains durable commit evidence"
        stored.evidence
        (ok (S.read db ~namespace ~mutation_id:(uuid 1)) |> Option.get).evidence))
;;

let atomic_outbox_transaction () =
  fixture (fun path ->
    with_db path (fun db ->
      ignore
        (ok
           (S.prepare db ~namespace ~mutation_id:(uuid 2) ~payload:"persist before write"));
      Sqlite3.Rc.check
        (Sqlite3.exec db "CREATE TABLE synthetic_outbox(id INTEGER PRIMARY KEY)");
      Sqlite3.Rc.check (Sqlite3.exec db "BEGIN IMMEDIATE");
      Sqlite3.Rc.check (Sqlite3.exec db "INSERT INTO synthetic_outbox VALUES(1)");
      ignore
        (ok
           (S.commit
              db
              ~namespace
              ~mutation_id:(uuid 2)
              ~payload:"persist before write"
              ~evidence:"commit point"));
      Sqlite3.Rc.check (Sqlite3.exec db "ROLLBACK");
      Alcotest.(check (option string))
        "rollback retains prepared payload without commit"
        None
        (ok (S.read db ~namespace ~mutation_id:(uuid 2)) |> Option.get).evidence;
      Sqlite3.Rc.check (Sqlite3.exec db "BEGIN IMMEDIATE");
      Sqlite3.Rc.check (Sqlite3.exec db "INSERT INTO synthetic_outbox VALUES(1)");
      ignore
        (ok
           (S.commit
              db
              ~namespace
              ~mutation_id:(uuid 2)
              ~payload:"persist before write"
              ~evidence:"commit point"));
      Sqlite3.Rc.check (Sqlite3.exec db "COMMIT");
      Alcotest.(check (option string))
        "commit retains exact point"
        (Some "commit point")
        (ok (S.read db ~namespace ~mutation_id:(uuid 2)) |> Option.get).evidence))
;;

let paging_and_bounds () =
  fixture (fun path ->
    with_db path (fun db ->
      for i = 1 to 260 do
        ignore
          (ok (S.prepare db ~namespace ~mutation_id:(uuid i) ~payload:(string_of_int i)))
      done;
      ignore
        (ok (S.prepare db ~namespace:other ~mutation_id:(uuid 1) ~payload:"isolated"));
      let first = ok (S.pending db ~namespace ~after:None ~limit:256) in
      Alcotest.(check int) "bounded first page" 256 (List.length first.items);
      Alcotest.(check bool)
        "partial does not claim complete"
        true
        (Option.is_some first.next);
      let last = ok (S.pending db ~namespace ~after:first.next ~limit:256) in
      Alcotest.(check int)
        "continuation retains remaining items"
        4
        (List.length last.items);
      Alcotest.(check bool) "last page is complete" true (last.next = None);
      Alcotest.(check bool)
        "unbounded page refused"
        true
        (Result.is_error (S.pending db ~namespace ~after:None ~limit:1000));
      Alcotest.(check bool)
        "unknown commit cannot manufacture evidence"
        true
        (Result.is_error
           (S.commit
              db
              ~namespace
              ~mutation_id:(uuid 999)
              ~payload:"absent"
              ~evidence:"invented"));
      Alcotest.(check bool)
        "uncommitted acknowledgement refused"
        true
        (Result.is_error
           (S.acknowledge db ~namespace ~mutation_id:(uuid 1) ~evidence:"invented"))))
;;

let recovery_has_total_byte_budget () =
  fixture (fun path ->
    with_db path (fun db ->
      let payload = String.make 2097152 'p'
      and evidence = String.make 1048576 'e' in
      for n = 1 to 3 do
        ignore (ok (S.prepare db ~namespace ~mutation_id:(uuid n) ~payload));
        ignore (ok (S.commit db ~namespace ~mutation_id:(uuid n) ~payload ~evidence))
      done;
      let rec pages after expected =
        let page = ok (S.pending db ~namespace ~after ~limit:256) in
        Alcotest.(check int)
          "byte budget stops before second large item"
          1
          (List.length page.items);
        Alcotest.(check bool)
          "sequence continuation does not skip large rows"
          true
          ((List.hd page.items).mutation_id = uuid expected);
        if expected < 3
        then (
          Alcotest.(check bool)
            "byte-truncated page remains Partial"
            true
            (Option.is_some page.next);
          pages page.next (expected + 1))
        else
          Alcotest.(check bool)
            "last byte-bounded page is complete"
            true
            (page.next = None)
      in
      pages None 1))
;;

let () =
  Alcotest.run
    "durable mutation intent bytes"
    [ ( "storage"
      , [ Alcotest.test_case "restart and exact identity" `Quick restart_and_identity
        ; Alcotest.test_case "atomic outbox transaction" `Quick atomic_outbox_transaction
        ; Alcotest.test_case "bounded scoped recovery" `Quick paging_and_bounds
        ; Alcotest.test_case
            "recovery total byte budget"
            `Quick
            recovery_has_total_byte_budget
        ] )
    ]
;;
