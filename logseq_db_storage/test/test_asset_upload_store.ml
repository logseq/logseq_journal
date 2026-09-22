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
      get (S.delete_graph db ~origin:a.origin ~account:a.account ~graph:a.graph);
      get (S.delete_graph db ~origin:a.origin ~account:a.account ~graph:a.graph);
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

let () =
  Alcotest.run
    "asset upload storage"
    [ ( "SQLite"
      , List.map
          (fun (n, f) -> Alcotest.test_case n `Quick f)
          [ "scoped cleanup", scoped_cleanup
          ; "restart", restart
          ; "atomic revision", atomic_revision
          ; "bounded recovery", paging
          ] )
    ]
;;
