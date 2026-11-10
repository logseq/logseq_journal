module Policy = Journal_asset_policy
module Graph = Logseq_db_types.Graph_types
module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Worker = Journal_worker_coordination.Worker_api
module Coordination = Journal_worker_coordination.Worker_pure_coordinator

type demand_registration = Worker.asset_demand Coordination.ticket * Worker.asset_demand option

type scan_cursor =
  | Journals_cursor of Worker_pure_data.journal_item Worker.continuation
  | Favorites_cursor of Worker_pure_data.favorite_item Worker.continuation
  | Assets_cursor of Logseq_db_types.Asset_descriptor.t Worker.continuation

type read_result =
  | Read_result :
      { read_id : Graph.Uuid.t
      ; query : 'a Worker.query
      ; value : 'a
      }
      -> read_result

type read_request =
  | Read :
      { request_id : Graph.Uuid.t
      ; maximum_items : int
      ; query : 'a Worker.query
      ; outcome : 'a -> read_result
      }
      -> read_request

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
  { read_port : read_request -> bool
  ; release_consumer : demand_registration -> bool
  ; bound_consumers : (string,demand_registration)Hashtbl.t
  ; mutable resource_binding : Worker.binding option
  ; mutable resume_configuration : (int*int*Policy.settings)option
  ; read_planned : Graph.Uuid.t -> unit
  ; read_retired : Graph.Uuid.t -> unit
  ; demand : graph_generation:int -> name:string -> Worker.asset_priority -> Logseq_db_types.Asset_descriptor.t list -> Worker.asset_demand Coordination.ticket option
  ; changed : int option -> Policy.offline -> Policy.offline -> unit
  ; mutable published : (int option * Policy.offline * Policy.offline) option
  ; mutable policy : scan_cursor Policy.t
  ; mutable configuration : (int * int * Policy.settings) option
  ; mutable generation : int option
  ; mutable queued : scan_cursor Policy.instruction Queue.t
  ; pending : (string, scan_cursor Policy.ticket) Hashtbl.t
  ; facts : (string, fact) Hashtbl.t
  ; pages : (string, Graph.page option * int) Hashtbl.t
  ; page_dirty : (string, Graph.page option * Uuids.t * int * bool) Hashtbl.t
  ; assets : (string, unit) Hashtbl.t
  ; requests : (string, int * bool) Hashtbl.t
  ; dependencies : (string, dependency * int) Hashtbl.t
  ; dependency_queue : (dependency * Graph.Uuid.t) Queue.t
  ; dependency_waiting : (string, Graph.Uuid.t) Hashtbl.t
  ; mutable serial : int
  ; dirty : (string, Graph.block option * Uuids.t * int * bool) Hashtbl.t
  ; mutable barrier : int
  ; mutable degraded : bool
  ; mutable favorites_page : Graph.Uuid.t option
  ; mutable favorite_members : Uuids.t
  }

let create_state ~release_consumer ~read_port ~read_planned ~read_retired ~demand ~changed =
  { read_port
  ; release_consumer
  ; bound_consumers=Hashtbl.create 32
  ; resource_binding=None
  ; resume_configuration=None
  ; read_planned
  ; read_retired
  ; demand
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

let create ~release_consumer ?(read_planned=fun _->()) ?(read_retired=fun _->()) ~read ~demand ~changed () =
  create_state ~release_consumer ~read_port:read ~read_planned ~read_retired ~demand ~changed
;;

let scan_request_id id =
  Graph.Uuid.of_string(Printf.sprintf "a55e7000-0000-4000-8000-%012x" id) |> Result.get_ok

let dependency_id (dependency : _ Policy.read_dependency) =
  match dependency.after_demand with
  | None -> scan_request_id dependency.ticket.id
  | Some _ ->
    Graph.Uuid.of_string(Printf.sprintf "a55e7200-0000-4000-8000-%012x" dependency.ticket.id)
    |> Result.get_ok

let clear_dependency_queue t =
  Queue.iter(fun(_,id)->t.read_retired id)t.dependency_queue;
  Queue.clear t.dependency_queue;
  Hashtbl.clear t.dependency_waiting

let retire_policy_reads t =
  List.iter(fun dependency->t.read_retired(dependency_id dependency))(Policy.read_dependencies t.policy)

let retire_dependency_reads t =
  Hashtbl.iter(fun id _->t.read_retired(Graph.Uuid.of_string id |> Result.get_ok))t.dependencies;
  clear_dependency_queue t

let owns_read t request_id =
  let key=Graph.Uuid.to_string request_id in
  Hashtbl.mem t.pending key || Hashtbl.mem t.dependencies key

let projection_read_error t =
  if t.configuration<>None && t.degraded
  then Some "Offline attachment dependencies could not be read" else None

(* A ticket is pending authority only. Checked ACKs/notices establish the exact
   demand round; late results cannot replace a newer consumer registration. *)
let retain_demand t consumer demand =
  match Hashtbl.find_opt t.bound_consumers consumer with
  | Some(ticket,previous) when Worker.equal_request_id (Coordination.ticket_id ticket)(Worker.asset_demand_round demand) ->
    (match previous with
     | Some previous -> Worker.equal_asset_demand previous demand
     | None -> Hashtbl.replace t.bound_consumers consumer (ticket,Some demand);true)
  | _ -> false

let receive_demand t ticket demand =
  if not(Worker.equal_request_id (Coordination.ticket_id ticket)(Worker.asset_demand_round demand)) then false else
  let consumer=Hashtbl.to_seq t.bound_consumers |> Seq.find_map(fun(consumer,(pending,_))->
    if Worker.equal_request_id (Coordination.ticket_id pending)(Coordination.ticket_id ticket)
    then Some consumer else None) in
  Option.fold ~none:false ~some:(fun consumer->retain_demand t consumer demand)consumer

let current_demand_notice t notice =
  match Worker.asset_notice_demand notice,Worker.asset_notice_data notice with
  | Some demand,(Service.Asset_availability{consumer;_}|Asset_demand_accepted consumer|Asset_backpressure consumer) ->
    retain_demand t consumer demand
  | None,(Service.Upload_status _|Asset_capacity_available) -> true
  | _ -> false

let notice_reads t notice =
  if not(current_demand_notice t notice) then [] else
  let scope=Worker.asset_notice_scope notice and notice=Worker.asset_notice_data notice in
  if t.generation <> Some scope.graph_generation then [] else
  let event=match notice with
    | Service.Asset_demand_accepted consumer -> Some(Policy.Demand_accepted consumer)
    | Asset_backpressure consumer -> Some(Policy.Backpressure consumer)
    | _ -> None in
  match event with None->[]|Some event->
    Policy.completed_deferred_reads t.policy event |> List.map dependency_id
;;

let degrade t =
  if not t.degraded
  then (
    t.degraded <- true;
    retire_policy_reads t;
    clear_dependency_queue t;
    let policy, _ = Policy.step t.policy Dependencies_unavailable in
    t.policy <- policy;
    let recent = Policy.offline t.policy Recent
    and favorites = Policy.offline t.policy Favorites in
    t.changed t.generation recent favorites)
;;

let observe_fact_request t ~request_id ~first_page =
  let key = Graph.Uuid.to_string request_id in
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
      Hashtbl.replace t.requests key (t.serial, first_page)))
;;



let execute t = function
  | Policy.Read ticket ->
    let request_id = scan_request_id ticket.id in
    let accepted =
        let submit query =
          t.read_port
            (Read
               { request_id
               ; maximum_items = Policy.page_size
               ; query
               ; outcome = (fun value -> Read_result { read_id = request_id; query; value })
               })
        in
        (match ticket.query with
         | Recent_roots { from_day; through_day; cursor } ->
           let after =
             match cursor with
             | None -> None
             | Some (Journals_cursor c) -> Some c
             | Some _ -> invalid_arg "Wrong journals continuation"
           in
           (match Worker.journal_day from_day, Worker.journal_day through_day with
            | Ok from_day, Ok through_day ->
              submit
                (Worker.Journals { from_day; through_day; revision = None; after })
            | _ -> false)
         | Favorite_roots cursor ->
           let after =
             match cursor with
             | None -> None
             | Some (Favorites_cursor c) -> Some c
             | Some _ -> invalid_arg "Wrong favorites continuation"
           in
           submit (Worker.Favorites after)
         | Assets { roots; cursor } ->
           let after =
             match cursor with
             | None -> None
             | Some (Assets_cursor c) -> Some c
             | Some _ -> invalid_arg "Wrong assets continuation"
           in
           submit
             (Worker.Assets { recursive = true; roots; after }))
    in
    if accepted
    then (
      (* The logical scan identity is independent of the physical mailbox ID. *)
      observe_fact_request t ~request_id
          ~first_page:(match ticket.query with Favorite_roots None -> true | _ -> false);
      Hashtbl.replace t.pending (Graph.Uuid.to_string request_id) ticket;
      true)
    else false
  | Demand {consumer;priority;assets}->
    (match t.generation with None->true|Some graph_generation->
      match t.demand ~graph_generation ~name:consumer priority assets with
      |None->false|Some bound->Hashtbl.replace t.bound_consumers consumer (bound,None);true)
  | Release consumer->
    (match Hashtbl.find_opt t.bound_consumers consumer with
     |None->true|Some bound->
       if t.release_consumer bound then (Hashtbl.remove t.bound_consumers consumer;true)else false)

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
  let existing=match Hashtbl.find_opt t.dependency_waiting key with
    | Some id->Some id
    | None->Hashtbl.fold(fun id (item,_) found->
        if dependency_key item=key then Some(Graph.Uuid.of_string id |> Result.get_ok) else found)
        t.dependencies None in
  Option.iter t.read_planned existing;
  if
    Option.is_some t.configuration
    && (not t.degraded)
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
      t.serial <- t.serial+1;
      let request_id=Graph.Uuid.of_string(Printf.sprintf "a55e7100-0000-4000-8000-%012x" t.serial) |> Result.get_ok in
      t.read_planned request_id;
      Queue.add (dependency,request_id) t.dependency_queue;
      Hashtbl.replace t.dependency_waiting key request_id)
;;

let rec pump_dependencies t =
  if (not t.degraded) && Hashtbl.length t.dependencies < maximum_active_dependency_reads
  then
    if not (Queue.is_empty t.dependency_queue)
    then (
      let dependency,request_id = Queue.peek t.dependency_queue in
      let accepted =
          let submit query = t.read_port (Read
            { request_id; maximum_items = 1; query
            ; outcome = (fun value -> Read_result { read_id = request_id; query; value })
            }) in
          match dependency with
          | Block uuid -> submit (Worker.Outline_block { uuid; revision = None })
          | Page uuid -> submit (Worker.Page { uuid; revision = None }) in
      if accepted then (
        observe_fact_request t ~request_id ~first_page:false;
        Hashtbl.replace
          t.dependencies
          (Graph.Uuid.to_string request_id)
          (dependency, t.serial);
        ignore (Queue.take t.dependency_queue : dependency * Graph.Uuid.t);
        Hashtbl.remove t.dependency_waiting (dependency_key dependency);
        pump_dependencies t))
;;

let rec pump t =
  if Queue.is_empty t.queued
  then pump_dependencies t
  else if execute t (Queue.peek t.queued)
  then (
    ignore (Queue.take t.queued : scan_cursor Policy.instruction);
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
  let previous=Policy.read_dependencies t.policy in
  let policy, instructions, dependencies = Policy.step_with_dependencies t.policy event in
  t.policy <- policy;
  let current=Policy.read_dependencies policy in
  List.iter(fun dependency->if not(List.mem dependency current)
    then t.read_retired(dependency_id dependency))previous;
  List.iter(fun dependency->t.read_planned(dependency_id dependency))dependencies;
  List.iter (fun instruction -> Queue.add instruction t.queued) instructions;
  pump t;
  publish t
;;

let refresh t ~graph_generation ~today ~settings =
  let configuration = graph_generation, today, settings in
  if t.configuration <> Some configuration
  then (
    t.resume_configuration<-None;
    retire_policy_reads t;
    Hashtbl.clear t.pending;
    if t.generation <> Some graph_generation
    then (
      Hashtbl.clear t.facts;
      Hashtbl.clear t.pages;
      Hashtbl.clear t.page_dirty;
      Hashtbl.clear t.assets;
      Hashtbl.clear t.dirty;
      Hashtbl.clear t.requests;
      retire_dependency_reads t;
      Hashtbl.clear t.dependencies;
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
  retire_dependency_reads t;
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

let change_application_error t windows =
  let failed reason = Policy.progress t.policy reason = Policy.Failed in
  let root uuid =
    Seq.exists(Graph.Uuid.equal uuid)(all_roots t)
    || not(Uuids.is_empty(roots_for_uuid t uuid)) in
  let needed = List.exists(fun (window:Worker_pure_data.change_window)->
    List.exists(function
      | Worker_pure_data.V2_journal_index_interest -> failed Recent
      | Worker_pure_data.V2_children_interest uuid | Worker_pure_data.V2_page_tree_interest uuid -> root uuid
        || (t.degraded && not(Hashtbl.mem t.pages(Graph.Uuid.to_string uuid))))window.structure_interests
    || List.exists(fun uuid->not(Hashtbl.mem t.assets(Graph.Uuid.to_string uuid))
      && (root uuid || (t.degraded && not(Hashtbl.mem t.facts(Graph.Uuid.to_string uuid)))))window.block_uuids
    || List.exists(fun uuid->root uuid || (t.degraded && t.favorites_page=None))window.page_uuids)windows in
  if t.configuration<>None && needed
    && (t.degraded || failed Recent || failed Favorites)
  then Some "Offline attachment enumeration could not be applied" else None
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

let remember_block_value t ~issuance uuid block =
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

;;

let remember_page_value t ~issuance uuid page =
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
;;

let observe_favorites t ~first_page ~favorites_page items =
  t.favorites_page <- favorites_page;
  if first_page then t.favorite_members <- Uuids.empty;
  List.iter
    (fun (item : Worker_pure_data.favorite_item) ->
       t.favorite_members <- Uuids.add item.membership_uuid t.favorite_members;
       match item.target with
       | Worker_pure_data.V2_favorite_block { uuid; _ } -> enqueue t (Block uuid)
       | Worker_pure_data.V2_favorite_page { uuid; _ } ->
         if not (Hashtbl.mem t.pages (Graph.Uuid.to_string uuid))
         then enqueue t (Page uuid))
    items
;;

let remember_assets t items =
  List.iter
    (fun (asset : Logseq_db_types.Asset_descriptor.t) ->
       if Hashtbl.length t.assets < maximum_dependency_facts
          || Hashtbl.mem t.assets (Graph.Uuid.to_string asset.uuid)
       then Hashtbl.replace t.assets (Graph.Uuid.to_string asset.uuid) ()
       else degrade t)
    items
;;

let observe_fact_result t ~request_id apply =
  let key = Graph.Uuid.to_string request_id in
  match Hashtbl.find_opt t.requests key with
  | None -> ()
  | Some (issuance, first_page) ->
    Hashtbl.remove t.requests key;
    if issuance > t.barrier then (
      apply issuance first_page;
      settle_dirty t)
;;

let observe_query : type a. t -> request_id:Graph.Uuid.t -> a Worker.query -> unit =
  fun t ~request_id query ->
  observe_fact_request t ~request_id
    ~first_page:(match query with Worker.Favorites None -> true | _ -> false)
;;

let observe_query_result
    : type a. t -> request_id:Graph.Uuid.t -> a Worker.query -> a -> unit
  = fun t ~request_id query value ->
  observe_fact_result t ~request_id (fun issuance first_page ->
    match query with
    | Worker.Outline_block _ ->
      (match value with
       | Worker_pure_data.V2_present_block { value; _ } ->
         remember_block_value t ~issuance value.block.uuid (Some value.block)
       | Worker_pure_data.V2_missing_block { uuid; _ } -> remember_block_value t ~issuance uuid None)
    | Page _ ->
      (match value with
       | Worker_pure_data.V2_present_page { page; _ } ->
         remember_page_value t ~issuance page.uuid (Some page);
         if page.name = "$$$favorites" && t.favorites_page <> Some page.uuid
         then dispatch t (Index_changed Favorites)
       | Worker_pure_data.V2_missing_page { uuid; _ } -> remember_page_value t ~issuance uuid None)
    | Block_summary _ ->
      (match value.lookup with
       | Worker_pure_data.V2_present_block { value; _ } ->
         remember_block_value t ~issuance value.block.uuid (Some value.block)
       | Worker_pure_data.V2_missing_block { uuid; _ } -> remember_block_value t ~issuance uuid None);
      Option.iter (function
        | Worker_pure_data.V2_present_page { page; _ } -> remember_page_value t ~issuance page.uuid (Some page)
        | Worker_pure_data.V2_missing_page { uuid; _ } -> remember_page_value t ~issuance uuid None) value.page;
      List.iter (fun (item : Worker_pure_data.child_member) ->
        remember_block_value t ~issuance item.value.block.uuid (Some item.value.block)) value.items
    | Child_members _ -> List.iter (fun (item : Worker_pure_data.child_member) ->
        remember_block_value t ~issuance item.value.block.uuid (Some item.value.block)) value.items
    | Tree _ -> List.iter (fun (item : Worker_pure_data.tree_member) ->
        remember_block_value t ~issuance item.value.block.uuid (Some item.value.block)) value.items
    | Journals _ -> List.iter (fun (item : Worker_pure_data.journal_item) ->
        remember_page_value t ~issuance item.page.uuid (Some item.page)) value.items
    | Worker.Favorites _ ->
      observe_favorites t ~first_page ~favorites_page:value.favorites_page value.items
    | Assets _ -> remember_assets t value.items
    | Asset_descriptors _ -> List.iter (Option.iter (fun asset -> remember_assets t [asset])) value.items
    | Children _ -> List.iter (fun value ->
        let value=Worker.block_data value in
        remember_block_value t ~issuance value.block.uuid (Some value.block)) value.items
    | Journal _ -> Option.iter (fun page ->
        let page=Worker.page_data page in
        remember_page_value t ~issuance page.uuid (Some page)) value
    | _ -> ())
;;

let changes t windows =
  if Option.is_some t.configuration && not t.degraded
  then (
    let affected = ref Uuids.empty in
    List.iter
      (fun (window : Worker_pure_data.change_window) ->
         List.iter
           (function
             | Worker_pure_data.V2_journal_index_interest -> dispatch t (Index_changed Recent)
             | Worker_pure_data.V2_children_interest uuid | Worker_pure_data.V2_page_tree_interest uuid ->
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
                            | Worker_pure_data.V2_page_tree_interest page ->
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
  t.resource_binding<-None;t.resume_configuration<-None;
  retire_policy_reads t;
  retire_dependency_reads t;
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
  clear_dependency_queue t;
  t.favorites_page <- None;
  t.favorite_members <- Uuids.empty;
  retain_releases t;
  pump t;
  t.configuration <- None;
  t.generation <- None;
  publish t
;;

let retire_coordinated_resources t =
  if t.resource_binding<>None then (
    t.resource_binding<-None;
    t.resume_configuration<-t.configuration;
    (* Keep the scan/dependency tickets that the coordinator will replan. Only
       physical demand registrations belong to the retiring binding. *)
    let consumers=ref(Hashtbl.to_seq_keys t.bound_consumers |> List.of_seq) in
    let reads=Queue.create() and cleanup=Queue.create() in
    Queue.iter(function
      |Policy.Demand{consumer;_}->consumers:=consumer::!consumers
      |Policy.Read _ as instruction->Queue.add instruction reads
      |Policy.Release _ as instruction->Queue.add instruction cleanup)t.queued;
    let consumers=List.sort_uniq String.compare !consumers in
    List.iter(fun consumer->Queue.add(Policy.Release consumer)cleanup)consumers;
    Queue.transfer reads cleanup;
    t.queued<-cleanup;
    List.iter(fun consumer->dispatch t (Policy.Backpressure consumer))consumers;
    pump t)
;;
let bind_coordinated_resources t binding =
  if Option.exists(fun previous->not(Worker.equal_binding previous binding))t.resource_binding
  then retire_coordinated_resources t;
  let resume=t.resume_configuration in
  t.resource_binding<-Some binding;t.resume_configuration<-None;
  match resume with
  |Some _->
    (* Resync preserves in-flight read ownership, but discards any sealed scan
       continuation before rebuilding demand against the replacement binding. *)
    dispatch t Policy.Resync;
    dispatch t Policy.Capacity_available
  |None->pump t
;;

let complete_dependency t ~request_id dependency issuance observe =
  Hashtbl.remove t.dependencies (Graph.Uuid.to_string request_id);
  observe ();
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
  true
;;

let receive_read t ~request_id (Read_result { read_id; query; value }) =
  let key = Graph.Uuid.to_string request_id in
  if not (Graph.Uuid.equal request_id read_id) then false
  else match Hashtbl.find_opt t.pending key with
  | None ->
    (match Hashtbl.find_opt t.dependencies key with
     | Some ((Block _ as dependency), issuance) ->
       (match query with
        | Worker.Outline_block _ -> complete_dependency t ~request_id dependency issuance
            (fun () -> observe_query_result t ~request_id query value)
        | _ -> false)
     | Some ((Page _ as dependency), issuance) ->
       (match query with
        | Worker.Page _ -> complete_dependency t ~request_id dependency issuance
            (fun () -> observe_query_result t ~request_id query value)
        | _ -> false)
     | None -> false)
  | Some ticket ->
    let event = match ticket.query, query with
      | Policy.Recent_roots _, Worker.Journals _ -> Some (Policy.Roots_loaded
          (ticket, List.map (fun (item : Worker_pure_data.journal_item) -> item.page.uuid) value.items,
           Option.map (fun c -> Journals_cursor c) value.next))
      | Favorite_roots _, Worker.Favorites _ -> Some (Policy.Roots_loaded
          (ticket, List.map (fun (item : Worker_pure_data.favorite_item) ->
             match item.target with
             | Worker_pure_data.V2_favorite_page { uuid; _ }
             | Worker_pure_data.V2_favorite_block { uuid; _ } -> uuid) value.items,
           Option.map (fun c -> Favorites_cursor c) value.next))
      | Assets _, Worker.Assets _ -> Some (Policy.Assets_loaded
          (ticket, value.items, Option.map (fun c -> Assets_cursor c) value.next))
      | _ -> None in
    match event with
    | None -> false
    | Some event ->
      Hashtbl.remove t.pending key;
      observe_query_result t ~request_id query value;
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
      clear_dependency_queue t;
      degrade t);
    Hashtbl.remove t.dependencies key;
    Hashtbl.remove t.requests key;
    pump t
  | Some ticket ->
    Hashtbl.remove t.pending key;
    dispatch t (Read_failed ticket)
;;

let demand_backpressured ?ticket t consumer =
  let current=match ticket,Hashtbl.find_opt t.bound_consumers consumer with
    |None,_->true
    |Some ticket,Some(pending,_)->Worker.equal_request_id (Coordination.ticket_id pending)(Coordination.ticket_id ticket)
    |Some _,None->false in
  if current then dispatch t(Policy.Backpressure consumer)

let notice t notice =
  if current_demand_notice t notice then
  let scope=Worker.asset_notice_scope notice and notice=Worker.asset_notice_data notice in
  if t.generation = Some scope.graph_generation
  then (
    match notice with
    | Service.Asset_demand_accepted consumer -> dispatch t (Demand_accepted consumer)
    | Asset_backpressure consumer -> dispatch t (Backpressure consumer)
    | Upload_status _ -> ()
    | Asset_capacity_available -> dispatch t Capacity_available
    | Asset_availability { consumer; asset; availability; _ } ->
      dispatch t (Availability { consumer; asset; availability }))
;;

let idle t = Queue.is_empty t.queued
