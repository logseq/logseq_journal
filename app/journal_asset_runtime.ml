module Policy = Journal_asset_policy
module Protocol = Logseq_db_worker.Protocol
module Graph = Logseq_db_types.Graph_types
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service

module Uuids = Set.Make (struct
    type t = Graph.Uuid.t

    let compare = Graph.Uuid.compare
  end)

module Properties = Map.Make (struct
    type t = Graph.Uuid.t

    let compare = Graph.Uuid.compare
  end)

(* These are session resource bounds, independent of the total graph size.
   Exhaustion publishes Failed without releasing resident consumers or issuing
   a full-scope query. A genuine resync or graph replacement clears the cache. *)
let maximum_dependency_facts = 4096
let maximum_accepted_fact_requests = 4096
let maximum_queued_dependency_reads = 4096
let maximum_active_dependency_reads = 4
let maximum_ancestry_depth = 256

type fact =
  { block : Graph.block option
  ; issuance : int
  ; references : Uuids.t
  }

type dependency =
  | Block of Graph.Uuid.t
  | Page of Graph.Uuid.t

type t =
  { send : Service.request -> bool
  ; changed : int option -> Policy.offline -> Policy.offline -> unit
  ; mutable published : (int option * Policy.offline * Policy.offline) option
  ; mutable policy : Policy.t
  ; mutable configuration : (int * int * Policy.settings) option
  ; mutable generation : int option
  ; mutable queued : Policy.instruction Queue.t
  ; pending : (string, Policy.ticket) Hashtbl.t
  ; facts : (string, fact) Hashtbl.t
  ; pages : (string, Graph.page option * int) Hashtbl.t
  ; page_dirty : (string, Graph.page option * Uuids.t * int * bool) Hashtbl.t
  ; assets : (string, unit) Hashtbl.t
  ; requests : (string, int * Protocol.command) Hashtbl.t
  ; dependencies : (string, dependency * int) Hashtbl.t
  ; dependency_queue : dependency Queue.t
  ; dependency_waiting : (string, unit) Hashtbl.t
  ; mutable serial : int
  ; dirty : (string, Graph.block option * Uuids.t * int * bool) Hashtbl.t
  ; mutable barrier : int
  ; mutable degraded : bool
  ; mutable favorites_page : Graph.Uuid.t option
  ; mutable favorite_members : Uuids.t
  }

let create ~send ~changed =
  { send
  ; changed
  ; published = None
  ; policy = Policy.empty
  ; configuration = None
  ; generation = None
  ; queued = Queue.create ()
  ; pending = Hashtbl.create 2
  ; facts = Hashtbl.create 32
  ; pages = Hashtbl.create 8
  ; page_dirty = Hashtbl.create 8
  ; assets = Hashtbl.create 32
  ; requests = Hashtbl.create 32
  ; dependencies = Hashtbl.create 4
  ; dependency_queue = Queue.create ()
  ; dependency_waiting = Hashtbl.create 32
  ; serial = 0
  ; dirty = Hashtbl.create 32
  ; barrier = 0
  ; degraded = false
  ; favorites_page = None
  ; favorite_members = Uuids.empty
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

let degrade t =
  if not t.degraded
  then (
    t.degraded <- true;
    let policy, _ = Policy.step t.policy Dependencies_unavailable in
    t.policy <- policy;
    let recent = Policy.offline t.policy Recent
    and favorites = Policy.offline t.policy Favorites in
    t.changed t.generation recent favorites)
;;

let observe_request t (request : Protocol.request) =
  let key = Graph.Uuid.to_string request.request_id in
  if not (Hashtbl.mem t.requests key)
  then (
    if Hashtbl.length t.requests >= maximum_accepted_fact_requests
    then (
      let oldest =
        Hashtbl.fold
          (fun key (issuance, _) candidate ->
             if Hashtbl.mem t.pending key || Hashtbl.mem t.dependencies key
             then candidate
             else (
               match candidate with
               | None -> Some (key, issuance)
               | Some (_, prior) when issuance < prior -> Some (key, issuance)
               | _ -> candidate))
          t.requests
          None
      in
      Option.iter (fun (key, _) -> Hashtbl.remove t.requests key) oldest;
      degrade t);
    if Hashtbl.length t.requests < maximum_accepted_fact_requests
    then (
      t.serial <- t.serial + 1;
      Hashtbl.replace t.requests key (t.serial, request.command)))
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
      observe_request t Protocol.{ api_version = 2; request_id; command = command ticket };
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

let forget_request t ~request_id =
  Hashtbl.remove t.requests (Graph.Uuid.to_string request_id)
;;

let dependency_key = function
  | Block uuid -> "b:" ^ Graph.Uuid.to_string uuid
  | Page uuid -> "p:" ^ Graph.Uuid.to_string uuid
;;

let enqueue t dependency =
  let key = dependency_key dependency in
  if
    (not t.degraded)
    && (not (Hashtbl.mem t.dependency_waiting key))
    && not
         (Hashtbl.fold
            (fun _ (item, _) found -> found || dependency_key item = key)
            t.dependencies
            false)
  then
    if Queue.length t.dependency_queue >= maximum_queued_dependency_reads
    then degrade t
    else (
      Queue.add dependency t.dependency_queue;
      Hashtbl.replace t.dependency_waiting key ())
;;

let rec pump_dependencies t =
  if (not t.degraded) && Hashtbl.length t.dependencies < maximum_active_dependency_reads
  then
    if not (Queue.is_empty t.dependency_queue)
    then (
      let dependency = Queue.peek t.dependency_queue in
      let request_id =
        Graph.Uuid.of_string (Printf.sprintf "a55e7100-0000-4000-8000-%012x" t.serial)
        |> Result.get_ok
      in
      let command =
        match dependency with
        | Block block -> Protocol.V2_get_block { block; revision = None }
        | Page page -> V2_get_page { page; revision = None }
      in
      let request = Protocol.{ api_version = 2; request_id; command } in
      if t.send (Service.Graph_request request)
      then (
        observe_request t request;
        Hashtbl.replace
          t.dependencies
          (Graph.Uuid.to_string request_id)
          (dependency, t.serial);
        ignore (Queue.take t.dependency_queue : dependency);
        Hashtbl.remove t.dependency_waiting (dependency_key dependency);
        pump_dependencies t))
;;

let rec pump t =
  if Queue.is_empty t.queued
  then pump_dependencies t
  else if execute t (Queue.peek t.queued)
  then (
    ignore (Queue.take t.queued : Policy.instruction);
    pump t)
;;

let retain_releases t =
  let retained = Queue.create () in
  Queue.iter
    (function
      | Policy.Release _ as instruction -> Queue.add instruction retained
      | Read _ | Demand _ -> ())
    t.queued;
  t.queued <- retained
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
  List.iter (fun instruction -> Queue.add instruction t.queued) instructions;
  pump t;
  publish t
;;

let refresh t ~graph_generation ~today ~settings =
  let configuration = graph_generation, today, settings in
  if t.configuration <> Some configuration
  then (
    Hashtbl.clear t.pending;
    if t.generation <> Some graph_generation
    then (
      Hashtbl.clear t.facts;
      Hashtbl.clear t.pages;
      Hashtbl.clear t.page_dirty;
      Hashtbl.clear t.assets;
      Hashtbl.clear t.dirty;
      Hashtbl.clear t.requests;
      Hashtbl.clear t.dependencies;
      Queue.clear t.dependency_queue;
      Hashtbl.clear t.dependency_waiting;
      t.favorites_page <- None;
      t.favorite_members <- Uuids.empty;
      t.degraded <- false);
    retain_releases t;
    t.configuration <- Some configuration;
    t.generation <- Some graph_generation);
  dispatch t (Refresh { graph_generation; today; settings })
;;

let resync t =
  Hashtbl.clear t.dirty;
  Hashtbl.clear t.facts;
  Hashtbl.clear t.pages;
  Hashtbl.clear t.page_dirty;
  Hashtbl.clear t.assets;
  Queue.clear t.dependency_queue;
  Hashtbl.clear t.dependency_waiting;
  t.degraded <- false;
  t.barrier <- t.serial;
  dispatch t Resync
;;

let all_roots t =
  Seq.append (Policy.roots t.policy Recent) (Policy.roots t.policy Favorites)
;;

let fact t uuid =
  Option.bind
    (Hashtbl.find_opt t.facts (Graph.Uuid.to_string uuid))
    (fun fact -> fact.block)
;;

let fold_values f state values = Rrbvec.fold_left f state (Rrbvec.of_list values)

let rec value_uuids set = function
  | Graph.Internal_uuid uuid -> Uuids.add uuid set
  | Internal_list values -> fold_values value_uuids set values
  | Internal_map values ->
    fold_values
      (fun set (key, value) -> value_uuids (value_uuids set key) value)
      set
      values
  | Internal_null
  | Internal_bool _
  | Internal_number _
  | Internal_string _
  | Internal_keyword _ -> set
;;

let property_value_uuids set = function
  | Graph.Node_value uuid
  | Asset_value uuid
  | Entity_value uuid
  | Class_value uuid
  | Page_value uuid -> Uuids.add uuid set
  | Collection_value values -> fold_values value_uuids set values
  | Map_value values ->
    fold_values
      (fun set (key, value) -> value_uuids (value_uuids set key) value)
      set
      values
  | Any_value value -> value_uuids set value
  | _ -> set
;;

let uuid_set values = fold_values (fun set uuid -> Uuids.add uuid set) Uuids.empty values

let property_membership properties =
  fold_values
    (fun members (property : Graph.property_summary) ->
       Properties.add
         property.uuid
         ( property.schema
         , property.values_truncated
         , fold_values property_value_uuids Uuids.empty property.values )
         members)
    Properties.empty
    properties
;;

let references (block : Graph.block) =
  fold_values
    (fun set (property : Graph.property_summary) ->
       fold_values property_value_uuids (Uuids.add property.uuid set) property.values)
    (uuid_set block.refs)
    block.properties
;;

let path ?(discover = true) t start =
  let rec walk seen depth uuid =
    if depth = maximum_ancestry_depth || Uuids.mem uuid seen
    then seen
    else (
      let seen = Uuids.add uuid seen in
      match fact t uuid with
      | None ->
        if
          discover
          && (not (Hashtbl.mem t.pages (Graph.Uuid.to_string uuid)))
          && not (Hashtbl.mem t.facts (Graph.Uuid.to_string uuid))
        then enqueue t (Block uuid);
        seen
      | Some block -> walk (Uuids.add block.page seen) (depth + 1) block.parent)
  in
  walk Uuids.empty 0 start
;;

let roots_for_block t (block : Graph.block) =
  let parents =
    if Graph.Uuid.equal block.parent block.page then Uuids.empty else path t block.parent
  in
  let ancestors = Uuids.add block.uuid (Uuids.add block.page parents) in
  Seq.fold_left
    (fun roots root -> if Uuids.mem root ancestors then Uuids.add root roots else roots)
    Uuids.empty
    (all_roots t)
;;

let roots_for_uuid t uuid =
  let roots =
    Seq.fold_left
      (fun roots root ->
         if Uuids.mem uuid (path ~discover:false t root)
         then Uuids.add root roots
         else roots)
      Uuids.empty
      (all_roots t)
  in
  Hashtbl.fold
    (fun _ fact roots ->
       match fact.block with
       | Some block
         when Graph.Uuid.equal block.uuid uuid || Uuids.mem uuid fact.references ->
         Uuids.union roots (roots_for_block t block)
       | None | Some _ -> roots)
    t.facts
    roots
;;

let property_membership_equal =
  Properties.equal
    (fun (schema, truncated, values) (other, other_truncated, other_values) ->
       schema = other
       && (not truncated)
       && (not other_truncated)
       && Uuids.equal values other_values)
;;

let block_membership_equal =
  Option.equal
    (fun
        (parent, page, refs, tags, properties)
         (other_parent, other_page, other_refs, other_tags, other_properties)
       ->
       Graph.Uuid.equal parent other_parent
       && Graph.Uuid.equal page other_page
       && Uuids.equal refs other_refs
       && Uuids.equal tags other_tags
       && property_membership_equal properties other_properties)
;;

let page_membership_equal =
  Option.equal
    (fun (recycled, tags, properties) (other_recycled, other_tags, other_properties) ->
       recycled = other_recycled
       && Uuids.equal tags other_tags
       && property_membership_equal properties other_properties)
;;

let signature =
  Option.map (fun (block : Graph.block) ->
    ( block.parent
    , block.page
    , uuid_set block.refs
    , uuid_set block.tags
    , property_membership block.properties ))
;;

let settle_dirty t =
  let affected = ref Uuids.empty in
  let complete = ref [] in
  Hashtbl.iter
    (fun key (before, old_roots, barrier, observed) ->
       match Hashtbl.find_opt t.facts key with
       | None -> ()
       | Some current when current.issuance > barrier ->
         if
           (not (block_membership_equal (signature before) (signature current.block)))
           || ((not observed) && not (Uuids.is_empty old_roots))
         then (
           let roots =
             match current.block with
             | None -> Uuids.empty
             | Some block -> roots_for_block t block
           in
           affected := Uuids.union !affected (Uuids.union old_roots roots));
         (* A known ancestry chain completes here. Unknown ancestors remain pending. *)
         let resolved =
           match current.block with
           | None -> true
           | Some block when Graph.Uuid.equal block.parent block.page -> true
           | Some block ->
             let ancestors = path t block.parent in
             Uuids.for_all
               (fun uuid ->
                  Hashtbl.mem t.facts (Graph.Uuid.to_string uuid)
                  || Hashtbl.mem t.pages (Graph.Uuid.to_string uuid))
               ancestors
         in
         if resolved then complete := key :: !complete
       | Some _ -> ())
    t.dirty;
  List.iter (Hashtbl.remove t.dirty) !complete;
  if not (Uuids.is_empty !affected)
  then dispatch t (Roots_changed (Uuids.elements !affected));
  pump t
;;

let observe_response t (Protocol.V2_response { request_id; outcome; _ }) =
  match Hashtbl.find_opt t.requests (Graph.Uuid.to_string request_id) with
  | None -> ()
  | Some (issuance, command) ->
    Hashtbl.remove t.requests (Graph.Uuid.to_string request_id);
    if issuance > t.barrier
    then (
      let remember_block uuid block =
        let key = Graph.Uuid.to_string uuid in
        let prior = Hashtbl.find_opt t.facts key in
        if
          (Hashtbl.length t.facts < maximum_dependency_facts || Option.is_some prior)
          &&
          match prior with
          | None -> true
          | Some fact -> issuance >= fact.issuance
        then (
          Hashtbl.replace
            t.facts
            key
            { block
            ; issuance
            ; references = Option.fold ~none:Uuids.empty ~some:references block
            };
          if Seq.exists (Graph.Uuid.equal uuid) (all_roots t)
          then
            Option.iter
              (fun (block : Graph.block) -> ignore (path t block.parent : Uuids.t))
              block)
        else if Option.is_none prior
        then degrade t
      in
      let remember_lookup = function
        | Protocol.V2_present_block { value; _ } ->
          remember_block value.block.uuid (Some value.block)
        | V2_missing_block { uuid; _ } -> remember_block uuid None
      in
      let remember_page_value uuid page =
        let key = Graph.Uuid.to_string uuid in
        let prior = Hashtbl.find_opt t.pages key in
        if Hashtbl.length t.pages < maximum_dependency_facts || Option.is_some prior
        then (
          if
            match prior with
            | None -> true
            | Some (_, stamp) -> issuance >= stamp
          then (
            Hashtbl.replace t.pages key (page, issuance);
            match Hashtbl.find_opt t.page_dirty key with
            | Some (before, roots, barrier, observed) when issuance > barrier ->
              let direct =
                Seq.exists (Graph.Uuid.equal uuid) (all_roots t)
                || Hashtbl.fold
                     (fun _ fact found -> found || Uuids.mem uuid fact.references)
                     t.facts
                     false
              in
              let changed =
                if direct
                then (
                  let membership =
                    Option.map (fun (page : Graph.page) ->
                      ( page.recycled
                      , uuid_set page.tags
                      , property_membership page.properties ))
                  in
                  (not (page_membership_equal (membership before) (membership page)))
                  || not observed)
                else (
                  let live = function
                    | Some (page : Graph.page) -> not page.recycled
                    | None -> false
                  in
                  (if observed then live before else true) <> live page)
              in
              if changed then dispatch t (Roots_changed (Uuids.elements roots));
              Hashtbl.remove t.page_dirty key
            | _ -> ()))
        else degrade t
      in
      let remember_page = function
        | Protocol.V2_present_page { page; _ } ->
          remember_page_value page.uuid (Some page)
        | V2_missing_page { uuid; _ } -> remember_page_value uuid None
      in
      (match outcome with
       | V2_block_outcome lookup -> remember_lookup lookup
       | V2_page_outcome lookup ->
         remember_page lookup;
         (match lookup with
          | V2_present_page { page; _ }
            when page.name = "$$$favorites" && t.favorites_page <> Some page.uuid ->
            dispatch t (Index_changed Favorites)
          | _ -> ())
       | V2_block_summary_outcome { lookup; page; items; _ } ->
         remember_lookup lookup;
         Option.iter remember_page page;
         List.iter
           (fun (item : Protocol.v2_child_member) ->
              remember_block item.value.block.uuid (Some item.value.block))
           items
       | V2_children_outcome { items; _ } ->
         List.iter
           (fun (item : Protocol.v2_child_member) ->
              remember_block item.value.block.uuid (Some item.value.block))
           items
       | V2_page_tree_outcome { items; _ } ->
         List.iter
           (fun (item : Protocol.v2_tree_member) ->
              remember_block item.value.block.uuid (Some item.value.block))
           items
       | V2_journals_outcome { items; _ } ->
         List.iter
           (fun (item : Protocol.v2_journal_item) ->
              remember_page_value item.page.uuid (Some item.page))
           items
       | V2_favorites_outcome { favorites_page; items; _ } ->
         t.favorites_page <- favorites_page;
         (match command with
          | V2_list_favorites { cursor = None; _ } -> t.favorite_members <- Uuids.empty
          | _ -> ());
         List.iter
           (fun (item : Protocol.v2_favorite_item) ->
              t.favorite_members <- Uuids.add item.membership_uuid t.favorite_members;
              match item.target with
              | V2_favorite_block { uuid; _ } -> enqueue t (Block uuid)
              | V2_favorite_page { uuid; _ } ->
                if not (Hashtbl.mem t.pages (Graph.Uuid.to_string uuid))
                then enqueue t (Page uuid))
           items
       | V2_assets_outcome { items; _ } ->
         List.iter
           (fun (asset : Logseq_db_types.Asset_descriptor.t) ->
              if
                Hashtbl.length t.assets < maximum_dependency_facts
                || Hashtbl.mem t.assets (Graph.Uuid.to_string asset.uuid)
              then Hashtbl.replace t.assets (Graph.Uuid.to_string asset.uuid) ()
              else degrade t)
           items
       | _ -> ());
      settle_dirty t)
;;

let changes t windows =
  if not t.degraded
  then (
    let affected = ref Uuids.empty in
    List.iter
      (fun (window : Protocol.v2_change_window) ->
         List.iter
           (function
             | Protocol.V2_journal_index_interest -> dispatch t (Index_changed Recent)
             | V2_children_interest uuid | V2_page_tree_interest uuid ->
               let direct =
                 Seq.fold_left
                   (fun roots root ->
                      if Graph.Uuid.equal root uuid then Uuids.add root roots else roots)
                   Uuids.empty
                   (all_roots t)
               in
               let below =
                 match fact t uuid with
                 | None -> Uuids.empty
                 | Some block -> roots_for_block t block
               in
               affected := Uuids.union !affected (Uuids.union direct below);
               if t.favorites_page = Some uuid then dispatch t (Index_changed Favorites);
               if
                 Option.is_none (fact t uuid)
                 && (not (Hashtbl.mem t.facts (Graph.Uuid.to_string uuid)))
                 && (not
                       (List.exists
                          (function
                            | Protocol.V2_page_tree_interest page ->
                              Graph.Uuid.equal page uuid
                            | _ -> false)
                          window.structure_interests))
                 && not (Hashtbl.mem t.pages (Graph.Uuid.to_string uuid))
               then (
                 let key = Graph.Uuid.to_string uuid in
                 if not (Hashtbl.mem t.dirty key)
                 then
                   if Hashtbl.length t.dirty >= maximum_dependency_facts
                   then degrade t
                   else Hashtbl.replace t.dirty key (None, Uuids.empty, t.serial, false);
                 enqueue t (Block uuid)))
           window.structure_interests;
         List.iter
           (fun uuid ->
              if t.favorites_page = Some uuid || Uuids.mem uuid t.favorite_members
              then dispatch t (Index_changed Favorites);
              if not (Hashtbl.mem t.assets (Graph.Uuid.to_string uuid))
              then (
                let key = Graph.Uuid.to_string uuid in
                (match Hashtbl.find_opt t.dirty key with
                 | Some (before, roots, _, observed) ->
                   Hashtbl.replace t.dirty key (before, roots, t.serial, observed)
                 | None ->
                   if Hashtbl.length t.dirty >= maximum_dependency_facts
                   then degrade t
                   else
                     Hashtbl.replace
                       t.dirty
                       key
                       ( fact t uuid
                       , roots_for_uuid t uuid
                       , t.serial
                       , Hashtbl.mem t.facts key ));
                enqueue t (Block uuid)))
           window.block_uuids;
         List.iter
           (fun uuid ->
              let roots = roots_for_uuid t uuid in
              if not (Uuids.is_empty roots)
              then (
                let key = Graph.Uuid.to_string uuid in
                let before = Hashtbl.find_opt t.pages key in
                if
                  Hashtbl.length t.page_dirty < maximum_dependency_facts
                  || Hashtbl.mem t.page_dirty key
                then (
                  (match Hashtbl.find_opt t.page_dirty key with
                   | Some (before, roots, _, observed) ->
                     Hashtbl.replace t.page_dirty key (before, roots, t.serial, observed)
                   | None ->
                     Hashtbl.replace
                       t.page_dirty
                       key
                       (Option.bind before fst, roots, t.serial, Option.is_some before));
                  enqueue t (Page uuid))
                else degrade t)
              else if t.favorites_page = None
              then enqueue t (Page uuid))
           window.page_uuids)
      windows;
    if not (Uuids.is_empty !affected)
    then dispatch t (Roots_changed (Uuids.elements !affected));
    pump t)
;;

let shutdown t =
  retain_releases t;
  dispatch t Shutdown;
  Hashtbl.clear t.pending;
  Hashtbl.clear t.facts;
  Hashtbl.clear t.pages;
  Hashtbl.clear t.page_dirty;
  Hashtbl.clear t.assets;
  Hashtbl.clear t.dirty;
  Hashtbl.clear t.requests;
  Hashtbl.clear t.dependencies;
  Queue.clear t.dependency_queue;
  Hashtbl.clear t.dependency_waiting;
  t.favorites_page <- None;
  t.favorite_members <- Uuids.empty;
  Queue.clear t.queued;
  t.configuration <- None;
  t.generation <- None;
  publish t
;;

let receive t (Protocol.V2_response { request_id; outcome; _ } as response) =
  let key = Graph.Uuid.to_string request_id in
  match Hashtbl.find_opt t.pending key with
  | None ->
    (match Hashtbl.find_opt t.dependencies key with
     | None -> false
     | Some (dependency, issuance) ->
       Hashtbl.remove t.dependencies key;
       let expected =
         match dependency, outcome with
         | Block _, Protocol.V2_block_outcome _ | Page _, V2_page_outcome _ -> true
         | _ -> false
       in
       if not expected
       then (
         Hashtbl.clear t.dirty;
         Hashtbl.clear t.page_dirty;
         Queue.clear t.dependency_queue;
         Hashtbl.clear t.dependency_waiting;
         degrade t);
       observe_response t response;
       (match dependency with
        | Block uuid ->
          (match Hashtbl.find_opt t.dirty (Graph.Uuid.to_string uuid) with
           | Some (_, _, barrier, _) when issuance <= barrier -> enqueue t dependency
           | _ -> ())
        | Page uuid ->
          (match Hashtbl.find_opt t.page_dirty (Graph.Uuid.to_string uuid) with
           | Some (_, _, barrier, _) when issuance <= barrier -> enqueue t dependency
           | _ -> ()));
       pump t;
       true)
  | Some ticket ->
    Hashtbl.remove t.pending key;
    observe_response t response;
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
  forget_request t ~request_id;
  let key = Graph.Uuid.to_string request_id in
  match Hashtbl.find_opt t.pending key with
  | None ->
    if Hashtbl.mem t.dependencies key
    then (
      Hashtbl.clear t.dirty;
      Hashtbl.clear t.page_dirty;
      Queue.clear t.dependency_queue;
      Hashtbl.clear t.dependency_waiting;
      degrade t);
    Hashtbl.remove t.dependencies key;
    Hashtbl.remove t.requests key;
    pump t
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
