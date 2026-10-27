module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Projection = Journal_graph_projection

type day_feed =
  { page : Projection.page
  ; entries : Projection.timeline_entry Rrbvec.t
  ; has_more_entries : bool
  ; continuation : Projection.block_cursor option
  }

type feed_scan =
  { root_session : int64
  ; root_generation : int64
  ; root_start_day : int option
  ; mutable root_before_day : int option
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
  ; mutable root_journal_cursor : Graph.Cursor.t option
  ; mutable root_journal_boundary : int option
  ; mutable root_date_retries : int
  ; mutable root_journals_done : bool
  }

type root_refresh =
  { mutable refresh_remaining : int
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
  ; root_page : Projection.page
  ; root_epoch : int64
  ; root_limit : int
  ; root_cursor : Graph.Cursor.t option
  ; root_next : Graph.Cursor.t option
  ; root_members : Projection.tree_member Rrbvec.t
  ; root_todo : Projection.tree_member Rrbvec.t
  }

type root_preview =
  { preview_batch : root_batch
  ; preview_root : Projection.tree_member
  ; preview_members : Projection.tree_member Rrbvec.t
  ; preview_cursor : Graph.Cursor.t option
  ; preview_limit : int
  ; preview_revision : string option
  ; preview_retries : int
  }

type operation = Root_dates of feed_scan | Root_today of feed_scan
  | Root_tree of root_batch | Root_preview of root_preview
type failure_scope = Feed of int64 | Day of { day : int; request_generation : int64 } | Reconciliation
type publication =
  | Loaded of { request_generation : int64; feed : Projection.feed; complete : bool }
  | Reconciled of { page : Projection.page; value : Projection.timeline_entry_page }
  | Failed of { scope : failure_scope; stale_cursor : bool; message : string }
type output = { requests : Protocol.request Rrbvec.t; publications : publication Rrbvec.t }
type packet = Dates of Protocol.v2_journal_item Seq.t | Roots of Protocol.v2_tree_member Seq.t
  | Preview of Protocol.v2_child_member Seq.t
type fragment = { page : Projection.page; members : Projection.tree_member Rrbvec.t
  ; entries : Projection.timeline_entry Rrbvec.t }
type context = { today : int option; time_context : (Projection.time_context, string) result }
type ports =
  { now : unit -> int64
  ; plan_read : operation -> Protocol.command -> Protocol.request
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
  ; root_pages : (string, unit) Hashtbl.t
  ; root_page_epochs : (string, int64) Hashtbl.t
  ; root_page_counts : (string, int) Hashtbl.t
  ; root_page_following_days : (string, Projection.feed_cursor option) Hashtbl.t
  }
let empty = { requests = Rrbvec.empty; publications = Rrbvec.empty }
let requests values = { empty with requests = Rrbvec.of_list values }
let responses values = { empty with publications = Rrbvec.of_list values }
let response value = value
let feed_failure request_generation message = responses [Failed { scope = Feed request_generation; stale_cursor = false; message }]
let day_failure ~day request_generation message = responses [Failed { scope = Day {day;request_generation}; stale_cursor = false; message }]
let reject message = responses [Failed { scope = Reconciliation; stale_cursor = false; message }]
let create () =
  { initial_feed_spec = None
  ; feed_session = 0L
  ; root_pages = Hashtbl.create 32
  ; root_page_epochs = Hashtbl.create 32
  ; root_page_counts = Hashtbl.create 32
  ; root_page_following_days = Hashtbl.create 32
  }
let reset t ~now =
  Hashtbl.clear t.root_pages;
  Hashtbl.clear t.root_page_epochs;
  Hashtbl.clear t.root_page_counts;
  Hashtbl.clear t.root_page_following_days;
  t.initial_feed_spec <- None;
  t.feed_session <- now ()
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
  | Changed_roots _ -> true
;;

let root_batch_current t batch =
  root_owner_current t batch.root_owner
  && Option.value
       (Hashtbl.find_opt t.root_page_epochs batch.root_page.Projection.id)
       ~default:0L
     = batch.root_epoch
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

let superseded_root_batch t batch =
  match batch.root_owner with
  | Feed_roots scan when root_owner_current t batch.root_owner ->
    (match scan.root_start_day with
     | None ->
       feed_failure
         scan.root_generation
         "The Timeline changed while loading. Retry to read the current prefix."
     | Some day ->
       responses
         [ response
             (Failed { scope = Day { day; request_generation = scan.root_generation };
                   stale_cursor = true; message = "The root read was superseded by a refresh." })
         ])
  | Feed_roots _ | Changed_roots _ -> empty
;;

let read_root_batch t ~ports owner (page : Projection.page) cursor limit =
  Hashtbl.replace t.root_pages page.id ();
  ports.retain_root_interest page ~minimum_limit:limit;
  let epoch = Option.value (Hashtbl.find_opt t.root_page_epochs page.id) ~default:0L in
  let batch =
    { root_owner = owner
    ; root_page = page
    ; root_epoch = epoch
    ; root_limit = limit
    ; root_cursor = cursor
    ; root_next = None
    ; root_members = Rrbvec.empty
    ; root_todo = Rrbvec.empty
    }
  in
  let request =
    ports.plan_read
      (Root_tree batch)
      (Protocol.V2_get_page_tree
         { page = Graph.Uuid.of_string page.id |> Result.get_ok
         ; maximum_depth = 0
         ; limit
         ; cursor
         ; revision = None
         })
  in
  (match owner with
   | Feed_roots scan ->
     ports.report
       "runtime-feed-tree-request"
       [ "request", `String (Graph.Uuid.to_string request.request_id)
       ; "requestGeneration", `String (Int64.to_string scan.root_generation)
       ; "target", timeline_uuid page.id
       ; "day", `Int page.day
       ; "limit", `Int limit
       ; "maximumDepth", `Int 0
       ; "hasContinuation", `Bool (Option.is_some cursor)
       ; "kind", `String "roots"
       ]
   | Changed_roots _ -> ());
  request
;;

let read_changed_roots t ~ports page limit =
  (* One invalidation owns both the retained suffix and its concurrent feed
     prefix. Only a newer invalidation fences their shared page observation. *)
  Hashtbl.replace t.root_page_epochs page.Projection.id (ports.now ());
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
       { refresh_remaining = target
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
  let request =
    ports.plan_read
      (Root_dates scan)
      (Protocol.V2_list_journals
         { from_day = 0
         ; through_day =
             Option.fold ~none:99_999_999 ~some:previous_journal_day scan.root_before_day
         ; limit = scan.root_list_size
         ; cursor = scan.root_journal_cursor
         ; revision = None
         })
  in
  ports.report
    "runtime-feed-request"
    [ "request", `String (Graph.Uuid.to_string request.request_id)
    ; "requestGeneration", `String (Int64.to_string scan.root_generation)
    ; "beforeDay", Option.fold ~none:`Null ~some:(fun d -> `Int d) scan.root_before_day
    ; "dayLimit", `Int scan.root_list_size
    ; "rootRemaining", `Int scan.root_remaining
    ; "hasContinuation", `Bool (Option.is_some scan.root_journal_cursor)
    ; "kind", `String "date-catalog"
    ];
  request
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
  let today = Option.get scan.root_skipped_day in
  let request =
    ports.plan_read
      (Root_today scan)
      (Protocol.V2_list_journals
         { from_day = today
         ; through_day = today
         ; limit = 1
         ; cursor = None
         ; revision = None
         })
  in
  ports.report
    "runtime-feed-request"
    [ "request", `String (Graph.Uuid.to_string request.request_id)
    ; "requestGeneration", `String (Int64.to_string scan.root_generation)
    ; "day", `Int today
    ; "dayLimit", `Int 1
    ; "rootRemaining", `Int scan.root_remaining
    ; "hasContinuation", `Bool false
    ; "kind", `String "priority-today"
    ];
  request
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
let next_feed_batch t ~ports scan =
  if not (root_owner_current t (Feed_roots scan))
  then empty
  else if scan.root_remaining = 0
  then responses [ root_feed_response ~ports scan true ]
  else (
    match Rrbvec.pop_front scan.root_queued with
    | Some (page, rest) ->
      scan.root_queued <- rest;
      requests
        [ read_root_batch t ~ports
            (Feed_roots scan)
            page
            None
            (min scan.root_page_size scan.root_remaining)
        ]
    | None when scan.root_journals_done -> responses [ root_feed_response ~ports scan true ]
    | None -> requests [ read_root_dates ~ports scan ])
;;

let complete_root_batch t ~ports batch =
  if not (root_batch_current t batch)
  then empty
  else (
    match (ports.context ()).time_context with
    | Error message -> root_failure batch message
    | Ok time_context ->
      (match
         Projection.timeline_entry_page
           ~tag_titles:ports.tag_titles
           ~page:batch.root_page
           ~time_context
           Graph.{ items = Rrbvec.to_list batch.root_members; continuation = batch.root_next }
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
                 requests
                   [ read_root_batch t ~ports
                       batch.root_owner
                       batch.root_page
                       (Some cursor)
                       (if refresh.refresh_remaining > 0
                        then min batch.root_limit refresh.refresh_remaining
                        else 1)
                   ]
             | None | Some _ ->
               Hashtbl.replace
                 t.root_page_counts
                 batch.root_page.id
                 refresh.refresh_consumed;
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
            scan.root_days
            <- (match previous with
                | None when Rrbvec.is_empty day.entries -> scan.root_days
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
                  requests
                    [ read_root_batch t ~ports
                        batch.root_owner
                        batch.root_page
                        (Some cursor)
                        (min scan.root_page_size scan.root_remaining)
                    ]
              | None | Some _ -> next_feed_batch t ~ports scan
            in
            if Rrbvec.is_empty next.publications && scan.root_publish_partial && not (Rrbvec.is_empty scan.root_days)
            then { next with publications = Rrbvec.singleton (root_feed_response ~ports scan false) }
            else next)))
;;

let read_root_preview ~ports preview =
  let request =
    ports.plan_read
      (Root_preview preview)
      (Protocol.V2_get_children
         { parent = preview.preview_root.block.uuid
         ; limit = preview.preview_limit
         ; cursor = preview.preview_cursor
         ; revision = None
         })
  in
  (match preview.preview_batch.root_owner with
   | Feed_roots scan ->
     ports.report
       "runtime-feed-tree-request"
       [ "request", `String (Graph.Uuid.to_string request.request_id)
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
    | None -> complete_root_batch t ~ports batch
    | Some (root, rest) ->
      let preview =
        { preview_batch = { batch with root_todo = rest }
        ; preview_root = root
        ; preview_members = Rrbvec.empty
        ; preview_cursor = None
        ; preview_limit = 3
        ; preview_revision = None
        ; preview_retries = 0
        }
      in
      requests [ read_root_preview ~ports preview ])
;;

let receive_root_tree t ~ports batch items next_cursor =
  let items = Rrbvec.of_list items in
  if not (root_batch_current t batch)
  then empty
  else if
    Rrbvec.exists
      (fun (m : Protocol.v2_tree_member) ->
         m.depth <> 0
         || Graph.Uuid.to_string m.value.block.page <> batch.root_page.id
         || Graph.Uuid.to_string m.value.block.parent <> batch.root_page.id)
      items
  then root_failure batch "The root query returned a foreign or nested block."
  else (
    let members =
      Rrbvec.map
        (fun (m : Protocol.v2_tree_member) ->
           Projection.{ block = m.value.block; revision = m.revision; depth = 0 })
        items
    in
    match (ports.context ()).time_context with
    | Error message -> root_failure batch message
    | Ok time_context ->
      (match
         Projection.timeline_entry_page
           ~tag_titles:ports.tag_titles
           ~page:batch.root_page
           ~time_context
           Graph.{ items = Rrbvec.to_list members; continuation = None }
       with
       | Error message -> root_failure batch message
       | Ok projected ->
         let ids =
           Rrbvec.map
             (fun (e : Projection.timeline_entry) -> Journal_model.id e.block)
             (Rrbvec.of_list projected.entries)
         in
         let todo =
           Rrbvec.filter
             (fun (m : Projection.tree_member) ->
                Rrbvec.exists (String.equal (Graph.Uuid.to_string m.block.uuid)) ids)
             members
         in
         next_root_preview t ~ports
           { batch with
             root_members = members
           ; root_todo = todo
           ; root_next = next_cursor
           }))
;;

let receive_root_preview t ~ports preview parent revision items next_cursor =
  let items = Rrbvec.of_list items in
  let batch = preview.preview_batch in
  if not (root_batch_current t batch)
  then empty
  else if
    (not (Graph.Uuid.equal parent preview.preview_root.block.uuid))
    || Rrbvec.exists
         (fun (m : Protocol.v2_child_member) ->
            (not (Graph.Uuid.equal m.value.block.parent parent))
            || Graph.Uuid.to_string m.value.block.page <> batch.root_page.id)
         items
  then root_failure batch "The preview query returned a foreign child."
  else if
    Option.is_some preview.preview_revision && preview.preview_revision <> Some revision
  then
    if preview.preview_retries >= 2
    then root_failure batch "The preview changed repeatedly while loading."
    else
      requests
        [ read_root_preview ~ports
            { preview with
              preview_members = Rrbvec.empty
            ; preview_cursor = None
            ; preview_revision = None
            ; preview_retries = preview.preview_retries + 1
            }
        ]
  else (
    let members =
      Rrbvec.append preview.preview_members
        (Rrbvec.map
          (fun (m : Protocol.v2_child_member) ->
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
                   ; preview_revision = Some revision
                   ; preview_limit = min preview.preview_limit (3 - count)
                   }
               ]
         else
           next_root_preview t ~ports { batch with root_members = Rrbvec.append batch.root_members selected }))
;;

let start_feed_scan t ~ports ~cursor ~root_limit ~day_limit ~request_generation ?after () =
  let before_day = Option.bind cursor (fun c -> c.Projection.before_day) in
  let start_day = Option.map (fun ((page : Projection.page), _) -> page.day) after in
  if root_limit <= 0 || day_limit <= 0
  then (
    match start_day with
    | None ->
      feed_failure request_generation "The root and date packet limits must be positive."
    | Some day -> day_failure ~day request_generation "The root limit must be positive.")
  else (
    t.feed_session <- ports.now ();
    if cursor = None && after = None
    then t.initial_feed_spec <- Some (root_limit, day_limit);
    let scan =
      { root_session = t.feed_session
      ; root_generation = request_generation
      ; root_start_day = start_day
      ; root_before_day = before_day
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
      ; root_page_size = min root_limit Protocol.maximum_page_size
      ; root_list_size = min day_limit Protocol.maximum_page_size
      ; root_days = Rrbvec.empty
      ; root_queued = Rrbvec.empty
      ; root_journal_cursor = None
      ; root_journal_boundary = before_day
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
      requests
        [ read_root_batch t ~ports
            (Feed_roots scan)
            page
            (Option.bind cursor (fun c -> c.Projection.protocol_cursor))
            scan.root_page_size
        ])
;;
let failure_scope = function
  | Root_dates scan | Root_today scan ->
    (match scan.root_start_day with None -> Feed scan.root_generation
       | Some day -> Day {day;request_generation=scan.root_generation})
  | Root_tree batch | Root_preview {preview_batch=batch;_} ->
    (match batch.root_owner with Changed_roots _ -> Reconciliation
     | Feed_roots scan -> match scan.root_start_day with None -> Feed scan.root_generation
       | Some day -> Day {day;request_generation=scan.root_generation})
;;
let operation_name = function Root_dates _ | Root_today _ -> "listTimelineDates"
  | Root_tree _ -> "readTimelineRoots" | Root_preview _ -> "readTimelinePreview"
let is_current t = function Root_dates scan | Root_today scan -> root_owner_current t (Feed_roots scan)
  | Root_tree batch -> root_batch_current t batch
  | Root_preview preview -> root_batch_current t preview.preview_batch
let superseded t = function Root_dates _ | Root_today _ -> empty
  | Root_tree batch -> superseded_root_batch t batch
  | Root_preview preview -> superseded_root_batch t preview.preview_batch
let handles operation outcome = match operation,outcome with
  | (Root_dates _ | Root_today _), Protocol.V2_journals_outcome _
  | Root_tree _, Protocol.V2_page_tree_outcome _
  | Root_preview _, Protocol.V2_children_outcome _ -> true
  | Root_dates scan, Protocol.V2_failed {code="responseTooLarge";_} -> scan.root_list_size > 1
  | Root_dates scan, Protocol.V2_failed {code="staleReadCursor";_} ->
    Option.is_some scan.root_journal_cursor && scan.root_date_retries < 2
  | Root_tree batch, Protocol.V2_failed {code="responseTooLarge";_} -> batch.root_limit > 1
  | Root_preview preview, Protocol.V2_failed {code="responseTooLarge";_} -> preview.preview_limit > 1
  | _ -> false
let receive t ~ports operation outcome =
  if not (handles operation outcome) then None else Some (match operation,outcome with
      | Root_dates scan, Protocol.V2_journals_outcome { items; next_cursor } ->
        ports.observe_packet (Dates (List.to_seq items));
        let items = Rrbvec.of_list items in
        if next_cursor <> None && next_cursor = scan.root_journal_cursor
        then scan_failure scan "The date cursor did not advance."
        else (
          let pages =
            Rrbvec.filter_map
              (fun (i : Protocol.v2_journal_item) -> ports.project_journal_page i.page)
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
          scan.root_journal_boundary <-
            Rrbvec.fold_left
              (fun boundary (item : Protocol.v2_journal_item) ->
                 Some (Option.fold ~none:item.journal_day ~some:(min item.journal_day) boundary))
              scan.root_journal_boundary items;
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
                        pages -> requests [ read_priority_today ~ports scan ]
            | None -> next_feed_batch t ~ports scan)
          else next_feed_batch t ~ports scan)
      | Root_today scan, Protocol.V2_journals_outcome { items; _ } ->
        ports.observe_packet (Dates (List.to_seq items));
        let items = Rrbvec.of_list items in
        let today =
          Rrbvec.filter_map
            (fun (i : Protocol.v2_journal_item) -> ports.project_journal_page i.page)
            items
        in
        scan.root_queued <- Rrbvec.append today scan.root_queued;
        next_feed_batch t ~ports scan
     | Root_tree batch, V2_page_tree_outcome {items;next_cursor;_} ->
       ports.observe_packet (Roots (List.to_seq items));
       receive_root_tree t ~ports batch items next_cursor
     | Root_preview preview, V2_children_outcome {parent;scope_revision;items;next_cursor;_} ->
       ports.observe_packet (Preview (List.to_seq items));
       receive_root_preview t ~ports preview parent scope_revision items next_cursor
     | Root_dates scan, V2_failed {code="staleReadCursor";_} ->
       if not (root_owner_current t (Feed_roots scan)) then empty else (
         scan.root_date_retries <- scan.root_date_retries + 1;
         scan.root_before_day <- scan.root_journal_boundary;
         scan.root_journal_cursor <- None;
         requests [read_root_dates ~ports scan])
     | Root_dates scan, V2_failed {code="responseTooLarge";_} when scan.root_list_size>1 ->
       scan.root_list_size <- max 1 (scan.root_list_size/2);requests [read_root_dates ~ports scan]
     | Root_tree batch, V2_failed {code="responseTooLarge";_} when batch.root_limit>1 ->
       let limit=max 1 (batch.root_limit/2) in
       (match batch.root_owner with Feed_roots scan->scan.root_page_size<-limit | _->());
       requests [read_root_batch t ~ports batch.root_owner batch.root_page batch.root_cursor limit]
     | Root_preview preview, V2_failed {code="responseTooLarge";_} when preview.preview_limit>1 ->
       requests [read_root_preview ~ports {preview with preview_limit=max 1 (preview.preview_limit/2)}]
  | _ -> empty)
;;
let load_feed t ~ports ~cursor ~root_limit ~day_limit ~request_generation =
  start_feed_scan t ~ports ~cursor ~root_limit ~day_limit ~request_generation ()
let load_day t ~ports ~page ~after ~limit ~request_generation =
  let day_limit = Option.fold ~none:7 ~some:snd t.initial_feed_spec in
  start_feed_scan t ~ports
    ~cursor:(Hashtbl.find_opt t.root_page_following_days page.Projection.id |> Option.join)
    ~root_limit:limit ~day_limit ~request_generation ~after:(page,after) ()
let has_initial_feed t = Option.is_some t.initial_feed_spec
let refresh_initial t ~ports ~request_generation =
  Option.map (fun (root_limit,day_limit) -> load_feed t ~ports ~cursor:None ~root_limit ~day_limit ~request_generation)
    t.initial_feed_spec
let reconcile_retained t ~ports ~page ~limit =
  if Hashtbl.mem t.root_pages page.Projection.id then Some (read_changed_roots t ~ports page limit) else None
