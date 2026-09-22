module T = Logseq_sync_pure_reducer.Asset_transfer
module C = Logseq_sync_pure_reducer.Core
module A = Logseq_db_types.Asset_descriptor
module U = Logseq_db_types.Graph_types.Uuid

let get = function
  | Ok x -> x
  | Error e -> failwith e
;;

let uuid n = get (U.of_string (Printf.sprintf "00000000-0000-4000-8000-%012d" n))

let scope : C.graph_scope =
  { account =
      { managed_sync_origin = Uri.of_string "https://sync.example"
      ; user_id = "user"
      ; account_generation = 1
      ; presentation_generation = 1
      ; lifecycle_generation = 1L
      }
  ; graph_id = uuid 1
  ; graph_generation = 1
  }
;;

let asset ?(checksum = String.make 64 'a') ?(remote = true) n =
  get
    (A.create
       ~uuid:(uuid n)
       ~source:
         (Managed
            (if remote then Some (get (A.version ~checksum ~file_type:"png")) else None))
       ~current_checksum:None
       ~size:None
       ~dimensions:None)
;;

let initial ?(online = true) () =
  T.create
    (get (T.config ~active:2 ~foreground_reserved:1 ~pending:3 ~retries:2))
    ~scope
    ~online
    ~unlocked:true
;;

let replace t consumer priority assets = T.step t (Replace { consumer; priority; assets })

let checks effects =
  List.filter_map
    (function
      | T.Check_cache x -> Some x
      | _ -> None)
    effects
;;

let fetches effects =
  List.filter_map
    (function
      | T.Fetch x -> Some x
      | _ -> None)
    effects
;;

let only = function
  | [ x ] -> x
  | xs -> failwith (Printf.sprintf "expected one item, got %d" (List.length xs))
;;

let check label expected actual = Alcotest.(check int) label expected actual

let ready t consumer =
  match T.availability t ~consumer with
  | [ (_, T.Ready _) ] -> true
  | _ -> false
;;

let release_present effects =
  List.exists
    (function
      | T.Release_handle "stale" -> true
      | _ -> false)
    effects
;;

let bootstrap () =
  let t, effects = T.step (initial ()) (Descriptor_changed (asset 2)) in
  check "metadata does not download" 0 (List.length effects);
  check "no unsolicited demand" 0 (T.pending_count t)
;;

let coalescing () =
  let t, e = replace (initial ()) "recent" Background [ asset 2 ] in
  let lookup = only (checks e) in
  let t, e = replace t "visible" Foreground [ asset 2 ] in
  check "share cache lookup" 0 (List.length (checks e));
  let t, e = T.step t (Cache_checked (lookup, Ok None)) in
  let job = only (fetches e) in
  let t, e = T.step t (Release "recent") in
  Alcotest.(check bool)
    "still wanted"
    false
    (List.exists
       (function
         | T.Cancel _ -> true
         | _ -> false)
       e);
  let t, _ = T.step t (Downloaded (job, Ok "local")) in
  Alcotest.(check bool) "visible ready" true (ready t "visible");
  check "released reason" 0 (List.length (T.availability t ~consumer:"recent"))
;;

let waiting_remote () =
  let t, e = replace (initial ()) "visible" Foreground [ asset ~remote:false 2 ] in
  check
    "no GET without remote metadata"
    0
    (List.length (checks e) + List.length (fetches e));
  Alcotest.(check bool)
    "pending remote"
    true
    (match T.availability t ~consumer:"visible" with
     | [ (_, T.Waiting_remote) ] -> true
     | _ -> false);
  let _, e = T.step t (Descriptor_changed (asset 2)) in
  check "published version becomes eligible" 1 (List.length (checks e))
;;

let external_asset () =
  let a =
    get
      (A.create
         ~uuid:(uuid 2)
         ~source:(External "https://example/image")
         ~current_checksum:None
         ~size:None
         ~dimensions:None)
  in
  let t, e = replace (initial ()) "visible" Foreground [ a ] in
  check "external excluded" 0 (T.pending_count t);
  check "external has no managed IO" 0 (List.length (checks e) + List.length (fetches e))
;;

let stale () =
  let t, e = replace (initial ()) "visible" Foreground [ asset 2 ] in
  let t, e = T.step t (Cache_checked (only (checks e), Ok None)) in
  let old = only (fetches e) in
  let t, _ = T.step t (Descriptor_changed (asset ~checksum:(String.make 64 'b') 2)) in
  let t, e = T.step t (Downloaded (old, Ok "stale")) in
  Alcotest.(check bool) "stale handle cleaned" true (release_present e);
  Alcotest.(check bool) "old version never ready" false (ready t "visible");
  let t, _ = T.step t Shutdown in
  let _, e = T.step t (Downloaded (old, Ok "stale")) in
  Alcotest.(check bool) "shutdown cleans completion" true (release_present e)
;;

let foreground () =
  let t, e = replace (initial ()) "bg1" Background [ asset 2 ] in
  let t, e = T.step t (Cache_checked (only (checks e), Ok None)) in
  check "first background fetch" 1 (List.length (fetches e));
  let t, e = replace t "bg2" Background [ asset 3 ] in
  check "reserve foreground slot" 0 (List.length (checks e));
  let _, e = replace t "visible" Foreground [ asset 4 ] in
  check "foreground runs" 1 (List.length (checks e))
;;

let backpressure () =
  let t, _ = replace (initial ()) "bg" Background [ asset 2; asset 3 ] in
  let t, e = replace t "next" Background [ asset 5 ] in
  Alcotest.(check bool)
    "explicit pressure"
    true
    (List.exists
       (function
         | T.Backpressure "next" -> true
         | _ -> false)
       e);
  check
    "unaccepted demand not retained"
    0
    (List.length (T.availability t ~consumer:"next"));
  let t, e = T.step t (Release "bg") in
  Alcotest.(check bool) "enumerator can resume" true (List.mem T.Capacity_available e);
  let t, _ = replace t "next" Background [ asset 5 ] in
  check "accepted after capacity available" 1 (T.pending_count t)
;;

let offline () =
  let t, e = replace (initial ~online:false ()) "visible" Foreground [ asset 2 ] in
  let t, e = T.step t (Cache_checked (only (checks e), Ok (Some "cached"))) in
  Alcotest.(check bool) "offline cache usable" true (ready t "visible");
  check "offline no fetch" 0 (List.length (fetches e))
;;

let retry_limit () =
  let t, e = replace (initial ()) "visible" Foreground [ asset 2 ] in
  let t, e = T.step t (Cache_checked (only (checks e), Ok None)) in
  let rec loop t job attempt =
    let t, e = T.step t (Downloaded (job, Error T.Not_found)) in
    let timers =
      List.filter_map
        (function
          | T.Retry_after x -> Some x.id
          | _ -> None)
        e
    in
    if attempt = 3
    then check "bounded retry" 0 (List.length timers)
    else (
      let t, e = T.step t (Retry_elapsed (only timers)) in
      loop t (only (fetches e)) (attempt + 1))
  in
  loop t (only (fetches e)) 1
;;

let duplicate () =
  let t, e = replace (initial ()) "visible" Foreground [ asset 2 ] in
  let t, e = T.step t (Cache_checked (only (checks e), Ok None)) in
  let job = only (fetches e) in
  let t, _ = T.step t (Downloaded (job, Ok "local")) in
  let t, e = T.step t (Downloaded (job, Ok "local")) in
  Alcotest.(check bool) "duplicate keeps live handle" true (ready t "visible");
  Alcotest.(check bool)
    "does not release live handle"
    false
    (List.exists
       (function
         | T.Release_handle "local" -> true
         | _ -> false)
       e)
;;

let foreground_queue_capacity () =
  let t, _ = replace (initial ()) "bg" Background [ asset 2; asset 3 ] in
  let t, e = replace t "more-bg" Background [ asset 4 ] in
  Alcotest.(check bool)
    "reserve pending slot"
    true
    (List.exists
       (function
         | T.Backpressure "more-bg" -> true
         | _ -> false)
       e);
  let t, e = replace t "visible" Foreground [ asset 5 ] in
  check "foreground admitted despite background backlog" 1 (List.length (checks e));
  check "bounded admitted jobs" 3 (T.pending_count t)
;;

let lock_and_network () =
  let t, e = replace (initial ()) "visible" Foreground [ asset 2 ] in
  let t, e = T.step t (Cache_checked (only (checks e), Ok None)) in
  let old = only (fetches e) in
  let t, e = T.step t (Unlock_changed false) in
  Alcotest.(check bool) "lock cancels IO" true (List.mem (T.Cancel old) e);
  let t, e = T.step t (Downloaded (old, Ok "stale")) in
  Alcotest.(check bool) "lock fences bytes" true (release_present e);
  let t, _ = T.step t (Network_changed false) in
  let t, e = T.step t (Unlock_changed true) in
  check "unlock while offline has no GET" 0 (List.length (fetches e));
  let _, e = T.step t (Network_changed true) in
  check "online resumes demand" 1 (List.length (fetches e))
;;

let () =
  Alcotest.run
    "asset transfer"
    [ ( "public reducer"
      , List.map
          (fun (name, f) -> Alcotest.test_case name `Quick f)
          [ "metadata is not demand", bootstrap
          ; "coalescing and reasons", coalescing
          ; "waiting remote", waiting_remote
          ; "external excluded", external_asset
          ; "version and scope fence", stale
          ; "foreground reserve", foreground
          ; "backpressure", backpressure
          ; "offline cache", offline
          ; "bounded 404 retry", retry_limit
          ; "duplicate completion", duplicate
          ; "pending foreground capacity", foreground_queue_capacity
          ; "lock and network", lock_and_network
          ] )
    ]
;;
