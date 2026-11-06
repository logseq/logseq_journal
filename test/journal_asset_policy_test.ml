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

let first_root (ticket : _ P.ticket) =
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

module Runtime = Journal_asset_runtime
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Read = Worker_pure_read
module W = Journal_worker_coordination.Worker_api

type outgoing = Read of Runtime.read_request | Command : 'a W.request -> outgoing

let request_id (Runtime.Read request) = request.request_id
module Resources=Coordination_test_fixture.Resources
let resources=Resources.create ~graph:(uuid 3) ~graph_generation:1 8200L
let producer=lazy(resources.Resources.issuer,resources.session)
let demand_port sent ~graph_generation ~name priority assets =
  Option.map(fun ticket->
    let consumer=W.asset_consumer resources.session ~name |> Result.get_ok in
    Queue.add(Command(W.Replace_asset_demand(consumer,priority,assets)))sent;ticket)
    (Resources.demand_ticket resources ~graph_generation ~name priority assets)
let release_port sent (ticket,demand)=
  (match demand with
   |Some demand->Queue.add(Command(W.Release_asset_demand demand))sent
   |None->Resources.cancel_demand resources ticket);true
let consumer_name consumer=Hashtbl.to_seq resources.Resources.demands |>Seq.find_map(fun(name,(actual,_,_))->
  if W.equal_asset_consumer consumer actual then Some name else None) |>Option.get

let respond r (Runtime.Read request) produce =
  check (Runtime.owns_read r request.request_id) "runtime must retain the terminal owner";
  let issuer, session = Lazy.force producer in
  let module I = (val issuer : Worker_effect_authority.ISSUER) in
  let budget = W.read_budget session ~maximum_items:request.maximum_items
    ~maximum_bytes:65536 |> Result.get_ok in
  let operation = W.Query (budget, request.query) in
  let id = W.request_id request.request_id in
  let response=match I.request session ~request_id:id operation|>Result.get_ok with
    |Service.Coordination_query source->Service.Coordination_queried{registration=source.registration;owner=source.owner;
      request_id=source.request_id;answer=produce source.read}
    |_->failwith "Asset fixture did not issue the original query"in
  match I.reply session ~request_id:id operation response with
  | Ok (W.Answered (Ok value)) ->
    check (Runtime.receive_read r ~request_id:request.request_id (request.outcome value))
      "runtime must retain the typed terminal owner"
  | Ok (W.Answered (Error _)) -> Runtime.reject r ~request_id:request.request_id
  | _ -> failwith "invalid typed fixture completion"
;;

(* Runtime, unlike Policy, owns accepted Worker request IDs and queued IO. *)
let runtime_same_configuration () =
  let module R = Journal_asset_runtime in
  let module Read = Worker_pure_read in
  let sent = Queue.create () in
  let r =
    R.create
      ~read:(fun request -> Queue.add (Read request) sent; true)
      ~demand:(demand_port sent)
      ~release_consumer:(release_port sent)
      ~changed:(fun _ _ _ -> ()) ()
  in
  R.refresh r ~graph_generation:1 ~today:20260301 ~settings:P.default_settings;
  let first = Queue.take sent in
  Queue.clear sent;
  R.refresh r ~graph_generation:1 ~today:20260301 ~settings:P.default_settings;
  check (Queue.is_empty sent) "adapter must retain tickets on unchanged lifecycle refresh";
  let request = match first with Read request -> request | _ -> assert false in
  respond r request ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.slice ~items:(([] : Worker_pure_data.journal_item list)) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Journals _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))

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

let block_value (block : G.block) : Worker_pure_data.block_lookup =
  Worker_pure_data.V2_present_block
    {value={block;task_status=None;rendered_page_title="page";tag_titles=[]};revision="r"}
;;

let present block = (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((block_value block)) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch")

let raw r n (block : G.block) =
  let query = W.Outline_block { uuid = block.uuid; revision = None } in
  Runtime.observe_query r ~request_id:(uuid n) query;
  Runtime.observe_query_result r ~request_id:(uuid n) query (block_value block)
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
      ~read:(fun request -> Queue.add (Read request) sent; true)
      ~demand:(demand_port sent)
      ~release_consumer:(release_port sent)
      ~changed ()
  in
  Runtime.refresh
    r
    ~graph_generation:1
    ~today:20260301
    ~settings:(P.settings ~recent_days:0 |> Result.get_ok);
  let take () =
    match Queue.take sent with
    | Read request -> request
    | _ -> failwith "expected graph read"
  in
  let roots = take () in
  respond
    r
    roots
    ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.favorites ~favorites_page:(Some (uuid 9)) ~generation:("g") ~projection_revision:("r") ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None)) ~items:([ { membership_uuid = uuid 10
             ; membership_order = "a0"
             ; membership_revision = "r"
             ; target =
                 (if favorite_block
                  then
                    Worker_pure_data.V2_favorite_block
                      { uuid = uuid 2
                      ; title = "block"
                      ; task_status = None
                      ; revision = "r"
                      }
                  else Worker_pure_data.V2_favorite_page { uuid = uuid 1; title = "page"; revision = "r" })
             }
           ])) in match query with |Read.Favorites _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"));
  while not (Queue.is_empty sent) do
    match Queue.take sent with
    | Command(W.Replace_asset_demand(bound,_,_)) ->
      let consumer=consumer_name bound in
      initial_demand consumer;
      Runtime.notice r (Resources.notice resources(Service.Asset_demand_accepted consumer))
    | Read request ->
      (match request with
       | Runtime.Read { query = W.Assets _; _ } ->
         respond
           r
           request
           ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.asset_listing ~generation:("g") ~projection_revision:("r") ~items:(initial_assets) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Assets _->F.answer budget query value |Read.Asset_descriptors ids->let listing=Result.get_ok value in F.answer budget query (Ok(F.asset_lookup_result ~generation:listing.generation ~projection_revision:listing.projection_revision ~items:(List.map(fun uuid->List.find_opt(fun descriptor->Read.Uuid.equal uuid descriptor.Logseq_db_types.Asset_descriptor.uuid) listing.items)ids))) |_->failwith "Synthetic sample query family mismatch"))
       | Runtime.Read { query = W.Page { uuid = page; _ }; _ } ->
         respond
           r
           request
           ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page
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
                 })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
       | Runtime.Read { query = W.Outline_block { uuid = target; _ }; _ } ->
         respond
           r
           request
           (if G.Uuid.equal target (uuid 2)
            then present (block 2 root_parent 1 [])
            else if G.Uuid.equal target (uuid 3)
            then present (block 3 1 1 [])
            else (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = target; revision = "r" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
       | _ -> failwith "unexpected initial dependency")
    | _ -> ()
  done;
  r, sent
;;

let window n uuids interests =
  Worker_pure_data.{ id = string_of_int n
    ; predecessor = "r"
    ; successor = "next"
    ; block_uuids = List.map uuid uuids
    ; page_uuids = []
    ; structure_interests = interests
    }
;;

let runtime_unconfigured_changes after_shutdown () =
  let sent = Queue.create () in
  let r =
    Runtime.create
      ~read:(fun request -> Queue.add (Read request) sent; true)
      ~demand:(demand_port sent)
      ~release_consumer:(release_port sent)
      ~changed:(fun _ _ _ -> ()) ()
  in
  if after_shutdown
  then (
    Runtime.refresh
      r
      ~graph_generation:1
      ~today:20260301
      ~settings:(P.settings ~recent_days:0 |> Result.get_ok);
    Runtime.shutdown r;
    Queue.clear sent);
  (* Graph owns this inline-reference source and its target reads. No offline
     configuration has admitted any recursive root or attachment consumer. *)
  raw r 600 (block 200 1 1 []);
  for n = 1 to 4 do
    let id = uuid (600+n) in
    Runtime.observe_query r ~request_id:id (W.Outline_block{uuid=uuid n;revision=None});
    Runtime.forget_request r ~request_id:id
  done;
  Runtime.changes r [ window 1 [ 1; 2; 3; 4 ] [] ];
  Runtime.pump r;
  check
    (Queue.is_empty sent)
    "unconfigured offline owner must not duplicate Graph reference target reads";
  Runtime.changes
    r
    [ { (window 2 [] [ Worker_pure_data.V2_children_interest (uuid 99) ]) with
        page_uuids = [ uuid 98 ]
      }
    ];
  Runtime.pump r;
  check
    (Queue.is_empty sent)
    "unconfigured offline owner must not discover structure or page dependencies"
;;

let runtime_title_only () =
  let r, sent = runtime_fixture () in
  let original = block 2 1 1 [] in
  raw r 600 original;
  Runtime.changes r [ window 1 [ 2 ] [] ];
  let request =
    match Queue.take sent with
    | Read request -> request
    | _ -> assert false
  in
  respond r request (present { original with title = "edited" });
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
      | Read (Runtime.Read { query = W.Outline_block { uuid = target; _ }; _ } as request) ->
        respond
          r
          request
          (if G.Uuid.equal target (uuid 99)
           then present (block 99 98 98 [])
           else (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = target; revision = "r" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
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
    | Read request -> request
    | _ -> assert false
  in
  respond r request (present (block 2 1 1 [ 50 ]));
  let request =
    match Queue.take sent with
    | Read request -> request
    | _ -> assert false
  in
  check
    (match request with
     | Runtime.Read { query = W.Assets { roots; recursive = true; after = None }; _ } -> roots = [ uuid 1 ]
     | _ -> false)
    "raw ref insertion reads only the matching offline batch";
  respond
    r
    request
    ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.asset_listing ~generation:("g") ~projection_revision:("r") ~items:([]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Assets _->F.answer budget query value |Read.Asset_descriptors ids->let listing=Result.get_ok value in F.answer budget query (Ok(F.asset_lookup_result ~generation:listing.generation ~projection_revision:listing.projection_revision ~items:(List.map(fun uuid->List.find_opt(fun descriptor->Read.Uuid.equal uuid descriptor.Logseq_db_types.Asset_descriptor.uuid) listing.items)ids))) |_->failwith "Synthetic sample query family mismatch"));
  check (Queue.is_empty sent) "raw ref replacement settles"
;;

let runtime_sibling_structure () =
  let r, sent = runtime_fixture () in
  raw r 600 (block 2 1 1 []);
  Runtime.changes r [ window 1 [] [ Worker_pure_data.V2_children_interest (uuid 98) ] ];
  let request =
    match Queue.take sent with
    | Read request -> request
    | _ -> assert false
  in
  respond
    r
    request
    ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = uuid 98; revision = "r" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"));
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
    | Read request -> request
    | _ -> assert false
  in
  respond
    r
    request
    ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = uuid 4; revision = "r" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"));
  let fresh =
    match Queue.take sent with
    | Read request -> request
    | _ -> failwith "changed ancestor must follow its pre-change query"
  in
  respond
    r
    fresh
    ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = uuid 4; revision = "r" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"));
  let request =
    match Queue.take sent with
    | Read request -> request
    | _ -> failwith "unknown ancestor deletion must replace its dependent root batch"
  in
  check
    (match request with
     | Runtime.Read { query = W.Assets { roots; after = None; _ }; _ } -> roots = [ uuid 2 ]
     | _ -> false)
    "ancestor liveness has a precise favorite-root dependency"
;;

let runtime_late_fact () =
  let r, sent = runtime_fixture () in
  let old = block 2 1 1 [] in
  raw r 600 old;
  let query = W.Outline_block { uuid=uuid 2;revision=None } in
  Runtime.observe_query r ~request_id:(uuid 601) query;
  Runtime.changes r [ window 1 [ 2 ] [] ];
  Runtime.observe_query_result r ~request_id:(uuid 601) query (block_value old);
  let request =
    match Queue.take sent with
    | Read request -> request
    | _ -> assert false
  in
  respond r request (present (block 2 1 1 [ 50 ]));
  let request =
    match Queue.take sent with
    | Read request -> request
    | _ -> failwith "late pre-change fact must not consume the dirty owner"
  in
  check
    (match request with
     | Runtime.Read { query = W.Assets _; _ } -> true
     | _ -> false)
    "new membership survives a late old raw completion"
;;

let runtime_known_asset_immutable () =
  let r, sent = runtime_fixture () in
  let query = W.Asset_descriptors [ uuid 50 ] in
  let id = uuid 600 in
  Runtime.observe_query r ~request_id:id query;
  let issuer,session=Lazy.force producer in
  let module I=(val issuer : Worker_effect_authority.ISSUER) in
  let budget=W.read_budget session ~maximum_items:32 ~maximum_bytes:65536 |> Result.get_ok in
  let operation=W.Query(budget,query) in
  let response=match I.request session ~request_id:(W.request_id id)operation|>Result.get_ok with
    |Service.Coordination_query source->Service.Coordination_queried{registration=source.registration;owner=source.owner;
      request_id=source.request_id;answer=Read.For_worker.answer budget query(Ok(Read.For_worker.asset_lookup_result
        ~generation:"g" ~projection_revision:"r" ~items:[Some(asset 50)]))}
    |_->failwith "descriptor fixture changed its query"in
  let value=match I.reply session ~request_id:(W.request_id id) operation response with
    | Ok(W.Answered(Ok value))->value|_->failwith "invalid descriptor fixture" in
  Runtime.observe_query_result r ~request_id:id query value;
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
      [ Worker_pure_data.{ id = string_of_int n
          ; predecessor = "r"
          ; successor = "next"
          ; block_uuids = [ uuid 7 ]
          ; page_uuids = [ uuid 1 ]
          ; structure_interests =
              [ Worker_pure_data.V2_children_interest (uuid 1); Worker_pure_data.V2_page_tree_interest (uuid 1) ]
          }
      ];
    let rounds = ref 0 in
    while not (Queue.is_empty sent) do
      incr rounds;
      check (!rounds <= 2) "Capture dependency point reads remain bounded";
      match Queue.take sent with
      | Read (Runtime.Read { query = W.Outline_block _; _ } as request) ->
        respond r request (present (block 7 1 1 []))
      | Read (Runtime.Read { query = W.Page { uuid = page; _ }; _ } as request) ->
        respond
          r
          request
          ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_present_page
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
                })) in match query with |Read.Page _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
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
    Runtime.observe_query r ~request_id:(uuid n)
      (W.Outline_block{uuid=uuid 99;revision=None})
  done;
  check
    (!status = P.Failed)
    "4096 accepted nonterminal registrations expose capacity failure";
  check(Runtime.projection_read_error r<>None)
    "shared DTO ownership capacity failure has no read application error";
  check (Queue.is_empty sent) "capacity failure cannot trigger an unbounded rescan";
  Runtime.resync r;
  let request =
    match Queue.take sent with
    | Read request -> request
    | _ -> assert false
  in
  respond
    r
    request
    ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.favorites ~favorites_page:(Some (uuid 9)) ~generation:("g") ~projection_revision:("r") ~items:([]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Favorites _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"));
  check (Queue.is_empty sent) "bounded registry preserves real resync terminal ownership"
;;

let runtime_unconfigured_shared_capacity () =
  let runtime=Runtime.create ~read:(fun _->true) ~demand:(fun ~graph_generation:_ ~name:_ _ _->failwith "unconfigured fixture emitted a demand") ~release_consumer:(fun _->failwith "unconfigured fixture released a consumer") ~changed:(fun _ _ _->()) () in
  for n=1 to 4200 do raw runtime (10000+n) (block n 9999 9999 []) done;
  check(Runtime.projection_read_error runtime=None)
    "unconfigured shared DTO cache overflow invented an offline ACK consumer"
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
    | Read request -> request
    | _ -> assert false
  in
  respond r request (present (block 2 1 1 [ 51; 50 ]));
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
    | Read (Runtime.Read { query = W.Outline_block { uuid = target; _ }; _ } as request) ->
      respond
        r
        request
        (if G.Uuid.equal target (uuid 50)
         then present (block 50 99 99 [])
         else if G.Uuid.equal target (uuid 2)
         then present (block 2 1 1 [ 50 ])
         else (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = target; revision = "r" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
    | Read (Runtime.Read { query = W.Assets { roots; _ }; _ } as request) ->
      queried := roots = [ uuid 1 ];
      respond
        r
        request
        ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.asset_listing ~generation:("g") ~projection_revision:("r") ~items:([ asset 50 ]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Assets _->F.answer budget query value |Read.Asset_descriptors ids->let listing=Result.get_ok value in F.answer budget query (Ok(F.asset_lookup_result ~generation:listing.generation ~projection_revision:listing.projection_revision ~items:(List.map(fun uuid->List.find_opt(fun descriptor->Read.Uuid.equal uuid descriptor.Logseq_db_types.Asset_descriptor.uuid) listing.items)ids))) |_->failwith "Synthetic sample query family mismatch"))
    | Command(W.Replace_asset_demand(bound,_,_)) ->
      Runtime.notice r (Resources.notice resources(Service.Asset_demand_accepted(consumer_name bound)))
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
    | Read request -> request
    | _ -> assert false
  in
  respond r request (present holder);
  let request =
    match Queue.take sent with
    | Read request -> request
    | _ -> failwith "truncated membership cannot prove unchanged hidden references"
  in
  check
    (match request with
     | Runtime.Read { query = W.Assets { roots; after = None; _ }; _ } -> roots = [ uuid 1 ]
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
        [ Worker_pure_data.V2_children_interest (uuid 3)
        ; Worker_pure_data.V2_children_interest (uuid 7)
        ; Worker_pure_data.V2_page_tree_interest (uuid 1)
        ]
    ];
  let queried = ref false in
  while not (Queue.is_empty sent) do
    match Queue.take sent with
    | Read (Runtime.Read { query = W.Outline_block { uuid = target; _ }; _ } as request) ->
      respond
        r
        request
        (if G.Uuid.equal target (uuid 4)
         then present (block 4 7 1 [])
         else if G.Uuid.equal target (uuid 3)
         then present (block 3 2 1 [])
         else (fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok((Worker_pure_data.V2_missing_block { uuid = target; revision = "r" })) in match query with |Read.Outline_block _->F.answer budget query value |_->failwith "Synthetic sample query family mismatch"))
    | Read (Runtime.Read { query = W.Assets { roots; _ }; _ } as request) ->
      queried := roots = [ uuid 2 ];
      respond
        r
        request
        ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in let value=Ok(F.asset_listing ~generation:("g") ~projection_revision:("r") ~items:([]) ~next:(Option.map(fun cursor->F.continuation ~owner:(F.read_budget_owner budget) ~budget ~key:(Read.query_key budget query) ~cursor)(None))) in match query with |Read.Assets _->F.answer budget query value |Read.Asset_descriptors ids->let listing=Result.get_ok value in F.answer budget query (Ok(F.asset_lookup_result ~generation:listing.generation ~projection_revision:listing.projection_revision ~items:(List.map(fun uuid->List.find_opt(fun descriptor->Read.Uuid.equal uuid descriptor.Logseq_db_types.Asset_descriptor.uuid) listing.items)ids))) |_->failwith "Synthetic sample query family mismatch"))
    | Command(W.Release_asset_demand bound) ->
      released := Some(consumer_name(W.asset_demand_consumer bound)) = !old
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
    | Read request -> request
    | _ -> assert false
  in
  if rejected
  then Runtime.reject r ~request_id:(request_id request)
  else
    respond r request ((fun (Read.Read_query(budget,query))->let module F=Read.For_worker in F.answer budget query (Error(Read.Service_failed (("storage")^": "^("unavailable"))))));
  check
    (!status = P.Failed && Queue.is_empty sent)
    "owned dependency failure must expose Failed without retrying or preserving false \
     completeness"
;;

let repeated_cursor_fails () =
  let cursor n = n, "opaque" in
  let state, instructions = refresh P.empty in
  let first = read Favorites instructions in
  let state, instructions = P.step state (Roots_loaded (first, [], Some (cursor 1))) in
  check
    (P.progress state Favorites = Enumerating)
    "new empty More was treated as complete";
  let second = read Favorites instructions in
  let failed, instructions = P.step state (Roots_loaded (second, [], Some (cursor 1))) in
  check
    (P.progress failed Favorites = Failed && instructions = [])
    "repeated catalog More must fail without another Read";
  let state, instructions = P.step state (Roots_loaded (second, [], Some (cursor 2))) in
  let third = read Favorites instructions in
  let failed, instructions = P.step state (Roots_loaded (third, [], Some (cursor 1))) in
  check
    (P.progress failed Favorites = Failed && instructions = [])
    "cyclic catalog More must fail";
  let state, instructions = refresh P.empty in
  let state, instructions =
    P.step state (Roots_loaded (read Favorites instructions, [ uuid 1 ], None))
  in
  let state, instructions =
    P.step
      state
      (Assets_loaded (read Favorites instructions, [ asset 2 ], Some (cursor 1)))
  in
  let consumer, _ = demand instructions in
  let state, instructions = P.step state (Demand_accepted consumer) in
  let failed, instructions =
    P.step
      state
      (Assets_loaded (read Favorites instructions, [ asset 2 ], Some (cursor 1)))
  in
  check (P.progress failed Favorites = Failed) "repeated asset More must fail";
  check
    (not
       (List.exists
          (function
            | P.Read _ | Demand _ -> true
            | Release _ -> false)
          instructions))
    "repeated asset More created a new consumer or Read"
;;

(* The pure scan owns continuations and lifecycle decisions; this generator
   supplies equality-comparable payloads without access to any cursor decoder. *)
let deferred_read_identity () =
  let s,ins=refresh P.empty in
  let s,ins=P.step s (Roots_loaded(read Favorites ins,[uuid 1],None)) in
  let ticket=read Favorites ins in
  let awaiting,ins,dependencies=P.step_with_dependencies s (Assets_loaded(ticket,[asset 2],Some cursor)) in
  let consumer,_=demand ins in
  check (List.exists(fun (d:_ P.read_dependency)->d.ticket=ticket && d.after_demand=Some consumer)dependencies)
    "deferred More lost the exact source before its parent completed";
  let paused,_,joined=P.step_with_dependencies awaiting (Backpressure consumer) in
  check (joined=dependencies) "backpressure changed the deferred read identity";
  check(P.completed_deferred_reads awaiting (Backpressure consumer)=[])
    "backpressure completed the deferred consumer";
  check(P.completed_deferred_reads paused (Demand_accepted consumer)=dependencies)
    "accepted demand failed to complete its exact deferred consumer";
  let same,_=refresh paused in
  check (P.read_dependencies same=P.read_dependencies paused) "same config retired deferred read";
  let untouched,_,joined=P.step_with_dependencies paused (Demand_accepted "old-consumer") in
  check (joined=[] && P.read_dependencies untouched=P.read_dependencies paused)
    "unowned demand notice re-associated a read";
  let reading,ins,joined=P.step_with_dependencies paused (Demand_accepted consumer) in
  let next=read Favorites ins in
  check (List.exists(fun (d:_ P.read_dependency)->d.ticket=next && d.after_demand=None)joined)
    "accepted demand did not expand into its actual next read";
  let final,ins=P.step reading (Assets_loaded(next,[asset 3],None)) in
  let final_consumer,_=demand ins in
  check (not(List.exists(fun (d:_ P.read_dependency)->d.ticket.reason=Favorites)(P.read_dependencies final)))
    "final download demand unnecessarily blocks a read ACK";
  let dirty,_,joined=P.step_with_dependencies final (Index_changed Favorites) in
  check (List.exists(fun (d:_ P.read_dependency)->d.after_demand=Some final_consumer)joined)
    "coalesced index work behind demand lost its cause";
  let closed,_=P.step dirty Shutdown in
  check (P.read_dependencies closed=[]) "shutdown retained causal read work";
  let late,ins=P.step closed (Demand_accepted final_consumer) in
  check (ins=[] && P.read_dependencies late=[]) "old demand revived a closed scan"
;;

let opaque_cursor_properties () =
  let snapshot state =
    ( P.offline state Recent
    , P.offline state Favorites
    , List.of_seq (P.roots state Recent)
    , List.of_seq (P.roots state Favorites)
    , P.read_dependencies state )
  in
  let run seed actions =
    let state = ref P.empty
    and tickets = ref []
    and consumers = ref [] in
    let record instructions =
      List.iter
        (function
          | P.Read ticket -> tickets := ticket :: !tickets
          | Demand { consumer; _ } -> consumers := consumer :: !consumers
          | Release _ -> ())
        instructions
    in
    let apply event =
      let before = snapshot !state in
      let next, instructions, dependencies = P.step_with_dependencies !state event in
      let repeated, again, repeated_dependencies = P.step_with_dependencies !state event in
      check (snapshot !state = before) "pure scan mutated a previous state";
      check
        (snapshot next = snapshot repeated && instructions = again && dependencies=repeated_dependencies)
        "pure scan is nondeterministic";
      let ordinary,ordinary_instructions=P.step !state event in
      check(snapshot ordinary=snapshot next && ordinary_instructions=instructions)
        "causal planning changed policy transport decisions";
      state := next;
      record instructions;
      check(List.length(P.read_dependencies next)<=2) "causal work exceeds the two configured reasons";
      List.iter(fun (dependency:_ P.read_dependency)->
        check(List.mem dependency.ticket !tickets) "causal work fabricated a source ticket";
        Option.iter(fun consumer->check(List.mem consumer !consumers)
          "deferred work fabricated a resource demand")dependency.after_demand)
        (P.read_dependencies next);
      match event with
      | P.Roots_loaded _ | Assets_loaded _ | Read_failed _ ->
        let duplicate, extra = P.step !state event in
        check
          (extra = [] && snapshot duplicate = snapshot !state)
          "read terminal consumed twice"
      | _ -> ()
    in
    apply
      (Refresh { graph_generation = 1; today = 20260301; settings = P.default_settings });
    List.iteri
      (fun index action ->
         let picked () =
           if action mod 3=0 then
             List.find_map(fun (d:_ P.read_dependency)->if d.after_demand=None then Some d.ticket else None)(P.read_dependencies !state)
           else List.nth_opt !tickets (action mod max 1 (List.length !tickets))
         in
         match action mod 11 with
         | 0 | 1 | 2 ->
           Option.iter
             (fun ticket ->
                let next =
                  if action mod 3 = 0
                  then None
                  else Some (seed, index, "sealed-by-data-owner")
                in
                match ticket.P.query with
                | Recent_roots _ | Favorite_roots _ ->
                  apply
                    (Roots_loaded
                       ( ticket
                       , (if action mod 2 = 0 then [] else [ uuid (index + 1) ])
                       , next ))
                | Assets _ ->
                  apply
                    (Assets_loaded
                       ( ticket
                       , (if action mod 2 = 0 then [] else [ asset (index + 1) ])
                       , next )))
             (picked ())
         | 3 -> Option.iter (fun ticket -> apply (Read_failed ticket)) (picked ())
         | 4 -> apply Resync
         | 5 ->
           let retired = !tickets in
           apply Shutdown;
           apply
             (Refresh
                { graph_generation = index + 2
                ; today = 20260301
                ; settings = P.default_settings
                });
           List.iter
             (fun ticket ->
                let before = snapshot !state in
                let next, instructions = P.step !state (Read_failed ticket) in
                check
                  (instructions = [] && snapshot next = before)
                  "old graph response revived retired scan")
             retired
         | 6 ->
           Option.iter
             (fun consumer -> apply (Demand_accepted consumer))
             (List.nth_opt !consumers 0)
         | 7 -> apply Capacity_available
         | 8 -> apply(Index_changed Favorites)
         | 9 -> apply(Roots_changed[uuid(index+1)])
         | _ -> Option.iter(fun consumer->apply(Backpressure consumer))(List.nth_opt !consumers 0))
      actions
  in
  let failed seed actions =
    try
      run seed actions;
      false
    with
    | _ -> true
  in
  let rec shrink seed actions width =
    if width = 0
    then actions
    else (
      let rec seek offset =
        if offset >= List.length actions
        then shrink seed actions (width / 2)
        else (
          let candidate =
            List.filteri
              (fun index _ -> index < offset || index >= offset + width)
              actions
          in
          if failed seed candidate then shrink seed candidate width else seek (offset + 1))
      in
      seek 0)
  in
  for seed = 1 to 200 do
    let random = Random.State.make [| 0xA55E; seed |] in
    let actions = List.init 64 (fun _ -> Random.State.int random 10000) in
    try run seed actions with
    | error ->
      let minimal = shrink seed actions 32 in
      failwith
        (Printf.sprintf
           "opaque cursor seed=%d trace=[%s]: %s"
           seed
           (String.concat ";" (List.map string_of_int minimal))
           (Printexc.to_string error))
  done
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
    [ "deferred read identity and resource-independent final page", deferred_read_identity
    ; "repeated and cyclic opaque More", repeated_cursor_fails
    ; "opaque cursor 200 seeded traces and shrinking", opaque_cursor_properties
    ; "runtime never configured changes", runtime_unconfigured_changes false
    ; "runtime shutdown changes", runtime_unconfigured_changes true
    ; "runtime unknown old parent", runtime_unknown_old_parent
    ; "runtime dependency reject", runtime_dependency_failure true
    ; "runtime dependency failed", runtime_dependency_failure false
    ; "runtime hidden negative holder", runtime_hidden_holder_fanout
    ; "runtime truncated membership", runtime_truncated_membership
    ; "ready index retirement", ready_index_retirement
    ; "runtime equivalent reference set", runtime_reference_order
    ; "immutable pending residency", pending_preserves_ready
    ; "runtime actual Capture sibling", runtime_real_capture_sibling
    ; "runtime accepted registry capacity", runtime_registry_capacity
    ; "unconfigured shared DTO capacity has no ACK consumer", runtime_unconfigured_shared_capacity
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
