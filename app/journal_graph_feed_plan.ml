module Graph = Logseq_db_types.Graph_types
module Projection = Journal_graph_projection
module Worker = Journal_worker_coordination.Worker_api
module Paging = Journal_timeline_cursor.Timeline_cursor

type scope = Dates_scope of Worker.journal_day * Worker.journal_day | Roots_scope of string | Preview_scope of string * string
type proofs = (scope, Paging.packed_receipt) Hashtbl.t

type day_feed =
  { page : Projection.page
  ; entries : Projection.timeline_entry Rrbvec.t
  ; has_more_entries : bool
  ; continuation : Projection.block_cursor option
  }

type feed_scan =
  { root_session : int64
  ; root_proofs : proofs
  ; mutable root_retries : int
  ; root_reuse : bool
  ; root_generation : int64
  ; root_continued : bool
  ; root_start_day : int option
  ; root_before_day : int option
  ; root_source_cursor : Projection.feed_cursor option
  ; root_requested_root_limit : int
  ; root_requested_day_limit : int
  ; root_skipped_day : int option
  ; mutable root_date_boundary : int option
  ; mutable root_priority_pending : bool
  ; root_publish_partial : bool
  ; root_consumed_by_page : (string, int) Hashtbl.t
  ; mutable root_remaining : int
  ; mutable root_page_size : int
  ; mutable root_list_size : int
  ; mutable root_days : day_feed Rrbvec.t
  ; mutable root_queued : Projection.page Rrbvec.t
  ; mutable root_journal_cursor : Worker_pure_data.journal_item Paging.cursor option
  ; mutable root_journal_through : int
  ; mutable root_journal_boundary : int option
  ; root_journal_boundary_pages : (string, unit) Hashtbl.t
  ; mutable root_date_retries : int
  ; mutable root_journals_done : bool
  }

type root_refresh =
  { refresh_session : int64
  ; refresh_proofs : proofs
  ; mutable refresh_retries : int
  ; mutable refresh_prefix : day_feed option
  ; refresh_prefix_limit : int
  ; refresh_limit : int
  ; mutable refresh_remaining : int
  ; mutable refresh_consumed : int
  ; mutable refresh_entries : Projection.timeline_entry Rrbvec.t
  ; refresh_anchor : (string * string) option
  ; mutable refresh_anchor_reached : bool
  }

type root_owner =
  | Feed_roots of feed_scan
  | Changed_roots of root_refresh

type root_batch =
  { root_owner : root_owner
  ; root_page_uuid : Graph.Uuid.t
  ; root_page : Projection.page
  ; root_epoch : int64
  ; root_limit : int
  ; root_cursor : Projection.root_cursor option
  ; root_next : Projection.root_cursor option
  ; root_members : Projection.tree_member Rrbvec.t
  ; root_proofs : proofs
  ; root_todo : Projection.tree_member Rrbvec.t
  }

type root_preview =
  { preview_batch : root_batch
  ; preview_root : Projection.tree_member
  ; preview_members : Projection.tree_member Rrbvec.t
  ; preview_cursor : Worker_pure_data.child_member Paging.cursor option
  ; preview_limit : int
  }

type journal_request =
  { from_day : Worker.journal_day
  ; through_day : Worker.journal_day
  ; limit : int
  ; after : Worker_pure_data.journal_item Paging.cursor option
  }

type validation_action = Assemble of root_batch | Publish_feed of feed_scan | Window of {request_generation:int64; refresh:bool}
type validation = { action : validation_action; proofs : (scope * Paging.packed_receipt) Rrbvec.t
  ; session : int64; epoch : int64 }

type operation =
  | Check of validation
  | Root_dates of feed_scan * journal_request
  | Root_today of feed_scan * journal_request
  | Root_tree of root_batch
  | Root_preview of root_preview

type failure_scope = Feed of int64 | Day of { day : int; request_generation : int64 } | Reconciliation
type publication =
  | Loaded of { request_generation : int64; feed : Projection.feed; complete : bool }
  | Reconciled of { page : Projection.page; value : Projection.timeline_entry_page }
  | Failed of { scope : failure_scope; stale_cursor : bool; message : string; cause : Worker.error option }
type output = { requests : Graph.Uuid.t Rrbvec.t; publications : publication Rrbvec.t}
type packet = Dates of Worker_pure_data.journal_item Seq.t | Roots of Worker_pure_data.tree_member Seq.t
  | Preview of Worker_pure_data.child_member Seq.t
type fragment = { page : Projection.page; members : Projection.tree_member Rrbvec.t
  ; entries : Projection.timeline_entry Rrbvec.t }
type context = { today : int option; time_context : (Projection.time_context, string) result }
type ports =
  { now : unit -> int64
  ; validate_session : Worker.session -> (unit, Worker.error) result
  ; plan_read : 'a. maximum_items:int -> operation -> 'a Worker.query -> Graph.Uuid.t
  ; context : unit -> context
  ; tag_titles : Graph.Uuid.t -> string list
  ; project_journal_page : Graph.page -> Projection.page option
  ; retain_root_interest : Projection.page -> minimum_limit:int -> unit
  ; retained_anchor : page_id:string -> (string * string) option
  ; observe_packet : packet -> unit
  ; remember_fragment : fragment -> unit
  ; report : string -> (string * Yojson.Safe.t) list -> unit
  }
type t =
  { mutable initial_feed_spec : (int * int) option
  ; mutable feed_session : int64
  ; mutable session : Worker.session option
  ; mutable owner : int64
  ; mutable window_epoch : int64
  ; retained : proofs
  ; retained_prefixes : (string, day_feed) Hashtbl.t
  ; root_page_limits : (string, int) Hashtbl.t
  ; root_page_epochs : (string, int64) Hashtbl.t
  ; root_page_counts : (string, int) Hashtbl.t
  ; root_page_following_days : (string, Projection.feed_cursor option) Hashtbl.t
  }
let empty = { requests = Rrbvec.empty; publications = Rrbvec.empty}
let requests values = { empty with requests = Rrbvec.of_list values }
let responses values = { empty with publications = Rrbvec.of_list values }
let response value = value
let feed_failure request_generation message = responses [Failed { scope = Feed request_generation; stale_cursor = false; message; cause=None }]
let day_failure ~day request_generation message = responses [Failed { scope = Day {day;request_generation}; stale_cursor = false; message; cause=None }]
let reject message = responses [Failed { scope = Reconciliation; stale_cursor = false; message; cause=None }]
let create () =
  { initial_feed_spec = None
  ; feed_session = 0L
  ; session = None
  ; owner = 0L
  ; window_epoch = 0L
  ; retained = Hashtbl.create 32
  ; retained_prefixes = Hashtbl.create 32
  ; root_page_limits = Hashtbl.create 32
  ; root_page_epochs = Hashtbl.create 32
  ; root_page_counts = Hashtbl.create 32
  ; root_page_following_days = Hashtbl.create 32
  }
let reset t =
  t.session <- None;
  t.owner <- Int64.succ t.owner;
  t.window_epoch <- Int64.succ t.window_epoch;
  Hashtbl.clear t.retained;
  Hashtbl.clear t.retained_prefixes;
  Hashtbl.clear t.root_page_limits;
  Hashtbl.clear t.root_page_epochs;
  Hashtbl.clear t.root_page_counts;
  Hashtbl.clear t.root_page_following_days;
  t.initial_feed_spec <- None;
  t.feed_session <- Int64.succ t.feed_session
;;
let timeline_uuid value =
  match Graph.Uuid.of_string value with
  | Ok uuid -> `String (Graph.Uuid.to_string uuid)
  | Error _ -> `String "invalid"
;;

let previous_journal_day day =
  if day <= 10101
  then 0
  else if day mod 100 > 1
  then day - 1
  else (
    let year = day / 10000 in
    let month = day / 100 mod 100 in
    let year, month = if month = 1 then year - 1, 12 else year, month - 1 in
    let last_day =
      match month with
      | 2 -> if year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0) then 29 else 28
      | 4 | 6 | 9 | 11 -> 30
      | _ -> 31
    in
    (year * 10000) + (month * 100) + last_day)
;;

let root_owner_current t = function
  | Feed_roots scan -> scan.root_session = t.feed_session
  | Changed_roots refresh -> refresh.refresh_session = t.owner
;;

let root_batch_current t batch =
  root_owner_current t batch.root_owner
  && Hashtbl.find_opt t.root_page_epochs batch.root_page.Projection.id
     = Some batch.root_epoch
;;

let scan_failure scan message =
  match scan.root_start_day with
  | None -> feed_failure scan.root_generation message
  | Some day -> day_failure ~day scan.root_generation message
;;

let root_failure batch message =
  match batch.root_owner with
  | Feed_roots scan -> scan_failure scan message
  | Changed_roots _ -> reject message
;;

let make_root_batch t ~ports owner ~page_uuid (page : Projection.page) cursor limit =
  let limit = match owner with
    | Changed_roots refresh when refresh.refresh_prefix = None ->
      min limit (max 1 (refresh.refresh_prefix_limit - Rrbvec.length refresh.refresh_entries))
    | _ -> limit in
  Hashtbl.replace t.root_page_limits page.id (max limit (Option.value ~default:1 (Hashtbl.find_opt t.root_page_limits page.id)));
  ports.retain_root_interest page ~minimum_limit:limit;
  let epoch = match Hashtbl.find_opt t.root_page_epochs page.id with
    | Some epoch -> epoch
    | None -> let epoch = ports.now () in
      Hashtbl.replace t.root_page_epochs page.id epoch; epoch in
  { root_owner = owner
  ; root_page_uuid = page_uuid
  ; root_page = page
  ; root_epoch = epoch
  ; root_limit = limit
  ; root_cursor = cursor
  ; root_next = None
  ; root_members = Rrbvec.empty
  ; root_proofs = Hashtbl.create 8
  ; root_todo = Rrbvec.empty
  }
;;

let plan_root_batch ~ports batch =
  let limit = batch.root_limit in
  let request =
    ports.plan_read
      (Root_tree batch)
      ~maximum_items:limit
      (Worker.Timeline_read
         { query = Paging.roots ~page:(batch.root_page_uuid)
         ; after = batch.root_cursor })
  in
  (match batch.root_owner with
   | Feed_roots scan ->
     ports.report
       "runtime-feed-tree-request"
       [ "request", `String (Graph.Uuid.to_string request)
       ; "requestGeneration", `String (Int64.to_string scan.root_generation)
       ; "target", timeline_uuid batch.root_page.id
       ; "day", `Int batch.root_page.day
       ; "limit", `Int limit
       ; "maximumDepth", `Int 0
       ; "hasContinuation", `Bool (Option.is_some batch.root_cursor)
       ; "kind", `String "roots"
       ]
   | Changed_roots _ -> ());
  request
;;

let read_root_batch t ~ports owner (page:Projection.page) cursor limit =
  match Graph.Uuid.of_string page.id with
  | Error message -> Error message
  | Ok page_uuid -> Ok (make_root_batch t ~ports owner ~page_uuid page cursor limit |> plan_root_batch ~ports)
;;

let continue_root_batch t ~ports owner page cursor limit =
  match read_root_batch t ~ports owner page cursor limit with
  | Ok request -> requests [request]
  | Error message -> (match owner with Feed_roots scan -> scan_failure scan message | Changed_roots _ -> reject message)
;;

let scope_page = function Roots_scope id | Preview_scope (id, _) -> Some id | Dates_scope _ -> None
let drop_page t id =
  Hashtbl.remove t.retained_prefixes id;
  Hashtbl.filter_map_inplace (fun scope proof ->
    if scope_page scope = Some id then None else Some proof) t.retained
;;

let retire t ~ports ~pages ~entries ~pending =
  let removed_pages = Hashtbl.create (Rrbvec.length pages) in
  let changed_entries = Hashtbl.create (Rrbvec.length entries) in
  Rrbvec.iter (fun id -> Hashtbl.replace removed_pages id ()) pages;
  Rrbvec.iter (fun ((old:Projection.timeline_entry),replacement) ->
    let same_page = Option.exists (fun (fresh:Projection.timeline_entry) ->
      Journal_model.page_id old.block = Journal_model.page_id fresh.block) replacement in
    if not same_page || Option.exists (fun (fresh:Projection.timeline_entry) ->
      old.child_summaries <> fresh.child_summaries) replacement then
      Hashtbl.replace changed_entries
        (Journal_model.page_id old.block,Journal_model.id old.block)
        (if same_page then replacement else None)) entries;
  if Hashtbl.length removed_pages > 0 || Hashtbl.length changed_entries > 0 then (
    let filter_proofs proofs = Hashtbl.filter_map_inplace (fun scope proof ->
      let removed = match scope with
        | Dates_scope _ -> false
        | Roots_scope page -> Hashtbl.mem removed_pages page
        | Preview_scope (page,root) -> Hashtbl.mem removed_pages page
            || Hashtbl.find_opt changed_entries (page,root) = Some None in
      if removed then None else Some proof) proofs in
    let filter_days days = Rrbvec.filter_map (fun (day:day_feed) ->
      if Hashtbl.mem removed_pages day.page.id then None else
      Some {day with entries=Rrbvec.filter_map (fun (entry:Projection.timeline_entry) ->
        match Hashtbl.find_opt changed_entries (day.page.id,Journal_model.id entry.block) with
        | None -> Some entry | Some replacement -> replacement) day.entries}) days in
    t.window_epoch <- Int64.succ t.window_epoch;
    filter_proofs t.retained;
    Rrbvec.iter (fun id ->
      Hashtbl.remove t.retained_prefixes id;
      Hashtbl.remove t.root_page_limits id;
      Hashtbl.remove t.root_page_epochs id;
      Hashtbl.remove t.root_page_counts id;
      Hashtbl.remove t.root_page_following_days id) pages;
    Hashtbl.iter (fun (page,_) replacement ->
      if not (Hashtbl.mem removed_pages page) then (
        Hashtbl.replace t.root_page_epochs page (ports.now ());
        if replacement = None then
          Option.iter (fun count -> Hashtbl.replace t.root_page_counts page (max 0 (count-1)))
            (Hashtbl.find_opt t.root_page_counts page))) changed_entries;
    Hashtbl.filter_map_inplace (fun _ day ->
      Rrbvec.nth_opt (filter_days (Rrbvec.singleton day)) 0) t.retained_prefixes;
    let clean_scan (scan:feed_scan) =
      filter_proofs scan.root_proofs;
      scan.root_days <- filter_days scan.root_days;
      scan.root_queued <- Rrbvec.filter (fun (page:Projection.page) ->
        not (Hashtbl.mem removed_pages page.id)) scan.root_queued;
      Rrbvec.iter (Hashtbl.remove scan.root_consumed_by_page) pages in
    let clean_batch batch = match batch.root_owner with
      | Feed_roots scan -> clean_scan scan
      | Changed_roots _ -> () in
    Seq.iter (function
      | Root_dates (scan,_) | Root_today (scan,_) -> clean_scan scan
      | Root_tree batch | Root_preview {preview_batch=batch;_}
      | Check {action=Assemble batch;_} -> clean_batch batch
      | Check {action=Publish_feed scan;_} -> clean_scan scan
      | Check {action=Window _;_} -> ()) pending)
;;

let read_changed_roots t ~ports page limit =
  (* One invalidation owns both the retained suffix and its concurrent feed
     prefix. Only a newer invalidation fences their shared page observation. *)
  Hashtbl.replace t.root_page_epochs page.Projection.id (ports.now ());
  drop_page t page.id;
  let target =
    max
      1
      (Option.value
         (Hashtbl.find_opt t.root_page_counts page.Projection.id)
         ~default:limit)
  in
  let anchor = ports.retained_anchor ~page_id:page.id in
  read_root_batch t ~ports
    (Changed_roots
       { refresh_session = t.owner
       ; refresh_proofs = Hashtbl.create 8
       ; refresh_retries = 0
       ; refresh_prefix = None
       ; refresh_prefix_limit = Option.fold ~none:limit ~some:fst t.initial_feed_spec
       ; refresh_limit = limit
       ; refresh_remaining = target
       ; refresh_consumed = 0
       ; refresh_entries = Rrbvec.empty
       ; refresh_anchor = anchor
       ; refresh_anchor_reached = anchor = None
       })
    page
    None
    (min limit target)
;;

let read_root_dates ~ports scan =
  match Worker.journal_day 10101,
        Worker.journal_day (min 99991231 scan.root_journal_through) with
  | Error error, _ | _, Error error -> scan_failure scan (Paging.error_message (Paging.Read_failed error))
  | Ok from_day, Ok through_day ->
  let params = {from_day;through_day;limit=scan.root_list_size;after=scan.root_journal_cursor} in
  let request =
    ports.plan_read
      (Root_dates (scan, params))
      ~maximum_items:params.limit
      (Worker.Timeline_read
         { query = Paging.dates ~from_day:params.from_day ~through_day:params.through_day
         ; after = params.after })
  in
  ports.report
    "runtime-feed-request"
    [ "request", `String (Graph.Uuid.to_string request)
    ; "requestGeneration", `String (Int64.to_string scan.root_generation)
    ; "beforeDay", Option.fold ~none:`Null ~some:(fun d -> `Int d) scan.root_before_day
    ; "dayLimit", `Int scan.root_list_size
    ; "rootRemaining", `Int scan.root_remaining
    ; "hasContinuation", `Bool (Option.is_some scan.root_journal_cursor)
    ; "kind", `String "date-catalog"
    ];
  requests [request]
;;

let root_date_continuation scan =
  if Rrbvec.is_empty scan.root_queued && scan.root_journals_done
  then None
  else
    Some
      Projection.
        { before_day = scan.root_date_boundary; skipped_day = scan.root_skipped_day }
;;
(* The first metadata packet usually covers Today. Probe its exact range only
   when every discovered date is future and the catalog has more packets. *)
let read_priority_today ~ports scan =
  match scan.root_skipped_day with
  | None -> scan_failure scan "The priority date is unavailable."
  | Some today -> match Worker.journal_day today with
  | Error error -> scan_failure scan (Paging.error_message (Paging.Read_failed error))
  | Ok day ->
  let params = { from_day = day; through_day = day; limit = 1; after = None } in
  let request =
    ports.plan_read
      (Root_today (scan, params))
      ~maximum_items:params.limit
      (Worker.Timeline_read
         { query = Paging.dates ~from_day:params.from_day ~through_day:params.through_day
         ; after = params.after })
  in
  ports.report
    "runtime-feed-request"
    [ "request", `String (Graph.Uuid.to_string request)
    ; "requestGeneration", `String (Int64.to_string scan.root_generation)
    ; "day", `Int today
    ; "dayLimit", `Int 1
    ; "rootRemaining", `Int scan.root_remaining
    ; "hasContinuation", `Bool false
    ; "kind", `String "priority-today"
    ];
  requests [request]
;;

let root_feed_response ~ports scan complete =
  let days = scan.root_days in
  let slot_count = Rrbvec.fold_left
    (fun n (d:day_feed)->n+1+Rrbvec.length d.entries) 0 days in
  let feed : Projection.feed =
    { days = Rrbvec.to_list (Rrbvec.map (fun (d:day_feed)->Projection.
        {page=d.page;entries=Rrbvec.to_list d.entries;has_more_entries=d.has_more_entries;continuation=d.continuation}) days)
    ; slot_count
    (* Date traversal survives a day cursor removed by authoritative reconciliation. *)
    ; continuation = root_date_continuation scan
    ; prioritized_day = scan.root_skipped_day
    } in
  ports.report "runtime-feed-result"
    [ "requestGeneration", `String (Int64.to_string scan.root_generation)
    ; "complete", `Bool complete
    ; "dayCount", `Int (Rrbvec.length days)
    ; "slotCount", `Int feed.slot_count
    ; "rootCount", `Int (feed.slot_count - Rrbvec.length days)
    ; "truncated", `Bool (Rrbvec.length days > 16 || feed.slot_count - Rrbvec.length days > 16)
    ; "pages", `List (Rrbvec.to_seq days |> Seq.take 16 |> Seq.map (fun (d:day_feed)->
        `Assoc ["page",timeline_uuid d.page.id;"day",`Int d.page.day;
          "rootCount",`Int (Rrbvec.length d.entries);"hasContinuation",`Bool d.has_more_entries]) |> List.of_seq)
    ; "roots", `List (Rrbvec.to_seq days |> Seq.flat_map (fun (d:day_feed)->Rrbvec.to_seq d.entries)
        |> Seq.take 16 |> Seq.map (fun (e:Projection.timeline_entry)->timeline_uuid (Journal_model.id e.block)) |> List.of_seq)
    ];
  response (Loaded {request_generation=scan.root_generation;feed;complete})
;;
let owner_proofs = function Feed_roots scan -> scan.root_proofs | Changed_roots refresh -> refresh.refresh_proofs
let merge_proofs into source = Hashtbl.iter (Hashtbl.replace into) source
let retained_page t id = Hashtbl.mem t.retained (Roots_scope id)
let has_retained t = Hashtbl.length t.retained > 0
let validation_failure action message = match action with
  | Assemble batch -> root_failure batch message
  | Publish_feed scan -> scan_failure scan message
  | Window _ -> reject message

let check t ~ports action =
  let proofs = Hashtbl.copy t.retained in
  (match action with
   | Assemble batch -> merge_proofs proofs (owner_proofs batch.root_owner); merge_proofs proofs batch.root_proofs
   | Publish_feed scan -> merge_proofs proofs scan.root_proofs
   | Window _ -> ());
  if Hashtbl.length proofs > Paging.maximum_receipts then
    validation_failure action "The retained Timeline window exceeds the receipt budget."
  else
    let proofs = Hashtbl.to_seq proofs |> Rrbvec.of_seq in
    requests [ports.plan_read ~maximum_items:1
      (Check {action;proofs;session=t.owner;epoch=t.window_epoch})
      (Worker.Timeline_check (Rrbvec.map snd proofs))]
;;

let validate_retained t ~ports ~request_generation ~refresh =
  if not (has_retained t) then empty else (
    t.window_epoch <- Int64.succ t.window_epoch;
    check t ~ports (Window {request_generation;refresh}))
;;

let rec next_feed_batch ?(verified=false) t ~ports scan =
  if not (root_owner_current t (Feed_roots scan))
  then empty
  else if scan.root_remaining = 0
  then (if verified then responses [root_feed_response ~ports scan true] else check t ~ports (Publish_feed scan))
  else (
    match Rrbvec.pop_front scan.root_queued with
    | Some (page, rest) ->
      scan.root_queued <- rest;
      (match if scan.root_reuse then Hashtbl.find_opt t.retained_prefixes page.id else None with
       | Some day when day.page.day = page.day && Rrbvec.length day.entries <= scan.root_remaining ->
         scan.root_remaining <- scan.root_remaining - Rrbvec.length day.entries;
         if not (Rrbvec.is_empty day.entries) then
           scan.root_days <- Rrbvec.push_back scan.root_days {day with page};
         if Some page.day <> scan.root_skipped_day then scan.root_date_boundary <- Some page.day;
         next_feed_batch t ~ports scan
       | _ -> continue_root_batch t ~ports (Feed_roots scan) page None
           (min scan.root_page_size scan.root_remaining))
    | None when scan.root_journals_done -> if verified then responses [root_feed_response ~ports scan true] else check t ~ports (Publish_feed scan)
    | None when scan.root_journal_through < 10101 ->
      scan.root_journals_done <- true;
      if not (has_retained t) then responses [root_feed_response ~ports scan true] else check t ~ports (Publish_feed scan)
    | None -> read_root_dates ~ports scan)
;;

let complete_verified_batch t ~ports batch =
  if not (root_batch_current t batch)
  then empty
  else (
    match (ports.context ()).time_context with
    | Error message -> root_failure batch message
    | Ok time_context ->
      (match
         Projection.timeline_entry_page
           ?root_continuation:batch.root_next
           ~tag_titles:ports.tag_titles
           ~page:batch.root_page
           ~time_context
           Graph.{ items = Rrbvec.to_list batch.root_members; continuation = None }
       with
       | Error message -> root_failure batch message
       | Ok projected ->
         (match batch.root_owner with
          | Changed_roots _ -> ()
          | Feed_roots scan ->
            if Some batch.root_page.day <> scan.root_skipped_day then
              scan.root_date_boundary <- Some batch.root_page.day;
            (* Date traversal belongs to the retained page, not the disposable
               Worker structure cursor used by recovery and reconciliation. *)
            Hashtbl.replace t.root_page_following_days batch.root_page.id
              (root_date_continuation scan));
         ports.remember_fragment { page = batch.root_page
           ; members = batch.root_members
           ; entries = Rrbvec.of_list projected.entries };
         let consumed =
           Rrbvec.fold_left
             (fun n (m : Projection.tree_member) -> if m.depth = 0 then n + 1 else n)
             0
             batch.root_members
         in
         (match batch.root_owner with
          | Feed_roots scan ->
            let previous =
              if batch.root_cursor = None
              then 0
              else
                Option.value
                  (Hashtbl.find_opt scan.root_consumed_by_page batch.root_page.id)
                  ~default:0
            in
            let consumed = previous + consumed in
            Hashtbl.replace scan.root_consumed_by_page batch.root_page.id consumed;
            let retained =
              Option.value
                (Hashtbl.find_opt t.root_page_counts batch.root_page.id)
                ~default:0
            in
            Hashtbl.replace
              t.root_page_counts
              batch.root_page.id
              (if batch.root_next = None then consumed else max retained consumed)
          | Changed_roots _ -> ());
         (match batch.root_owner with
          | Changed_roots refresh ->
            refresh.refresh_remaining <- refresh.refresh_remaining - consumed;
            refresh.refresh_consumed <- refresh.refresh_consumed + consumed;
            refresh.refresh_entries
            <- Rrbvec.append_list refresh.refresh_entries projected.entries;
            if refresh.refresh_prefix = None &&
               (Rrbvec.length refresh.refresh_entries >= refresh.refresh_prefix_limit || batch.root_next = None) then
              refresh.refresh_prefix <- Some {page=batch.root_page;entries=refresh.refresh_entries;
                has_more_entries=Option.is_some projected.continuation;continuation=projected.continuation};
            Rrbvec.iter
              (fun (m : Projection.tree_member) ->
                 if
                   m.depth = 0
                   && Option.fold
                        ~none:true
                        ~some:(fun key ->
                          compare (m.block.order, Graph.Uuid.to_string m.block.uuid) key
                          >= 0)
                        refresh.refresh_anchor
                 then refresh.refresh_anchor_reached <- true)
              batch.root_members;
            (match batch.root_next with
             | Some cursor
               when refresh.refresh_remaining > 0
                    || (not refresh.refresh_anchor_reached)
                    || Rrbvec.is_empty refresh.refresh_entries ->
               if Some cursor = batch.root_cursor
               then root_failure batch "The refresh cursor did not advance."
               else
                 continue_root_batch t ~ports batch.root_owner batch.root_page (Some cursor)
                   (if refresh.refresh_remaining>0 then min batch.root_limit refresh.refresh_remaining else 1)
             | None | Some _ ->
               Hashtbl.replace
                 t.root_page_counts
                 batch.root_page.id
                 refresh.refresh_consumed;
               Option.iter (fun prefix -> Hashtbl.replace t.retained_prefixes batch.root_page.id prefix)
                 refresh.refresh_prefix;
               responses
                 [ response
                     (Reconciled
                        { page = batch.root_page
                        ; value =
                            { projected with
                              entries = Rrbvec.to_list refresh.refresh_entries
                            }
                        })
                 ])
          | Feed_roots scan ->
            let previous =
              Rrbvec.find_opt
                (fun (d : day_feed) -> d.page.id = batch.root_page.id)
                scan.root_days
            in
            let old =
              Option.fold
                ~none:Rrbvec.empty
                ~some:(fun (d : day_feed) -> d.entries)
                previous
            in
            let old_ids =
              Rrbvec.map
                (fun (e : Projection.timeline_entry) -> Journal_model.id e.block)
                old
            in
            let added =
              Rrbvec.filter
                (fun (e : Projection.timeline_entry) ->
                   not (Rrbvec.exists (String.equal (Journal_model.id e.block)) old_ids))
                (Rrbvec.of_list projected.entries)
            in
            scan.root_remaining <- scan.root_remaining - Rrbvec.length added;
            let day : day_feed =
              { page = batch.root_page
              ; entries = Rrbvec.append old added
              ; has_more_entries = Option.is_some projected.continuation
              ; continuation = projected.continuation
              }
            in
            if scan.root_start_day = None || not (Hashtbl.mem t.retained_prefixes batch.root_page.id) then
              Hashtbl.replace t.retained_prefixes batch.root_page.id day;
            scan.root_days
            <- (match previous with
                | None when Rrbvec.is_empty day.entries && scan.root_start_day = None -> scan.root_days
                | None -> Rrbvec.push_back scan.root_days day
                | Some _ ->
                  Rrbvec.map
                    (fun (d : day_feed) ->
                       if d.page.id = day.page.id then day else d)
                    scan.root_days);
            let next =
              match batch.root_next with
              | Some cursor when scan.root_remaining > 0 ->
                if Some cursor = batch.root_cursor
                then root_failure batch "The root cursor did not advance."
                else
                  continue_root_batch t ~ports batch.root_owner batch.root_page (Some cursor)
                    (min scan.root_page_size scan.root_remaining)
              | None | Some _ -> next_feed_batch ~verified:true t ~ports scan
            in
            if Rrbvec.is_empty next.publications && scan.root_publish_partial && not (Rrbvec.is_empty scan.root_days)
            then { next with publications = Rrbvec.singleton (root_feed_response ~ports scan false) }
            else next)))
;;

let read_root_preview ~ports preview =
  let request =
    ports.plan_read
      (Root_preview preview)
      ~maximum_items:preview.preview_limit
      (Worker.Timeline_read
         { query = Paging.preview_children ~parent:preview.preview_root.block.uuid
         ; after = preview.preview_cursor })
  in
  (match preview.preview_batch.root_owner with
   | Feed_roots scan ->
     ports.report
       "runtime-feed-tree-request"
       [ "request", `String (Graph.Uuid.to_string request)
       ; "requestGeneration", `String (Int64.to_string scan.root_generation)
       ; "target", `String (Graph.Uuid.to_string preview.preview_root.block.uuid)
       ; "day", `Int preview.preview_batch.root_page.day
       ; "limit", `Int preview.preview_limit
       ; "hasContinuation", `Bool (Option.is_some preview.preview_cursor)
       ; "kind", `String "child-preview"
       ]
   | Changed_roots _ -> ());
  request
;;

let next_root_preview t ~ports batch =
  if not (root_batch_current t batch)
  then empty
  else (
    match Rrbvec.pop_front batch.root_todo with
    | None -> check t ~ports (Assemble batch)
    | Some (root, rest) ->
      let preview =
        { preview_batch = { batch with root_todo = rest }
        ; preview_root = root
        ; preview_members = Rrbvec.empty
        ; preview_cursor = None
        ; preview_limit = 3
        }
      in
      requests [ read_root_preview ~ports preview ])
;;

let start_feed_scan t ~ports ~cursor ~root_limit ~day_limit ~request_generation ?(reuse=false) ?after () =
  let before_day = Option.bind cursor (fun c -> c.Projection.before_day) in
  let start_day = Option.map (fun ((page : Projection.page), _) -> page.day) after in
  if root_limit <= 0 || day_limit <= 0
  then (
    match start_day with
    | None ->
      feed_failure request_generation "The root and date packet limits must be positive."
    | Some day -> day_failure ~day request_generation "The root limit must be positive.")
  else if Option.exists (fun (_,cursor) -> Option.exists (fun cursor ->
      match cursor.Projection.protocol_cursor with
        | Some (Projection.Child_cursor _) -> true
        | Some (Projection.Root_tree_cursor _) | None -> false) cursor) after
  then (match start_day with
    | Some day -> day_failure ~day request_generation "A Detail child cursor cannot continue Timeline roots."
    | None -> feed_failure request_generation "A Detail child cursor cannot continue Timeline roots.")
  else if Option.exists (fun day -> Result.is_error (Worker.journal_day day)) before_day
  then (
    match start_day with
    | None -> feed_failure request_generation "The date continuation boundary is invalid."
    | Some day -> day_failure ~day request_generation "The date continuation boundary is invalid.")
  else (
    t.feed_session <- Int64.succ t.feed_session;
    t.window_epoch <- Int64.succ t.window_epoch;
    (* A replacement catalog traversal owns its own date scopes. Root and
       preview receipts still belong to every retained page. *)
    Hashtbl.filter_map_inplace (fun scope proof -> match scope with
      | Dates_scope _ -> None | _ -> Some proof) t.retained;
    if cursor = None && after = None
    then t.initial_feed_spec <- Some (root_limit, day_limit);
    let scan =
      { root_session = t.feed_session
      ; root_proofs = Hashtbl.create 16
      ; root_retries = 0
      ; root_reuse = reuse
      ; root_generation = request_generation
      ; root_continued = Option.exists (fun (_, cursor) -> Option.is_some cursor) after
      ; root_start_day = start_day
      ; root_before_day = before_day
      ; root_source_cursor = cursor
      ; root_requested_root_limit = root_limit
      ; root_requested_day_limit = day_limit
      ; root_skipped_day =
          (match cursor, after with
           | Some c, _ -> c.Projection.skipped_day
           | None, None -> (ports.context ()).today
           | None, Some _ -> None)
      ; root_date_boundary = before_day
      ; root_priority_pending = cursor = None && after = None
      ; root_publish_partial = cursor = None && after = None
      ; root_consumed_by_page = Hashtbl.create 32
      ; root_remaining = root_limit
      ; root_page_size = min root_limit Worker_pure_data.maximum_page_size
      ; root_list_size = min day_limit Worker_pure_data.maximum_page_size
      ; root_days = Rrbvec.empty
      ; root_queued = Rrbvec.empty
      ; root_journal_cursor = None
      ; root_journal_through =
          Option.fold ~none:99_999_999 ~some:previous_journal_day before_day
      ; root_journal_boundary = None
      ; root_journal_boundary_pages = Hashtbl.create 8
      ; root_date_retries = 0
      ; root_journals_done = after <> None && cursor = None
      }
    in
    match after with
    | None -> next_feed_batch t ~ports scan
    | Some (page, cursor) ->
      if Option.is_some cursor
      then
        Hashtbl.replace
          scan.root_consumed_by_page
          page.id
          (Option.value (Hashtbl.find_opt t.root_page_counts page.id) ~default:0);
      continue_root_batch t ~ports (Feed_roots scan) page
        (Option.bind cursor (fun c -> match c.Projection.protocol_cursor with
          | Some (Projection.Root_tree_cursor cursor)->Some cursor
          | Some (Projection.Child_cursor _) | None->None))
        scan.root_page_size)
;;
let superseded_root_batch t ~ports batch =
  match batch.root_owner with
  | Feed_roots scan when root_owner_current t batch.root_owner
                         && Hashtbl.mem t.root_page_limits batch.root_page.id ->
    (match scan.root_start_day with
     | None ->
       (* A canonical local completion can invalidate a page while startup is
          still reading it. Retire that whole prefix, preserve its demand, and
          let the current owner read a fresh prefix without a new UI state. *)
       start_feed_scan t ~ports ~cursor:scan.root_source_cursor
         ~root_limit:scan.root_requested_root_limit
         ~day_limit:scan.root_requested_day_limit
         ~request_generation:scan.root_generation ()
     | Some day ->
       responses
         [ response
             (Failed { scope = Day { day; request_generation = scan.root_generation };
                   stale_cursor = true; cause=None; message = "The root read was superseded by a refresh." })
         ])
  | Feed_roots _ | Changed_roots _ -> empty
;;

let receive_root_tree t ~ports batch (packet : Worker_pure_data.tree_member Paging.packet) =
  let items = packet.items in
  let next_cursor = match packet.next with Paging.End -> None | More cursor -> Some cursor in
  if not (root_batch_current t batch) then empty
  else if Rrbvec.exists (fun (m : Worker_pure_data.tree_member) ->
    m.depth <> 0 || Graph.Uuid.to_string m.value.block.page <> batch.root_page.id
    || Graph.Uuid.to_string m.value.block.parent <> batch.root_page.id) items
  then root_failure batch "The root query returned a foreign or nested block."
  else if Rrbvec.length items > batch.root_limit
  then root_failure batch "The root packet exceeded its requested item budget."
  else if next_cursor <> None && next_cursor = batch.root_cursor
  then root_failure batch "The root cursor did not advance."
  else (
    Hashtbl.replace batch.root_proofs (Roots_scope batch.root_page.id) (Paging.Receipt packet.receipt);
    let members = Rrbvec.map (fun (m : Worker_pure_data.tree_member) ->
      Projection.{block=m.value.block;revision=m.revision;depth=0}) items in
    match (ports.context ()).time_context with
    | Error message -> root_failure batch message
    | Ok time_context ->
      match Projection.timeline_entry_page ~tag_titles:ports.tag_titles ~page:batch.root_page
        ~time_context Graph.{items=Rrbvec.to_list members;continuation=None} with
      | Error message -> root_failure batch message
      | Ok projected ->
        let ids = List.map (fun (e : Projection.timeline_entry) -> Journal_model.id e.block) projected.entries in
        let todo = Rrbvec.filter (fun (m : Projection.tree_member) ->
          List.mem (Graph.Uuid.to_string m.block.uuid) ids) members in
        next_root_preview t ~ports
          {batch with root_members=members;root_todo=todo;root_next=next_cursor})
;;

let receive_root_preview t ~ports preview (packet : Worker_pure_data.child_member Paging.packet) =
  let parent = preview.preview_root.block.uuid in
  let items = packet.items in
  let next_cursor = match packet.next with Paging.End -> None | More cursor -> Some cursor in
  let batch = preview.preview_batch in
  if not (root_batch_current t batch)
  then empty
  else if
    (not (Graph.Uuid.equal parent preview.preview_root.block.uuid))
    || Rrbvec.exists
         (fun (m : Worker_pure_data.child_member) ->
            (not (Graph.Uuid.equal m.value.block.parent parent))
            || Graph.Uuid.to_string m.value.block.page <> batch.root_page.id)
         items
  then root_failure batch "The preview query returned a foreign child."
  else if Rrbvec.length items > preview.preview_limit then
    root_failure batch "The preview packet exceeded its requested item budget."
  else (
    Hashtbl.replace batch.root_proofs
      (Preview_scope (batch.root_page.id, Graph.Uuid.to_string parent)) (Paging.Receipt packet.receipt);
    let members =
      Rrbvec.append preview.preview_members
        (Rrbvec.map
          (fun (m : Worker_pure_data.child_member) ->
             Projection.{ block = m.value.block; revision = m.revision; depth = 1 })
          items)
    in
    match (ports.context ()).time_context with
    | Error message -> root_failure batch message
    | Ok time_context ->
      (match
         Projection.timeline_entry_page
           ~page:batch.root_page
           ~time_context
           Graph.{ items = Rrbvec.to_list (Rrbvec.push_front members preview.preview_root); continuation = None }
       with
       | Error message -> root_failure batch message
       | Ok projected ->
         let summaries =
           match projected.entries with
           | [] -> []
           | e :: _ -> e.child_summaries
         in
         let count = List.length summaries in
         let selected =
           Rrbvec.filter
             (fun (m : Projection.tree_member) ->
                List.exists
                  (fun (c : Projection.child_summary) ->
                     c.block_id = Graph.Uuid.to_string m.block.uuid)
                  summaries)
             members
         in
         if count < 3 && Option.is_some next_cursor
         then
           if next_cursor = preview.preview_cursor
           then root_failure batch "The child cursor did not advance."
           else
             requests
               [ read_root_preview ~ports
                   { preview with
                     preview_members = selected
                   ; preview_cursor = next_cursor
                   }
               ]
         else
           next_root_preview t ~ports { batch with root_members = Rrbvec.append batch.root_members selected }))
;;

let stale_continuation scan =
  responses [Failed {scope=Day {day=Option.get scan.root_start_day;
    request_generation=scan.root_generation};stale_cursor=true;cause=None;
    message="The retained Timeline continuation changed. Reload the day."}]
;;

let restart_batch t ~ports batch =
  let proofs = owner_proofs batch.root_owner in
  Hashtbl.filter_map_inplace (fun scope proof ->
    if scope_page scope = Some batch.root_page.id then None else Some proof) proofs;
  drop_page t batch.root_page.id;
  match batch.root_owner with
  | Feed_roots scan ->
    if scan.root_continued then stale_continuation scan
    else if scan.root_retries >= 2 then root_failure batch "Timeline roots changed repeatedly during assembly."
    else (
      scan.root_retries <- scan.root_retries + 1;
      let previous = Rrbvec.fold_left (fun n (day:day_feed) ->
        if day.page.id = batch.root_page.id then n + Rrbvec.length day.entries else n) 0 scan.root_days in
      scan.root_remaining <- scan.root_remaining + previous;
      scan.root_days <- Rrbvec.filter (fun (day:day_feed) -> day.page.id <> batch.root_page.id) scan.root_days;
      Hashtbl.remove scan.root_consumed_by_page batch.root_page.id;
      continue_root_batch t ~ports batch.root_owner batch.root_page None
        (min scan.root_page_size scan.root_remaining))
  | Changed_roots refresh ->
    if refresh.refresh_retries >= 2 then root_failure batch "Timeline roots changed repeatedly during reconciliation."
    else (
      refresh.refresh_retries <- refresh.refresh_retries + 1;
      refresh.refresh_remaining <- refresh.refresh_remaining + refresh.refresh_consumed;
      refresh.refresh_consumed <- 0;
      refresh.refresh_entries <- Rrbvec.empty;
      refresh.refresh_prefix <- None;
      refresh.refresh_anchor_reached <- refresh.refresh_anchor = None;
      continue_root_batch t ~ports batch.root_owner batch.root_page None
        (min refresh.refresh_limit refresh.refresh_remaining))
;;

let restart_dates t ~ports scan =
  if scan.root_continued then stale_continuation scan
  else if scan.root_retries >= 2 then scan_failure scan "Timeline dates changed repeatedly during assembly."
  else (
    scan.root_retries <- scan.root_retries + 1;
    Hashtbl.clear scan.root_proofs;
    Hashtbl.clear scan.root_consumed_by_page;
    Hashtbl.filter_map_inplace (fun scope proof -> match scope with Dates_scope _ -> None | _ -> Some proof) t.retained;
    scan.root_days <- Rrbvec.empty;
    scan.root_queued <- Rrbvec.empty;
    scan.root_remaining <- scan.root_requested_root_limit;
    scan.root_date_boundary <- scan.root_before_day;
    scan.root_priority_pending <- scan.root_source_cursor = None && scan.root_start_day = None;
    scan.root_journal_cursor <- None;
    scan.root_journal_through <- Option.fold ~none:99991231 ~some:previous_journal_day scan.root_before_day;
    scan.root_journal_boundary <- None;
    Hashtbl.clear scan.root_journal_boundary_pages;
    scan.root_journals_done <- false;
    read_root_dates ~ports scan)
;;

let operation_failure operation message = match operation with
  | Root_dates (scan, _) | Root_today (scan, _) -> scan_failure scan message
  | Root_tree batch | Root_preview {preview_batch=batch;_} -> root_failure batch message
  | Check validation -> validation_failure validation.action message
;;

let with_worker_cause error output =
  {output with publications=Rrbvec.map (function
    | Failed failure -> Failed {failure with cause=Some error}
    | publication -> publication) output.publications}
;;

let paging_failure failure error =
  let output = failure (Paging.error_message error) in
  match error with Paging.Read_failed cause -> with_worker_cause cause output | _ -> output
;;

let paging_error t ~ports operation error =
  match error with
  | Paging.Invalidated Scope_changed ->
    (match operation with
     | Root_dates (scan, _) | Root_today (scan, _) -> restart_dates t ~ports scan
     | Root_tree batch | Root_preview {preview_batch=batch;_} -> restart_batch t ~ports batch
     | Check _ -> operation_failure operation (Paging.error_message error))
  | Paging.Invalidated Owner_changed ->
    reset t;
    operation_failure operation (Paging.error_message error)
  | _ -> paging_failure (operation_failure operation) error
;;

let receive_check t ~ports validation (checked : Paging.check) =
  if Rrbvec.length checked.results <> Rrbvec.length validation.proofs then
    validation_failure validation.action "The Timeline check returned a different receipt count."
  else
    let invalid = Rrbvec.fold_left (fun (index, failures) result ->
      let scope, _ = Rrbvec.nth validation.proofs index in
      index+1, (match result with Ok () -> failures | Error error -> Rrbvec.push_back failures (scope,error)))
      (0,Rrbvec.empty) checked.results |> snd in
    if Rrbvec.is_empty invalid then (
      Rrbvec.iter (fun (scope,proof) -> Hashtbl.replace t.retained scope proof) validation.proofs;
      match validation.action with
      | Assemble batch ->
        merge_proofs (owner_proofs batch.root_owner) batch.root_proofs;
        complete_verified_batch t ~ports batch
      | Publish_feed scan -> responses [root_feed_response ~ports scan true]
      | Window {request_generation;refresh} ->
        if refresh then Option.fold ~none:empty ~some:(fun (root_limit,day_limit) ->
          start_feed_scan t ~ports ~cursor:None ~root_limit ~day_limit ~request_generation ~reuse:true ()) t.initial_feed_spec
        else empty)
    else if Rrbvec.exists (fun (_,error) -> error = Paging.Invalidated Paging.Owner_changed) invalid then (
      reset t;
      validation_failure validation.action (Paging.error_message (Paging.Invalidated Owner_changed)))
    else
      match Rrbvec.find_opt (fun (_,error) -> error <> Paging.Invalidated Paging.Scope_changed) invalid with
      | Some (_,error) ->
        paging_failure (validation_failure validation.action) error
      | None ->
        let dates_changed = Rrbvec.exists (fun (scope,_) -> match scope with Dates_scope _ -> true | _ -> false) invalid in
        let pages = Hashtbl.create 8 in
        Rrbvec.iter (fun (scope,_) ->
          Hashtbl.remove t.retained scope;
          Option.iter (fun id -> Hashtbl.replace pages id ()) (scope_page scope)) invalid;
        let current_page = match validation.action with
          | Assemble batch -> Some batch.root_page.id | _ -> None in
        let scan_sibling_changed = match validation.action with
          | Assemble {root_owner=Feed_roots scan;_} ->
            Rrbvec.exists (fun (day:day_feed) -> Hashtbl.mem pages day.page.id) scan.root_days
          | _ -> false in
        let roots = Hashtbl.to_seq_keys pages |> Seq.filter_map (fun id ->
          if current_page = Some id then None else
          let day = Hashtbl.find_opt t.retained_prefixes id in
          drop_page t id;
          let accumulated = match validation.action with
            | Assemble {root_owner=Feed_roots scan;_} ->
              Rrbvec.exists (fun (day:day_feed) -> day.page.id = id) scan.root_days
            | _ -> false in
          if scan_sibling_changed && accumulated then None else
          Option.bind day (fun (day:day_feed) -> read_changed_roots t ~ports day.page
            (Option.value ~default:1 (Hashtbl.find_opt t.root_page_limits id)) |> Result.to_option)) |> Rrbvec.of_seq in
        let next = match validation.action with
         | Assemble batch ->
           if dates_changed || scan_sibling_changed then (match batch.root_owner with
             | Feed_roots scan -> restart_dates t ~ports scan
             | Changed_roots _ -> restart_batch t ~ports batch)
           else if Hashtbl.mem pages batch.root_page.id then restart_batch t ~ports batch
           else check t ~ports (Assemble batch)
         | Publish_feed scan -> restart_dates t ~ports scan
         | Window {request_generation;refresh} ->
           if dates_changed || refresh then
             Option.fold ~none:empty ~some:(fun (root_limit,day_limit) ->
               start_feed_scan t ~ports ~cursor:None ~root_limit ~day_limit ~request_generation ~reuse:true ()) t.initial_feed_spec
           else empty in
        {next with requests=Rrbvec.append roots next.requests}
;;

let failure_scope = function
  | Check {action=Assemble {root_owner=Changed_roots _;_};_}
  | Check {action=Window _;_} -> Reconciliation
  | Check {action=Assemble {root_owner=Feed_roots scan;_};_}
  | Check {action=Publish_feed scan;_} ->
    (match scan.root_start_day with None -> Feed scan.root_generation
     | Some day -> Day {day;request_generation=scan.root_generation})
  | Root_dates (scan, _) | Root_today (scan, _) ->
    (match scan.root_start_day with None -> Feed scan.root_generation
       | Some day -> Day {day;request_generation=scan.root_generation})
  | Root_tree batch | Root_preview {preview_batch=batch;_} ->
    (match batch.root_owner with Changed_roots _ -> Reconciliation
     | Feed_roots scan -> match scan.root_start_day with None -> Feed scan.root_generation
       | Some day -> Day {day;request_generation=scan.root_generation})
;;
let operation_name = function Check _ -> "checkTimelineWindow" | Root_dates _ | Root_today _ -> "listTimelineDates"
  | Root_tree _ -> "readTimelineRoots" | Root_preview _ -> "readTimelinePreview"
let is_current t = function
  | Check validation -> validation.session = t.owner && validation.epoch = t.window_epoch && (match validation.action with
      | Assemble batch -> root_batch_current t batch
      | Publish_feed scan -> root_owner_current t (Feed_roots scan)
      | Window _ -> true)
  | Root_dates (scan, _) | Root_today (scan, _) -> root_owner_current t (Feed_roots scan)
  | Root_tree batch -> root_batch_current t batch
  | Root_preview preview -> root_batch_current t preview.preview_batch
let superseded t ~ports = function
  | Check validation when validation.session <> t.owner -> empty
  | Check {action=Assemble batch;_} when root_batch_current t batch -> check t ~ports (Assemble batch)
  | Check {action=Assemble batch;_} -> superseded_root_batch t ~ports batch
  | Check {action=Publish_feed scan;_} when root_owner_current t (Feed_roots scan) ->
    check t ~ports (Publish_feed scan)
  | Check {action=Window {request_generation;refresh};_} when has_retained t ->
    check t ~ports (Window {request_generation;refresh})
  | Check _ | Root_dates _ | Root_today _ -> empty
  | Root_tree batch -> superseded_root_batch t ~ports batch
  | Root_preview preview -> superseded_root_batch t ~ports preview.preview_batch
let receive : type a. ?session:Worker.session -> t -> ports:ports
  -> operation -> a Worker.query -> a -> output option =
  fun ?session t ~ports operation query value ->
  let handles = match operation, query with
    | Check _, Worker.Timeline_check _ -> true
    | (Root_dates _ | Root_today _), Worker.Timeline_read {query=Paging.Dates _;_} -> true
    | Root_tree _, Worker.Timeline_read {query=Paging.Roots _;_} -> true
    | Root_preview _, Worker.Timeline_read {query=Paging.Preview_children _;_} -> true
    | _ -> false in
  if not handles then None else if not (is_current t operation) then Some empty else
  let session = match session with Some _ -> session | None -> t.session in
  match Option.map ports.validate_session session with
  | Some (Error error) ->
    reset t;
    Some (operation_failure operation (Paging.error_message (Paging.Read_failed error)))
  | None | Some (Ok ()) -> (
  Option.iter (fun session -> t.session <- Some session) session;
  Some (match operation,query,value with
      | Check validation, Worker.Timeline_check _, checked -> receive_check t ~ports validation checked
      | Root_dates (scan, params), Worker.Timeline_read {query=Paging.Dates _;_}, Ok packet ->
        Hashtbl.replace scan.root_proofs
          (Dates_scope (params.from_day, params.through_day))
          (Paging.Receipt packet.receipt);
        let items = packet.items in
        let next_cursor = match packet.next with Paging.End -> None | More cursor -> Some cursor in
        ports.observe_packet (Dates (Rrbvec.to_seq items));
        let boundary_page (i : Worker_pure_data.journal_item) =
          scan.root_journal_boundary = Some i.journal_day
          && Hashtbl.mem scan.root_journal_boundary_pages (Graph.Uuid.to_string i.page.uuid)
        in
        (* Stale recovery rereads the oldest catalog date inclusively. *)
        let items = Rrbvec.filter (fun i -> not (boundary_page i)) items in
        if next_cursor <> None && next_cursor = scan.root_journal_cursor
        then scan_failure scan "The date cursor did not advance."
        else (
          let pages =
            Rrbvec.filter_map
              (fun (i : Worker_pure_data.journal_item) -> ports.project_journal_page i.page)
              items
            |> Rrbvec.sort (fun a b -> Int.compare b.Projection.day a.Projection.day)
          in
          let pages =
            if scan.root_priority_pending
            then pages
            else
              Rrbvec.filter
                (fun (p : Projection.page) -> Some p.day <> scan.root_skipped_day)
                pages
          in
          scan.root_queued <- pages;
          (* Catalog progress includes Today, even when the feed continuation skips it. *)
          Rrbvec.iter
            (fun (i : Worker_pure_data.journal_item) ->
               if Option.fold ~none:true ~some:(fun day -> i.journal_day < day)
                    scan.root_journal_boundary
               then (
                 scan.root_journal_boundary <- Some i.journal_day;
                 Hashtbl.reset scan.root_journal_boundary_pages);
               if scan.root_journal_boundary = Some i.journal_day
               then
                 Hashtbl.replace
                   scan.root_journal_boundary_pages
                   (Graph.Uuid.to_string i.page.uuid)
                   ())
            items;
          scan.root_journal_cursor <- next_cursor;
          scan.root_journals_done <- next_cursor = None;
          if scan.root_priority_pending
          then (
            scan.root_priority_pending <- false;
            match
              Rrbvec.find_opt
                (fun (p : Projection.page) -> Some p.day = scan.root_skipped_day)
                pages
            with
            | Some today ->
              scan.root_queued
              <- Rrbvec.push_front (Rrbvec.filter (fun (p : Projection.page) -> p.day <> today.day) pages) today;
              next_feed_batch t ~ports scan
            | None
              when next_cursor <> None
                   && Rrbvec.for_all
                        (fun (p : Projection.page) ->
                           Option.fold
                             ~none:false
                             ~some:(fun day -> p.day > day)
                             scan.root_skipped_day)
                        pages -> read_priority_today ~ports scan
            | None -> next_feed_batch t ~ports scan)
          else next_feed_batch t ~ports scan)
      | Root_today (scan, params), Worker.Timeline_read {query=Paging.Dates _;_}, Ok packet ->
        Hashtbl.replace scan.root_proofs
          (Dates_scope (params.from_day, params.through_day))
          (Paging.Receipt packet.receipt);
        let items = packet.items in
        ports.observe_packet (Dates (Rrbvec.to_seq items));
        let today =
          Rrbvec.filter_map
            (fun (i : Worker_pure_data.journal_item) -> ports.project_journal_page i.page)
            items
        in
        scan.root_queued <- Rrbvec.append today scan.root_queued;
        next_feed_batch t ~ports scan
     | Root_tree batch, Worker.Timeline_read {query=Paging.Roots _;_}, Ok packet ->
       ports.observe_packet (Roots (Rrbvec.to_seq packet.items));
       receive_root_tree t ~ports batch packet
     | Root_preview preview, Worker.Timeline_read {query=Paging.Preview_children _;_}, Ok packet ->
       ports.observe_packet (Preview (Rrbvec.to_seq packet.items));
       receive_root_preview t ~ports preview packet
     | _, Worker.Timeline_read _, Error error -> paging_error t ~ports operation error
     | _ -> empty))
;;

let failed t ~ports operation ~code =
  let handles = match operation,code with
    | Root_dates (scan,_),Logseq_db_worker.Error.Response_too_large -> scan.root_list_size>1
    | Root_dates (scan,_),Logseq_db_worker.Error.Stale_read_cursor ->
      Option.is_some scan.root_journal_cursor && scan.root_date_retries<2
    | Root_tree batch,Logseq_db_worker.Error.Response_too_large -> batch.root_limit>1
    | Root_preview preview,Logseq_db_worker.Error.Response_too_large -> preview.preview_limit>1
    | _ -> false in
  if not handles then None else Some (match operation,code with
     | Root_dates (scan, _), Logseq_db_worker.Error.Stale_read_cursor ->
       if not (root_owner_current t (Feed_roots scan)) then empty else (
         scan.root_date_retries <- scan.root_date_retries + 1;
         Option.iter (fun day -> scan.root_journal_through <- day) scan.root_journal_boundary;
         scan.root_journal_cursor <- None;
         read_root_dates ~ports scan)
     | Root_dates (scan, _), Logseq_db_worker.Error.Response_too_large when scan.root_list_size>1 ->
       scan.root_list_size <- max 1 (scan.root_list_size/2);
       (* Resize from the inclusive catalog boundary and deduplicate only
          identities already observed at that boundary. *)
       Option.iter (fun day -> scan.root_journal_through <- day) scan.root_journal_boundary;
       scan.root_journal_cursor <- None;
       read_root_dates ~ports scan
     | Root_tree batch, Logseq_db_worker.Error.Response_too_large when batch.root_limit>1 ->
       let limit=max 1 (batch.root_limit/2) in
       (match batch.root_owner with Feed_roots scan->scan.root_page_size<-limit | _->());
       continue_root_batch t ~ports batch.root_owner batch.root_page batch.root_cursor limit
     | Root_preview preview, Logseq_db_worker.Error.Response_too_large when preview.preview_limit>1 ->
       requests [read_root_preview ~ports {preview with preview_limit=max 1 (preview.preview_limit/2);
         preview_members=Rrbvec.empty;preview_cursor=None}]
  | _ -> empty)
;;
let load_feed t ~ports ~cursor ~root_limit ~day_limit ~request_generation =
  start_feed_scan t ~ports ~cursor ~root_limit ~day_limit ~request_generation ()
let load_day t ~ports ~page ~after ~limit ~request_generation =
  let day_limit = Option.fold ~none:7 ~some:snd t.initial_feed_spec in
  let revoked = Option.exists (fun session -> Result.is_error (ports.validate_session session)) t.session in
  if Option.is_some after && (revoked || not (retained_page t page.Projection.id)) then
    responses [Failed {scope=Day {day=page.day;request_generation};stale_cursor=true;cause=None;
      message="The retained Timeline continuation was revoked."}]
  else (
  if after = None then drop_page t page.id;
  start_feed_scan t ~ports
    ~cursor:(Hashtbl.find_opt t.root_page_following_days page.Projection.id |> Option.join)
    ~root_limit:limit ~day_limit ~request_generation ~after:(page,after) ())
let has_initial_feed t = Option.is_some t.initial_feed_spec
let refresh_initial t ~ports ~request_generation =
  Option.map (fun (root_limit,day_limit) -> start_feed_scan t ~ports ~cursor:None ~root_limit ~day_limit ~request_generation ~reuse:true ())
    t.initial_feed_spec
let reconcile_page t ~ports ~page ~limit =
  match Graph.Uuid.of_string page.Projection.id with
  | Error _ -> None
  | Ok _ -> read_changed_roots t ~ports page limit |> Result.to_option
