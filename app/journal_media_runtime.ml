module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
module Asset = Logseq_db_types.Asset_descriptor
module P = Journal_media
module G = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Owners = Set.Make (String)

type ticket =
  | Query of
      { root : string
      ; epoch : int
      ; request_id : G.Uuid.t
      }
  | Facts of
      { block : string
      ; request_id : G.Uuid.t
      ; generation : int option
      }
  | Lease of
      { root : string
      ; epoch : int
      ; consumer : string
      ; ticket : P.ticket
      }

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

type group =
  { root : string
  ; epoch : int
  ; mutable visible : bool
  ; mutable owners : Owners.t
  ; mutable membership_changed : bool
  ; mutable invalidation : int
  ; mutable dependency_failed : bool
  ; mutable pending : G.Uuid.t option
  ; mutable cursor : G.Cursor.t option
  ; mutable error : string option
  ; mutable local : Logseq_db_worker.import_receipt list
  ; mutable controllers : controller list
  ; mutable last_view : view option
  }

type outgoing =
  { ticket : ticket option
  ; request : Service.request
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
  { send : ticket option -> Service.request -> bool
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

let create ~send ~changed =
  { send
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

let empty_view = { items = []; more = false; error = None }

let notify t g =
  let view =
    { items =
        List.filter_map
          (fun (receipt : Logseq_db_worker.import_receipt) ->
             Option.map
               (fun (_, path) ->
                  { token = "import:" ^ G.Uuid.to_string receipt.operation
                  ; asset = receipt.asset
                  ; file_type = receipt.file_type
                  ; presentation = P.File path
                  })
               receipt.preview)
          g.local
        @ List.map
            (fun c ->
               { token = c.consumer
               ; asset = c.asset
               ; file_type =
                   (match c.asset.source with
                    | Managed (Some v) -> v.file_type
                    | _ -> "")
               ; presentation = P.presentation c.state
               })
            (List.filter
               (fun c ->
                  not
                    (List.exists
                       (fun (local : Logseq_db_worker.import_receipt) ->
                          local.asset.uuid = c.asset.uuid)
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
         g.error <- Some message;
         notify t g))
    t.groups
;;

let observe_request t (request : Protocol.request) =
  if Hashtbl.mem t.sources request.request_id || Hashtbl.length t.sources < 4096
  then Hashtbl.replace t.sources request.request_id (tick t)
  else (
    let fail uuid =
      dependency_failure
        t
        (G.Uuid.to_string uuid)
        "Attachment dependency requests are full. Retry."
    in
    match request.command with
    | Protocol.V2_get_block { block; _ } | V2_get_block_summary { block; _ } -> fail block
    | V2_get_children { parent; _ } -> fail parent
    | V2_get_page { page; _ } ->
      dependency_failure
        t
        ("page:" ^ G.Uuid.to_string page)
        "Attachment page requests are full. Retry."
    | V2_list_assets { roots; _ } -> List.iter fail roots
    | _ -> ())
;;

let fact_needed t target =
  Hashtbl.to_seq_values t.groups
  |> Seq.exists (fun g ->
    g.visible && (not g.dependency_failed) && group_reaches t g target)
;;

let rec pump t =
  match t.queued with
  | [] -> ()
  | next :: rest ->
    if not (next.current ())
    then (
      (match next.ticket with
       | Some (Facts { block; request_id; _ })
         when Hashtbl.find_opt t.fact_requests block = Some request_id ->
         Hashtbl.remove t.fact_requests block
       | _ -> ());
      t.queued <- rest;
      pump t)
    else if t.send next.ticket next.request
    then (
      (match next.request with
       | Service.Graph_request request -> observe_request t request
       | _ -> ());
      t.queued <- rest;
      pump t)
;;

let enqueue t ?ticket ?(current = fun () -> true) request =
  t.queued
  <- List.filter (fun item -> item.current ()) t.queued @ [ { ticket; request; current } ]
;;

let current_group t g =
  match Hashtbl.find_opt t.groups g.root with
  | Some current -> current.epoch = g.epoch
  | None -> false
;;

let current_controller t g c = current_group t g && Hashtbl.mem t.consumers c.consumer

let instructions t g c effects =
  List.iter
    (function
      | P.Demand { graph_generation; consumer; asset } ->
        enqueue
          t
          ~current:(fun () ->
            current_controller t g c && c.shown && P.descriptor c.state = Some asset)
          (Service.Asset_command
             { graph_generation
             ; command =
                 Replace_asset_demand
                   { consumer; priority = Foreground; assets = [ asset ] }
             })
      | Release { graph_generation; consumer } ->
        enqueue
          t
          (Service.Asset_command
             { graph_generation; command = Release_asset_demand consumer })
      | Retry { graph_generation; asset } ->
        enqueue
          t
          ~current:(fun () -> current_controller t g c && c.shown)
          (Service.Asset_command { graph_generation; command = Retry_asset asset })
      | Acquire ticket ->
        enqueue
          t
          ~ticket:
            (Lease { root = g.root; epoch = g.epoch; consumer = c.consumer; ticket })
          ~current:(fun () -> current_controller t g c && P.ticket_current c.state ticket)
          (Service.Acquire_asset_file { scope = ticket.scope; handle = ticket.handle })
      | Release_file { scope; lease } ->
        enqueue t (Service.Release_asset_file { scope; handle = lease }))
    effects
;;

let dispatch t g c event =
  let state, effects = P.step c.state event in
  c.state <- state;
  instructions t g c effects
;;

let release_import t (receipt : Logseq_db_worker.import_receipt) =
  Option.iter
    (fun (handle, _) ->
       enqueue t (Service.Release_asset_file { scope = receipt.scope; handle }))
    receipt.preview
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
    enqueue
      t
      ~ticket:(Query { root = g.root; epoch = g.epoch; request_id })
      ~current:(fun () -> current_group t g && g.pending = Some request_id)
      (Service.Graph_request
         { api_version = 2
         ; request_id
         ; command =
             V2_list_assets { recursive = false; roots = [ root ]; limit = 16; cursor }
         }))
  else if g.pending = None
  then g.error <- Some "Attachment requests are busy. Retry shortly."
;;

let ensure_fresh t g = if g.membership_changed && g.pending = None then read t g None

let reset t ~graph_generation =
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
             match queued.ticket with
             | Some (Query { request_id; _ }) -> g.pending = Some request_id
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

let retain_owners t owners =
  let retained = Owners.of_list owners in
  Hashtbl.filter_map_inplace
    (fun preview (owner, root, asset) ->
       if Owners.mem owner retained
       then Some (owner, root, asset)
       else (
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
         g.owners)
    t.groups
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
    Option.iter (fun (_, root, _) -> root_visible ~owner:preview t ~root false) current);
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
                (fun (receipt : Logseq_db_worker.import_receipt) ->
                   asset = "import:" ^ G.Uuid.to_string receipt.operation
                   && Option.is_some receipt.preview)
                g.local ->
      Hashtbl.replace t.previews preview selected;
      root_visible ~owner:preview t ~root true;
      asset_visible ~owner:preview t ~root ~asset true
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
      let generation = t.generation in
      enqueue
        t
        ~ticket:(Facts { block; request_id; generation })
        ~current:(fun () ->
          t.generation = generation
          && fact_needed t block
          && Hashtbl.find_opt t.fact_requests block = Some request_id)
        (Service.Graph_request
           { api_version = 2
           ; request_id
           ; command =
               (if page
                then V2_get_page { page = uuid; revision = None }
                else V2_get_block { block = uuid; revision = None })
           }))
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

let observe_response t (Protocol.V2_response { request_id; outcome; _ }) =
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
        if Hashtbl.mem t.barriers key then changed := true)
      else if issued > barrier && issued >= prior && not (Hashtbl.mem t.facts key)
      then dependency_failure t key "Attachment dependency cache is full. Retry."
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
          if was_alive <> alive
          then
            Hashtbl.iter
              (fun _ g ->
                 if group_page t g = Some page then invalidate t g (max barrier issued))
              t.groups)
        else dependency_failure t ("page:" ^ page) "Attachment page cache is full. Retry."
    in
    let page_lookup = function
      | Protocol.V2_present_page { page; _ } ->
        remember_page page.uuid (not page.recycled)
      | V2_missing_page { uuid; _ } -> remember_page uuid false
    in
    let block (record : Protocol.v2_block_record) =
      remember record.block.uuid (Some record.block)
    in
    let lookup = function
      | Protocol.V2_present_block { value; _ } -> block value
      | V2_missing_block { uuid; _ } -> remember uuid None
    in
    (match outcome with
     | Protocol.V2_block_outcome value -> lookup value
     | V2_block_summary_outcome { lookup = value; page; items; _ } ->
       lookup value;
       Option.iter page_lookup page;
       List.iter (fun (item : Protocol.v2_child_member) -> block item.value) items
     | V2_children_outcome { items; _ } ->
       List.iter (fun (item : Protocol.v2_child_member) -> block item.value) items
     | V2_page_tree_outcome { items; _ } ->
       List.iter (fun (item : Protocol.v2_tree_member) -> block item.value) items
     | V2_page_outcome value -> page_lookup value
     | V2_journals_outcome { items; _ } ->
       List.iter
         (fun (item : Protocol.v2_journal_item) ->
            remember_page item.page.uuid (not item.page.recycled))
         items
     | _ -> ());
    if !changed
    then (
      reconcile_dependencies t;
      pump t)
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
               g.error <- Some "Attachment change dependencies are full. Retry.";
               notify t g))
          t.groups
  in
  (* Non-recursive membership does not depend on siblings or page-tree growth.
     The changed block identities carry holder/ancestor moves and deletion. *)
  List.iter
    (fun (window : Protocol.v2_change_window) -> List.iter mark window.block_uuids)
    windows;
  List.iter
    (fun (window : Protocol.v2_change_window) ->
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
                  "Attachment page dependencies are full. Retry.")
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
  pump t
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

let release_stale t ticket result =
  match result with
  | None -> ()
  | Some (lease, _) ->
    enqueue t (Service.Release_asset_file { scope = ticket.P.scope; handle = lease })
;;

let receive t ticket response =
  (match ticket with
   | Facts { block; request_id; generation } ->
     if
       t.generation = generation
       && Hashtbl.find_opt t.fact_requests block = Some request_id
     then (
       Hashtbl.remove t.fact_requests block;
       match response with
       | Service.Graph_response
           (Protocol.V2_response { request_id = actual; outcome; _ } as raw)
         when actual = request_id ->
         let barrier =
           if String.starts_with ~prefix:"page:" block
           then
             Hashtbl.find_opt
               t.page_barriers
               (String.sub block 5 (String.length block - 5))
           else Hashtbl.find_opt t.barriers block
         in
         let superseded =
           match Hashtbl.find_opt t.sources request_id, barrier with
           | Some issued, Some at -> issued <= at
           | _ -> false
         in
         observe_response t raw;
         (match outcome with
          | V2_block_outcome _ when superseded || Hashtbl.mem t.facts block -> ()
          | V2_page_outcome _ when String.starts_with ~prefix:"page:" block -> ()
          | _ ->
            dependency_failure t block "Unable to load attachment dependencies. Retry.");
         reconcile_dependencies t;
         (match outcome with
          | V2_block_outcome _ when superseded && fact_needed t block ->
            request_fact t block
          | _ -> ())
       | _ ->
         Hashtbl.remove t.sources request_id;
         dependency_failure t block "Unable to load attachment dependencies. Retry.")
   | Query { root; epoch; request_id } ->
     (match Hashtbl.find_opt t.groups root with
      | Some g when g.epoch = epoch && g.pending = Some request_id ->
        Hashtbl.remove t.sources request_id;
        g.pending <- None;
        if g.membership_changed
        then (if g.visible && not g.dependency_failed then ensure_fresh t g)
        else (
          match response with
          | Service.Graph_response
              (Protocol.V2_response
                 { request_id = actual
                 ; outcome = V2_assets_outcome { items; next_cursor; _ }
                 ; _
                 })
            when actual = request_id && List.length items <= 16 ->
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
            List.iter (fun c -> Hashtbl.replace t.consumers c.consumer (g, c)) controllers
          | _ -> g.error <- Some "Unable to load attachments. Retry.");
        notify t g
      | _ -> ())
   | Lease { root; epoch; consumer; ticket } ->
     let result =
       match response with
       | Service.Asset_file result -> result
       | _ -> None
     in
     (match Hashtbl.find_opt t.groups root with
      | Some g when g.epoch = epoch ->
        (match List.find_opt (fun c -> c.consumer = consumer) g.controllers with
         | Some c ->
           dispatch t g c (Acquired (ticket, result));
           notify t g
         | None -> release_stale t ticket result)
      | _ -> release_stale t ticket result));
  pump t
;;

let reject t ticket = receive t ticket Service.Client_command_completed

let notice t scope = function
  | Service.Asset_availability { consumer; asset; availability } ->
    (match Hashtbl.find_opt t.consumers consumer with
     | Some (g, c) when c.asset.uuid = asset ->
       dispatch t g c (Availability { scope; consumer; availability });
       notify t g;
       pump t
     | _ -> ())
  | Upload_status _ -> ()
  | Asset_capacity_available ->
    Hashtbl.iter (fun _ (g, c) -> dispatch t g c P.Capacity_available) t.consumers;
    pump t
  | Asset_backpressure consumer ->
    Option.iter
      (fun (g, c) -> dispatch t g c P.Demand_backpressured)
      (Hashtbl.find_opt t.consumers consumer)
  | Asset_demand_accepted consumer ->
    Option.iter
      (fun (g, c) -> dispatch t g c P.Demand_accepted)
      (Hashtbl.find_opt t.consumers consumer)
;;

let imported t ~current (receipt : Logseq_db_worker.import_receipt) =
  if (not current) || t.generation <> Some receipt.graph_generation
  then release_import t receipt
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
    | None -> release_import t receipt
    | Some g ->
      let duplicate, retained =
        List.partition
          (fun (old : Logseq_db_worker.import_receipt) ->
             old.operation = receipt.operation)
          g.local
      in
      List.iter
        (fun old ->
           if
             old.Logseq_db_worker.preview <> receipt.preview || old.scope <> receipt.scope
           then release_import t old)
        duplicate;
      if List.length retained >= 16
      then (
        release_import t receipt;
        g.error <- Some "Too many open attachment previews")
      else (
        g.local <- (retained @ if receipt.preview = None then [] else [ receipt ]);
        if receipt.preview = None
        then g.error <- Some "Local attachment preview unavailable";
        if g.visible && g.pending = None then read t g None);
      notify t g);
  pump t
;;
