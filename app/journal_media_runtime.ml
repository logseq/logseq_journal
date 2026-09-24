module Service = Logseq_db_worker_lui.Logseq_db_worker_lui_service
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
  | Reference of
      { root : string
      ; epoch : int
      ; request_id : G.Uuid.t
      }
  | Picker of
      { root : string
      ; epoch : int
      ; request_id : G.Uuid.t
      }
  | Reference_commit of
      { root : string
      ; epoch : int
      ; request_id : G.Uuid.t
      }
  | Replace_reference of
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

type reference =
  { page : G.Uuid.t
  ; revision : string
  ; previous : G.Uuid.t option
  }

type reuse =
  { mutable pending : bool
  ; mutable committing : bool
  ; mutable items : item list
  ; mutable cursor : G.Cursor.t option
  }

type picker =
  { candidates : item list
  ; candidates_more : bool
  ; busy : bool
  }

type view =
  { items : item list
  ; more : bool
  ; error : string option
  ; picker : picker option
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
  ; mutable reference : reference option
  ; mutable reuse : reuse option
  ; mutable replace : bool
  }

type outgoing =
  { ticket : ticket option
  ; request : Service.request
  ; current : unit -> bool
  }

type t =
  { send : ticket option -> Service.request -> bool
  ; changed : string -> view -> unit
  ; armed : string -> G.Uuid.t option -> unit
  ; groups : (string, group) Hashtbl.t
  ; consumers : (string, group * controller) Hashtbl.t
  ; mutable generation : int option
  ; mutable serial : int
  ; mutable queued : outgoing list
  }

let create ~send ~changed ~armed =
  { send
  ; changed
  ; armed
  ; groups = Hashtbl.create 16
  ; consumers = Hashtbl.create 32
  ; generation = None
  ; serial = 0
  ; queued = []
  }
;;

let empty_view = { items = []; more = false; error = None; picker = None }

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
    ; picker =
        Option.map
          (fun (reuse : reuse) ->
             { candidates = reuse.items
             ; candidates_more = Option.is_some reuse.cursor
             ; busy = reuse.pending || reuse.committing
             })
          g.reuse
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

let next_request_id t =
  t.serial <- t.serial + 1;
  G.Uuid.of_string (Printf.sprintf "a55e8000-0000-4000-8000-%012x" t.serial)
  |> Result.get_ok
;;

let read t g cursor =
  if List.length t.queued < 1024
  then (
    let request_id = next_request_id t in
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
    g.replace <- false;
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
         ; reference = None
         ; reuse = None
         ; replace = false
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

let request_reference t g =
  match G.Uuid.of_string g.root with
  | Error _ ->
    g.reuse <- None;
    g.error <- Some "The attachment holder is unavailable."
  | Ok block ->
    let request_id = next_request_id t in
    enqueue
      t
      ~ticket:(Reference { root = g.root; epoch = g.epoch; request_id })
      ~current:(fun () -> current_group t g && g.reuse <> None)
      (Service.Graph_request
         { api_version = 2
         ; request_id
         ; command = Protocol.V2_get_block { block; revision = None }
         })
;;

let begin_replace t ~root =
  if not (Hashtbl.mem t.groups root) then root_visible t ~root true;
  match Hashtbl.find_opt t.groups root, t.generation with
  | Some g, Some _ when (not g.replace) && List.length t.queued < 1024 ->
    (match G.Uuid.of_string g.root with
     | Error _ -> g.error <- Some "The attachment holder is unavailable."
     | Ok block ->
       g.replace <- true;
       g.error <- None;
       let request_id = next_request_id t in
       enqueue
         t
         ~ticket:(Replace_reference { root = g.root; epoch = g.epoch; request_id })
         ~current:(fun () -> current_group t g && g.replace)
         (Service.Graph_request
            { api_version = 2
            ; request_id
            ; command = Protocol.V2_get_block { block; revision = None }
            }));
    notify t g;
    pump t
  | _ -> ()
;;

let request_candidates t g page cursor =
  (match g.reuse with
   | Some reuse -> reuse.pending <- true
   | None -> ());
  let request_id = next_request_id t in
  enqueue
    t
    ~ticket:(Picker { root = g.root; epoch = g.epoch; request_id })
    ~current:(fun () -> current_group t g && g.reuse <> None)
    (Service.Graph_request
       { api_version = 2
       ; request_id
       ; command =
           Protocol.V2_list_assets
             { recursive = true; roots = [ page ]; limit = 16; cursor }
       })
;;

let candidate (asset : Asset.t) =
  match asset.source with
  | Asset.Managed (Some version) ->
    Some
      { token = "reuse:" ^ G.Uuid.to_string asset.uuid
      ; asset
      ; file_type = version.file_type
      ; presentation = P.Placeholder ""
      }
  | _ -> None
;;

let begin_reuse t ~root =
  if not (Hashtbl.mem t.groups root) then root_visible t ~root true;
  match Hashtbl.find_opt t.groups root, t.generation with
  | Some g, Some _ when List.length t.queued < 1024 ->
    g.reference <- None;
    g.reuse <- Some { pending = true; committing = false; items = []; cursor = None };
    request_reference t g;
    notify t g;
    pump t
  | _ -> ()
;;

let reuse_next t ~root =
  match Hashtbl.find_opt t.groups root with
  | Some g ->
    (match g.reference, g.reuse with
     | ( Some { page; _ }
       , Some { pending = false; committing = false; cursor = Some cursor; _ } ) ->
       request_candidates t g page (Some cursor);
       notify t g;
       pump t
     | _ -> ())
  | None -> ()
;;

let reuse_select t ~root ~asset =
  match Hashtbl.find_opt t.groups root with
  | Some g ->
    (match g.reference, g.reuse with
     | Some reference, Some { committing = false; _ } ->
       let candidate_uuid =
         if String.starts_with ~prefix:"reuse:" asset
         then String.sub asset 6 (String.length asset - 6)
         else asset
       in
       (match G.Uuid.of_string candidate_uuid, G.Uuid.of_string g.root with
        | Ok asset_uuid, Ok block ->
          let request_id = next_request_id t in
          (match g.reuse with
           | Some reuse -> reuse.committing <- true
           | None -> ());
          enqueue
            t
            ~ticket:(Reference_commit { root = g.root; epoch = g.epoch; request_id })
            ~current:(fun () -> current_group t g && g.reuse <> None)
            (Service.Graph_request
               { api_version = 2
               ; request_id
               ; command =
                   Protocol.V2_set_asset_reference
                     { mutation_id = request_id
                     ; block
                     ; previous = reference.previous
                     ; asset = asset_uuid
                     ; preconditions =
                         Protocol.
                           { blocks = [ block, reference.revision ]
                           ; pages = []
                           ; scopes = []
                           }
                     }
               })
        | _ -> ());
       notify t g;
       pump t
     | _ -> ())
  | None -> ()
;;

let end_reuse t ~root =
  match Hashtbl.find_opt t.groups root with
  | Some g when g.reuse <> None || g.reference <> None ->
    g.reuse <- None;
    g.reference <- None;
    notify t g;
    pump t
  | _ -> ()
;;

let previous_reference (block : G.block) =
  List.find_map
    (fun (property : G.property_summary) ->
       if String.equal property.ident "logseq.property/asset"
       then
         List.find_map
           (function
             | G.Entity_value asset -> Some asset
             | _ -> None)
           property.values
       else None)
    block.properties
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
   | Reference { root; epoch; _ } ->
     (match Hashtbl.find_opt t.groups root with
      | Some g when g.epoch = epoch && g.reuse <> None ->
        (match response with
         | Service.Graph_response
             (Protocol.V2_response
                { outcome = V2_block_outcome (V2_present_block { value; revision }); _ })
           ->
           let reference =
             { page = value.block.page
             ; revision
             ; previous = previous_reference value.block
             }
           in
           g.reference <- Some reference;
           request_candidates t g value.block.page None;
           notify t g
         | _ ->
           g.reuse <- None;
           g.error <- Some "Unable to open the attachment reference. Retry.";
           notify t g)
      | _ -> ())
   | Picker { root; epoch; _ } ->
     (match Hashtbl.find_opt t.groups root with
      | Some g when g.epoch = epoch ->
        (match g.reuse, response with
         | ( Some reuse
           , Service.Graph_response
               (Protocol.V2_response
                  { outcome = V2_assets_outcome { items; next_cursor; _ }; _ }) ) ->
           reuse.items
           <- List.filteri
                (fun index _ -> index < 64)
                (reuse.items
                 @ List.filter
                     (fun (incoming : item) ->
                        not
                          (List.exists
                             (fun (existing : item) ->
                                existing.asset.uuid = incoming.asset.uuid)
                             reuse.items))
                     (List.filter_map candidate items));
           reuse.cursor <- next_cursor;
           reuse.pending <- false;
           g.error <- None;
           notify t g
         | Some reuse, _ ->
           reuse.pending <- false;
           g.reuse <- None;
           g.error <- Some "Unable to list reusable attachments. Retry.";
           notify t g
         | None, _ -> ())
      | _ -> ())
   | Replace_reference { root; epoch; _ } ->
     (match Hashtbl.find_opt t.groups root with
      | Some g when g.epoch = epoch && g.replace ->
        g.replace <- false;
        (match response with
         | Service.Graph_response
             (Protocol.V2_response
                { outcome = V2_block_outcome (V2_present_block { value; _ }); _ }) ->
           t.armed g.root (previous_reference value.block)
         | _ -> g.error <- Some "Unable to open the attachment reference. Retry.");
        notify t g
      | _ -> ())
   | Reference_commit { root; epoch; _ } ->
     (match Hashtbl.find_opt t.groups root with
      | Some g when g.epoch = epoch ->
        (match g.reuse, response with
         | ( Some _
           , Service.Graph_response
               (Protocol.V2_response { outcome = V2_mutation_committed _; _ }) ) ->
           g.reuse <- None;
           g.reference <- None;
           read t g None;
           notify t g
         | Some reuse, _ ->
           reuse.committing <- false;
           g.reuse <- None;
           g.error <- Some "Unable to reuse the attachment. Retry.";
           notify t g
         | None, _ -> ())
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
          ; reference = None
          ; reuse = None
          ; replace = false
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
