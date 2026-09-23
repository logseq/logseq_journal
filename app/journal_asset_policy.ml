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

type scan =
  { reason : reason
  ; root_query : query
  ; root_next : Graph.Cursor.t option
  ; committed : string list
  ; staged : string list
  ; phase : phase
  }

type visible =
  { name : string
  ; consumer : string
  ; assets : Asset.t list
  ; pressured : bool
  }

module Consumers = Map.Make (String)

module Versions = Map.Make (struct
    type t = Graph.Uuid.t * Asset.source

    let compare = compare
  end)

type residency =
  { ready : bool
  ; failed : bool
  }

type t =
  { graph_generation : int option
  ; revision : int
  ; serial : int
  ; scans : scan list
  ; visible : visible list
  ; residency : residency Versions.t Consumers.t
  }

let empty =
  { graph_generation = None
  ; revision = 0
  ; serial = 0
  ; scans = []
  ; visible = []
  ; residency = Consumers.empty
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

let releases consumers = List.map (fun consumer -> Release consumer) consumers

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

let finish state scan =
  ( with_scan state { scan with committed = scan.staged; staged = []; phase = Finished }
  , releases scan.committed )
;;

let continue state scan = function
  | None -> finish state scan
  | Some query -> issue state scan query
;;

let root_continuation scan =
  Option.map
    (fun cursor ->
       match scan.root_query with
       | Recent_roots range -> Recent_roots { range with cursor = Some cursor }
       | Favorite_roots _ -> Favorite_roots (Some cursor)
       | Assets _ -> assert false)
    scan.root_next
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
  with_scan state { scan with staged = []; phase = Broken }, releases scan.staged
;;

let scope_releases state =
  releases
    (List.concat_map (fun scan -> scan.committed @ scan.staged) state.scans
     @ List.map (fun (visible : visible) -> visible.consumer) state.visible)
;;

let step_policy state = function
  | Shutdown ->
    ( { empty with serial = state.serial; revision = state.revision + 1 }
    , scope_releases state )
  | Refresh { graph_generation; today; settings } ->
    let same_scope = state.graph_generation = Some graph_generation in
    let prior = if same_scope then state.scans else [] in
    let cleanup =
      if same_scope
      then releases (List.concat_map (fun scan -> scan.staged) prior)
      else scope_releases state
    in
    let state =
      { state with
        graph_generation = Some graph_generation
      ; revision = state.revision + 1
      ; scans = []
      ; visible = (if same_scope then state.visible else [])
      }
    in
    List.fold_left
      (fun (state, instructions) reason ->
         let committed =
           match List.find_opt (fun (scan : scan) -> scan.reason = reason) prior with
           | None -> []
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
           ; root_query = Option.value query ~default:(Favorite_roots None)
           ; root_next = None
           ; committed
           ; staged = []
           ; phase = Finished
           }
         in
         let state, next = continue state scan query in
         state, instructions @ next)
      (state, cleanup)
      [ Recent; Favorites ]
  | Roots_loaded (ticket, roots, next_cursor) ->
    (match current state ticket with
     | None -> state, []
     | Some scan ->
       if List.length roots > page_size
       then fail state scan
       else (
         match ticket.query with
         | Assets _ -> state, []
         | Recent_roots _ | Favorite_roots _ ->
           let scan = { scan with root_next = next_cursor } in
           if roots = []
           then continue state scan (root_continuation scan)
           else issue state scan (Assets { roots; cursor = None })))
  | Assets_loaded (ticket, assets, next_cursor) ->
    (match current state ticket with
     | None -> state, []
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
           if assets = []
           then continue state scan continuation
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
                 { scan with staged = consumer :: scan.staged; phase = Awaiting pending }
             , [ demand pending ] ))))
  | Read_failed ticket ->
    (match current state ticket with
     | None -> state, []
     | Some scan -> fail state scan)
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
     | Some scan ->
       (match scan.phase with
        | Awaiting p | Pressured p -> continue state scan p.continuation
        | _ -> assert false))
  | Backpressure consumer ->
    let scans =
      List.map
        (fun scan ->
           match scan.phase with
           | Awaiting p when p.consumer = consumer -> { scan with phase = Pressured p }
           | _ -> scan)
        state.scans
    in
    ( { state with
        scans
      ; visible =
          List.map
            (fun (v : visible) ->
               if v.consumer = consumer then { v with pressured = true } else v)
            state.visible
      }
    , [] )
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
    { state with visible }, releases (List.map (fun (v : visible) -> v.consumer) selected)
;;

let register state consumer assets =
  let previous =
    Option.value (Consumers.find_opt consumer state.residency) ~default:Versions.empty
  in
  let versions =
    List.fold_left
      (fun versions (asset : Asset.t) ->
         match asset.source with
         | External _ -> versions
         | Managed _ ->
           let key = asset.uuid, asset.source in
           let residency =
             Option.value
               (Versions.find_opt key previous)
               ~default:{ ready = false; failed = false }
           in
           Versions.add key residency versions)
      Versions.empty
      assets
  in
  { state with residency = Consumers.add consumer versions state.residency }
;;

let step state event =
  let state =
    match event with
    | Availability { consumer; asset; availability } ->
      let residency =
        Consumers.update
          consumer
          (Option.map (fun versions ->
             Versions.mapi
               (fun (uuid, _) resident ->
                  if Graph.Uuid.equal uuid asset
                  then (
                    match availability with
                    | Transfer.Ready _ -> { ready = true; failed = false }
                    | Failed _ -> { ready = false; failed = true }
                    | Queued
                    | Downloading
                    | Waiting_remote
                    | Waiting_network
                    | Waiting_unlock -> { ready = false; failed = false })
                  else resident)
               versions))
          state.residency
      in
      { state with residency }
    | _ -> state
  in
  let state, instructions = step_policy state event in
  let state =
    List.fold_left
      (fun state -> function
         | Demand { consumer; assets; _ } -> register state consumer assets
         | Release consumer ->
           { state with residency = Consumers.remove consumer state.residency }
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
    | None -> []
    | Some scan ->
      (match scan.phase with
       | Finished -> scan.committed
       | _ -> scan.staged)
  in
  let versions =
    List.fold_left
      (fun versions consumer ->
         match Consumers.find_opt consumer state.residency with
         | None -> versions
         | Some current ->
           Versions.union
             (fun _ (a : residency) (b : residency) ->
                Some { ready = a.ready && b.ready; failed = a.failed || b.failed })
             versions
             current)
      Versions.empty
      consumers
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
