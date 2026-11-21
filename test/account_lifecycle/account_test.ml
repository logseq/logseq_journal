module Account = Journal_sync_lifecycle.Account
module Dsl = Sync_dsl.Core
module Graph = Logseq_db_types.Managed_graph
module Uuid = Logseq_db_types.Graph_types.Uuid

let ok = function
  | Ok value -> value
  | Error error -> failwith (Dsl.error_message error)
;;

let check label condition = if not condition then failwith label

let rejected label = function
  | Error _ -> ()
  | Ok _ -> failwith label
;;

let graph suffix =
  { Graph.graph_id =
      Uuid.of_string ("00000000-0000-0000-0000-00000000000" ^ suffix) |> Result.get_ok
  ; name = suffix
  ; schema = { major = 1; minor = 0; exact = true }
  ; encrypted = false
  }
;;

let first = graph "1"
let second = graph "2"

let with_root run =
  let root = Filename.temp_file "account-lifecycle" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter (fun name -> Sys.remove (Filename.concat root name)) (Sys.readdir root);
      Unix.rmdir root)
    (fun () -> run { Account.origin = "https://example.org"; account = "user"; root })
;;

let fixture ?(maximum_services = 1) ?(fetch = fun () -> Ok [ first; second ]) run =
  with_root (fun account ->
    let events = ref [] in
    let fail_close = ref false in
    let on_start = ref (fun () -> ()) in
    let add value = events := !events @ [ value ] in
    let controller =
      Account.create
        ~maximum_services
        ~catalog:(fun ~account:_ ~check_current ~gate:_ ->
          let result = fetch () in
          match check_current () with
          | Ok () -> result
          | Error _ as error -> error)
        ~start:
          (fun
            ~account:_
            ~account_generation:_
            ~graph_generation:_
            ~graph
            ~upload_store:_
            ~network:_
            ~on_change:_ ->
          add ("start:" ^ graph.Graph.name);
          !on_start ();
          Ok
            (Account.service
               ~set_network:(fun gate ->
                 add
                   (match gate with
                    | Dsl.Closed -> "closed"
                    | Dsl.Open _ -> "open");
                 Ok ())
               ~close:(fun () ->
                 add "close";
                 if !fail_close then Error (Dsl.Storage_failure "held") else Ok ())))
        ~delete_local:(fun ~account:_ ~graph:_ ->
          add "delete";
          Ok ())
        ~on_change:(fun _ _ -> add "change")
      |> ok
    in
    ok (Account.replace controller account);
    run controller account events fail_close on_start;
    fail_close := false;
    ok (Account.logout controller))
;;

let selection () =
  fixture (fun controller _ events _ _ ->
    ignore (ok (Account.refresh controller));
    ok (Account.select controller first.graph_id);
    ok (Account.select controller first.graph_id);
    check "one start" (!events = [ "start:1" ]);
    ok (Account.deselect controller);
    check "deselected" (Account.selected controller = None);
    check "bounded warm registry" (Account.service_count controller = 1);
    ok (Account.set_network controller (Dsl.Open { authorization_epoch = 1L }));
    ok (Account.delete_local controller first.graph_id);
    check "close precedes deletion" (!events = [ "start:1"; "open"; "close"; "delete" ]);
    check "removed" (Account.service_count controller = 0);
    rejected "deleted graph cannot restart" (Account.select controller first.graph_id))
;;

let local_restoration () =
  fixture ~maximum_services:2 ~fetch:(fun () -> failwith "offline restore fetched catalog")
    (fun controller _ events fail_close _ ->
      ok (Account.restore_catalog controller [first;second]);
      ok (Account.select controller first.graph_id);
      ok (Account.select controller second.graph_id);
      check "local residents start without network" (!events = ["start:1";"start:2"]);
      fail_close := true;
      rejected "failed retirement retains resident" (Account.release_graph controller first.graph_id);
      check "failed retirement retains ownership" (Account.service_count controller = 2);
      fail_close := false;
      ok (Account.release_graph controller first.graph_id);
      check "host close retains catalog" (List.length (Account.catalog controller) = 2);
      check "other resident remains selected" (Account.selected controller = Some second.graph_id);
      check "host close releases service" (Account.service_count controller = 1);
      ok (Account.select controller first.graph_id);
      check "closed graph can be reopened" (Account.service_count controller = 2))
;;

let retirement_failure () =
  fixture (fun controller account events fail_close _ ->
    ignore (ok (Account.refresh controller));
    ok (Account.select controller first.graph_id);
    fail_close := true;
    rejected "delete blocked" (Account.delete_local controller first.graph_id);
    check "no delete" (not (List.mem "delete" !events));
    rejected "logout blocked" (Account.logout controller);
    rejected "replacement blocked" (Account.replace controller account);
    rejected "revoked catalog" (Account.refresh controller);
    check "retained registry" (Account.service_count controller = 1);
    check
      "store retained"
      (Sys.file_exists (Filename.concat account.root "asset-upload-intents.sqlite"));
    fail_close := false;
    ok (Account.logout controller);
    ok (Account.replace controller account))
;;

let stale_refresh () =
  let during_fetch = ref (fun () -> ()) in
  fixture
    ~fetch:(fun () ->
      !during_fetch ();
      Ok [ first; second ])
    (fun controller account _ _ _ ->
       (during_fetch
        := fun () ->
             ok (Account.logout controller);
             ok (Account.replace controller account));
       rejected "old account result" (Account.refresh controller);
       check "no stale catalog" (Account.catalog controller = []))
;;

let refresh_order () =
  let during_fetch = ref (fun () -> ()) in
  fixture
    ~fetch:(fun () ->
      !during_fetch ();
      Ok [ first ])
    (fun controller _ _ _ _ ->
       (during_fetch
        := fun () ->
             (during_fetch := fun () -> ());
             ignore (ok (Account.refresh controller)));
       rejected "older request" (Account.refresh controller);
       check "new catalog retained" (List.length (Account.catalog controller) = 1))
;;

let reentry () =
  fixture (fun controller _ _ _ on_start ->
    ignore (ok (Account.refresh controller));
    (on_start := fun () -> rejected "start reentry" (Account.logout controller));
    ok (Account.select controller first.graph_id))
;;

let network_refresh () =
  let during_fetch = ref (fun () -> ()) in
  fixture
    ~fetch:(fun () ->
      !during_fetch ();
      Ok [ first ])
    (fun controller _ _ _ _ ->
       ok (Account.set_network controller (Dsl.Open { authorization_epoch = 1L }));
       (during_fetch := fun () -> ok (Account.set_network controller Dsl.Closed));
       rejected "network revocation" (Account.refresh controller))
;;

let multiple_services () =
  fixture ~maximum_services:2 (fun controller account events _ _ ->
    ignore (ok (Account.refresh controller));
    ok (Account.select controller first.graph_id);
    ok (Account.select controller second.graph_id);
    check "two resident services" (Account.service_count controller = 2);
    ok (Account.replace controller account);
    check
      "both services physically closed"
      (!events = [ "start:1"; "start:2"; "close"; "close" ]);
    check "replacement registry empty" (Account.service_count controller = 0);
    check "replacement selection empty" (Account.selected controller = None))
;;

let bounded_replacement () =
  fixture (fun controller _ events fail_close _ ->
    ignore (ok (Account.refresh controller));
    ok (Account.select controller first.graph_id);
    fail_close := true;
    rejected
      "replacement waits for retirement"
      (Account.select controller second.graph_id);
    check "no overlapping start" (!events = [ "start:1"; "close" ]);
    check "failed retirement counted" (Account.service_count controller = 1);
    fail_close := false;
    ok (Account.select controller second.graph_id);
    check
      "close precedes replacement start"
      (!events = [ "start:1"; "close"; "close"; "start:2" ]);
    check "bounded after replacement" (Account.service_count controller = 1))
;;

let account_store () =
  with_root (fun account ->
    let stores = ref [] in
    let closed = ref 0 in
    let controller =
      Account.create
        ~maximum_services:2
        ~catalog:(fun ~account:_ ~check_current:_ ~gate:_ -> Ok [ first; second ])
        ~start:
          (fun
            ~account:_
            ~account_generation:_
            ~graph_generation:_
            ~graph:_
            ~upload_store
            ~network:_
            ~on_change:_ ->
          stores := upload_store :: !stores;
          Ok
            (Account.service
               ~set_network:(fun _ -> Ok ())
               ~close:(fun () ->
                 incr closed;
                 Ok ())))
        ~delete_local:(fun ~account:_ ~graph:_ -> Ok ())
        ~on_change:(fun _ _ -> ())
      |> ok
    in
    Fun.protect
      ~finally:(fun () -> ok (Account.logout controller))
      (fun () ->
         ok (Account.replace controller account);
         ignore (ok (Account.refresh controller));
         ok (Account.select controller first.graph_id);
         ok (Account.select controller second.graph_id);
         let previous = List.hd !stores in
         check "one store per account" (previous == List.nth !stores 1);
         ok (Account.replace controller account);
         check "old services retired before reopening store" (!closed = 2);
         ignore (ok (Account.refresh controller));
         ok (Account.select controller first.graph_id);
         check "replacement store has a fresh owner" (previous != List.hd !stores)))
;;

let duplicate_catalog () =
  fixture
    ~fetch:(fun () -> Ok [ first; first ])
    (fun controller _ _ _ _ ->
       rejected "duplicate catalog" (Account.refresh controller);
       check "atomic catalog publication" (Account.catalog controller = []))
;;

let http_catalog () =
  with_root (fun account ->
    let module Client = Logseq_sync_transport.Http_client in
    let module Native = Logseq_sync_native_transport.Http_eio in
    let calls = ref 0 in
    let refreshes = ref [] in
    let current = ref true in
    let gate = ref (Dsl.Open { authorization_epoch = 7L }) in
    let status = ref 200 in
    let body =
      ref
        {|{"graphs":[{"graph-ready-for-use?":false},{"graph-ready-for-use?":true,"graph-id":"00000000-0000-0000-0000-000000000001","graph-name":"One","schema-version":"2.3"}]}|}
    in
    let content_type = ref "application/json" in
    let after_request = ref (fun () -> ()) in
    let backend =
      { Client.perform =
          (fun request ->
            incr calls;
            check
              "catalog endpoint"
              (Uri.path request.Logseq_sync_native_transport.Http.uri = "/graphs");
            check
              "authorization"
              (List.mem_assoc "Authorization" request.headers
               || List.mem_assoc "authorization" request.headers);
            !after_request ();
            Ok
              { Native.status = (if !calls = 1 then 401 else !status)
              ; headers = [ "content-type", !content_type ]
              ; body = !body
              })
      ; download =
          (fun ~request:_ ~destination:_ ~maximum_bytes:_ -> failwith "not a download")
      }
    in
    let fetch =
      Account.http_catalog ~backend ~token:(fun ~account:_ ~epoch ~refresh ->
        check "authorization epoch" (epoch = 7L);
        refreshes := !refreshes @ [ refresh ];
        Ok "token")
    in
    let run () =
      fetch
        ~account
        ~check_current:(fun () -> if !current then Ok () else Error Dsl.Stale_context)
        ~gate:(fun () -> !gate)
    in
    let graphs = ok (run ()) in
    check "one auth refresh" (!refreshes = [ false; true ]);
    check "ready graphs only" (List.length graphs = 1);
    let decoded = List.hd graphs in
    check
      "native catalog decoding"
      (decoded.encrypted
       && decoded.schema.major = 2
       && decoded.schema.minor = 3
       && decoded.schema.exact);
    status := 404;
    rejected "404 is not empty catalog" (run ());
    status := 200;
    body := "not JSON";
    rejected "malformed JSON" (run ());
    body := "{\"graphs\":[]}";
    content_type := "text/html";
    rejected "content type" (run ());
    content_type := "application/json";
    (after_request := fun () -> current := false);
    rejected "stale HTTP result" (run ());
    current := true;
    (after_request := fun () -> gate := Dsl.Closed);
    rejected "network closed during HTTP" (run ());
    let before = !calls in
    rejected "closed network admission" (run ());
    check "no request while closed" (!calls = before))
;;

let () =
  List.iter
    (fun (name, run) ->
       run ();
       Printf.printf "PASS %s\n%!" name)
    [ "selection and checked deletion", selection
    ; "offline restore and host retirement", local_restoration
    ; "retirement failure", retirement_failure
    ; "stale account catalog", stale_refresh
    ; "catalog request ordering", refresh_order
    ; "mutation reentry", reentry
    ; "network revocation", network_refresh
    ; "multiple service retirement", multiple_services
    ; "bounded replacement", bounded_replacement
    ; "account-owned upload store", account_store
    ; "duplicate catalog", duplicate_catalog
    ; "native HTTP catalog adapter", http_catalog
    ]
;;
