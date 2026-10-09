module Asset = Logseq_db_types.Asset_descriptor
module Graph = Logseq_db_types.Graph_types
module Transfer = Logseq_db_worker_lui.Logseq_db_worker_lui_service.Asset

type reason =
  | Recent
  | Favorites

type settings = int

let settings ~recent_days =
  if recent_days >= 0 && recent_days <= 3660
  then Ok recent_days
  else Error "Recent days must be between 0 and 3660"
;;

let default_settings = 7

let previous_day day =
  let candidate = day - 1 in
  if Journal_validation.is_journal_day candidate
  then candidate
  else (
    let year = day / 10000 in
    let month = day / 100 mod 100 in
    let year, month = if month = 1 then year - 1, 12 else year, month - 1 in
    let rec last n =
      let candidate = (year * 10000) + (month * 100) + n in
      if Journal_validation.is_journal_day candidate then candidate else last (n - 1)
    in
    last 31)
;;

let recent_interval days ~today =
  if days = 0 || not (Journal_validation.is_journal_day today)
  then None
  else (
    let rec subtract day remaining =
      if remaining = 0 || day <= 10101
      then day
      else subtract (previous_day day) (remaining - 1)
    in
    Some (subtract today (days - 1), today))
;;

type query =
  | Recent_roots of
      { from_day : int
      ; through_day : int
      ; cursor : Graph.Cursor.t option
      }
  | Favorite_roots of Graph.Cursor.t option
  | Assets of
      { roots : Graph.Uuid.t list
      ; cursor : Graph.Cursor.t option
      }

type ticket =
  { id : int
  ; graph_generation : int
  ; revision : int
  ; reason : reason
  ; query : query
  }

type instruction =
  | Read of ticket
  | Demand of
      { consumer : string
      ; priority : Transfer.priority
      ; assets : Asset.t list
      }
  | Release of string

type event =
  | Refresh of
      { graph_generation : int
      ; today : int
      ; settings : settings
      }
  | Resync
  | Roots_changed of Graph.Uuid.t list
  | Index_changed of reason
  | Dependencies_unavailable
  | Roots_loaded of ticket * Graph.Uuid.t list * Graph.Cursor.t option
  | Assets_loaded of ticket * Asset.t list * Graph.Cursor.t option
  | Read_failed of ticket
  | Demand_accepted of string
  | Backpressure of string
  | Capacity_available
  | Availability of
      { consumer : string
      ; asset : Graph.Uuid.t
      ; availability : Transfer.availability
      }
  | Visible of
      { consumer : string
      ; assets : Asset.t list
      }
  | Hidden of string
  | Shutdown

type progress =
  | Inactive
  | Enumerating
  | Paused
  | Complete
  | Failed

let page_size = 32

type pending_demand =
  { consumer : string
  ; assets : Asset.t list
  ; continuation : query option
  }

type phase =
  | Reading of ticket
  | Awaiting of pending_demand
  | Pressured of pending_demand
  | Finished
  | Broken

module Uuids = Set.Make (struct
    type t = Graph.Uuid.t

    let compare = Graph.Uuid.compare
  end)

module Batches = Map.Make (String)
module Names = Set.Make (String)

type batch =
  { roots : Graph.Uuid.t list
  ; consumers : Names.t
  }

type mode =
  | Full
  | Index of Uuids.t
  | Partial of query Rrbvec.t * int

type scan =
  { reason : reason
  ; enabled : bool
  ; dirty : bool
  ; root_query : query
  ; root_next : Graph.Cursor.t option
  ; committed : Names.t
  ; staged : Names.t
  ; phase : phase
  ; batches : batch Batches.t
  ; staged_batches : batch Batches.t
  ; replacing : Names.t
  ; mode : mode
  ; changed_roots : Uuids.t
  ; index_dirty : bool
  ; known_roots : Uuids.t
  }

type visible =
  { name : string
  ; consumer : string
  ; assets : Asset.t list
  ; pressured : bool
  }

module Consumers = Map.Make (String)

module Versions = Map.Make (struct
    type t = Graph.Uuid.t

    let compare = compare
  end)

type residency =
  { ready : bool
  ; failed : bool
  }

type t =
  { configuration : (int * int * settings) option
  ; graph_generation : int option
  ; revision : int
  ; serial : int
  ; scans : scan list
  ; visible : visible list
  ; residency : residency Versions.t Consumers.t
  ; ready_owners : int Versions.t
  }

let empty =
  { configuration = None
  ; graph_generation = None
  ; revision = 0
  ; serial = 0
  ; scans = []
  ; visible = []
  ; residency = Consumers.empty
  ; ready_owners = Versions.empty
  }
;;

let progress state reason =
  match List.find_opt (fun (scan : scan) -> scan.reason = reason) state.scans with
  | None -> Inactive
  | Some scan ->
    (match scan.phase with
     | Reading _ | Awaiting _ -> Enumerating
     | Pressured _ -> Paused
     | Finished -> Complete
     | Broken -> Failed)
;;

let managed assets =
  List.filter
    (fun (asset : Asset.t) ->
       match asset.source with
       | Managed _ -> true
       | External _ -> false)
    assets
;;

let demand (pending : pending_demand) =
  Demand
    { consumer = pending.consumer
    ; priority = Transfer.Background
    ; assets = pending.assets
    }
;;

let releases consumers =
  Names.fold (fun consumer instructions -> Release consumer :: instructions) consumers []
;;

let with_scan state scan =
  { state with
    scans =
      scan :: List.filter (fun (other : scan) -> other.reason <> scan.reason) state.scans
  }
;;

let issue state scan query =
  let ticket =
    { id = state.serial
    ; graph_generation = Option.get state.graph_generation
    ; revision = state.revision
    ; reason = scan.reason
    ; query
    }
  in
  let state = { state with serial = state.serial + 1 } in
  with_scan state { scan with phase = Reading ticket }, [ Read ticket ]
;;

let batch_key roots = String.concat ":" (List.map Graph.Uuid.to_string roots)
let root_set roots = List.fold_left (fun set root -> Uuids.add root set) Uuids.empty roots

let batch_roots batches =
  Batches.fold
    (fun _ batch roots -> Uuids.union roots (root_set batch.roots))
    batches
    Uuids.empty
;;

let batch_consumers batches =
  Batches.fold (fun _ batch all -> Names.union batch.consumers all) batches Names.empty
;;

let finish state scan =
  let replaced, retained =
    Batches.partition (fun key _ -> Names.mem key scan.replacing) scan.batches
  in
  let batches =
    Batches.union (fun _ _ fresh -> Some fresh) retained scan.staged_batches
  in
  ( with_scan
      state
      { scan with
        committed = batch_consumers batches
      ; staged = Names.empty
      ; batches
      ; staged_batches = Batches.empty
      ; replacing = Names.empty
      ; phase = Finished
      ; known_roots =
          (match scan.mode with
           | Full -> batch_roots batches
           | Index _ | Partial _ -> scan.known_roots)
      }
  , releases (batch_consumers replaced) )
;;

let continue state scan = function
  | None -> finish state scan
  | Some query -> issue state scan query
;;

let root_continuation scan =
  match scan.mode with
  | Partial (queries, index) -> Rrbvec.nth_opt queries index
  | Full | Index _ ->
    Option.map
      (fun cursor ->
         match scan.root_query with
         | Recent_roots range -> Recent_roots { range with cursor = Some cursor }
         | Favorite_roots _ -> Favorite_roots (Some cursor)
         | Assets _ -> assert false)
      scan.root_next
;;

let continue_roots state scan =
  let query = root_continuation scan in
  let scan =
    match scan.mode with
    | Partial (queries, index) -> { scan with mode = Partial (queries, index + 1) }
    | _ -> scan
  in
  continue state scan query
;;

let current state ticket =
  List.find_opt
    (fun (scan : scan) ->
       match scan.phase with
       | Reading expected -> expected = ticket
       | _ -> false)
    state.scans
;;

let fail state scan =
  with_scan state { scan with staged = Names.empty; phase = Broken }, releases scan.staged
;;

let scope_releases state =
  let consumers =
    List.fold_left
      (fun consumers scan ->
         Names.union consumers (Names.union scan.committed scan.staged))
      Names.empty
      state.scans
  in
  releases
    (List.fold_left
       (fun consumers (visible : visible) -> Names.add visible.consumer consumers)
       consumers
       state.visible)
;;

let restart state scan =
  let cleanup = releases scan.staged in
  let scan =
    { scan with
      dirty = false
    ; root_next = None
    ; staged = Names.empty
    ; staged_batches = Batches.empty
    ; replacing =
        Batches.fold (fun key _ keys -> Names.add key keys) scan.batches Names.empty
    ; mode = Full
    ; changed_roots = Uuids.empty
    ; index_dirty = false
    }
  in
  let state, instructions =
    continue state scan (if scan.enabled then Some scan.root_query else None)
  in
  state, cleanup @ instructions
;;

let partial state scan roots =
  let selected =
    Batches.filter
      (fun _ batch -> not (Uuids.is_empty (Uuids.inter roots (root_set batch.roots))))
      scan.batches
  in
  if Batches.is_empty selected
  then with_scan state { scan with changed_roots = Uuids.empty }, []
  else (
    let replacing =
      Batches.fold (fun key _ keys -> Names.add key keys) selected Names.empty
    in
    let queries =
      Batches.fold
        (fun _ batch queries ->
           Rrbvec.append_list queries [ Assets { roots = batch.roots; cursor = None } ])
        selected
        Rrbvec.empty
    in
    let scan =
      { scan with
        staged = Names.empty
      ; staged_batches = Batches.empty
      ; replacing
      ; mode = Partial (queries, 0)
      ; changed_roots = Uuids.empty
      ; root_next = None
      }
    in
    continue_roots state scan)
;;

let index state scan =
  issue
    state
    { scan with
      mode = Index Uuids.empty
    ; root_next = None
    ; index_dirty = false
    ; staged = Names.empty
    ; staged_batches = Batches.empty
    ; replacing = Names.empty
    }
    scan.root_query
;;

let finish_or_changes state scan =
  let state, instructions = finish state scan in
  let scan = List.find (fun other -> other.reason = scan.reason) state.scans in
  let state, next =
    if scan.index_dirty then index state scan else partial state scan scan.changed_roots
  in
  state, instructions @ next
;;

let continue_scan state scan query =
  match query with
  | None -> finish_or_changes state scan
  | Some query -> issue state scan query
;;

let continue_scan_roots state scan =
  let query = root_continuation scan in
  let scan =
    match scan.mode with
    | Partial (queries, index) -> { scan with mode = Partial (queries, index + 1) }
    | _ -> scan
  in
  continue_scan state scan query
;;

let indexed state scan roots =
  let old_roots = batch_roots scan.batches in
  let removed = Uuids.diff old_roots roots in
  let added = Uuids.diff roots old_roots in
  let selected =
    Batches.filter
      (fun _ batch -> not (Uuids.is_empty (Uuids.inter removed (root_set batch.roots))))
      scan.batches
  in
  let replacing =
    Batches.fold (fun key _ keys -> Names.add key keys) selected Names.empty
  in
  let kept_queries =
    Batches.fold
      (fun _ batch queries ->
         let remaining = List.filter (fun root -> Uuids.mem root roots) batch.roots in
         if remaining = []
         then queries
         else Rrbvec.append_list queries [ Assets { roots = remaining; cursor = None } ])
      selected
      Rrbvec.empty
  in
  let rec chunks remaining queries =
    if Uuids.is_empty remaining
    then queries
    else (
      let batch, rest =
        Uuids.fold
          (fun root (batch, rest) ->
             if List.length batch < page_size
             then root :: batch, rest
             else batch, Uuids.add root rest)
          remaining
          ([], Uuids.empty)
      in
      chunks
        rest
        (Rrbvec.append_list queries [ Assets { roots = List.rev batch; cursor = None } ]))
  in
  let scan =
    { scan with
      replacing
    ; mode = Partial (Rrbvec.append kept_queries (chunks added Rrbvec.empty), 0)
    ; root_next = None
    ; known_roots = roots
    }
  in
  continue_scan_roots state scan
;;

let step_policy state = function
  | Shutdown ->
    ( { empty with serial = state.serial; revision = state.revision + 1 }
    , scope_releases state )
  | Refresh { graph_generation; today; settings }
    when state.configuration = Some (graph_generation, today, settings) -> state, []
  | Refresh { graph_generation; today; settings } ->
    let same_scope = state.graph_generation = Some graph_generation in
    let prior = if same_scope then state.scans else [] in
    let cleanup =
      if same_scope
      then
        releases
          (List.fold_left
             (fun consumers scan -> Names.union consumers scan.staged)
             Names.empty
             prior)
      else scope_releases state
    in
    let state =
      { state with
        configuration = Some (graph_generation, today, settings)
      ; graph_generation = Some graph_generation
      ; revision = state.revision + 1
      ; scans = []
      ; visible = (if same_scope then state.visible else [])
      }
    in
    List.fold_left
      (fun (state, instructions) reason ->
         let committed =
           match List.find_opt (fun (scan : scan) -> scan.reason = reason) prior with
           | None -> Names.empty
           | Some scan -> scan.committed
         in
         let query =
           match reason with
           | Favorites -> Some (Favorite_roots None)
           | Recent ->
             Option.map
               (fun (from_day, through_day) ->
                  Recent_roots { from_day; through_day; cursor = None })
               (recent_interval settings ~today)
         in
         let scan =
           { reason
           ; enabled = Option.is_some query
           ; dirty = false
           ; root_query = Option.value query ~default:(Favorite_roots None)
           ; root_next = None
           ; committed
           ; staged = Names.empty
           ; phase = Finished
           ; batches =
               (match List.find_opt (fun scan -> scan.reason = reason) prior with
                | None -> Batches.empty
                | Some scan -> scan.batches)
           ; staged_batches = Batches.empty
           ; replacing =
               (match List.find_opt (fun scan -> scan.reason = reason) prior with
                | None -> Names.empty
                | Some scan ->
                  Batches.fold
                    (fun key _ keys -> Names.add key keys)
                    scan.batches
                    Names.empty)
           ; mode = Full
           ; changed_roots = Uuids.empty
           ; index_dirty = false
           ; known_roots =
               (match List.find_opt (fun scan -> scan.reason = reason) prior with
                | None -> Uuids.empty
                | Some scan -> scan.known_roots)
           }
         in
         let state, next = continue state scan query in
         state, instructions @ next)
      (state, cleanup)
      [ Recent; Favorites ]
  | Resync ->
    let state = { state with revision = state.revision + 1 } in
    List.fold_left
      (fun (state, instructions) scan ->
         if not scan.enabled
         then state, instructions
         else (
           match scan.phase with
           | Reading _ | Awaiting _ ->
             let cleanup = releases scan.staged in
             let scan =
               { scan with dirty = true; root_next = None; staged = Names.empty }
             in
             with_scan state scan, instructions @ cleanup
           | Pressured _ | Finished | Broken ->
             let state, next = restart state scan in
             state, instructions @ next))
      (state, [])
      state.scans
  | Roots_changed roots ->
    let roots = root_set roots in
    List.fold_left
      (fun (state, instructions) scan ->
         let owned = scan.known_roots in
         let relevant = Uuids.inter roots owned in
         if Uuids.is_empty relevant
         then state, instructions
         else (
           let scan =
             { scan with changed_roots = Uuids.union scan.changed_roots relevant }
           in
           match scan.phase with
           | Finished | Broken ->
             let state, next = partial state scan scan.changed_roots in
             state, instructions @ next
           | Reading _ | Awaiting _ | Pressured _ -> with_scan state scan, instructions))
      (state, [])
      state.scans
  | Index_changed reason ->
    (match
       List.find_opt (fun scan -> scan.reason = reason && scan.enabled) state.scans
     with
     | None -> state, []
     | Some scan ->
       (match scan.phase with
        | Finished | Broken -> index state scan
        | Reading _ | Awaiting _ | Pressured _ ->
          with_scan state { scan with index_dirty = true }, []))
  | Dependencies_unavailable ->
    ( { state with
        scans =
          List.map
            (fun scan -> if scan.enabled then { scan with phase = Broken } else scan)
            state.scans
      }
    , [] )
  | Roots_loaded (ticket, roots, next_cursor) ->
    (match current state ticket with
     | None -> state, []
     | Some scan when scan.dirty -> restart state scan
     | Some scan ->
       if List.length roots > page_size
       then fail state scan
       else (
         match ticket.query with
         | Assets _ -> state, []
         | Recent_roots _ | Favorite_roots _ ->
           let scan = { scan with root_next = next_cursor } in
           (match scan.mode with
            | Index collected ->
              let collected = Uuids.union collected (root_set roots) in
              let scan = { scan with mode = Index collected } in
              (match next_cursor with
               | None -> indexed state scan collected
               | Some _ -> continue_scan_roots state scan)
            | Full | Partial _ ->
              if roots = []
              then continue_scan_roots state scan
              else (
                let key = batch_key roots in
                let scan =
                  { scan with
                    staged_batches =
                      Batches.add
                        key
                        { roots; consumers = Names.empty }
                        scan.staged_batches
                  ; known_roots = Uuids.union scan.known_roots (root_set roots)
                  }
                in
                issue state scan (Assets { roots; cursor = None })))))
  | Assets_loaded (ticket, assets, next_cursor) ->
    (match current state ticket with
     | None -> state, []
     | Some scan when scan.dirty -> restart state scan
     | Some scan ->
       if List.length assets > page_size
       then fail state scan
       else (
         match ticket.query with
         | Recent_roots _ | Favorite_roots _ -> state, []
         | Assets { roots; _ } ->
           let continuation =
             match next_cursor with
             | Some cursor -> Some (Assets { roots; cursor = Some cursor })
             | None -> root_continuation scan
           in
           let assets = managed assets in
           let key = batch_key roots in
           let existing =
             Option.value
               (Batches.find_opt key scan.staged_batches)
               ~default:{ roots; consumers = Names.empty }
           in
           let scan =
             { scan with staged_batches = Batches.add key existing scan.staged_batches }
           in
           if assets = []
           then (
             match next_cursor with
             | Some _ -> continue_scan state scan continuation
             | None -> continue_scan_roots state scan)
           else (
             let consumer =
               Printf.sprintf
                 "asset-policy:%d:%d:%d"
                 ticket.graph_generation
                 ticket.revision
                 ticket.id
             in
             let pending = { consumer; assets; continuation } in
             ( with_scan
                 state
                 { scan with
                   staged = Names.add consumer scan.staged
                 ; phase = Awaiting pending
                 ; staged_batches =
                     Batches.add
                       key
                       { existing with consumers = Names.add consumer existing.consumers }
                       scan.staged_batches
                 }
             , [ demand pending ] ))))
  | Read_failed ticket ->
    (match current state ticket with
     | None -> state, []
     | Some scan -> if scan.dirty then restart state scan else fail state scan)
  | Demand_accepted consumer ->
    (match
       List.find_opt
         (fun scan ->
            match scan.phase with
            | Awaiting p | Pressured p -> p.consumer = consumer
            | _ -> false)
         state.scans
     with
     | None ->
       ( { state with
           visible =
             List.map
               (fun (v : visible) ->
                  if v.consumer = consumer then { v with pressured = false } else v)
               state.visible
         }
       , [] )
     | Some scan when scan.dirty -> restart state scan
     | Some scan ->
       (match scan.phase with
        | Awaiting p | Pressured p ->
          (match p.continuation with
           | Some (Assets { cursor = Some _; _ }) ->
             continue_scan state scan p.continuation
           | _ -> continue_scan_roots state scan)
        | _ -> assert false))
  | Backpressure consumer ->
    let state =
      { state with
        visible =
          List.map
            (fun (v : visible) ->
               if v.consumer = consumer then { v with pressured = true } else v)
            state.visible
      }
    in
    List.fold_left
      (fun (state, instructions) scan ->
         match scan.phase with
         | Awaiting p when p.consumer = consumer ->
           if scan.dirty
           then (
             let state, next = restart state scan in
             state, instructions @ next)
           else with_scan state { scan with phase = Pressured p }, instructions
         | _ -> state, instructions)
      (state, [])
      state.scans
  | Capacity_available ->
    let visible_instructions =
      List.filter_map
        (fun (v : visible) ->
           if v.pressured
           then
             Some
               (Demand { consumer = v.consumer; priority = Foreground; assets = v.assets })
           else None)
        state.visible
    in
    let state =
      { state with
        visible =
          List.map (fun (v : visible) -> { v with pressured = false }) state.visible
      }
    in
    List.fold_left
      (fun (state, instructions) scan ->
         match scan.phase with
         | Pressured pending ->
           ( with_scan state { scan with phase = Awaiting pending }
           , instructions @ [ demand pending ] )
         | _ -> state, instructions)
      (state, visible_instructions)
      state.scans
  | Availability _ -> state, []
  | Visible { consumer = name; assets } ->
    (match state.graph_generation with
     | None -> state, []
     | Some generation ->
       let consumer = Printf.sprintf "asset-visible:%d:%s" generation name in
       let assets = managed assets in
       let visible =
         { name; consumer; assets; pressured = false }
         :: List.filter (fun (v : visible) -> v.name <> name) state.visible
       in
       { state with visible }, [ Demand { consumer; priority = Foreground; assets } ])
  | Hidden name ->
    let selected, visible =
      List.partition (fun (v : visible) -> v.name = name) state.visible
    in
    ( { state with visible }
    , releases
        (List.fold_left
           (fun consumers (v : visible) -> Names.add v.consumer consumers)
           Names.empty
           selected) )
;;

let update_ready_owners ready_owners versions delta =
  Versions.fold
    (fun uuid resident counts ->
       if not resident.ready
       then counts
       else
         Versions.update
           uuid
           (fun current ->
              let count = Option.value current ~default:0 + delta in
              if count <= 0 then None else Some count)
           counts)
    versions
    ready_owners
;;

let replace_residency state consumer versions =
  let previous =
    Option.value (Consumers.find_opt consumer state.residency) ~default:Versions.empty
  in
  let ready_owners = update_ready_owners state.ready_owners previous (-1) in
  let ready_owners = update_ready_owners ready_owners versions 1 in
  { state with residency = Consumers.add consumer versions state.residency; ready_owners }
;;

let register state consumer assets =
  let previous =
    Option.value (Consumers.find_opt consumer state.residency) ~default:Versions.empty
  in
  let versions =
    Rrbvec.fold_left
      (fun versions (asset : Asset.t) ->
         match asset.source with
         | External _ -> versions
         | Managed _ ->
           let resident =
             match Versions.find_opt asset.uuid previous with
             | Some resident -> resident
             | None ->
               { ready = Versions.mem asset.uuid state.ready_owners; failed = false }
           in
           Versions.add asset.uuid resident versions)
      Versions.empty
      (Rrbvec.of_list assets)
  in
  replace_residency state consumer versions
;;

let step state event =
  let state =
    match event with
    | Availability { consumer; asset; availability } ->
      (match Consumers.find_opt consumer state.residency with
       | None -> state
       | Some versions ->
         let versions =
           Versions.update
             asset
             (Option.map (fun _ ->
                match availability with
                | Transfer.Ready _ -> { ready = true; failed = false }
                | Failed _ -> { ready = false; failed = true }
                | Queued | Downloading | Waiting_remote | Waiting_network | Waiting_unlock
                  -> { ready = false; failed = false }))
             versions
         in
         replace_residency state consumer versions)
    | _ -> state
  in
  let state, instructions = step_policy state event in
  let state =
    List.fold_left
      (fun state -> function
         | Demand { consumer; assets; _ } -> register state consumer assets
         | Release consumer ->
           let previous =
             Option.value
               (Consumers.find_opt consumer state.residency)
               ~default:Versions.empty
           in
           { state with
             residency = Consumers.remove consumer state.residency
           ; ready_owners = update_ready_owners state.ready_owners previous (-1)
           }
         | Read _ -> state)
      state
      instructions
  in
  state, instructions
;;

type offline =
  { enumeration : progress
  ; total : int
  ; ready : int
  ; failed : int
  }

let offline state reason =
  let consumers =
    match List.find_opt (fun (scan : scan) -> scan.reason = reason) state.scans with
    | None -> Names.empty
    | Some scan ->
      (match scan.phase with
       | Finished -> scan.committed
       | _ -> Names.union scan.committed scan.staged)
  in
  let versions =
    Names.fold
      (fun consumer versions ->
         match Consumers.find_opt consumer state.residency with
         | None -> versions
         | Some current ->
           Versions.union
             (fun _ (a : residency) (b : residency) ->
                Some { ready = a.ready && b.ready; failed = a.failed || b.failed })
             versions
             current)
      consumers
      Versions.empty
  in
  Versions.fold
    (fun _ (resident : residency) status ->
       { status with
         total = status.total + 1
       ; ready = (status.ready + if resident.ready then 1 else 0)
       ; failed = (status.failed + if resident.failed then 1 else 0)
       })
    versions
    { enumeration = progress state reason; total = 0; ready = 0; failed = 0 }
;;

let roots state reason =
  match List.find_opt (fun scan -> scan.reason = reason) state.scans with
  | None -> Seq.empty
  | Some scan -> Uuids.to_seq scan.known_roots
;;
