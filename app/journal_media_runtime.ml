module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Asset = Logseq_db_types.Asset_descriptor
module P = Journal_media
module G = Logseq_db_types.Graph_types
module Owners = Set.Make (String)

module Worker = Journal_worker_coordination.Worker_api
module Coordination = Journal_worker_coordination.Worker_pure_coordinator

type demand_registration = Worker.asset_demand Coordination.ticket * Worker.asset_demand option

type fact_ticket =
  { block : string
  ; request_id : G.Uuid.t
  ; generation : int option
  }

type _ read_ticket =
  | Listing : { root : string; epoch : int; request_id : G.Uuid.t }
      -> Worker.asset_listing read_ticket
  | Block_fact : fact_ticket -> Worker_pure_data.block_lookup read_ticket
  | Page_fact : fact_ticket -> Worker_pure_data.page_lookup read_ticket

type ticket =
  | Lease of
      { root : string
      ; epoch : int
      ; consumer : string
      ; ticket : P.ticket
      }

type read_result =
  | Read_result :
      { ticket : 'a read_ticket; query : 'a Worker.query; value : 'a }
      -> read_result

type read_request =
  | Read :
      { ticket : 'a read_ticket
      ; maximum_items : int
      ; query : 'a Worker.query
      ; outcome : 'a -> read_result
      }
      -> read_request

type item =
  { token : string
  ; asset : Asset.t
  ; file_type : string
  ; presentation : P.presentation
  }

type view =
  { items : item list
  ; more : bool
  ; error : string option
  }

type controller =
  { mutable asset : Asset.t
  ; consumer : string
  ; mutable state : P.t
  ; mutable shown : bool
  ; mutable owners : Owners.t
  }

let read_ticket_id : type a. a read_ticket -> G.Uuid.t = function
  | Listing { request_id; _ } -> request_id
  | Block_fact { request_id; _ } | Page_fact { request_id; _ } -> request_id
;;

let read_request_id (Read request) = read_ticket_id request.ticket
;;

type local_import=Worker.imported

type group =
  { root : string
  ; epoch : int
  ; mutable visible : bool
  ; mutable owners : Owners.t
  ; mutable membership_changed : bool
  ; mutable invalidation : int
  ; mutable dependency_failed : bool
  ; mutable listing_failed : bool
  ; mutable listing_recovered : bool
  ; mutable dependency_recovered : bool
  ; mutable failed_dependencies : Owners.t
  ; mutable pending : G.Uuid.t option
  ; mutable cursor : Asset.t Worker.continuation option
  ; mutable error : string option
  ; mutable local : local_import list
  ; mutable controllers : controller list
  ; mutable last_view : view option
  }

type outgoing_request =
  | Demand of {graph_generation:int;consumer:string;priority:Worker.asset_priority;assets:Asset.t list}
  | Acquire of ticket * Worker.asset_file
  | Retry_asset of {graph_generation:int;asset:G.Uuid.t}
  | Perform_read of read_request
  | Release_preview of Worker.file_lease
  | Release_consumer of demand_registration

type outgoing =
  { request : outgoing_request
  ; current : unit -> bool
  }

type fact =
  { value : G.block option
  ; issued : int
  ; edges_changed : bool
  }

type page_fact =
  { alive : bool
  ; issued : int
  }

type t =
  { release_file : Worker.file_lease -> bool
  ; release_consumer : demand_registration -> bool
  ; bound_consumers : (string,demand_registration)Hashtbl.t
  ; mutable resource_binding : Worker.binding option
  ; read_port : read_request -> bool
  ; read_planned : G.Uuid.t -> unit
  ; read_retired : G.Uuid.t -> unit
  ; demand : graph_generation:int -> name:string -> Worker.asset_priority -> Asset.t list -> Worker.asset_demand Coordination.ticket option
  ; acquire : ticket -> Worker.asset_file -> bool
  ; retry_asset : graph_generation:int -> G.Uuid.t -> bool
  ; changed : string -> view -> unit
  ; groups : (string, group) Hashtbl.t
  ; consumers : (string, group * controller) Hashtbl.t
  ; previews : (string, string * string * string) Hashtbl.t
  ; facts : (string, fact) Hashtbl.t
  ; pages : (string, page_fact) Hashtbl.t
  ; page_barriers : (string, int) Hashtbl.t
  ; sources : (G.Uuid.t, int) Hashtbl.t
  ; barriers : (string, int) Hashtbl.t
  ; fact_requests : (string, G.Uuid.t) Hashtbl.t
  ; mutable clock : int
  ; mutable generation : int option
  ; mutable serial : int
  ; mutable queued : outgoing list
  }

let create_state ~release_file ~release_consumer ~read_port ~read_planned ~read_retired ~demand ~acquire ~retry_asset ~changed =
  { release_file
  ; release_consumer
  ; bound_consumers=Hashtbl.create 32
  ; resource_binding=None
  ; read_port
  ; read_planned
  ; read_retired
  ; demand;acquire;retry_asset
  ; changed
  ; groups = Hashtbl.create 16
  ; consumers = Hashtbl.create 32
  ; previews = Hashtbl.create 4
  ; facts = Hashtbl.create 64
  ; pages = Hashtbl.create 16
  ; page_barriers = Hashtbl.create 16
  ; sources = Hashtbl.create 64
  ; barriers = Hashtbl.create 64
  ; fact_requests = Hashtbl.create 64
  ; clock = 0
  ; generation = None
  ; serial = 0
  ; queued = []
  }
;;

let create ~release_file ~release_consumer ?(read_planned=fun _->())
      ?(read_retired=fun _->()) ~read ~demand ~acquire ~retry_asset ~changed () =
  create_state ~release_file ~release_consumer ~read_port:read ~read_planned ~read_retired ~demand ~acquire ~retry_asset ~changed
;;

let owns_read t request_id =
  Hashtbl.fold
    (fun _ actual found -> found || G.Uuid.equal actual request_id)
    t.fact_requests
    false
  || Hashtbl.fold (fun _ g found -> found || g.pending = Some request_id) t.groups false
;;

let retire_outgoing t outgoing =
  match outgoing.request with
  | Perform_read (Read request) ->
    (match request.ticket with
     | Block_fact { block; request_id; _ } | Page_fact { block; request_id; _ } ->
       if Hashtbl.find_opt t.fact_requests block = Some request_id
       then Hashtbl.remove t.fact_requests block
     | Listing { root; epoch; request_id } ->
       (match Hashtbl.find_opt t.groups root with
        | Some g when g.epoch = epoch && g.pending = Some request_id ->
          g.pending <- None; g.membership_changed <- true
        | _ -> ()));
    t.read_retired (read_request_id (Read request))
  | Demand _ | Acquire _ | Retry_asset _ | Release_preview _ | Release_consumer _ -> ()
;;

let empty_view = { items = []; more = false; error = None }

let notify t g =
  let view =
    { items =
        List.filter_map
          (fun (local:local_import) ->
         let receipt=Worker.import_data local in
             Option.map
               (fun lease ->
                  { token = "import:" ^ G.Uuid.to_string receipt.operation
                  ; asset = receipt.asset
                  ; file_type = receipt.file_type
                  ; presentation = P.File (Worker.file_path lease)
                  })
               (Worker.import_preview local))
          g.local
        @ List.map
            (fun c ->
               { token = c.consumer
               ; asset = c.asset
               ; file_type =
                   (match P.presentation c.state with
                    | File path when Filename.extension path <> "" ->
                      let extension = Filename.extension path in
                      String.sub extension 1 (String.length extension - 1)
                    | _ ->
                      (match c.asset.source with
                       | Managed (Some v) -> v.file_type
                       | _ -> ""))
               ; presentation = P.presentation c.state
               })
            (List.filter
               (fun c ->
                  not
                    (List.exists
                       (fun (local:local_import) ->
                          (Worker.import_data local).asset.uuid = c.asset.uuid)
                       g.local))
               g.controllers)
    ; more = Option.is_some g.cursor
    ; error = g.error
    }
  in
  if g.last_view <> Some view
  then (
    g.last_view <- Some view;
    t.changed g.root view)
;;

let tick t =
  t.clock <- t.clock + 1;
  t.clock
;;

let forget_request t request_id = Hashtbl.remove t.sources request_id

let group_page t g =
  match Hashtbl.find_opt t.facts g.root with
  | Some { value = Some block; _ } -> Some (G.Uuid.to_string block.page)
  | _ -> None
;;

let group_reaches t g target =
  let rec reachable depth seen node =
    if node = target
    then true
    else if depth >= 256 || Owners.mem node seen
    then false
    else (
      match Hashtbl.find_opt t.facts node with
      | Some { value = Some block; _ } ->
        let parent = G.Uuid.to_string block.parent in
        parent <> G.Uuid.to_string block.page
        && reachable (depth + 1) (Owners.add node seen) parent
      | _ -> false)
  in
  if String.starts_with ~prefix:"page:" target
  then group_page t g = Some (String.sub target 5 (String.length target - 5))
  else reachable 0 Owners.empty g.root
;;

let dependency_failure t node message =
  Hashtbl.iter
    (fun _ g ->
       if group_reaches t g node
       then (
         g.dependency_failed <- true;
         g.failed_dependencies <- Owners.add node g.failed_dependencies;
         g.error <- Some message;
         notify t g))
    t.groups
;;

let dependency_received t node =
  Hashtbl.iter(fun _ g->
    if Owners.mem node g.failed_dependencies then (
      g.failed_dependencies<-Owners.remove node g.failed_dependencies;
      if Owners.is_empty g.failed_dependencies then (
        g.dependency_recovered<-false;
        g.dependency_failed<-false;
        if not g.listing_failed then g.error<-None)))t.groups
;;

let observe_fact_request t ~request_id =
  if Hashtbl.mem t.sources request_id || Hashtbl.length t.sources < 4096
  then Hashtbl.replace t.sources request_id (tick t)
;;



let fact_needed t target =
  Hashtbl.to_seq_values t.groups
  |> Seq.exists (fun g ->
    g.visible && (not g.dependency_failed) && group_reaches t g target)
;;

let observe_query : type a. t -> request_id:G.Uuid.t -> a Worker.query -> unit =
  fun t ~request_id query ->
  if Hashtbl.mem t.sources request_id || Hashtbl.length t.sources < 4096
  then observe_fact_request t ~request_id
  else
    let fail uuid = dependency_failure t (G.Uuid.to_string uuid)
      "Attachment dependency requests are full." in
    match query with
    | Worker.Outline_block { uuid; _ } -> fail uuid
    | Block_summary { block; _ } -> fail block
    | Children { parent; _ } -> fail parent
    | Child_members { parent; _ } -> fail parent
    | Page { uuid; _ } -> dependency_failure t ("page:" ^ G.Uuid.to_string uuid)
        "Attachment page requests are full."
    | Assets { roots; _ } -> List.iter fail roots
    | _ -> ()
;;

let rec pump t =
  match t.queued with
  | [] -> ()
  | next :: rest ->
    if not (next.current ())
    then (
      retire_outgoing t next;
      t.queued <- rest;
      pump t)
    else if
      match next.request with
      | Demand {graph_generation;consumer;priority;assets}->
        (match t.demand ~graph_generation ~name:consumer priority assets with
         |None->false|Some bound->Hashtbl.replace t.bound_consumers consumer (bound,None);true)
      | Acquire(ticket,file)->t.acquire ticket file
      | Retry_asset{graph_generation;asset}->t.retry_asset ~graph_generation asset
      | Perform_read request -> t.read_port request
      | Release_preview lease->t.release_file lease
      | Release_consumer consumer->t.release_consumer consumer
    then (
      (match next.request with
       | Perform_read (Read request) ->
         (match request.ticket with
          | Block_fact _ -> observe_query t ~request_id:(read_ticket_id request.ticket) request.query
          | Page_fact _ -> observe_query t ~request_id:(read_ticket_id request.ticket) request.query
          | Listing _ -> ())
       | _ -> ());
      t.queued <- rest;
      pump t)
;;

let enqueue t ?(current = fun () -> true) request =
  t.queued
  <- List.filter
       (fun item ->
          if item.current ()
          then true
          else (
            retire_outgoing t item;
            false))
       t.queued
     @ [ { request; current } ]
;;

let current_group t g =
  match Hashtbl.find_opt t.groups g.root with
  | Some current -> current.epoch = g.epoch
  | None -> false
;;

let current_controller t g c = current_group t g && Hashtbl.mem t.consumers c.consumer

let release_retained_file t lease =
  enqueue t (Release_preview lease)
;;

let release_bound_consumer t consumer =
  match Hashtbl.find_opt t.bound_consumers consumer with
  | Some bound->Hashtbl.remove t.bound_consumers consumer;enqueue t(Release_consumer bound)
  | None->()
;;

let instructions t g c effects =
  List.iter
    (function
      | P.Demand {graph_generation;consumer;asset}->
        enqueue t ~current:(fun()->current_controller t g c && c.shown && P.descriptor c.state=Some asset)
          (Demand{graph_generation;consumer;priority=Worker.Foreground;assets=[asset]})
      | Release{consumer;_}->release_bound_consumer t consumer
      | Retry{graph_generation;asset}->
        enqueue t ~current:(fun()->current_controller t g c && c.shown)(Retry_asset{graph_generation;asset})
      | Acquire ticket->
        enqueue t ~current:(fun()->current_controller t g c && P.ticket_current c.state ticket)
          (Acquire(Lease{root=g.root;epoch=g.epoch;consumer=c.consumer;ticket},ticket.file))
      | Release_file lease->release_retained_file t lease)
    effects
;;

let dispatch t g c event =
  let state, effects = P.step c.state event in
  c.state <- state;
  instructions t g c effects
;;

let release_import t local =
  Option.iter(release_retained_file t)(Worker.import_preview local)
;;

let handoff_imports t g =
  let completed, pending =
    List.partition
      (fun (local:local_import) ->
         let receipt=Worker.import_data local in
         let token = "import:" ^ G.Uuid.to_string receipt.operation in
         (not
            (Hashtbl.to_seq_values t.previews
             |> Seq.exists (fun (_, root, asset) -> root = g.root && asset = token)))
         (* Hidden controllers already released their File. Without a view
            owner, the durable intent/cache owns the bytes, not this UI lease. *)
         && ((not g.visible)
             || List.exists
                  (fun c ->
                     c.asset.uuid = receipt.asset.uuid
                     && c.asset.current_checksum = receipt.asset.current_checksum
                     &&
                     match P.presentation c.state with
                     | P.File _ -> true
                     | _ -> false)
                  g.controllers))
      g.local
  in
  g.local <- pending;
  List.iter (release_import t) completed
;;

let clear t g =
  List.iter (release_import t) g.local;
  g.local <- [];
  g.owners <- Owners.empty;
  List.iter
    (fun c ->
       c.shown <- false;
       c.owners <- Owners.empty;
       dispatch t g c P.Hide;
       Hashtbl.remove t.consumers c.consumer)
    g.controllers;
  g.controllers <- []
;;

let next_request_id t =
  t.serial <- t.serial + 1;
  G.Uuid.of_string (Printf.sprintf "a55e8000-0000-4000-8000-%012x" t.serial)
  |> Result.get_ok
;;

let read t g cursor =
  if (not g.dependency_failed) && g.pending = None && List.length t.queued < 1024
  then (
    let request_id = next_request_id t in
    let root = G.Uuid.of_string g.root |> Result.get_ok in
    g.pending <- Some request_id;
    g.membership_changed <- false;
    g.error <- None;
    let ticket = Listing { root = g.root; epoch = g.epoch; request_id } in
    t.read_planned request_id;
    let current () = current_group t g && g.pending = Some request_id in
    let query = Worker.Assets { recursive = false; roots = [ root ]; after = cursor } in
    let request = Read
      { ticket; maximum_items = 16; query
      ; outcome = (fun value -> Read_result { ticket; query; value }) }
    in
    t.queued <- List.filter
      (fun item -> if item.current () then true else (retire_outgoing t item; false))
      t.queued
      @ [{ request = Perform_read request; current }])
  else if g.pending = None
  then g.error <- Some "Attachment requests are busy."
;;

let ensure_fresh t g = if g.membership_changed && g.pending = None then read t g None

let reset t ~graph_generation =
  Hashtbl.iter (fun _ id -> t.read_retired id) t.fact_requests;
  Hashtbl.iter (fun _ g -> Option.iter t.read_retired g.pending) t.groups;
  Hashtbl.iter
    (fun _ g ->
       clear t g;
       t.changed g.root empty_view)
    t.groups;
  Hashtbl.clear t.groups;
  Hashtbl.clear t.consumers;
  Hashtbl.clear t.previews;
  Hashtbl.clear t.facts;
  Hashtbl.clear t.pages;
  Hashtbl.clear t.page_barriers;
  Hashtbl.clear t.sources;
  Hashtbl.clear t.barriers;
  Hashtbl.clear t.fact_requests;
  t.generation <- graph_generation;
  pump t
;;

let root_visible ?(owner = "default") t ~root visible =
  if visible && (not (Hashtbl.mem t.groups root)) && Hashtbl.length t.groups >= 64
  then (
    match Hashtbl.to_seq_values t.groups |> Seq.find (fun g -> not g.visible) with
    | None -> ()
    | Some old ->
      clear t old;
      Hashtbl.remove t.groups old.root;
      t.changed old.root empty_view);
  match Hashtbl.find_opt t.groups root, visible, t.generation with
  | Some g, false, _ ->
    g.owners <- Owners.remove owner g.owners;
    g.visible <- not (Owners.is_empty g.owners);
    if not g.visible
    then (
      let removed =
        List.exists
          (fun queued ->
             match queued.request with
             | Perform_read (Read { ticket = Listing { request_id; _ }; _ }) -> g.pending = Some request_id
             | _ -> false)
          t.queued
      in
      if removed
      then (
        g.pending <- None;
        g.membership_changed <- true));
    List.iter
      (fun (c : controller) ->
         c.owners <- Owners.remove owner c.owners;
         if c.shown && Owners.is_empty c.owners
         then (
           c.shown <- false;
           dispatch t g c Hide))
      g.controllers;
    notify t g;
    pump t
  | Some g, true, Some _ ->
    g.owners <- Owners.add owner g.owners;
    g.visible <- true;
    ensure_fresh t g;
    pump t
  | None, true, Some _ when Hashtbl.length t.groups < 64 && List.length t.queued < 1024 ->
    (match G.Uuid.of_string root with
     | Error _ -> ()
     | Ok _ ->
       t.serial <- t.serial + 1;
       let g =
         { root
         ; epoch = t.serial
         ; visible = true
         ; owners = Owners.singleton owner
         ; membership_changed = true
         ; invalidation = 0
         ; dependency_failed = false
         ; listing_failed = false
         ; listing_recovered = false
         ; dependency_recovered = false
         ; failed_dependencies = Owners.empty
         ; pending = None
         ; cursor = None
         ; error = None
         ; local = []
         ; controllers = []
         ; last_view = None
         }
       in
       Hashtbl.add t.groups root g;
       read t g None;
       pump t)
  | _ -> ()
;;

let retain_visible_roots ?(owner = "default") t roots =
  let visible = Hashtbl.create (List.length roots) in
  List.iter (fun root -> Hashtbl.replace visible root ()) roots;
  Hashtbl.iter
    (fun root group ->
       if Owners.mem owner group.owners && not (Hashtbl.mem visible root)
       then root_visible ~owner t ~root false)
    t.groups
;;

let unpin_preview t preview root asset =
  Option.iter(fun g->Option.iter(fun c->dispatch t g c(P.Unpin_preview preview))
    (List.find_opt(fun c->c.consumer=asset)g.controllers))(Hashtbl.find_opt t.groups root)
;;

let retain_owners t owners =
  let retained = Owners.of_list owners in
  Hashtbl.filter_map_inplace
    (fun preview (owner, root, asset) ->
       if Owners.mem owner retained
       then Some (owner, root, asset)
       else (
         unpin_preview t preview root asset;
         root_visible ~owner:preview t ~root false;
         None))
    t.previews;
  let retained =
    Hashtbl.fold (fun preview _ owners -> Owners.add preview owners) t.previews retained
  in
  Hashtbl.iter
    (fun root g ->
       Owners.iter
         (fun owner ->
            if not (Owners.mem owner retained) then root_visible ~owner t ~root false)
         g.owners;
       handoff_imports t g;
       notify t g)
    t.groups;
  pump t
;;

let asset_visible ?(owner = "default") t ~root ~asset visible =
  match Hashtbl.find_opt t.groups root, t.generation with
  | Some g, Some graph_generation ->
    (match List.find_opt (fun c -> c.consumer = asset) g.controllers with
     | Some c when (not visible) || c.shown || List.length t.queued < 1024 ->
       (* Native child appearance can precede its parent's appearance. The
          visible asset itself establishes this presentation's root ownership. *)
       if visible
       then (
         g.owners <- Owners.add owner g.owners;
         g.visible <- true;
         ensure_fresh t g);
       c.owners
       <- (if visible then Owners.add owner c.owners else Owners.remove owner c.owners);
       let shown = not (Owners.is_empty c.owners) in
       if c.shown <> shown
       then (
         c.shown <- shown;
         dispatch
           t
           g
           c
           (if shown
            then Show { graph_generation; consumer = c.consumer; asset = c.asset }
            else Hide);
         notify t g);
       pump t
     | _ -> ())
  | _ -> ()
;;

let preview_visible t ~owner ~slot ~root ~asset visible =
  let preview = "preview:" ^ owner ^ ":" ^ slot in
  let selected = owner, root, asset in
  let current = Hashtbl.find_opt t.previews preview in
  if (not visible) || current <> Some selected
  then (
    Hashtbl.remove t.previews preview;
    Option.iter
      (fun (_, root, asset) ->
         unpin_preview t preview root asset;
         root_visible ~owner:preview t ~root false;
         Option.iter
           (fun g ->
              handoff_imports t g;
              notify t g)
           (Hashtbl.find_opt t.groups root))
      current;
    pump t);
  if visible
  then (
    match Hashtbl.find_opt t.groups root with
    | Some g
      when List.exists
             (fun c ->
                c.consumer = asset
                &&
                match P.presentation c.state with
                | File _ -> true
                | _ -> false)
             g.controllers
           || List.exists
                (fun (local:local_import) ->
         let receipt=Worker.import_data local in
                   asset = "import:" ^ G.Uuid.to_string receipt.operation
                   && Option.is_some(Worker.import_preview local))
                g.local ->
      Hashtbl.replace t.previews preview selected;
      root_visible ~owner:preview t ~root true;
      asset_visible ~owner:preview t ~root ~asset true;
      Option.iter(fun c->dispatch t g c(P.Pin_preview preview))
        (List.find_opt(fun c->c.consumer=asset)g.controllers)
    | _ -> ())
;;

let next t ~root =
  match Hashtbl.find_opt t.groups root with
  | Some g when g.pending = None && (g.membership_changed || g.cursor <> None) ->
    read t g (if g.membership_changed then None else g.cursor);
    notify t g;
    pump t
  | _ -> ()
;;

let property_dependencies properties =
  let rec internal depth found = function
    | G.Internal_uuid uuid -> Owners.add (G.Uuid.to_string uuid) found
    | Internal_list values when depth < 64 ->
      List.fold_left (internal (depth + 1)) found values
    | Internal_map values when depth < 64 ->
      List.fold_left
        (fun acc (k, v) -> internal (depth + 1) (internal (depth + 1) acc k) v)
        found
        values
    | _ -> found
  in
  List.fold_left
    (fun found (property : G.property_summary) ->
       List.fold_left
         (fun found -> function
            | G.Node_value uuid
            | Asset_value uuid
            | Entity_value uuid
            | Class_value uuid
            | Page_value uuid -> Owners.add (G.Uuid.to_string uuid) found
            | Map_value values -> internal 0 found (G.Internal_map values)
            | Collection_value values -> internal 0 found (G.Internal_list values)
            | Any_value value -> internal 0 found value
            | _ -> found)
         (Owners.add (G.Uuid.to_string property.uuid) found)
         property.values)
    Owners.empty
    properties
;;

let request_fact t block =
  Option.iter t.read_planned (Hashtbl.find_opt t.fact_requests block);
  if
    (not (Hashtbl.mem t.fact_requests block))
    && Hashtbl.length t.fact_requests < 64
    && List.length t.queued < 1024
  then (
    let page = String.starts_with ~prefix:"page:" block in
    let uuid_string =
      if page then String.sub block 5 (String.length block - 5) else block
    in
    match G.Uuid.of_string uuid_string with
    | Error _ -> ()
    | Ok uuid ->
      let request_id = next_request_id t in
      Hashtbl.add t.fact_requests block request_id;
      t.read_planned request_id;
      let generation = t.generation in
      let fact = { block; request_id; generation } in
      let current () =
        t.generation = generation
        && fact_needed t block
        && Hashtbl.find_opt t.fact_requests block = Some request_id
      in
      let submit : type a. a read_ticket -> a Worker.query -> unit = fun ticket query ->
        let request = Read { ticket; maximum_items = 1; query;
          outcome = (fun value -> Read_result { ticket; query; value }) } in
        t.queued <- t.queued @ [{ request = Perform_read request; current }]
      in
      if page then submit (Page_fact fact) (Worker.Page { uuid; revision = None })
      else submit (Block_fact fact) (Worker.Outline_block { uuid; revision = None }))
;;

let request_pending_pages t =
  Hashtbl.iter
    (fun page at ->
       let key = "page:" ^ page in
       if
         fact_needed t key
         &&
         match Hashtbl.find_opt t.pages page with
         | Some fact -> fact.issued <= at
         | None -> true
       then request_fact t key)
    t.page_barriers
;;

let asset_dependencies t g =
  let successful =
    List.fold_left
      (fun ids c ->
         match P.presentation c.state with
         | P.File _ -> Owners.add (G.Uuid.to_string c.asset.uuid) ids
         | _ -> ids)
      Owners.empty
      g.controllers
  in
  let found =
    match Hashtbl.find_opt t.facts g.root with
    | Some { value = Some block; _ } ->
      List.fold_left
        (fun deps uuid -> Owners.add (G.Uuid.to_string uuid) deps)
        (property_dependencies block.properties)
        block.refs
    | _ -> Owners.empty
  in
  let found =
    List.fold_left
      (fun deps c -> Owners.add (G.Uuid.to_string c.asset.uuid) deps)
      found
      g.controllers
  in
  Owners.diff found successful
;;

let membership_signature block =
  block.G.parent, block.refs, block.tags, property_dependencies block.properties
;;

let truncated (block : G.block) =
  List.exists (fun (p : G.property_summary) -> p.values_truncated) block.G.properties
;;

let dependencies t g =
  let rec ancestors depth seen node =
    if depth >= 256 || Owners.mem node seen
    then seen
    else (
      let seen = Owners.add node seen in
      match Hashtbl.find_opt t.facts node with
      | None ->
        if g.visible && not g.dependency_failed then request_fact t node;
        seen
      | Some { value = None; _ } -> seen
      | Some { value = Some block; _ } ->
        let page = G.Uuid.to_string block.page
        and parent = G.Uuid.to_string block.parent in
        let seen = Owners.add page seen in
        if parent = page then seen else ancestors (depth + 1) seen parent)
  in
  let found = ancestors 0 Owners.empty g.root in
  Owners.union found (asset_dependencies t g)
;;

let invalidate t g at =
  if at > g.invalidation
  then (
    g.invalidation <- at;
    g.membership_changed <- true;
    g.cursor <- None;
    Option.iter t.read_planned g.pending;
    if g.visible && not g.dependency_failed then ensure_fresh t g)
;;

let reconcile_dependencies t =
  Hashtbl.iter
    (fun _ g ->
       let deps = dependencies t g
       and assets = asset_dependencies t g in
       let latest =
         Owners.fold
           (fun node at ->
              let changed =
                Owners.mem node assets
                ||
                match Hashtbl.find_opt t.facts node with
                | Some fact -> fact.edges_changed
                | None -> false
              in
              if changed
              then max at (Option.value (Hashtbl.find_opt t.barriers node) ~default:0)
              else at)
           deps
           0
       in
       invalidate t g latest)
    t.groups;
  request_pending_pages t
;;

let observe_fact_result t ~request_id apply =
  match Hashtbl.find_opt t.sources request_id with
  | None -> ()
  | Some issued ->
    Hashtbl.remove t.sources request_id;
    let changed = ref false in
    let remember uuid value =
      let key = G.Uuid.to_string uuid in
      let barrier = Option.value (Hashtbl.find_opt t.barriers key) ~default:0 in
      let prior =
        match Hashtbl.find_opt t.facts key with
        | Some fact -> fact.issued
        | None -> 0
      in
      if
        issued > barrier
        && issued >= prior
        && (Hashtbl.mem t.facts key || Hashtbl.length t.facts < 4096)
      then (
        let edges_changed =
          match Hashtbl.find_opt t.facts key, value with
          | Some { value = Some old; _ }, Some fresh ->
            membership_signature old <> membership_signature fresh
            || truncated old
            || truncated fresh
          | Some { value = None; _ }, None -> false
          | Some _, _ -> true
          | None, _ ->
            Hashtbl.to_seq_values t.groups |> Seq.exists (fun g -> group_reaches t g key)
        in
        Hashtbl.replace t.facts key { value; issued; edges_changed };
        dependency_received t key;
        if Hashtbl.mem t.barriers key then changed := true)
      else if issued > barrier && issued >= prior && not (Hashtbl.mem t.facts key)
      then dependency_failure t key "Attachment dependency cache is full."
    in
    let remember_page uuid alive =
      let page = G.Uuid.to_string uuid in
      let barrier = Option.value (Hashtbl.find_opt t.page_barriers page) ~default:0 in
      let previous = Hashtbl.find_opt t.pages page in
      let prior =
        match previous with
        | Some fact -> fact.issued
        | None -> 0
      in
      if issued > barrier && issued >= prior
      then
        if Hashtbl.mem t.pages page || Hashtbl.length t.pages < 64
        then (
          let was_alive =
            match previous with
            | Some fact -> fact.alive
            | None -> true
          in
          Hashtbl.replace t.pages page { alive; issued };
          dependency_received t ("page:" ^ page);
          if was_alive <> alive
          then
            Hashtbl.iter
              (fun _ g ->
                 if group_page t g = Some page then invalidate t g (max barrier issued))
              t.groups)
        else dependency_failure t ("page:" ^ page) "Attachment page cache is full."
    in
    apply remember remember_page;
    if !changed
    then (
      reconcile_dependencies t;
      pump t)
;;

let remember_page_lookup remember_page = function
  | Worker_pure_data.V2_present_page { page; _ } ->
    remember_page page.uuid (not page.recycled)
  | Worker_pure_data.V2_missing_page { uuid; _ } -> remember_page uuid false
;;

let remember_block remember (record : Worker_pure_data.block_record) =
  remember record.block.uuid (Some record.block)
;;

let remember_block_lookup remember = function
  | Worker_pure_data.V2_present_block { value; _ } -> remember_block remember value
  | Worker_pure_data.V2_missing_block { uuid; _ } -> remember uuid None
;;

let observe_query_result
    : type a. t -> request_id:G.Uuid.t -> a Worker.query -> a -> unit
  = fun t ~request_id query value ->
  observe_fact_result t ~request_id (fun remember remember_page ->
    let page_lookup = remember_page_lookup remember_page in
    let block = remember_block remember in
    let lookup = remember_block_lookup remember in
    match query with
    | Worker.Outline_block _ -> lookup value
    | Page _ -> page_lookup value
    | Journal _ -> Option.iter (fun page ->
        let page = Worker.page_data page in remember_page page.uuid (not page.recycled)) value
    | Block_summary _ ->
      lookup value.lookup;
      Option.iter page_lookup value.page;
      List.iter (fun (item : Worker_pure_data.child_member) -> block item.value) value.items
    | Child_members _ ->
      List.iter (fun (item : Worker_pure_data.child_member) -> block item.value) value.items
    | Children _ -> List.iter (fun value -> block (Worker.block_data value)) value.items
    | Tree _ -> List.iter (fun (item : Worker_pure_data.tree_member) -> block item.value) value.items
    | Journals _ -> List.iter (fun (item : Worker_pure_data.journal_item) ->
        remember_page item.page.uuid (not item.page.recycled)) value.items
    | _ -> ())
;;

(* Observation registers facts only. The changes owner determines which
       membership reads are invalid; dependency lookups complete that decision. *)

let chain_complete t g =
  let rec walk depth seen node =
    if depth >= 256 || Owners.mem node seen
    then true
    else (
      match Hashtbl.find_opt t.facts node with
      | None -> false
      | Some { value = None; _ } -> true
      | Some { value = Some block; _ } ->
        let parent = G.Uuid.to_string block.parent in
        parent = G.Uuid.to_string block.page
        || walk (depth + 1) (Owners.add node seen) parent)
  in
  walk 0 Owners.empty g.root
;;

let affected_by_changes t g windows =
  let deps = dependencies t g in
  (not (chain_complete t g))
  || List.exists
       (fun (window : Worker_pure_data.change_window) ->
          List.exists (fun id -> Owners.mem (G.Uuid.to_string id) deps) window.block_uuids
          || Option.exists
               (fun page ->
                  List.exists (fun id -> G.Uuid.to_string id = page) window.page_uuids)
               (group_page t g))
       windows
;;

let group_read_error g =
  if g.visible && (g.dependency_failed || (g.listing_failed && g.pending = None))
  then Some (Option.value g.error ~default:"Attachment reads could not finish")
  else None
;;

let projection_read_error t ~root =
  Option.bind (Hashtbl.find_opt t.groups root) group_read_error
;;

let changes t windows =
  let at = tick t in
  let relevant =
    Hashtbl.fold
      (fun _ g deps -> Owners.union deps (dependencies t g))
      t.groups
      Owners.empty
  in
  let unresolved =
    Hashtbl.to_seq_values t.groups
    |> Seq.exists (fun g -> (not g.dependency_failed) && not (chain_complete t g))
  in
  if not unresolved
  then
    Hashtbl.filter_map_inplace
      (fun node barrier -> if Owners.mem node relevant then Some barrier else None)
      t.barriers;
  let mark uuid =
    let key = G.Uuid.to_string uuid in
    if Owners.mem key relevant || unresolved
    then
      if Hashtbl.mem t.barriers key || Hashtbl.length t.barriers < 4096
      then Hashtbl.replace t.barriers key at
      else
        Hashtbl.iter
          (fun _ g ->
             if group_reaches t g key || not (chain_complete t g)
             then (
               g.dependency_failed <- true;
               g.error <- Some "Attachment change dependencies are full.";
               notify t g))
          t.groups
  in
  (* Non-recursive membership does not depend on siblings or page-tree growth.
     The changed block identities carry holder/ancestor moves and deletion. *)
  List.iter
    (fun (window : Worker_pure_data.change_window) -> List.iter mark window.block_uuids)
    windows;
  List.iter
    (fun (window : Worker_pure_data.change_window) ->
       List.iter
         (fun uuid ->
            let page = G.Uuid.to_string uuid in
            if
              Hashtbl.to_seq_values t.groups
              |> Seq.exists (fun g -> group_page t g = Some page)
            then
              if Hashtbl.mem t.page_barriers page || Hashtbl.length t.page_barriers < 64
              then Hashtbl.replace t.page_barriers page at
              else
                dependency_failure
                  t
                  ("page:" ^ page)
                  "Attachment page dependencies are full.")
         window.page_uuids)
    windows;
  reconcile_dependencies t;
  Hashtbl.iter
    (fun _ g ->
       if g.visible && not g.dependency_failed
       then
         Owners.iter
           (fun node ->
              if
                Hashtbl.find_opt t.barriers node = Some at
                && Hashtbl.mem t.facts node
                && not (Owners.mem node (asset_dependencies t g))
              then (
                let fact = Hashtbl.find t.facts node in
                let stable_file =
                  node = g.root
                  && List.exists
                       (fun c ->
                          G.Uuid.to_string c.asset.uuid = node
                          &&
                          match P.presentation c.state with
                          | P.File _ -> true
                          | _ -> false)
                       g.controllers
                in
                if (not fact.edges_changed) && not stable_file then request_fact t node))
           (dependencies t g))
    t.groups;
  Hashtbl.iter
    (fun node fact ->
       if Hashtbl.find_opt t.barriers node = Some at
       then Hashtbl.replace t.facts node { fact with edges_changed = false })
    t.facts;
  (* A user-initiated retry may already be queued/in flight before this batch is
     re-delivered. It remains a read obligation until the real listing succeeds. *)
  Hashtbl.iter
    (fun _ g ->
       if g.visible && g.listing_failed && affected_by_changes t g windows
       then Option.iter t.read_planned g.pending)
    t.groups;
  pump t
;;

let change_application_error t windows =
  Hashtbl.fold
    (fun _ g found ->
       match found with
       | Some _ -> found
       | None -> if affected_by_changes t g windows then group_read_error g else None)
    t.groups
    None
;;

let resync t =
  let at = tick t in
  Hashtbl.clear t.facts;
  Hashtbl.clear t.pages;
  Hashtbl.clear t.page_barriers;
  Hashtbl.clear t.sources;
  Hashtbl.clear t.fact_requests;
  Hashtbl.clear t.barriers;
  Hashtbl.iter
    (fun _ g ->
       g.dependency_failed <- false;
       invalidate t g at)
    t.groups;
  pump t
;;

let retry ?(owner = "default") t ~root ~asset =
  match Hashtbl.find_opt t.groups root with
  | None -> ()
  | Some g ->
    (match List.find_opt (fun c -> c.consumer = asset) g.controllers with
     | Some c when c.shown -> dispatch t g c Retry_requested
     | Some _ -> asset_visible ~owner t ~root ~asset true
     | None when asset = "" ->
       (* Explicit retry may reclaim facts no retained root depends on. *)
       Hashtbl.filter_map_inplace
         (fun node fact ->
            if
              Hashtbl.to_seq_values t.groups
              |> Seq.exists (fun owner -> group_reaches t owner node)
            then Some fact
            else None)
         t.facts;
       let retained_page page =
         Hashtbl.to_seq_values t.groups
         |> Seq.exists (fun owner -> group_page t owner = Some page)
       in
       Hashtbl.filter_map_inplace
         (fun page fact -> if retained_page page then Some fact else None)
         t.pages;
       Hashtbl.filter_map_inplace
         (fun page barrier -> if retained_page page then Some barrier else None)
         t.page_barriers;
       g.dependency_failed <- false;
       g.error <- None;
       ignore (dependencies t g);
       request_pending_pages t;
       read t g None
     | None -> ());
    notify t g;
    pump t
;;

let recover_failed_reads t =
  Hashtbl.iter(fun _ g ->
    if g.visible then (
      if g.dependency_failed && not g.dependency_recovered then (
        g.dependency_recovered <- true;
        retry t ~root:g.root ~asset:"")
      ;
      if g.listing_failed && g.pending=None && not g.listing_recovered then (
        g.listing_recovered <- true;
        retry t ~root:g.root ~asset:""))) t.groups
;;

let release_stale t result = Option.iter(release_retained_file t)result
;;

let receive_listing t ~root ~epoch ~request_id listing =
  match Hashtbl.find_opt t.groups root with
  | Some g when g.epoch = epoch && g.pending = Some request_id ->
    Hashtbl.remove t.sources request_id;
    g.pending <- None;
    if g.membership_changed
    then (if g.visible && not g.dependency_failed then ensure_fresh t g)
    else (
      match listing with
      | Some (items, next_cursor) ->
        g.listing_failed <- false;
        g.listing_recovered <- false;
        let old = g.controllers in
        let controllers =
          List.map
            (fun asset ->
               match List.find_opt (fun c -> c.asset.uuid = asset.Asset.uuid) old with
               | Some c ->
                 c.asset <- asset;
                 if c.shown
                 then (
                   match t.generation with
                   | Some graph_generation ->
                     dispatch
                       t
                       g
                       c
                       (P.Show { graph_generation; consumer = c.consumer; asset })
                   | None -> ());
                 c
               | None ->
                 t.serial <- t.serial + 1;
                 { asset
                 ; consumer = Printf.sprintf "media:%d:%d" epoch t.serial
                 ; state = P.empty
                 ; shown = false
                 ; owners = Owners.empty
                 })
            items
        in
        List.iter
          (fun c ->
             if not (List.exists (fun kept -> kept.consumer = c.consumer) controllers)
             then (
               c.shown <- false;
               c.owners <- Owners.empty;
               dispatch t g c Hide;
               Hashtbl.remove t.consumers c.consumer))
          old;
        g.controllers <- controllers;
        g.cursor <- next_cursor;
        if not g.dependency_failed then g.error <- None;
        List.iter
          (fun c ->
             Hashtbl.replace t.consumers c.consumer (g, c);
             if
               g.visible
               && (not c.shown)
               && List.exists
                    (fun (local:local_import) ->
         let receipt=Worker.import_data local in
                       receipt.asset.uuid = c.asset.uuid)
                    g.local
             then (
               match t.generation with
               | None -> ()
               | Some graph_generation ->
                 c.shown <- true;
                 c.owners <- g.owners;
                 dispatch
                   t
                   g
                   c
                   (P.Show { graph_generation; consumer = c.consumer; asset = c.asset })))
          controllers
      | _ ->
        g.listing_failed <- true;
        g.error <- Some "Unable to load attachments.");
    recover_failed_reads t;
    notify t g;
    true
  | _ -> false
;;

let owns_fact t (fact : fact_ticket) =
  t.generation = fact.generation
  && Hashtbl.find_opt t.fact_requests fact.block = Some fact.request_id
;;

let complete_fact t (fact : fact_ticket) ~apply ~accepted ~refresh_superseded =
  let { block; request_id; _ } = fact in
  if not (owns_fact t fact) then false
  else (
    Hashtbl.remove t.fact_requests block;
    let barrier =
      if String.starts_with ~prefix:"page:" block
      then Hashtbl.find_opt t.page_barriers (String.sub block 5 (String.length block - 5))
      else Hashtbl.find_opt t.barriers block
    in
    let superseded = match Hashtbl.find_opt t.sources request_id, barrier with
      | Some issued, Some at -> issued <= at
      | _ -> false
    in
    apply ();
    if not (accepted superseded) then
      dependency_failure t block "Unable to load attachment dependencies.";
    reconcile_dependencies t;
    if refresh_superseded && superseded && fact_needed t block then request_fact t block;
    true)
;;

let reject_fact t (fact : fact_ticket) =
  if not (owns_fact t fact) then false
  else (
    Hashtbl.remove t.fact_requests fact.block;
    Hashtbl.remove t.sources fact.request_id;
    dependency_failure t fact.block "Unable to load attachment dependencies.";
    true)
;;

let receive_read t (Read_result result) =
  let consumed = match result.ticket with
    | Listing { root; epoch; request_id } ->
      receive_listing t ~root ~epoch ~request_id
        (Some (result.value.items, result.value.next))
    | Block_fact fact ->
      complete_fact t fact
        ~apply:(fun () -> observe_query_result t ~request_id:fact.request_id result.query result.value)
        ~accepted:(fun superseded -> superseded || Hashtbl.mem t.facts fact.block)
        ~refresh_superseded:true
    | Page_fact fact ->
      complete_fact t fact
        ~apply:(fun () -> observe_query_result t ~request_id:fact.request_id result.query result.value)
        ~accepted:(fun _ -> true) ~refresh_superseded:false
  in
  if consumed then (
    (match result.ticket with Listing _ -> () | Block_fact _ | Page_fact _ -> recover_failed_reads t);
    pump t);
  consumed
;;

let reject_read : type a. t -> a read_ticket -> unit = fun t ticket ->
  (match ticket with
   | Listing { root; epoch; request_id } ->
     ignore (receive_listing t ~root ~epoch ~request_id None : bool)
   | Block_fact fact -> ignore (reject_fact t fact : bool)
   | Page_fact fact -> ignore (reject_fact t fact : bool));
  recover_failed_reads t;
  pump t
;;

let receive_file t (Lease{root;epoch;consumer;ticket}) result =
  (match Hashtbl.find_opt t.groups root with
   |Some g when g.epoch=epoch->
     (match List.find_opt(fun c->c.consumer=consumer)g.controllers with
      |Some c->dispatch t g c(Acquired(ticket,result));handoff_imports t g;notify t g
      |None->release_stale t result)
   |_->release_stale t result);
  recover_failed_reads t;pump t
;;
let demand_backpressured ?ticket t consumer =
  let current=match ticket,Hashtbl.find_opt t.bound_consumers consumer with
    |None,_->true
    |Some ticket,Some(pending,_)->Worker.equal_request_id (Coordination.ticket_id pending)(Coordination.ticket_id ticket)
    |Some _,None->false in
  if current then Option.iter(fun(g,c)->dispatch t g c P.Demand_backpressured)
    (Hashtbl.find_opt t.consumers consumer)
;;

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

let notice t notice =
  if current_demand_notice t notice then
  let scope=Worker.asset_notice_scope notice in
  match Worker.asset_notice_data notice with
  | Service.Asset_availability { consumer; asset; _ } ->
    (match Hashtbl.find_opt t.consumers consumer with
     | Some (g, c) when c.asset.uuid = asset ->
       dispatch t g c (Availability notice);
       notify t g;
       pump t
     | _ -> ())
  | Upload_status { operation; target; status = Cancelled; _ } ->
    Option.iter
      (fun g ->
         let cancelled, pending =
           List.partition
             (fun (local:local_import) ->
         let receipt=Worker.import_data local in
                receipt.operation = operation && receipt.scope = scope)
             g.local
         in
         g.local <- pending;
         List.iter (release_import t) cancelled;
         notify t g;
         pump t)
      (Hashtbl.find_opt t.groups (G.Uuid.to_string target))
  | Upload_status _ -> ()
  | Asset_capacity_available ->
    Hashtbl.iter (fun _ (g, c) -> dispatch t g c P.Capacity_available) t.consumers;
    pump t
  | Asset_backpressure consumer -> demand_backpressured t consumer
  | Asset_demand_accepted consumer ->
    Option.iter
      (fun (g, c) -> dispatch t g c P.Demand_accepted)
      (Hashtbl.find_opt t.consumers consumer)
;;

let imported_local t ~current local =
  let receipt=Worker.import_data local in
  if (not current) || t.generation <> Some receipt.graph_generation
  then release_import t local
  else (
    let root = G.Uuid.to_string receipt.target in
    let group =
      match Hashtbl.find_opt t.groups root with
      | Some g -> Some g
      | None when Hashtbl.length t.groups < 64 ->
        t.serial <- t.serial + 1;
        let g =
          { root
          ; epoch = t.serial
          ; visible = false
          ; owners = Owners.empty
          ; membership_changed = true
          ; invalidation = 0
          ; dependency_failed = false
          ; listing_failed = false
         ; listing_recovered = false
         ; dependency_recovered = false
         ; failed_dependencies = Owners.empty
          ; pending = None
          ; cursor = None
          ; error = None
          ; local = []
          ; controllers = []
          ; last_view = None
          }
        in
        Hashtbl.add t.groups root g;
        Some g
      | None -> None
    in
    match group with
    | None -> release_import t local
    | Some g ->
      let duplicate, retained =
        List.partition
          (fun (old:local_import) ->
             (Worker.import_data old).operation = receipt.operation)
          g.local
      in
      List.iter
        (fun old ->
           if
             Worker.import_preview old <> Worker.import_preview local
           then release_import t old)
        duplicate;
      if List.length retained >= 16
      then (
        release_import t local;
        g.error <- Some "Too many open attachment previews")
      else (
        g.local <- (retained @ if Worker.import_preview local = None then [] else [ local ]);
        if Worker.import_preview local = None
        then g.error <- Some "Local attachment preview unavailable";
        if g.visible && g.pending = None then read t g None);
      notify t g);
  pump t
;;

let retire_coordinated_previews t =
  Hashtbl.iter(fun _ g->
    let retiring=g.local in
    if retiring<>[] then (
      List.iter(release_import t)retiring;g.local<-[];g.membership_changed<-true;notify t g))t.groups;
  pump t
;;
let retire_coordinated_resources t =
  if t.resource_binding<>None then (
    t.resource_binding<-None;
    t.queued<-List.filter(fun outgoing->match outgoing.request with
      |Release_preview _|Release_consumer _|Perform_read _->true
      |Demand _|Acquire _|Retry_asset _->retire_outgoing t outgoing;false)t.queued;
    (* Binding retirement invalidates resource capabilities, not the graph's
       logical read owners. The coordinator retains and replans those reads;
       clearing their slots here would strand shared dependency consumers. *)
    retire_coordinated_previews t;
    Hashtbl.iter(fun _ g->
      g.cursor<-None;
      if g.pending=None then g.membership_changed<-true;
      g.dependency_failed<-false;g.listing_failed<-false;g.error<-None;
      List.iter(fun c->dispatch t g c P.Hide)g.controllers;
      notify t g)t.groups;
    (* Cleanup must not wait for read admission or a successful fresh baseline. *)
    let cleanup,waiting=List.partition(fun outgoing->match outgoing.request with
      |Release_preview _|Release_consumer _->true|_->false)t.queued in
    t.queued<-cleanup @ waiting;
    pump t)
;;
let resume_coordinated_previews t =
  Hashtbl.iter(fun _ g->if g.visible then ensure_fresh t g)t.groups;
  pump t
;;
let bind_coordinated_resources t binding =
  if Option.exists(fun previous->not(Worker.equal_binding previous binding))t.resource_binding
  then retire_coordinated_resources t;
  t.resource_binding<-Some binding;
  resume_coordinated_previews t
;;

let imported t ~current imported=imported_local t ~current imported

let idle t = t.queued = []
