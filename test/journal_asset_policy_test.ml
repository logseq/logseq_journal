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
  let s, ins = P.step s Resync in
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
  let s, ins = P.step s Resync in
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
let changed state = P.step state Resync

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
    check (read_count ins = 0) "32 resync requests must coalesce behind each root read"
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
  check (read_count ins = 1) "explicit resync must restart finished Favorites only once";
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

let completed_favorites () =
  let s, ins = refresh P.empty in
  let s, ins = P.step s (Roots_loaded (read Favorites ins, [ uuid 1 ], None)) in
  let s, ins = P.step s (Assets_loaded (read Favorites ins, [ asset 2 ], None)) in
  let consumer, _ = demand ins in
  let s, _ = P.step s (Demand_accepted consumer) in
  s, consumer
;;

let unrelated_roots () =
  let s, _ = completed_favorites () in
  let state = ref s in
  for _ = 1 to 55 do
    let s, ins = P.step !state (Roots_changed [ uuid 99 ]) in
    state := s;
    check
      (ins = [])
      "unrelated roots must preserve completed offline demand without reads"
  done
;;

let related_roots () =
  let s, consumer = completed_favorites () in
  let s, ins = P.step s (Roots_changed [ uuid 1 ]) in
  check (read_count ins = 1) "one related batch only";
  let ticket = read Favorites ins in
  check
    (ticket.query = Assets { roots = [ uuid 1 ]; cursor = None })
    "membership updates must reread the related batch without index enumeration";
  check (not (List.mem (P.Release consumer) ins)) "old demand remains during replacement";
  let _, ins = P.step s (Assets_loaded (ticket, [], None)) in
  check
    (List.mem (P.Release consumer) ins)
    "empty replacement releases removed attachments"
;;

let same_index_roots () =
  let s, _ = completed_favorites () in
  let s, ins = P.step s (Index_changed Favorites) in
  check (read_count ins = 1) "only changed index enumerates";
  let _, ins = P.step s (Roots_loaded (read Favorites ins, [ uuid 1 ], None)) in
  check (ins = []) "unchanged index roots must not repeat recursive attachment reads"
;;

let shared_ready_uuid () =
  let s, consumer = completed_favorites () in
  let s, _ =
    P.step s (Availability { consumer; asset = uuid 2; availability = Ready "resident" })
  in
  let s, ins = P.step s (Roots_changed [ uuid 1 ]) in
  let version =
    A.version ~checksum:(String.make 64 'b') ~file_type:"png" |> Result.get_ok
  in
  let changed =
    A.create
      ~uuid:(uuid 2)
      ~source:(Managed (Some version))
      ~current_checksum:None
      ~size:None
      ~dimensions:None
    |> Result.get_ok
  in
  let s, ins = P.step s (Assets_loaded (read Favorites ins, [ changed ], None)) in
  let fresh, _ = demand ins in
  let s, _ = P.step s (Demand_accepted fresh) in
  check
    ((P.offline s Favorites).ready = 1)
    "same resident UUID must not lose readiness on descriptor replacement"
;;

let exact_batch_and_empty () =
  let s, ins = refresh P.empty in
  let first_roots = List.init 32 (fun n -> uuid (n + 100)) in
  let s, ins = P.step s (Roots_loaded (read Favorites ins, first_roots, Some cursor)) in
  let s, ins = P.step s (Assets_loaded (read Favorites ins, [], None)) in
  let s, ins = P.step s (Roots_loaded (read Favorites ins, [ uuid 200 ], None)) in
  let s, ins = P.step s (Assets_loaded (read Favorites ins, [ asset 300 ], None)) in
  let consumer, _ = demand ins in
  let s, _ = P.step s (Demand_accepted consumer) in
  let s, ins = P.step s (Roots_changed [ uuid 100 ]) in
  check (read_count ins = 1) "negative batch dependency causes exactly one read";
  let ticket = read Favorites ins in
  check
    (ticket.query = Assets { roots = first_roots; cursor = None })
    "preserve exact 32-root bounded owner";
  let s, ins = P.step s (Assets_loaded (ticket, [], None)) in
  check
    (ins = [] && (P.offline s Favorites).total = 1)
    "unrelated committed batch retained after empty replacement"
;;

let index_diff () =
  let s, old = completed_favorites () in
  let s, ins = P.step s (Index_changed Favorites) in
  let s, ins = P.step s (Roots_loaded (read Favorites ins, [ uuid 3 ], None)) in
  let ticket = read Favorites ins in
  check
    (ticket.query = Assets { roots = [ uuid 3 ]; cursor = None })
    "only added index roots read attachments";
  check
    (not (List.mem (P.Release old) ins))
    "removed root demand retained until added roots settle";
  let _, ins = P.step s (Assets_loaded (ticket, [], None)) in
  check (List.mem (P.Release old) ins) "removed index root retires its old demand"
;;

let selected_burst () =
  let s, _ = completed_favorites () in
  let s, ins = P.step s (Roots_changed [ uuid 1 ]) in
  let old = read Favorites ins in
  let state = ref s in
  for _ = 1 to 32 do
    let s, ins = P.step !state (Roots_changed [ uuid 1 ]) in
    state := s;
    check (ins = []) "selected batch burst holds one pending request"
  done;
  let s, ins = P.step !state (Assets_loaded (old, [], None)) in
  check (read_count ins = 1) "selected batch burst has one bounded followup";
  let _, ins = P.step s (Assets_loaded (read Favorites ins, [], None)) in
  check (ins = []) "followup settles without recursive restarts"
;;

module Runtime = Journal_asset_runtime
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Wire = Logseq_db_worker.Protocol

let block n parent page refs =
  G.
    { uuid = uuid n
    ; title = "title"
    ; parent = uuid parent
    ; page = uuid page
    ; order = "a0"
    ; created_at_ms = 0L
    ; updated_at_ms = 0L
    ; refs = List.map uuid refs
    ; tags = []
    ; properties = []
    }
;;

let present (block : G.block) =
  Wire.V2_block_outcome
    (V2_present_block
       { value =
           { block; task_status = None; rendered_page_title = "page"; tag_titles = [] }
       ; revision = "r"
       })
;;

let respond r request_id outcome =
  let response = Wire.V2_response { api_version = 2; request_id; outcome } in
  check (Runtime.receive r response) "runtime must retain the terminal owner"
;;

let raw r n (block : G.block) =
  let request =
    Wire.
      { api_version = 2
      ; request_id = uuid n
      ; command = V2_get_block { block = block.uuid; revision = None }
      }
  in
  Runtime.observe_request r request;
  Runtime.observe_response
    r
    (V2_response
       { api_version = 2; request_id = request.request_id; outcome = present block })
;;

let runtime_scope : Service.asset_scope =
  { account =
      { managed_sync_origin = Uri.of_string "https://sync.example"
      ; user_id = "u"
      ; account_generation = 1
      ; presentation_generation = 1
      ; lifecycle_generation = 1L
      }
  ; graph_id = uuid 3
  ; graph_generation = 1
  }
;;

let runtime_fixture
      ?(favorite_block = false)
      ?(root_parent = 3)
      ?(initial_assets = [])
      ?(initial_demand = fun _ -> ())
      ?(changed = fun _ _ _ -> ())
      ()
  =
  let sent = Queue.create () in
  let r =
    Runtime.create
      ~send:(fun request ->
        Queue.add request sent;
        true)
      ~changed
  in
  Runtime.refresh
    r
    ~graph_generation:1
    ~today:20260301
    ~settings:(P.settings ~recent_days:0 |> Result.get_ok);
  let take () =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> failwith "expected graph read"
  in
  let roots = take () in
  respond
    r
    roots.request_id
    (Wire.V2_favorites_outcome
       { favorites_page = Some (uuid 9)
       ; generation = "g"
       ; projection_revision = "r"
       ; next_cursor = None
       ; items =
           [ { membership_uuid = uuid 10
             ; membership_order = "a0"
             ; membership_revision = "r"
             ; target =
                 (if favorite_block
                  then
                    V2_favorite_block
                      { uuid = uuid 2
                      ; title = "block"
                      ; task_status = None
                      ; revision = "r"
                      }
                  else V2_favorite_page { uuid = uuid 1; title = "page"; revision = "r" })
             }
           ]
       });
  while not (Queue.is_empty sent) do
    match Queue.take sent with
    | Service.Asset_command { command = Replace_asset_demand { consumer; _ }; _ } ->
      initial_demand consumer;
      Runtime.notice r runtime_scope (Asset_demand_accepted consumer)
    | Service.Graph_request request ->
      (match request.command with
       | Wire.V2_list_assets _ ->
         respond
           r
           request.request_id
           (V2_assets_outcome
              { generation = "g"
              ; projection_revision = "r"
              ; items = initial_assets
              ; next_cursor = None
              })
       | V2_get_page { page; _ } ->
         respond
           r
           request.request_id
           (V2_page_outcome
              (V2_present_page
                 { page =
                     G.
                       { uuid = page
                       ; name = "page"
                       ; title = "page"
                       ; kind = Ordinary_page
                       ; created_at_ms = 0L
                       ; updated_at_ms = 0L
                       ; tags = []
                       ; properties = []
                       ; recycled = false
                       }
                 ; revision = "r"
                 }))
       | V2_get_block { block = target; _ } ->
         respond
           r
           request.request_id
           (if G.Uuid.equal target (uuid 2)
            then present (block 2 root_parent 1 [])
            else if G.Uuid.equal target (uuid 3)
            then present (block 3 1 1 [])
            else V2_block_outcome (V2_missing_block { uuid = target; revision = "r" }))
       | _ -> failwith "unexpected initial dependency")
    | _ -> ()
  done;
  r, sent
;;

let window n uuids interests =
  Wire.
    { id = string_of_int n
    ; predecessor = "r"
    ; successor = "next"
    ; block_uuids = List.map uuid uuids
    ; page_uuids = []
    ; structure_interests = interests
    }
;;

let runtime_title_only () =
  let r, sent = runtime_fixture () in
  let original = block 2 1 1 [] in
  raw r 600 original;
  Runtime.changes r [ window 1 [ 2 ] [] ];
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> assert false
  in
  respond r request.request_id (present { original with title = "edited" });
  check (Queue.is_empty sent) "title-only raw delta must not issue an offline asset query"
;;

let runtime_unknown_unrelated () =
  let r, sent = runtime_fixture () in
  for n = 1 to 55 do
    Runtime.changes r [ window n [ 99 ] [] ];
    let rounds = ref 0 in
    while not (Queue.is_empty sent) do
      incr rounds;
      check (!rounds <= 4) "unknown unrelated holder lookup must terminate";
      match Queue.take sent with
      | Service.Graph_request
          ({ command = Wire.V2_get_block { block = target; _ }; _ } as request) ->
        respond
          r
          request.request_id
          (if G.Uuid.equal target (uuid 99)
           then present (block 99 98 98 [])
           else V2_block_outcome (V2_missing_block { uuid = target; revision = "r" }))
      | _ -> failwith "55 unknown unrelated deltas must not issue an asset/index read"
    done
  done
;;

let runtime_refs_delta () =
  let r, sent = runtime_fixture () in
  raw r 600 (block 2 1 1 []);
  Runtime.changes r [ window 1 [ 2 ] [] ];
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> assert false
  in
  respond r request.request_id (present (block 2 1 1 [ 50 ]));
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> assert false
  in
  check
    (match request.command with
     | V2_list_assets { roots; recursive = true; cursor = None; _ } -> roots = [ uuid 1 ]
     | _ -> false)
    "raw ref insertion reads only the matching offline batch";
  respond
    r
    request.request_id
    (V2_assets_outcome
       { generation = "g"; projection_revision = "r"; items = []; next_cursor = None });
  check (Queue.is_empty sent) "raw ref replacement settles"
;;

let runtime_sibling_structure () =
  let r, sent = runtime_fixture () in
  raw r 600 (block 2 1 1 []);
  Runtime.changes r [ window 1 [] [ Wire.V2_children_interest (uuid 98) ] ];
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> assert false
  in
  respond
    r
    request.request_id
    (V2_block_outcome (V2_missing_block { uuid = uuid 98; revision = "r" }));
  check
    (Queue.is_empty sent)
    "unrelated unknown children scope point read never becomes an offline assets/index \
     read"
;;

let runtime_unknown_ancestor () =
  let r, sent = runtime_fixture ~favorite_block:true () in
  raw r 700 (block 2 4 1 []);
  Runtime.changes r [ window 1 [ 4 ] [] ];
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> assert false
  in
  respond
    r
    request.request_id
    (V2_block_outcome (V2_missing_block { uuid = uuid 4; revision = "r" }));
  let fresh =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> failwith "changed ancestor must follow its pre-change query"
  in
  respond
    r
    fresh.request_id
    (V2_block_outcome (V2_missing_block { uuid = uuid 4; revision = "r" }));
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> failwith "unknown ancestor deletion must replace its dependent root batch"
  in
  check
    (match request.command with
     | V2_list_assets { roots; cursor = None; _ } -> roots = [ uuid 2 ]
     | _ -> false)
    "ancestor liveness has a precise favorite-root dependency"
;;

let runtime_late_fact () =
  let r, sent = runtime_fixture () in
  let old = block 2 1 1 [] in
  raw r 600 old;
  let late_request =
    Wire.
      { api_version = 2
      ; request_id = uuid 601
      ; command = V2_get_block { block = uuid 2; revision = None }
      }
  in
  Runtime.observe_request r late_request;
  Runtime.changes r [ window 1 [ 2 ] [] ];
  Runtime.observe_response
    r
    (V2_response
       { api_version = 2; request_id = late_request.request_id; outcome = present old });
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> assert false
  in
  respond r request.request_id (present (block 2 1 1 [ 50 ]));
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> failwith "late pre-change fact must not consume the dirty owner"
  in
  check
    (match request.command with
     | V2_list_assets _ -> true
     | _ -> false)
    "new membership survives a late old raw completion"
;;

let runtime_known_asset_immutable () =
  let r, sent = runtime_fixture () in
  let request =
    Wire.
      { api_version = 2
      ; request_id = uuid 600
      ; command = V2_get_asset_descriptors { assets = [ uuid 50 ] }
      }
  in
  Runtime.observe_request r request;
  Runtime.observe_response
    r
    (V2_response
       { api_version = 2
       ; request_id = request.request_id
       ; outcome =
           V2_assets_outcome
             { generation = "g"
             ; projection_revision = "r"
             ; items = [ asset 50 ]
             ; next_cursor = None
             }
       });
  Runtime.changes r [ window 1 [ 50 ] [] ];
  check
    (Queue.is_empty sent)
    "same known asset UUID metadata does not renew offline demand"
;;

let runtime_real_capture_sibling () =
  let r, sent = runtime_fixture ~favorite_block:true () in
  for n = 1 to 55 do
    Runtime.changes
      r
      [ Wire.
          { id = string_of_int n
          ; predecessor = "r"
          ; successor = "next"
          ; block_uuids = [ uuid 7 ]
          ; page_uuids = [ uuid 1 ]
          ; structure_interests =
              [ V2_children_interest (uuid 1); V2_page_tree_interest (uuid 1) ]
          }
      ];
    let rounds = ref 0 in
    while not (Queue.is_empty sent) do
      incr rounds;
      check (!rounds <= 2) "Capture dependency point reads remain bounded";
      match Queue.take sent with
      | Service.Graph_request ({ command = V2_get_block _; _ } as request) ->
        respond r request.request_id (present (block 7 1 1 []))
      | Service.Graph_request ({ command = V2_get_page { page; _ }; _ } as request) ->
        respond
          r
          request.request_id
          (V2_page_outcome
             (V2_present_page
                { page =
                    G.
                      { uuid = page
                      ; name = "page"
                      ; title = "page"
                      ; kind = Ordinary_page
                      ; created_at_ms = 0L
                      ; updated_at_ms = 0L
                      ; tags = []
                      ; properties = []
                      ; recycled = false
                      }
                ; revision = "r"
                }))
      | _ ->
        failwith
          "55 actual Capture page/tree windows must not reread a sibling favorite \
           block's assets/index"
    done
  done
;;

let runtime_registry_capacity () =
  let status = ref P.Inactive in
  let r, sent =
    runtime_fixture ~changed:(fun _ _ favorites -> status := favorites.P.enumeration) ()
  in
  for n = 1000 to 5199 do
    Runtime.observe_request
      r
      Wire.
        { api_version = 2
        ; request_id = uuid n
        ; command = V2_get_block { block = uuid 99; revision = None }
        }
  done;
  check
    (!status = P.Failed)
    "4096 accepted nonterminal registrations expose capacity failure";
  check (Queue.is_empty sent) "capacity failure cannot trigger an unbounded rescan";
  Runtime.resync r;
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> assert false
  in
  respond
    r
    request.request_id
    (V2_favorites_outcome
       { favorites_page = Some (uuid 9)
       ; generation = "g"
       ; projection_revision = "r"
       ; items = []
       ; next_cursor = None
       });
  check (Queue.is_empty sent) "bounded registry preserves real resync terminal ownership"
;;

let dependency_capacity_status () =
  let s, consumer = completed_favorites () in
  let s, _ =
    P.step s (Availability { consumer; asset = uuid 2; availability = Ready "resident" })
  in
  let s, ins = P.step s Dependencies_unavailable in
  check
    (ins = [] && P.progress s Favorites = Failed && (P.offline s Favorites).ready = 1)
    "dependency capacity failure preserves verified readiness without a fallback read";
  let _, ins = P.step s Shutdown in
  check
    (List.mem (P.Release consumer) ins)
    "capacity failure must preserve and eventually release its existing lease"
;;

let index_pagination () =
  let s, old = completed_favorites () in
  let s, ins = P.step s (Index_changed Favorites) in
  let s, ins = P.step s (Roots_loaded (read Favorites ins, [ uuid 1 ], Some cursor)) in
  let ticket = read Favorites ins in
  check
    (ticket.query = Favorite_roots (Some cursor))
    "root diff waits for the complete changed index";
  let s, ins = P.step s (Roots_loaded (ticket, [ uuid 3 ], None)) in
  let ticket = read Favorites ins in
  check
    (ticket.query = Assets { roots = [ uuid 3 ]; cursor = None })
    "only added paginated index member reads assets";
  let s, ins = P.step s (Assets_loaded (ticket, [], None)) in
  check
    ((not (List.mem (P.Release old) ins)) && (P.offline s Favorites).total = 1)
    "unchanged roots retain committed offline demand"
;;

let pending_preserves_ready () =
  let s, consumer = completed_favorites () in
  let s, _ =
    P.step s (Availability { consumer; asset = uuid 2; availability = Ready "resident" })
  in
  let s, _ = P.step s (Roots_changed [ uuid 1 ]) in
  check
    ((P.offline s Favorites).ready = 1)
    "bounded membership read does not revoke a resident immutable UUID"
;;

let runtime_reference_order () =
  let r, sent = runtime_fixture () in
  raw r 600 (block 2 1 1 [ 50; 51 ]);
  Runtime.changes r [ window 1 [ 2 ] [] ];
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> assert false
  in
  respond r request.request_id (present (block 2 1 1 [ 51; 50 ]));
  check (Queue.is_empty sent) "reference membership order cannot renew offline demand"
;;

let runtime_hidden_holder_fanout () =
  let r, sent = runtime_fixture () in
  (* Initial recursive enumeration is empty; no raw fact for holder H exists.
     A's class declaration changes on a separate assets page. *)
  Runtime.changes r [ window 1 [ 50; 2 ] [] ];
  let queried = ref false in
  while not (Queue.is_empty sent) do
    match Queue.take sent with
    | Service.Graph_request
        ({ command = V2_get_block { block = target; _ }; _ } as request) ->
      respond
        r
        request.request_id
        (if G.Uuid.equal target (uuid 50)
         then present (block 50 99 99 [])
         else if G.Uuid.equal target (uuid 2)
         then present (block 2 1 1 [ 50 ])
         else V2_block_outcome (V2_missing_block { uuid = target; revision = "r" }))
    | Service.Graph_request ({ command = V2_list_assets { roots; _ }; _ } as request) ->
      queried := roots = [ uuid 1 ];
      respond
        r
        request.request_id
        (V2_assets_outcome
           { generation = "g"
           ; projection_revision = "r"
           ; items = [ asset 50 ]
           ; next_cursor = None
           })
    | Service.Asset_command { command = Replace_asset_demand { consumer; _ }; _ } ->
      Runtime.notice
        r
        { account =
            { managed_sync_origin = Uri.of_string "https://sync.example"
            ; user_id = "u"
            ; account_generation = 1
            ; presentation_generation = 1
            ; lifecycle_generation = 1L
            }
        ; graph_id = uuid 3
        ; graph_generation = 1
        }
        (Asset_demand_accepted consumer)
    | _ -> ()
  done;
  check
    !queried
    "new asset declaration needs bounded inverse H fanout; no H raw fact was seeded"
;;

let runtime_truncated_membership () =
  let r, sent = runtime_fixture () in
  let holder =
    { (block 2 1 1 []) with
      properties =
        [ G.
            { ident = "assets"
            ; uuid = uuid 4
            ; title = "Assets"
            ; schema =
                { property_type = Asset
                ; cardinality = Many
                ; hidden = false
                ; public = true
                }
            ; values = [ Asset_value (uuid 50) ]
            ; values_truncated = true
            }
        ]
    }
  in
  raw r 600 holder;
  Runtime.changes r [ window 1 [ 2 ] [] ];
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> assert false
  in
  respond r request.request_id (present holder);
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> failwith "truncated membership cannot prove unchanged hidden references"
  in
  check
    (match request.command with
     | V2_list_assets { roots; cursor = None; _ } -> roots = [ uuid 1 ]
     | _ -> false)
    "truncated owned holder refresh selects only its offline batch"
;;

let ready_index_retirement () =
  let s, consumer = completed_favorites () in
  let s, _ =
    P.step s (Availability { consumer; asset = uuid 2; availability = Ready "resident" })
  in
  let s, ins = P.step s (Roots_changed [ uuid 1 ]) in
  let s, _ = P.step s (Assets_loaded (read Favorites ins, [], None)) in
  let s, _ =
    P.step s (Availability { consumer; asset = uuid 2; availability = Ready "late" })
  in
  let s, ins = P.step s (Roots_changed [ uuid 1 ]) in
  let s, ins = P.step s (Assets_loaded (read Favorites ins, [ asset 2 ], None)) in
  let fresh, _ = demand ins in
  let s, _ = P.step s (Demand_accepted fresh) in
  check
    ((P.offline s Favorites).ready = 0)
    "last consumer release retires successful UUID inheritance; late notice cannot \
     revive it"
;;

let runtime_unknown_old_parent () =
  let old = ref None
  and released = ref false in
  let r, sent =
    runtime_fixture
      ~favorite_block:true
      ~root_parent:1
      ~initial_assets:[ asset 50 ]
      ~initial_demand:(fun consumer -> old := Some consumer)
      ()
  in
  Runtime.changes
    r
    [ window
        1
        [ 4 ]
        [ V2_children_interest (uuid 3)
        ; V2_children_interest (uuid 7)
        ; V2_page_tree_interest (uuid 1)
        ]
    ];
  let queried = ref false in
  while not (Queue.is_empty sent) do
    match Queue.take sent with
    | Service.Graph_request
        ({ command = V2_get_block { block = target; _ }; _ } as request) ->
      respond
        r
        request.request_id
        (if G.Uuid.equal target (uuid 4)
         then present (block 4 7 1 [])
         else if G.Uuid.equal target (uuid 3)
         then present (block 3 2 1 [])
         else V2_block_outcome (V2_missing_block { uuid = target; revision = "r" }))
    | Service.Graph_request ({ command = V2_list_assets { roots; _ }; _ } as request) ->
      queried := roots = [ uuid 2 ];
      respond
        r
        request.request_id
        (V2_assets_outcome
           { generation = "g"; projection_revision = "r"; items = []; next_cursor = None })
    | Service.Asset_command { command = Release_asset_demand consumer; _ } ->
      released := Some consumer = !old
    | _ -> ()
  done;
  check
    (!queried && !released)
    "old unknown structural parent resolves the old batch owner after a hidden child \
     moves out"
;;

let runtime_dependency_failure rejected () =
  let status = ref P.Inactive in
  let r, sent =
    runtime_fixture ~changed:(fun _ _ favorites -> status := favorites.P.enumeration) ()
  in
  Runtime.changes r [ window 1 [ 99 ] [] ];
  let request =
    match Queue.take sent with
    | Service.Graph_request request -> request
    | _ -> assert false
  in
  if rejected
  then Runtime.reject r ~request_id:request.request_id
  else
    respond r request.request_id (V2_failed { code = "storage"; message = "unavailable" });
  check
    (!status = P.Failed && Queue.is_empty sent)
    "owned dependency failure must expose Failed without retrying or preserving false \
     completeness"
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
    [ "runtime unknown old parent", runtime_unknown_old_parent
    ; "runtime dependency reject", runtime_dependency_failure true
    ; "runtime dependency failed", runtime_dependency_failure false
    ; "runtime hidden negative holder", runtime_hidden_holder_fanout
    ; "runtime truncated membership", runtime_truncated_membership
    ; "ready index retirement", ready_index_retirement
    ; "runtime equivalent reference set", runtime_reference_order
    ; "immutable pending residency", pending_preserves_ready
    ; "runtime actual Capture sibling", runtime_real_capture_sibling
    ; "runtime accepted registry capacity", runtime_registry_capacity
    ; "dependency capacity preserves lease", dependency_capacity_status
    ; "immutable paginated index diff", index_pagination
    ; "runtime unknown ancestor", runtime_unknown_ancestor
    ; "runtime late raw fact", runtime_late_fact
    ; "runtime immutable asset UUID", runtime_known_asset_immutable
    ; "runtime title-only raw facts", runtime_title_only
    ; "runtime unknown unrelated 55", runtime_unknown_unrelated
    ; "runtime raw ref insertion", runtime_refs_delta
    ; "runtime unrelated structure", runtime_sibling_structure
    ; "immutable resident UUID", shared_ready_uuid
    ; "immutable exact negative batch", exact_batch_and_empty
    ; "immutable index root diff", index_diff
    ; "immutable selected burst 32", selected_burst
    ; "immutable unrelated 55", unrelated_roots
    ; "immutable related batch", related_roots
    ; "immutable unchanged index", same_index_roots
    ; "calendar", interval
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
