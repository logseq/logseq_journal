module P = Journal_asset_policy
module G = Logseq_db_types.Graph_types
module A = Logseq_db_types.Asset_descriptor

let check value message = if not value then failwith message

let uuid n =
  G.Uuid.of_string (Printf.sprintf "00000000-0000-4000-8000-%012d" n) |> Result.get_ok
;;

let asset n =
  A.create
    ~uuid:(uuid n)
    ~source:(Managed None)
    ~current_checksum:None
    ~size:None
    ~dimensions:None
  |> Result.get_ok
;;

let cursor = G.Cursor.of_string "next" |> Result.get_ok

let refresh state =
  P.step
    state
    (Refresh { graph_generation = 1; today = 20260301; settings = P.default_settings })
;;

let read reason instructions =
  List.find_map
    (function
      | P.Read t when t.reason = reason -> Some t
      | _ -> None)
    instructions
  |> Option.get
;;

let demand instructions =
  List.find_map
    (function
      | P.Demand { consumer; assets; _ } -> Some (consumer, assets)
      | _ -> None)
    instructions
  |> Option.get
;;

let interval () =
  check
    (P.recent_interval P.default_settings ~today:20260301 = Some (20260223, 20260301))
    "calendar interval including today";
  check
    (P.recent_interval (P.settings ~recent_days:2 |> Result.get_ok) ~today:20240301
     = Some (20240229, 20240301))
    "leap day";
  check
    (P.recent_interval (P.settings ~recent_days:2 |> Result.get_ok) ~today:20260101
     = Some (20251231, 20260101))
    "year boundary";
  check
    (P.recent_interval (P.settings ~recent_days:0 |> Result.get_ok) ~today:20260301 = None)
    "disabled recent";
  check (Result.is_error (P.settings ~recent_days:(-1))) "invalid settings"
;;

let pages () =
  let s, ins = refresh P.empty in
  let root = read Favorites ins in
  let s, ins = P.step s (Roots_loaded (root, [ uuid 1 ], Some cursor)) in
  let a = read Favorites ins in
  let s, ins = P.step s (Assets_loaded (a, [ asset 2 ], Some cursor)) in
  let consumer, _ = demand ins in
  check (List.length ins = 1) "wait for demand ack";
  let s, ins = P.step s (Backpressure consumer) in
  check (ins = [] && P.progress s Favorites = Paused) "pause at capacity";
  let s, ins = P.step s Capacity_available in
  check (fst (demand ins) = consumer) "retry same bounded page";
  let s, ins = P.step s (Demand_accepted consumer) in
  let a = read Favorites ins in
  check
    (match a.query with
     | Assets { cursor = Some _; _ } -> true
     | _ -> false)
    "continue asset cursor";
  let s, ins = P.step s (Assets_loaded (a, [], None)) in
  let r = read Favorites ins in
  check
    (match r.query with
     | Favorite_roots (Some _) -> true
     | _ -> false)
    "continue favorites beyond UI page";
  let s, ins = P.step s (Roots_loaded (r, [], None)) in
  check (ins = [] && P.progress s Favorites = Complete) "complete enumeration";
  let s, ins = refresh s in
  let r = read Favorites ins in
  check
    (not
       (List.exists
          (function
            | P.Release c -> c = consumer
            | _ -> false)
          ins))
    "retain committed demand during refresh";
  let _, ins = P.step s (Roots_loaded (r, [], None)) in
  check
    (List.exists
       (function
         | P.Release c -> c = consumer
         | _ -> false)
       ins)
    "release after replacement complete"
;;

let fencing () =
  let s, ins = refresh P.empty in
  let old = read Recent ins in
  let s, _ = refresh s in
  let _, ins = P.step s (Roots_loaded (old, [ uuid 1 ], None)) in
  check (ins = []) "ignore stale revision";
  let s, ins =
    P.step
      s
      (Refresh { graph_generation = 2; today = 20260302; settings = P.default_settings })
  in
  let t = read Favorites ins in
  let s, _ = P.step s (Read_failed t) in
  check (P.progress s Favorites = Failed) "observable read failure";
  let _, ins = P.step s (Assets_loaded (old, [ asset 1 ], None)) in
  check (ins = []) "ignore other generation"
;;

let visible () =
  let s, _ = refresh P.empty in
  let external_asset =
    A.create
      ~uuid:(uuid 9)
      ~source:(External "https://example.com/a.png")
      ~current_checksum:None
      ~size:None
      ~dimensions:None
    |> Result.get_ok
  in
  let s, ins =
    P.step s (Visible { consumer = "preview"; assets = [ asset 1; external_asset ] })
  in
  let consumer, assets = demand ins in
  check (List.length assets = 1) "exclude external downloads";
  check
    (List.exists
       (function
         | P.Demand { priority = Foreground; _ } -> true
         | _ -> false)
       ins)
    "foreground visibility";
  let _, ins = P.step s (Hidden "preview") in
  check (ins = [ P.Release consumer ]) "release hidden media"
;;

let invalid_page () =
  let s, ins = refresh P.empty in
  let t = read Favorites ins in
  let s, ins = P.step s (Roots_loaded (t, List.init (P.page_size + 1) uuid, None)) in
  check (ins = [] && P.progress s Favorites = Failed) "reject oversized pages"
;;

let residency () =
  let version =
    A.version ~checksum:(String.make 64 'a') ~file_type:"png" |> Result.get_ok
  in
  let file =
    A.create
      ~uuid:(uuid 42)
      ~source:(Managed (Some version))
      ~current_checksum:None
      ~size:None
      ~dimensions:None
    |> Result.get_ok
  in
  let s, ins = refresh P.empty in
  let s, ins = P.step s (Roots_loaded (read Favorites ins, [ uuid 1 ], None)) in
  let s, ins = P.step s (Assets_loaded (read Favorites ins, [ file; file ], None)) in
  let consumer, _ = demand ins in
  let s, _ = P.step s (Demand_accepted consumer) in
  let status = P.offline s Favorites in
  check
    (status.enumeration = Complete && status.total = 1 && status.ready = 0)
    "enumerated demand is not offline-ready; duplicate versions count once";
  let notify s consumer availability =
    fst (P.step s (Availability { consumer; asset = file.uuid; availability }))
  in
  let s = notify s "foreign" (Ready "foreign-handle") in
  check ((P.offline s Favorites).ready = 0) "unknown consumer cannot claim residency";
  let s = notify s consumer (Ready "file-handle") in
  check ((P.offline s Favorites).ready = 1) "verified resident file is offline-ready";
  let s =
    notify
      s
      consumer
      (Failed { failure = Storage_full; attempts = 1; retry_scheduled = false })
  in
  let status = P.offline s Favorites in
  check (status.ready = 0 && status.failed = 1) "lost availability revokes completeness";
  let s, ins = refresh s in
  check
    ((P.offline s Favorites).enumeration = Enumerating)
    "replacement cannot claim completeness";
  let s, _ = P.step s (Roots_loaded (read Favorites ins, [], None)) in
  let s = notify s consumer (Ready "late-handle") in
  check ((P.offline s Favorites).total = 0) "retired consumer cannot revive residency";
  let s, _ = P.step s Shutdown in
  check ((P.offline s Favorites).enumeration = Inactive) "shutdown clears status"
;;

let () =
  List.iter
    (fun (name, test) ->
       test ();
       Printf.printf "PASS %s\n%!" name)
    [ "calendar", interval
    ; "paginated replacement", pages
    ; "fencing", fencing
    ; "visible", visible
    ; "bounds", invalid_page
    ; "offline residency", residency
    ]
;;
