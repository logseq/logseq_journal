module Ui = Journal_view
module L = Lui_elements

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

let view
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
  let emit ?(target_root = root) ?(asset = "") ?(visible = true) action =
    on_event
      (Yojson.Basic.to_string
         (`Assoc
             [ "action", `String action
             ; "root", `String target_root
             ; "asset", `String asset
             ; "visible", `Bool visible
             ]))
  in
  let items, more, error =
    match media with
    | None -> [], false, None
    | Some view -> view.Journal_media_runtime.items, view.more, view.error
  in
  Ui.View.of_lui (fun context parent ->
    let context = Lui_ui.child_context context ("media:" ^ scope ^ ":" ^ root) in
    let preview =
      Signal.state_at context.ui_scheduler context.ui_state_scope preview_slot None
    in
    let preview_file path = Signal.set preview (Some path) in
    let render_item ~gallery (item : Journal_media_runtime.item) =
      let visible _ =
        emit ~target_root:(asset_root item.token) ~asset:item.token "asset"
      in
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
          ~on_press:(fun _ -> preview_file path)
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
                      ~on_press:(fun _ -> preview_file path)
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
      | Placeholder message ->
        L.column
          ~key:item.token
          ~gap:6
          ~padding:10
          ~cross:`start
          ~background:"#839B7F0B"
          ~corner_radius:10
          ~on_appear:visible
          [ L.text ~value:message ~style_class:"caption" ~foreground:"secondary" []
          ; L.text
              ~value:"Retry"
              ~style_class:"caption"
              ~on_press:(fun _ ->
                emit ~target_root:(asset_root item.token) ~asset:item.token "retry")
              []
          ]
      | Hidden ->
        L.text
          ~key:item.token
          ~value:"Waiting for file"
          ~style_class:"caption"
          ~foreground:"secondary"
          ~on_appear:visible
          []
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
    let render_slot ~gallery (id, (item : Journal_media_runtime.item option)) =
      let content =
        match item with
        | Some ({ presentation = File _ | External _; _ } as item) ->
          render_item ~gallery item
        | Some item ->
          let message =
            match item.presentation with
            | Placeholder message -> message
            | Hidden -> "Waiting for file"
            | External _ | File _ -> "Waiting for file"
          in
          L.column
            ~gap:6
            ~padding:10
            ~cross:`start
            ~on_appear:(fun _ ->
              emit ~target_root:(asset_root item.token) ~asset:item.token "asset")
            [ L.text
                ~value:message
                ~style_class:"caption line-clamp-3"
                ~foreground:"secondary"
                []
            ; L.text
                ~value:"Retry"
                ~style_class:"caption"
                ~on_press:(fun _ ->
                  emit ~target_root:(asset_root item.token) ~asset:item.token "retry")
                []
            ]
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
    let file_rows = List.map (render_item ~gallery:false) files in
    let errors =
      match error with
      | None -> []
      | Some message ->
        [ L.text ~value:message ~style_class:"caption" ~foreground:"secondary" []
        ; L.text
            ~value:"Retry attachments"
            ~on_press:(fun _ ->
              List.iter (fun target_root -> emit ~target_root "retry") observed_roots)
            []
        ]
    in
    let more_rows =
      if more
      then [ L.text ~value:"Next attachments" ~on_press:(fun _ -> emit "next") [] ]
      else []
    in
    let content =
      L.column
        ~key:("media:" ^ scope ^ ":" ^ root)
        ~gap:12
        ~cross:`start
        ~on_appear:(fun _ -> emit "root")
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
              | Some path ->
                L.file_preview ~path ~on_dismiss:(fun _ -> Signal.set preview None) [])
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
                  ~on_appear:(fun _ -> emit ~target_root "root")
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

(* Aggregate the known root image and direct image asset children. Their own descriptors
   keep their lease/event owner, even when the parent references the same asset. *)
let row ~scope ~root ~image_children ~media_for_root ~on_event child =
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
  let parent = media_for_root root in
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
         let media = if id = root then parent else media_for_root id in
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
  view
    ~known_images:image_children
    ~observed_roots:(root :: List.map fst image_children)
    ~asset_root:(fun token -> Hashtbl.find_opt owners token |> Option.value ~default:root)
    ~scope
    ~root
    ~media
    ~on_event
    child
;;
