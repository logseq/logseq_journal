module Service = Logseq_db_worker_bonsai.Logseq_db_worker_bonsai_service
module Asset = Logseq_db_types.Asset_descriptor
module P = Journal_media
module G = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol

type ticket =
  | Query of
      { root : string
      ; epoch : int
      ; request_id : G.Uuid.t
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
  { asset : Asset.t
  ; consumer : string
  ; mutable state : P.t
  ; mutable shown : bool
  }

type group =
  { root : string
  ; epoch : int
  ; mutable visible : bool
  ; mutable pending : G.Uuid.t option
  ; mutable cursor : G.Cursor.t option
  ; mutable error : string option
  ; mutable local : Logseq_db_worker.import_receipt list
  ; mutable controllers : controller list
  }

type outgoing =
  { ticket : ticket option
  ; request : Service.request
  ; current : unit -> bool
  }

type t =
  { send : ticket option -> Service.request -> bool
  ; changed : string -> view -> unit
  ; groups : (string, group) Hashtbl.t
  ; consumers : (string, group * controller) Hashtbl.t
  ; mutable generation : int option
  ; mutable serial : int
  ; mutable queued : outgoing list
  }

let create ~send ~changed =
  { send
  ; changed
  ; groups = Hashtbl.create 16
  ; consumers = Hashtbl.create 32
  ; generation = None
  ; serial = 0
  ; queued = []
  }
;;

let empty_view = { items = []; more = false; error = None }

let notify t g =
  t.changed
    g.root
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
;;

let rec pump t =
  match t.queued with
  | [] -> ()
  | next :: rest ->
    if not (next.current ())
    then (
      t.queued <- rest;
      pump t)
    else if t.send next.ticket next.request
    then (
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
  List.iter
    (fun c ->
       c.shown <- false;
       dispatch t g c P.Hide;
       Hashtbl.remove t.consumers c.consumer)
    g.controllers;
  g.controllers <- []
;;

let read t g cursor =
  if List.length t.queued < 1024
  then (
    t.serial <- t.serial + 1;
    let request_id =
      G.Uuid.of_string (Printf.sprintf "a55e8000-0000-4000-8000-%012x" t.serial)
      |> Result.get_ok
    in
    let root = G.Uuid.of_string g.root |> Result.get_ok in
    g.pending <- Some request_id;
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
  else g.error <- Some "Attachment requests are busy. Retry shortly."
;;

let reset t ~graph_generation =
  Hashtbl.iter
    (fun _ g ->
       clear t g;
       t.changed g.root empty_view)
    t.groups;
  Hashtbl.clear t.groups;
  Hashtbl.clear t.consumers;
  t.generation <- graph_generation;
  pump t
;;

let root_visible t ~root visible =
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
    g.visible <- false;
    List.iter
      (fun c ->
         c.shown <- false;
         dispatch t g c Hide)
      g.controllers;
    notify t g;
    pump t
  | Some g, true, Some graph_generation ->
    g.visible <- true;
    List.iter
      (fun c ->
         if c.shown
         then
           dispatch
             t
             g
             c
             (Show { graph_generation; consumer = c.consumer; asset = c.asset }))
      g.controllers;
    notify t g;
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
         ; pending = None
         ; cursor = None
         ; error = None
         ; local = []
         ; controllers = []
         }
       in
       Hashtbl.add t.groups root g;
       read t g None;
       pump t)
  | _ -> ()
;;

let asset_visible t ~root ~asset visible =
  match Hashtbl.find_opt t.groups root, t.generation with
  | Some g, Some graph_generation ->
    (match List.find_opt (fun c -> c.consumer = asset) g.controllers with
     | Some c when c.shown <> visible && ((not visible) || List.length t.queued < 1024) ->
       c.shown <- visible;
       dispatch
         t
         g
         c
         (if visible && g.visible
          then Show { graph_generation; consumer = c.consumer; asset = c.asset }
          else Hide);
       notify t g;
       pump t
     | _ -> ())
  | _ -> ()
;;

let next t ~root =
  match Hashtbl.find_opt t.groups root with
  | Some g when g.pending = None && g.cursor <> None ->
    read t g g.cursor;
    notify t g;
    pump t
  | _ -> ()
;;

let retry t ~root ~asset =
  match Hashtbl.find_opt t.groups root with
  | None -> ()
  | Some g ->
    (match List.find_opt (fun c -> c.consumer = asset) g.controllers with
     | Some c when c.shown -> dispatch t g c Retry_requested
     | Some _ -> asset_visible t ~root ~asset true
     | None when asset = "" -> read t g None
     | None -> ());
    notify t g;
    pump t
;;

let refresh t =
  Hashtbl.iter (fun _ g -> read t g None) t.groups;
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
   | Query { root; epoch; request_id } ->
     (match Hashtbl.find_opt t.groups root with
      | Some g when g.epoch = epoch && g.pending = Some request_id ->
        g.pending <- None;
        (match response with
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
                  match List.find_opt (fun c -> c.asset = asset) old with
                  | Some c -> c
                  | None ->
                    t.serial <- t.serial + 1;
                    { asset
                    ; consumer = Printf.sprintf "media:%d:%d" epoch t.serial
                    ; state = P.empty
                    ; shown = false
                    })
               items
           in
           List.iter
             (fun c ->
                if not (List.exists (fun kept -> kept.consumer = c.consumer) controllers)
                then (
                  c.shown <- false;
                  dispatch t g c Hide;
                  Hashtbl.remove t.consumers c.consumer))
             old;
           g.controllers <- controllers;
           g.cursor <- next_cursor;
           g.error <- None;
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
          ; pending = None
          ; cursor = None
          ; error = None
          ; local = []
          ; controllers = []
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
        then g.error <- Some "Local attachment preview unavailable");
      notify t g);
  pump t
;;
