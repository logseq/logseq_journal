module Policy = Journal_asset_policy
module Protocol = Logseq_db_worker.Protocol
module Graph = Logseq_db_types.Graph_types
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service

type t =
  { send : Service.request -> bool
  ; changed : int option -> Policy.offline -> Policy.offline -> unit
  ; mutable published : (int option * Policy.offline * Policy.offline) option
  ; mutable policy : Policy.t
  ; mutable generation : int option
  ; mutable queued : Policy.instruction list
  ; pending : (string, Policy.ticket) Hashtbl.t
  }

let create ~send ~changed =
  { send
  ; changed
  ; published = None
  ; policy = Policy.empty
  ; generation = None
  ; queued = []
  ; pending = Hashtbl.create 2
  }
;;

let command (ticket : Policy.ticket) =
  match ticket.query with
  | Recent_roots { from_day; through_day; cursor } ->
    Protocol.V2_list_journals
      { from_day; through_day; cursor; limit = Policy.page_size; revision = None }
  | Favorite_roots cursor -> V2_list_favorites { cursor; limit = Policy.page_size }
  | Assets { roots; cursor } ->
    V2_list_assets { recursive = true; roots; cursor; limit = Policy.page_size }
;;

let execute t = function
  | Policy.Read ticket ->
    let request_id =
      Graph.Uuid.of_string (Printf.sprintf "a55e7000-0000-4000-8000-%012x" ticket.id)
      |> Result.get_ok
    in
    if
      t.send
        (Service.Graph_request { api_version = 2; request_id; command = command ticket })
    then (
      Hashtbl.replace t.pending (Graph.Uuid.to_string request_id) ticket;
      true)
    else false
  | Demand { consumer; priority; assets } ->
    (match t.generation with
     | None -> true
     | Some graph_generation ->
       t.send
         (Service.Asset_command
            { graph_generation
            ; command = Replace_asset_demand { consumer; priority; assets }
            }))
  | Release consumer ->
    (match t.generation with
     | None -> true
     | Some graph_generation ->
       t.send
         (Service.Asset_command
            { graph_generation; command = Release_asset_demand consumer }))
;;

let rec pump t =
  match t.queued with
  | [] -> ()
  | instruction :: rest ->
    if execute t instruction
    then (
      t.queued <- rest;
      pump t)
;;

let publish t =
  let recent = Policy.offline t.policy Recent in
  let favorites = Policy.offline t.policy Favorites in
  let status = t.generation, recent, favorites in
  if t.published <> Some status
  then (
    t.published <- Some status;
    t.changed t.generation recent favorites)
;;

let dispatch t event =
  let policy, instructions = Policy.step t.policy event in
  t.policy <- policy;
  t.queued <- t.queued @ instructions;
  pump t;
  publish t
;;

let refresh t ~graph_generation ~today ~settings =
  Hashtbl.clear t.pending;
  t.queued
  <- List.filter
       (function
         | Policy.Release _ -> true
         | Read _ | Demand _ -> false)
       t.queued;
  t.generation <- Some graph_generation;
  dispatch t (Refresh { graph_generation; today; settings })
;;

let shutdown t =
  t.queued
  <- List.filter
       (function
         | Policy.Release _ -> true
         | Read _ | Demand _ -> false)
       t.queued;
  dispatch t Shutdown;
  Hashtbl.clear t.pending;
  t.queued <- [];
  t.generation <- None;
  publish t
;;

let receive t (Protocol.V2_response { request_id; outcome; _ }) =
  let key = Graph.Uuid.to_string request_id in
  match Hashtbl.find_opt t.pending key with
  | None -> false
  | Some ticket ->
    Hashtbl.remove t.pending key;
    let event =
      match ticket.query, outcome with
      | Policy.Recent_roots _, Protocol.V2_journals_outcome { items; next_cursor } ->
        Policy.Roots_loaded
          ( ticket
          , List.map (fun (item : Protocol.v2_journal_item) -> item.page.uuid) items
          , next_cursor )
      | Favorite_roots _, V2_favorites_outcome { items; next_cursor; _ } ->
        Roots_loaded
          ( ticket
          , List.map
              (fun (item : Protocol.v2_favorite_item) ->
                 match item.target with
                 | V2_favorite_page { uuid; _ } | V2_favorite_block { uuid; _ } -> uuid)
              items
          , next_cursor )
      | Assets _, V2_assets_outcome { items; next_cursor; _ } ->
        Assets_loaded (ticket, items, next_cursor)
      | _ -> Read_failed ticket
    in
    dispatch t event;
    true
;;

let reject t ~request_id =
  let key = Graph.Uuid.to_string request_id in
  match Hashtbl.find_opt t.pending key with
  | None -> ()
  | Some ticket ->
    Hashtbl.remove t.pending key;
    dispatch t (Read_failed ticket)
;;

let notice
      t
      (scope : Logseq_db_worker_lui.Logseq_db_worker_lui_service.asset_scope)
      notice
  =
  if t.generation = Some scope.graph_generation
  then (
    match notice with
    | Service.Asset_demand_accepted consumer -> dispatch t (Demand_accepted consumer)
    | Asset_backpressure consumer -> dispatch t (Backpressure consumer)
    | Upload_status _ -> ()
    | Asset_capacity_available -> dispatch t Capacity_available
    | Asset_availability { consumer; asset; availability } ->
      dispatch t (Availability { consumer; asset; availability }))
;;

let visible t ~consumer assets = dispatch t (Visible { consumer; assets })
let hidden t ~consumer = dispatch t (Hidden consumer)
let progress t reason = Policy.progress t.policy reason
