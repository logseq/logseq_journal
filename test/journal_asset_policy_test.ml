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
  let s, ins = P.step s Graph_changed in
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
  let s, _ =
    P.step
      s
      (Refresh { graph_generation = 1; today = 20260302; settings = P.default_settings })
  in
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
  let s, ins = P.step s Graph_changed in
  check
    ((P.offline s Favorites).enumeration = Enumerating)
    "replacement cannot claim completeness";
  let s, _ = P.step s (Roots_loaded (read Favorites ins, [], None)) in
  let s = notify s consumer (Ready "late-handle") in
  check ((P.offline s Favorites).total = 0) "retired consumer cannot revive residency";
  let s, _ = P.step s Shutdown in
  check ((P.offline s Favorites).enumeration = Inactive) "shutdown clears status"
;;

(* Existing Refresh reproduces graph-push replacement in the baseline. GREEN
   separates this invalidation from unchanged lifecycle configuration. *)
let changed state = P.step state Graph_changed

let read_count ins =
  List.length
    (List.filter
       (function
         | P.Read _ -> true
         | _ -> false)
       ins)
;;

let first_root (ticket : P.ticket) =
  match ticket.query with
  | Recent_roots { cursor = None; _ } | Favorite_roots None -> true
  | _ -> false
;;

let same_configuration () =
  let s, ins = refresh P.empty in
  let original = read Favorites ins in
  let s, ins = refresh s in
  check (ins = []) "same configuration must retain the in-flight owner without new IO";
  let _, ins = P.step s (Roots_loaded (original, [ uuid 1 ], None)) in
  check (read_count ins = 1) "same configuration must accept its original completion"
;;

let burst_roots () =
  let s, ins = refresh P.empty in
  let old = read Favorites ins in
  let state = ref s in
  for _ = 1 to 32 do
    let s, ins = changed !state in
    state := s;
    check (read_count ins = 0) "32 graph changes must coalesce behind each root read"
  done;
  let s, ins = P.step !state (Roots_loaded (old, [ uuid 9 ], Some cursor)) in
  let fresh = read Favorites ins in
  check (first_root fresh) "superseded roots must restart at root cursor None";
  let _, ins = P.step s (Roots_loaded (old, [ uuid 9 ], None)) in
  check (ins = []) "duplicate superseded root completion must be fenced"
;;

let burst_assets terminal () =
  let s, ins = refresh P.empty in
  let s, ins = P.step s (Roots_loaded (read Favorites ins, [ uuid 1 ], Some cursor)) in
  let old = read Favorites ins in
  let s, ins = changed s in
  check (read_count ins = 0) "asset enumeration must keep its current request";
  let _, ins =
    P.step
      s
      (if terminal then Assets_loaded (old, [ asset 2 ], Some cursor) else Read_failed old)
  in
  check
    (read_count ins = 1 && first_root (read Favorites ins))
    "superseded asset success/error must discard old cursor and restart once";
  check
    (not
       (List.exists
          (function
            | P.Demand _ -> true
            | _ -> false)
          ins))
    "superseded descriptors cannot become staged demand"
;;

let dirty_demand pressured () =
  let s, ins = refresh P.empty in
  let s, ins = P.step s (Roots_loaded (read Favorites ins, [ uuid 1 ], None)) in
  let s, ins = P.step s (Assets_loaded (read Favorites ins, [ asset 2 ], Some cursor)) in
  let consumer, _ = demand ins in
  let s, _ = if pressured then P.step s (Backpressure consumer) else s, [] in
  let s, ins = changed s in
  check
    (List.exists
       (function
         | P.Release c -> c = consumer
         | _ -> false)
       ins)
    "invalidation releases superseded staged ownership";
  let _, follow = if pressured then s, ins else P.step s (Demand_accepted consumer) in
  check
    (read_count follow = 1 && first_root (read Favorites follow))
    "old demand ack/backpressure cannot continue a global stale assets cursor"
;;

let committed_and_finished () =
  let s, ins = refresh P.empty in
  let s, ins = P.step s (Roots_loaded (read Favorites ins, [ uuid 1 ], None)) in
  let s, ins = P.step s (Assets_loaded (read Favorites ins, [ asset 2 ], None)) in
  let consumer, _ = demand ins in
  let s, _ = P.step s (Demand_accepted consumer) in
  let s, ins = refresh s in
  check
    (read_count ins = 0 && P.progress s Favorites = Complete)
    "same configuration must not rescan a finished enumeration";
  let s, ins = changed s in
  check
    (read_count ins = 1)
    "actual graph change must restart finished Favorites only once";
  check
    (not
       (List.exists
          (function
            | P.Release c -> c = consumer
            | _ -> false)
          ins))
    "replacement preserves committed demand until complete";
  let _, ins = P.step s (Roots_loaded (read Favorites ins, [], None)) in
  check
    (List.exists
       (function
         | P.Release c -> c = consumer
         | _ -> false)
       ins)
    "successful fresh enumeration retires committed demand"
;;

let config_and_disabled () =
  let disabled = P.settings ~recent_days:0 |> Result.get_ok in
  let s, ins =
    P.step
      P.empty
      (Refresh { graph_generation = 1; today = 20260301; settings = disabled })
  in
  check
    (read_count ins = 1 && P.progress s Recent = Complete)
    "disabled Recent does not read";
  let old = read Favorites ins in
  let s, ins =
    P.step s (Refresh { graph_generation = 2; today = 20260302; settings = disabled })
  in
  check (read_count ins = 1) "hard graph change starts bounded configured scans";
  let _, ins = P.step s (Roots_loaded (old, [ uuid 1 ], None)) in
  check (ins = []) "old graph owner cannot escape scope replacement"
;;

(* Runtime, unlike Policy, owns accepted Worker request IDs and queued IO. *)
let runtime_same_configuration () =
  let module R = Journal_asset_runtime in
  let module S = Logseq_db_worker_lui.Logseq_db_worker_lui_service in
  let module Wire = Logseq_db_worker.Protocol in
  let sent = Queue.create () in
  let r =
    R.create
      ~send:(fun q ->
        Queue.add q sent;
        true)
      ~changed:(fun _ _ _ -> ())
  in
  R.refresh r ~graph_generation:1 ~today:20260301 ~settings:P.default_settings;
  let first = Queue.take sent in
  Queue.clear sent;
  R.refresh r ~graph_generation:1 ~today:20260301 ~settings:P.default_settings;
  check (Queue.is_empty sent) "adapter must retain tickets on unchanged lifecycle refresh";
  let request_id =
    match first with
    | S.Graph_request q -> q.request_id
    | _ -> assert false
  in
  let accepted =
    R.receive
      r
      (Wire.V2_response
         { api_version = 2
         ; request_id
         ; outcome = V2_journals_outcome { items = []; next_cursor = None }
         })
  in
  check accepted "adapter must not swallow still-owned response on same configuration"
;;

let () =
  let failed = ref 0 in
  List.iter
    (fun (name, test) ->
       try
         test ();
         Printf.printf "PASS %s\n%!" name
       with
       | exn ->
         incr failed;
         Printf.printf "FAIL %s: %s\n%!" name (Printexc.to_string exn))
    [ "calendar", interval
    ; "paginated replacement", pages
    ; "fencing", fencing
    ; "visible", visible
    ; "bounds", invalid_page
    ; "offline residency", residency
    ; "F2 same configuration pending", same_configuration
    ; "F2 32 root invalidations", burst_roots
    ; "F2 superseded assets", burst_assets true
    ; "F2 superseded read failure", burst_assets false
    ; "F2 awaiting dirty demand", dirty_demand false
    ; "F2 pressured dirty demand", dirty_demand true
    ; "F2 finished and committed ownership", committed_and_finished
    ; "F2 config scope and disabled recent", config_and_disabled
    ; "F2 adapter same-config request ownership", runtime_same_configuration
    ];
  check (!failed = 0) (Printf.sprintf "%d asset policy cases failed" !failed)
;;
