module S = Logseq_db_storage.Asset_upload_store
module I = Logseq_db_types.Asset_upload_intent
module A = Logseq_db_types.Asset_descriptor
module U = Logseq_db_types.Graph_types.Uuid

let get = function
  | Ok x -> x
  | Error e -> failwith e
;;

let uuid n = get (U.of_string (Printf.sprintf "00000000-0000-4000-8000-%012d" n))

let intent ?(origin = "https://sync.example") ?(graph = uuid 1) ?(account = "user") n =
  get
    (I.prepare
       ~replace_reference:(Some (uuid 99))
       ~operation_id:(uuid n)
       ~origin
       ~account
       ~graph
       ~asset:(uuid (n + 100))
       ~version:(get (A.version ~checksum:(String.make 64 'a') ~file_type:"png"))
       ~title:"Fixture image"
       ~size:4L
       ~staged_file:("staged-" ^ string_of_int n)
       ~target:(uuid 4)
       ~local_mutation:(uuid (n + 200))
       ~metadata_mutation:(uuid (n + 300)))
;;

let fixture test =
  let path = Filename.temp_file "asset-upload" ".sqlite" in
  Fun.protect ~finally:(fun () -> Sys.remove path) (fun () -> test path)
;;

let with_db path f =
  let db = Sqlite3.db_open path in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.db_close db))
    (fun () ->
       get (S.initialize_database db);
       f db)
;;

let restart () =
  fixture (fun path ->
    let original = intent 2 in
    with_db path (fun db -> get (S.save db ~expected:None original));
    with_db path (fun db ->
      Alcotest.(check bool)
        "checkpoint survives reopening"
        true
        (get (S.read db ~operation:original.operation_id) = Some original)))
;;

let atomic_revision () =
  fixture (fun path ->
    with_db path (fun db ->
      let initial = intent 2 in
      get (S.save db ~expected:None initial);
      get (S.save db ~expected:None initial);
      let local = get (I.advance initial Local_committed) in
      get (S.save db ~expected:(Some 0) local);
      Alcotest.(check bool)
        "stale checkpoint rejected"
        true
        (Result.is_error (S.save db ~expected:None initial));
      let cancelled = get (I.advance initial Cancelled) in
      Alcotest.(check bool)
        "CAS rejects conflicting checkpoint"
        true
        (Result.is_error (S.save db ~expected:(Some 0) cancelled));
      Alcotest.(check bool)
        "current phase retained"
        true
        (get (S.read db ~operation:initial.operation_id) = Some local)))
;;

let paging () =
  fixture (fun path ->
    with_db path (fun db ->
      List.iter
        (fun i -> get (S.save db ~expected:None i))
        [ intent 2; intent 3; intent ~account:"other" 4 ];
      let page after =
        get
          (S.list
             db
             ~origin:"https://sync.example"
             ~account:"user"
             ~graph:(uuid 1)
             ~after
             ~limit:1)
      in
      let first = page None in
      Alcotest.(check int) "bounded first page" 1 (List.length first);
      let second = page (Some (List.hd first).operation_id) in
      Alcotest.(check int) "bounded second page" 1 (List.length second);
      Alcotest.(check int)
        "account scoped end"
        0
        (List.length (page (Some (List.hd second).operation_id)))))
;;

let scoped_cleanup () =
  fixture (fun path ->
    let a = intent 2
    and b = intent ~graph:(uuid 8) 3
    and c = intent ~account:"other" 4
    and d = intent ~origin:"https://other.example" 5 in
    with_db path (fun db ->
      List.iter (fun i -> get (S.save db ~expected:None i)) [ a; b; c; d ];
      let captured = get (S.capture_graph db ~origin:a.origin ~account:a.account ~graph:a.graph) in
      get (S.delete_captured_graph db captured);
      get (S.delete_captured_graph db captured);
      Alcotest.(check bool)
        "selected graph removed"
        true
        (get (S.read db ~operation:a.operation_id) = None);
      List.iter
        (fun i ->
           Alcotest.(check bool)
             "other scope retained"
             true
             (get (S.read db ~operation:i.I.operation_id) = Some i))
        [ b; c; d ];
      get (S.delete_account db ~origin:b.origin ~account:b.account));
    with_db path (fun db ->
      Alcotest.(check bool)
        "account cleanup survives restart"
        true
        (get (S.read db ~operation:b.operation_id) = None);
      List.iter
        (fun i ->
           Alcotest.(check bool)
             "other owner survives restart"
             true
             (get (S.read db ~operation:i.I.operation_id) = Some i))
        [ c; d ]))
;;

let generated_checkpoint_validation () =
  fixture (fun path ->
    with_db path (fun db ->
      let original = intent 2 in
      get (S.save db ~expected:None original);
      let payload = ref "" in
      Sqlite3.Rc.check
        (Sqlite3.exec db "SELECT payload FROM asset_upload_intents" ~cb:(fun row _ ->
           payload := Option.get row.(0)));
      let replace before after source =
        let n = String.length before in
        let rec find i =
          if i + n > String.length source
          then source
          else if String.sub source i n = before
          then
            String.sub source 0 i
            ^ after
            ^ String.sub source (i + n) (String.length source - i - n)
          else find (i + 1)
        in
        find 0
      in
      let write payload =
        let stmt = Sqlite3.prepare db "UPDATE asset_upload_intents SET payload=?" in
        Fun.protect
          ~finally:(fun () -> ignore (Sqlite3.finalize stmt))
          (fun () ->
             Sqlite3.Rc.check (Sqlite3.bind_text stmt 1 payload);
             Sqlite3.Rc.check (Sqlite3.step stmt))
      in
      let reject label payload =
        write payload;
        Alcotest.(check bool)
          label
          true
          (Result.is_error (S.read db ~operation:original.operation_id))
      in
      Alcotest.(check bool) "generated phase variant" true (String.contains !payload '[');
      reject
        "old checkpoint phase rejected"
        (replace "[\"Prepared\"]" "\"prepared\"" !payload);
      reject
        "invalid UUID rejected"
        (replace (U.to_string original.graph) "not-a-uuid" !payload);
      reject "negative asset size rejected" (replace "\"size\":4" "\"size\":-1" !payload);
      reject
        "revision invariant rejected"
        (replace "\"revision\":0" "\"revision\":-1" !payload);
      Alcotest.(check bool) "oversized encoded checkpoint rejected" true
        (Result.is_error (S.save db ~expected:None
           (intent ~origin:(String.make 8193 'x') 3)));
      write !payload;
      Alcotest.(check bool)
        "valid generated checkpoint recovers"
        true
        (get (S.read db ~operation:original.operation_id) = Some original)))
;;

let exact_retirement_preserves_new_and_changed_operations () =
  fixture (fun path ->
    let first = intent 2 and second = intent 3 and replacement = intent 8 in
    let captured = with_db path (fun db ->
      get (S.save db ~expected:None first); get (S.save db ~expected:None second);
      get (S.capture_graph db ~origin:first.origin ~account:first.account ~graph:first.graph)) in
    let captured = S.captured_graph_to_yojson captured |> S.captured_graph_of_yojson |> get in
    with_db path (fun db ->
      get (S.save db ~expected:None replacement);
      let changed = get (I.advance second Local_committed) in
      get (S.save db ~expected:(Some second.revision) changed);
      Alcotest.(check bool) "changed captured checkpoint defers cleanup" true
        (Result.is_error (S.delete_captured_graph db captured));
      Alcotest.(check bool) "failed cleanup retains every captured row" true
        (get (S.read db ~operation:first.operation_id) = Some first);
      Alcotest.(check bool) "new operation survives failed old cleanup" true
        (get (S.read db ~operation:replacement.operation_id) = Some replacement)))
;;

let exact_retirement_survives_restart_and_replacement () =
  fixture (fun path ->
    let old = intent 2 and fresh = intent 8 in
    let captured = with_db path (fun db ->
      get (S.save db ~expected:None old);
      get (S.capture_graph db ~origin:old.origin ~account:old.account ~graph:old.graph)) in
    with_db path (fun db ->
      get (S.save db ~expected:None fresh);
      get (S.delete_captured_graph db captured));
    with_db path (fun db ->
      get (S.delete_captured_graph db captured);
      Alcotest.(check bool) "old captured row absent" true (get (S.read db ~operation:old.operation_id) = None);
      Alcotest.(check bool) "new same-graph row retained after replay" true
        (get (S.read db ~operation:fresh.operation_id) = Some fresh)))
;;

let () =
  Alcotest.run
    "asset upload storage"
    [ ( "SQLite"
      , List.map
          (fun (n, f) -> Alcotest.test_case n `Quick f)
          [ "retirement preserves changed operations", exact_retirement_preserves_new_and_changed_operations
          ; "retirement restart and replacement isolation", exact_retirement_survives_restart_and_replacement
          ; "generated checkpoint validation", generated_checkpoint_validation
          ; "scoped cleanup", scoped_cleanup
          ; "restart", restart
          ; "atomic revision", atomic_revision
          ; "bounded recovery", paging
          ] )
    ]
;;
