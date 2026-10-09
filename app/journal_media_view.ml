module Ui = Journal_view
module L = Lui_elements

module Store = struct
  module Runtime = Journal_media_runtime

  type listener =
    { epoch : int
    ; mutable active : bool
    ; callback : unit -> unit
    }

  type t =
    { views : (string, Runtime.view) Hashtbl.t
    ; structure : (string, (int, listener) Hashtbl.t) Hashtbl.t
    ; items : (string * string, (int, listener) Hashtbl.t) Hashtbl.t
    ; observe : string -> unit
    ; mutable epoch : int
    ; mutable serial : int
    }

  let create ?(observe = fun _ -> ()) () =
    { views = Hashtbl.create 64
    ; structure = Hashtbl.create 64
    ; items = Hashtbl.create 64
    ; observe
    ; epoch = 0
    ; serial = 0
    }
  ;;

  let find t root = Hashtbl.find_opt t.views root

  let item t root token =
    Option.bind (find t root) (fun view ->
      List.find_opt (fun (item : Runtime.item) -> item.token = token) view.items)
  ;;

  let listen t table key callback =
    let bucket =
      match Hashtbl.find_opt table key with
      | Some bucket -> bucket
      | None ->
        let bucket = Hashtbl.create 2 in
        Hashtbl.add table key bucket;
        bucket
    in
    t.serial <- t.serial + 1;
    let id = t.serial in
    let listener = { epoch = t.epoch; active = true; callback } in
    Hashtbl.add bucket id listener;
    fun () ->
      if listener.active
      then (
        listener.active <- false;
        Hashtbl.remove bucket id;
        if Hashtbl.length bucket = 0 then Hashtbl.remove table key)
  ;;

  let subscribe_structure t root callback = listen t t.structure root callback
  let subscribe_item t root token callback = listen t t.items (root, token) callback

  let notify t name table key =
    match Hashtbl.find_opt table key with
    | None -> ()
    | Some bucket ->
      let listeners = Hashtbl.fold (fun _ listener acc -> listener :: acc) bucket [] in
      List.iter
        (fun listener ->
           if listener.active && listener.epoch = t.epoch
           then (
             t.observe name;
             listener.callback ()))
        listeners
  ;;

  let shape = function
    | None -> [], false, None
    | Some (view : Runtime.view) ->
      ( List.map
          (fun (item : Runtime.item) -> item.token, item.asset.uuid, item.file_type)
          view.items
      , view.more
      , view.error )
  ;;

  let update t ~root view =
    let previous = find t root in
    if previous <> view
    then (
      (match view with
       | None -> Hashtbl.remove t.views root
       | Some view -> Hashtbl.replace t.views root view);
      t.observe "media-structure-compare";
      if shape previous <> shape view
      then notify t "media-structure-notify" t.structure root;
      let changed = Hashtbl.create 16 in
      Option.iter
        (fun (view : Runtime.view) ->
           List.iter
             (fun (item : Runtime.item) ->
                Hashtbl.replace changed item.token (Some item, None))
             view.items)
        previous;
      Option.iter
        (fun (view : Runtime.view) ->
           List.iter
             (fun (item : Runtime.item) ->
                let old =
                  match Hashtbl.find_opt changed item.token with
                  | Some (old, _) -> old
                  | None -> None
                in
                Hashtbl.replace changed item.token (old, Some item))
             view.items)
        view;
      Hashtbl.iter
        (fun token (old, current) ->
           t.observe "media-item-compare";
           if old <> current then notify t "media-item-notify" t.items (root, token))
        changed)
  ;;

  let reset t =
    t.epoch <- t.epoch + 1;
    Hashtbl.clear t.views
  ;;
end

type action =
  | Root
  | Asset
  | Preview
  | Retry
  | Next

type event =
  { action : action
  ; root : string
  ; asset : string
  ; visible : bool
  ; slot : string
  }

let preview_slot = Signal.state_slot "journal-media-preview"
let is_image_type = Journal_model.is_image_file_type

let size_text size =
  if size < 1000L
  then Printf.sprintf "%Ld B" size
  else if size < 1_000_000L
  then Printf.sprintf "%.1f KB" (Int64.to_float size /. 1000.)
  else if size < 1_000_000_000L
  then Printf.sprintf "%.1f MB" (Int64.to_float size /. 1_000_000.)
  else Printf.sprintf "%.1f GB" (Int64.to_float size /. 1_000_000_000.)
;;

let view_content
      ~store
      ?title
      ?(on_region = fun _ -> ())
      ?(observed_roots = [])
      ?asset_root
      ?(known_images = [])
      ~scope
      ~root
      ~media
      ~on_event
      child
  =
  let asset_root = Option.value asset_root ~default:(fun _ -> root) in
  let observed_roots = if observed_roots = [] then [ root ] else observed_roots in
  let emit ?(target_root = root) ?(asset = "") ?(visible = true) ?(slot = root) action =
    on_event { action; root = target_root; asset; visible; slot }
  in
  let items, more, error =
    match media with
    | None -> [], false, None
    | Some view -> view.Journal_media_runtime.items, view.more, view.error
  in
  let images, files =
    List.partition
      (fun (i : Journal_media_runtime.item) -> is_image_type i.file_type)
      items
  in
  (* Graph identity/type arrives independently of file availability. Keep its
     slot and composition even while the runtime descriptor is absent. *)
  let uuid (item : Journal_media_runtime.item) =
    Logseq_db_types.Graph_types.Uuid.to_string item.asset.uuid
  in
  let by_id = Hashtbl.create (List.length images) in
  List.iter (fun item -> Hashtbl.replace by_id (uuid item) item) images;
  let known_ids = Hashtbl.create (List.length known_images) in
  let known_slots =
    List.filter_map
      (fun (id, file_type) ->
         if (not (is_image_type file_type)) || Hashtbl.mem known_ids id
         then None
         else (
           Hashtbl.add known_ids id ();
           Some (id, Hashtbl.find_opt by_id id)))
      known_images
  in
  let image_slots =
    List.filter_map
      (fun item ->
         let id = uuid item in
         if Hashtbl.mem known_ids id then None else Some (id, Some item))
      images
    @ known_slots
  in
  Ui.View.of_lui (fun context parent ->
    let context = Lui_ui.child_context context ("media:" ^ scope ^ ":" ^ root) in
    let preview =
      Signal.state_at context.ui_scheduler context.ui_state_scope preview_slot None
    in
    let selected_preview = ref [] in
    let unsubscribe_preview = ref (fun () -> ()) in
    let close_preview () =
      let selected = !selected_preview in
      selected_preview := [];
      !unsubscribe_preview ();
      (unsubscribe_preview := fun () -> ());
      Signal.set preview None;
      List.iter
        (fun (owner, token, _, slot) ->
           emit ~target_root:owner ~asset:token ~slot ~visible:false Preview)
        selected
    in
    let preview_file (item : Journal_media_runtime.item) path =
      let owner = asset_root item.token in
      let current owner token = Store.item store owner token in
      let unchanged (owner, token, path, _) =
        Option.map
          (fun (item : Journal_media_runtime.item) -> item.presentation)
          (current owner token)
        = Some (Journal_media.File path)
      in
      let selected_slot = root ^ ":" ^ item.token in
      let selected = owner, item.token, path, selected_slot in
      if unchanged selected
      then (
        let group =
          if is_image_type item.file_type
          then
            List.filter_map
              (fun (_, candidate) ->
                 Option.bind candidate (fun (candidate : Journal_media_runtime.item) ->
                   let owner = asset_root candidate.token in
                   Option.bind (current owner candidate.token) (fun current ->
                     match current.presentation with
                     | Journal_media.File path ->
                       Some (owner, candidate.token, path, root ^ ":" ^ candidate.token)
                     | Hidden | Placeholder _ | Failed _ | External _ -> None)))
              image_slots
          else [ selected ]
        in
        (* Acquire every new preview reference before releasing previous ones.
           Each member has a separate runtime slot, so swiping never relinquishes
           a sibling's only file lease when the source row leaves the viewport. *)
        let previous = !selected_preview in
        !unsubscribe_preview ();
        (unsubscribe_preview := fun () -> ());
        selected_preview := group;
        List.iter
          (fun (owner, token, _, slot) ->
             emit ~target_root:owner ~asset:token ~slot Preview)
          group;
        let retained = Hashtbl.create (List.length group) in
        List.iter (fun (_, _, _, slot) -> Hashtbl.replace retained slot ()) group;
        List.iter
          (fun (owner, token, _, slot) ->
             if not (Hashtbl.mem retained slot)
             then emit ~target_root:owner ~asset:token ~slot ~visible:false Preview)
          previous;
        let paths = List.map (fun (_, _, path, _) -> path) group in
        let rec index position = function
          | [] -> 0
          | (_, token, _, _) :: _ when token = item.token -> position
          | _ :: rest -> index (position + 1) rest
        in
        Signal.set preview (Some (paths, index 0 group, is_image_type item.file_type));
        let subscriptions =
          List.map
            (fun ((owner, token, _, _) as member) ->
               Store.subscribe_item store owner token (fun () ->
                 if not (unchanged member) then close_preview ()))
            group
        in
        unsubscribe_preview
        := fun () -> List.iter (fun unsubscribe -> unsubscribe ()) subscriptions)
    in
    Signal.on_dispose context.ui_scope close_preview;
    let reactive_item (item : Journal_media_runtime.item) render =
      fun context parent ->
      let owner = asset_root item.token in
      let current =
        Signal.state context.Lui_ui.ui_scheduler (Store.item store owner item.token)
      in
      let unsubscribe =
        Store.subscribe_item store owner item.token (fun () ->
          Signal.set current (Store.item store owner item.token))
      in
      Signal.on_dispose context.ui_scope (fun () ->
        unsubscribe ();
        Signal.dispose_signal (Signal.value current));
      L.dyn
        ~equal:( = )
        (fun selected ->
           on_region "media-item-build";
           let selected =
             Option.value
               selected
               ~default:{ item with presentation = Journal_media.Hidden }
           in
           render { selected with file_type = item.file_type })
        (Signal.value current)
        context
        parent
    in
    let render_item ~gallery (item : Journal_media_runtime.item) =
      let visible _ = emit ~target_root:(asset_root item.token) ~asset:item.token Asset in
      let id = "journal-media:" ^ item.token in
      match item.presentation with
      | Journal_media.File path when is_image_type item.file_type ->
        L.file_image
          ~key:item.token
          ~path
          ~max_pixel_size:1024
          ~width:(if gallery then 190 else 102)
          ~height:(if gallery then 90 else 102)
          ~fit:`fill
          ~corner_radius:10
          ~accessibility_identifier:id
          ~on_appear:visible
          ~on_press:(fun _ -> preview_file item path)
          []
      | File path ->
        let typ =
          if item.file_type = "" then "File" else String.uppercase_ascii item.file_type
        in
        let detail =
          match item.asset.size with
          | None -> typ
          | Some size -> typ ^ " · " ^ size_text size
        in
        L.column
          ~key:item.token
          ~padding:10
          ~background:"#839B7F0B"
          ~corner_radius:10
          ~on_appear:visible
          [ L.row
              ~gap:10
              ~cross:`start
              [ L.icon
                  ~name:(`app (if item.file_type = "pdf" then "doc-text" else "doc"))
                  ~point_size:24
                  ~foreground:"secondary"
                  []
              ; L.column
                  ~gap:3
                  ~cross:`start
                  ~grow:1.
                  [ L.text
                      ~value:(typ ^ " attachment")
                      ~style_class:"footnote"
                      ~accessibility_identifier:id
                      ~on_press:(fun _ -> preview_file item path)
                      []
                  ; L.text ~value:detail ~style_class:"caption" ~foreground:"secondary" []
                  ]
              ]
          ]
      | External url ->
        L.link
          ~key:item.token
          ~url
          ~text:"Open external attachment"
          ~accessibility_identifier:id
          ~on_appear:visible
          []
      | Placeholder message | Failed message ->
        L.column
          ~key:item.token
          ~gap:6
          ~padding:10
          ~cross:`start
          ~background:"#839B7F0B"
          ~corner_radius:10
          ~on_appear:visible
          ([ L.text ~value:message ~style_class:"caption" ~foreground:"secondary" [] ]
           @
           match item.presentation with
           | Failed _ ->
             [ L.text
                 ~value:"Retry"
                 ~style_class:"caption"
                 ~on_press:(fun _ ->
                   emit ~target_root:(asset_root item.token) ~asset:item.token Retry)
                 []
             ]
           | _ -> [])
      | Hidden ->
        L.text
          ~key:item.token
          ~value:"Waiting for file"
          ~style_class:"caption"
          ~foreground:"secondary"
          ~on_appear:visible
          []
    in
    let render_slot ~gallery (id, (item : Journal_media_runtime.item option)) =
      let render_content (item : Journal_media_runtime.item option) =
        match item with
        | Some ({ presentation = File _ | External _; _ } as item) ->
          render_item ~gallery item
        | Some item ->
          let message =
            match item.presentation with
            | Placeholder message | Failed message -> message
            | Hidden -> "Waiting for file"
            | External _ | File _ -> "Waiting for file"
          in
          L.column
            ~gap:6
            ~padding:10
            ~cross:`start
            ~on_appear:(fun _ ->
              emit ~target_root:(asset_root item.token) ~asset:item.token Asset)
            ([ L.text
                 ~value:message
                 ~style_class:"caption line-clamp-3"
                 ~foreground:"secondary"
                 []
             ]
             @
             match item.presentation with
             | Failed _ ->
               [ L.text
                   ~value:"Retry"
                   ~style_class:"caption"
                   ~on_press:(fun _ ->
                     emit ~target_root:(asset_root item.token) ~asset:item.token Retry)
                   []
               ]
             | _ -> [])
        | None ->
          L.column
            ~padding:10
            ~cross:`start
            [ L.text
                ~value:"Waiting for file"
                ~style_class:"caption line-clamp-3"
                ~foreground:"secondary"
                []
            ]
      in
      let content =
        match item with
        | None -> render_content None
        | Some item -> reactive_item item (fun current -> render_content (Some current))
      in
      L.column
        ~key:("image-slot:" ^ id)
        ~width:(if gallery then 190 else 102)
        ~height:(if gallery then 90 else 102)
        ~cross:`start
        ~background:"#839B7F0B"
        ~corner_radius:10
        ~accessibility_identifier:("journal-image-slot:" ^ id)
        [ content ]
    in
    let gallery =
      match image_slots with
      | [] | [ _ ] -> []
      | slots ->
        [ L.scroll
            ~orientation:`horizontal
            [ L.row ~gap:8 (List.map (render_slot ~gallery:true) slots) ]
        ]
    in
    let body =
      match image_slots with
      | [ slot ] ->
        L.row
          ~gap:15
          ~cross:`start
          [ L.column ~grow:1. ~cross:`start [ Ui.mount child ]
          ; render_slot ~gallery:false slot
          ]
      | [] | _ :: _ :: _ -> Ui.mount child
    in
    let file_rows =
      List.map (fun item -> reactive_item item (render_item ~gallery:false)) files
    in
    let errors =
      match error with
      | None -> []
      | Some message ->
        [ L.text ~value:message ~style_class:"caption" ~foreground:"secondary" []
        ; L.text
            ~value:"Retry attachments"
            ~on_press:(fun _ ->
              List.iter (fun target_root -> emit ~target_root Retry) observed_roots)
            []
        ]
    in
    let more_rows =
      if more
      then [ L.text ~value:"Next attachments" ~on_press:(fun _ -> emit Next) [] ]
      else []
    in
    let content =
      L.column
        ~key:("media:" ^ scope ^ ":" ^ root)
        ~gap:12
        ~cross:`start
        ~on_appear:(fun _ -> emit Root)
        ([ body ] @ gallery @ file_rows @ errors @ more_rows)
    in
    (* A modal preview is an overlay, not a spacing child of the row body. *)
    let content =
      L.stack
        [ content
        ; L.dyn
            ~equal:( = )
            (function
              | None -> L.column ~width:0 ~height:0 []
              | Some (paths, selected_index, image) ->
                let payload =
                  Yojson.Safe.to_string
                    (`Assoc
                        ([ "paths", `List (List.map (fun path -> `String path) paths)
                         ; "selected_index", `Int selected_index
                         ]
                         @
                         if image
                         then []
                         else
                           [ "document", `Bool true
                           ; "title", `String (Option.value title ~default:"Attachment")
                           ]))
                in
                Journal_lui_native.image_preview
                  ~payload
                  ~on_event:(fun event ->
                    if event.payload = "{\"type\":\"dismiss\"}" then close_preview ())
                  [])
            (Signal.value preview)
        ]
    in
    let observers =
      List.filter_map
        (fun target_root ->
           if target_root = root
           then None
           else
             Some
               (L.column
                  ~key:("observe-media:" ^ target_root)
                  ~height:0
                  ~on_appear:(fun _ -> emit ~target_root Root)
                  []))
        observed_roots
    in
    let content =
      if observers = []
      then content
      else
        (* Each new child has its own native appearance lifecycle. A retained
           parent's onAppear alone does not run when lazy children arrive. The
           zero-height overlay does not add gallery gaps or intercept presses. *)
        L.stack [ content; L.column ~key:"media-observers" ~gap:0 ~height:0 observers ]
    in
    content context parent)
;;

let reactive_structure store ~roots ~on_region build =
  Ui.View.of_lui (fun context parent ->
    let version = Signal.state context.Lui_ui.ui_scheduler 0 in
    let seen = Hashtbl.create (List.length roots) in
    List.iter
      (fun root ->
         if not (Hashtbl.mem seen root)
         then (
           Hashtbl.add seen root ();
           let unsubscribe =
             Store.subscribe_structure store root (fun () ->
               Signal.update version (fun current -> current + 1))
           in
           Signal.on_dispose context.ui_scope unsubscribe))
      roots;
    Signal.on_dispose context.ui_scope (fun () ->
      Signal.dispose_signal (Signal.value version));
    L.dyn
      ~equal:Int.equal
      (fun _ ->
         on_region "media-structure-build";
         Ui.mount (build ()))
      (Signal.value version)
      context
      parent)
;;

let view
      ~store
      ?title
      ?(on_region = fun _ -> ())
      ?(observed_roots = [])
      ?asset_root
      ?(known_images = [])
      ~scope
      ~root
      ~on_event
      child
  =
  let roots = if observed_roots = [] then [ root ] else observed_roots in
  reactive_structure store ~roots ~on_region (fun () ->
    view_content
      ~store
      ?title
      ~on_region
      ~observed_roots
      ?asset_root
      ~known_images
      ~scope
      ~root
      ~media:(Store.find store root)
      ~on_event
      child)
;;

(* Aggregate the known root image and direct image asset children. Their own descriptors
   keep their lease/event owner, even when the parent references the same asset. *)
let row_content
      ~store
      ?title
      ?(on_region = fun _ -> ())
      ~scope
      ~root
      ~image_children
      ~on_event
      child
  =
  let module Runtime = Journal_media_runtime in
  let uuid (item : Runtime.item) =
    Logseq_db_types.Graph_types.Uuid.to_string item.asset.uuid
  in
  let child_ids = Hashtbl.create (List.length image_children) in
  let image_children =
    List.filter
      (fun (id, _) ->
         if Hashtbl.mem child_ids id
         then false
         else (
           Hashtbl.add child_ids id ();
           true))
      image_children
  in
  let parent = Store.find store root in
  let parent_items =
    Option.fold ~none:[] ~some:(fun (v : Runtime.view) -> v.items) parent
  in
  let parent_by_asset = Hashtbl.create (List.length parent_items) in
  List.iter (fun item -> Hashtbl.replace parent_by_asset (uuid item) item) parent_items;
  let owners = Hashtbl.create 16 in
  let seen = Hashtbl.create 16 in
  let add acc owner (item : Runtime.item) =
    let id = uuid item in
    if Hashtbl.mem seen id
    then acc
    else (
      Hashtbl.add seen id ();
      Hashtbl.replace owners item.token owner;
      item :: acc)
  in
  let initial =
    List.fold_left
      (fun acc item ->
         if Hashtbl.mem child_ids (uuid item) then acc else add acc root item)
      []
      parent_items
  in
  let items, errors =
    List.fold_left
      (fun (items, errors) (id, file_type) ->
         let media = if id = root then parent else Store.find store id in
         let own =
           Option.bind media (fun (v : Runtime.view) ->
             List.find_opt (fun item -> uuid item = id) v.items)
         in
         let own, owner =
           match own with
           | Some item -> Some item, id
           | None -> Hashtbl.find_opt parent_by_asset id, root
         in
         let items =
           match own with
           | None -> items
           | Some item -> add items owner { item with file_type }
         in
         let errors =
           match
             if id = root
             then None
             else Option.bind media (fun (v : Runtime.view) -> v.error)
           with
           | None -> errors
           | Some message -> message :: errors
         in
         items, errors)
      (initial, [])
      image_children
  in
  let base =
    Option.value parent ~default:{ Runtime.items = []; more = false; error = None }
  in
  let errors = Option.to_list base.error @ List.rev errors in
  let media =
    Some
      { base with
        items = List.rev items
      ; error = (if errors = [] then None else Some (String.concat "\n" errors))
      }
  in
  view_content
    ~store
    ?title
    ~on_region
    ~known_images:image_children
    ~observed_roots:(root :: List.map fst image_children)
    ~asset_root:(fun token -> Hashtbl.find_opt owners token |> Option.value ~default:root)
    ~scope
    ~root
    ~media
    ~on_event
    child
;;

let row
      ~store
      ?title
      ?(on_region = fun _ -> ())
      ~scope
      ~root
      ~image_children
      ~on_event
      child
  =
  reactive_structure
    store
    ~roots:(root :: List.map fst image_children)
    ~on_region
    (fun () ->
       row_content ~store ?title ~on_region ~scope ~root ~image_children ~on_event child)
;;
