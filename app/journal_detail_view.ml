module Ui = Journal_view
module V = Ui.View
module Presentation = Journal_page_layout

type content =
  | Loading of bool
  | Missing
  | Failed of string
  | Empty
  | Ready of Journal_detail.t

type props =
  { content : content
  ; scope : string
  ; enabled : bool
  ; copy_enabled : bool
  ; copy_feedback : string option
  ; import_request : Journal_asset_import.request
  ; import_completion : (string * string option) option
  ; render_title : string -> Journal_model.Title.t
  ; status_name : Journal_model.task_state -> string
  }

type action =
  | Append
  | Open_block of string
  | Delete_block of string
  | Copy_block of string
  | Load_more of string
  | Retry
  | Visible_range of int64 * int64
  | Import_asset of string

let handler on_action action =
  Ui.Event.Handler.create ~name:"journal-action" (fun _ -> on_action action)
;;

let live_region_text value =
  V.text value
  |> V.semantics ~properties:(Ui.Semantics.create ~label:value ~live_region:true ())
;;

module Detail_list = struct
  let view
        ~key
        ~detail
        ~enabled
        ~on_action
        ~on_scroll_completed
        ~on_visible_range
        ~children
    =
    let rows =
      List.map2 (fun row label ->
        let row_key = Ui.Key.string (Journal_detail.row_key row) in
        let item =
          match row with
          | Journal_detail.More _ ->
            V.Native_list.row ~key:row_key ~separator:Hidden label
          | Block { block; _ } ->
            let id = Journal_model.id block in
            let delete = handler on_action (Delete_block id) in
            let open_block = handler on_action (Open_block id) in
            let context_menu =
              V.Context_menu.create
                ~actions:
                  ((if id = Journal_model.page_id block then [] else [ V.Context_menu.action
                      ~key:(Ui.Key.string "open")
                      ~title:"Open block"
                      ~symbol:"arrow.up.right.square"
                      ~on_press:open_block
                      ()
                  ; V.Context_menu.action
                      ~key:(Ui.Key.string "delete")
                      ~enabled
                      ~role:Destructive
                      ~title:"Delete block and descendants"
                      ~symbol:"trash"
                      ~on_press:delete
                      ()
                  ]) @ [ V.Context_menu.action
                      ~key:(Ui.Key.string "copy")
                      ~enabled
                      ~title:"Copy"
                      ~symbol:"doc.on.doc"
                      ~on_press:(handler on_action (Copy_block id))
                      ()
                  ])
                ()
            in
            V.Native_list.row ~key:row_key ~separator:Hidden ~context_menu label
        in
        item)
        (Journal_detail.rows detail) children
    in
    let scroll_request =
      Option.map
        (fun id ->
           V.Native_list.scroll_request
             ~token:(Journal_detail.composer_revision detail)
             ~target:
               (V.Native_list.target
                  ~section:(Ui.Key.string "outline")
                  ~row_path:
                    [ Ui.Key.string ("block:" ^ id) ])
             ~anchor:Bottom
             ~animated:false
             ())
        (Journal_detail.reveal_id detail)
    in
    V.Native_list.vertical
      ~key
      ~style:Detail
      ?scroll_request
      ~on_scroll_completed
      ~on_visible_range
      [ V.Native_list.section ~key:(Ui.Key.string "outline") ~separator:Hidden rows ]
    |> V.Viewport.Vertical.with_test_id (Ui.Test_id.string "journal-detail-outline")
    |> V.Body.Vertical.fill
    |> fun content -> V.Body.Vertical.create [ content ]
  ;;
end

let view
      { content = presentation; scope; enabled; copy_enabled; copy_feedback
      ; import_request; import_completion; render_title; status_name }
      ~render_media ~on_scroll_completed ~on_action
  =
  let detail = match presentation with Ready detail -> Some detail | _ -> None in
  let saving = Option.fold ~none:false
      ~some:(fun detail -> Journal_detail.mode detail = Saving_child) detail in
  let bind command = handler on_action command in
  let button ?(enabled = true) ~id ~command ~symbol title =
    V.button
      ~enabled
      ~on_press:(bind command)
      ~child:(V.label ~title:(V.text title) ~icon:(V.symbol ~name:symbol ()) ())
      ()
    |> V.with_test_id (Ui.Test_id.string id)
  in
  let rows detail =
    List.map
      (function
        | Journal_detail.More { parent_id; loading; enabled; error; _ } ->
          if loading
          then V.loading ~message:"Loading children" ()
          else
            V.column
              (Option.to_list (Option.map live_region_text error)
               @ [ button
                     ~enabled
                     ~id:("detail-more:" ^ parent_id)
                     ~command:(Load_more parent_id)
                     ~symbol:
                       (if Option.is_some error then "arrow.clockwise" else "ellipsis")
                     (if Option.is_some error
                      then "Retry loading children"
                      else "Load more")
                 ]
               @ if enabled
                 then []
                 else [ V.text "Waiting for another branch to finish" ])
        | Block { block; depth; _ } ->
          let source = Journal_model.source block in
          let id = "detail-block:" ^ Journal_model.id block in
          let module Graph = Logseq_db_types.Graph_types in
          let created_from block =
            List.find_map (fun (p : Graph.property_summary) ->
              if p.ident = "logseq.property/created-from-property" then
                   List.find_map
                     (function
                       | Graph.Entity_value uuid -> Some uuid
                       | _ -> None)
                     p.values
              else None) (Journal_model.properties block)
          in
          let value_id = function
            | Graph.Default_value id when Journal_validation.is_uuid id -> Some id
            | Node_value uuid | Entity_value uuid | Asset_value uuid
            | Any_value (Internal_uuid uuid) -> Some (Graph.Uuid.to_string uuid)
            | _ -> None
          in
          let property_parent_id block =
            match Journal_model.parent_id block with
            | Some _ as parent -> parent
            | None when Journal_model.id block <> Journal_model.page_id block ->
              Some (Journal_model.page_id block)
            | None -> None
          in
          let owned_value property_uuid value =
            Option.fold ~none:false ~some:(fun id ->
              match Journal_detail.find_block detail ~block_id:id with
              | Some child -> property_parent_id child = Some (Journal_model.id block)
                && Journal_model.page_id child = Journal_model.page_id block
                && Option.fold ~none:false ~some:(Graph.Uuid.equal property_uuid) (created_from child)
              | None -> false) (value_id value)
          in
          let named_sources =
            Journal_model.display_properties block
            |> List.map (fun (p : Graph.property_summary) ->
              { p with values = List.filter (fun value -> not (owned_value p.uuid value)) p.values })
            |> Journal_model.property_sources
          in
          let property_name =
            Option.bind (created_from block) (fun property_uuid ->
              Option.bind (property_parent_id block) (fun parent_id ->
                Option.bind (Journal_detail.find_block detail ~block_id:parent_id) (fun parent ->
                  List.find_map (fun (p : Graph.property_summary) ->
                    if Graph.Uuid.equal p.uuid property_uuid
                      && List.exists (fun value -> value_id value = Some (Journal_model.id block)) p.values
                    then Some p.title else None) (Journal_model.properties parent))))
          in
          let property_value = Option.is_some (created_from block) in
          let field ~key name value =
            V.column ~spacing:4. ~alignment:Leading
              [ V.of_lui (Lui_elements.text ~value:name ~style_class:"caption" ~foreground:"secondary" [])
              ; Journal_header.detail_text ~title:(render_title value)
                  ~id:key ~depth:2 value ]
          in
          let text =
            if property_value then field ~key:id (Option.value property_name ~default:"Property") source
            else Journal_header.detail_text ~title:(render_title source)
              ~id ~depth source
          in
          let fields = List.map (fun (name, value) ->
            field ~key:("detail-property:" ^ Journal_model.id block ^ ":" ^ name) name value) named_sources in
          V.column ~spacing:8. ~alignment:Leading
            ((text :: Journal_row.metadata ~status_name:status_name block)
             @ fields)
          |> V.with_test_id (Ui.Test_id.string id)
          |> render_media
               ~known_images:(Option.fold ~none:[]
                 ~some:(fun file_type -> [Journal_model.id block, file_type])
                 (Journal_model.asset_file_type block))
               ~title:(Journal_model.source block)
               ~root:(Journal_model.id block)
          |> Journal_header.detail_row ~depth)
      (Journal_detail.rows detail)
  in
  let content =
    match detail with
    | Some detail ->
      Detail_list.view
        ~key:(Ui.Key.string scope)
        ~detail
        ~enabled:(enabled && not saving)
        ~on_action
        ~on_scroll_completed
        ~on_visible_range:
          (Ui.Event.Handler.create (function
             | Ui.Event.Payload.Visible_range range ->
               on_action (Visible_range (range.first_index, range.last_exclusive))
             | _ -> ()))
        ~children:(rows detail)
    | None ->
      (match presentation with
       | Loading visible ->
         if visible
         then V.loading ~centered:true ~message:"Loading block" ()
         else V.column []
       | Missing ->
         Presentation.unavailable
           ~title:"Block unavailable"
           ~symbol:"doc"
           ~message:"This block may have been deleted or moved."
           ~actions:(V.empty ())
       | Failed message ->
         Presentation.unavailable
           ~title:"Unable to open block"
           ~symbol:"exclamationmark.triangle"
           ~message
           ~actions:
             (button
                ~id:"detail-retry"
                ~command:Retry
                ~symbol:"arrow.clockwise"
                "Retry")
       | Ready _ | Empty -> V.empty ())
      |> V.Body.static
  in
  let actions_enabled = enabled && Option.is_some detail && not saving in
  content
  |> Journal_header.detail
       ~capture_enabled:actions_enabled
       ~on_capture:(bind Append)
       ~copy_enabled
       ~on_copy:(bind (Copy_block
         (Option.fold ~none:"" ~some:(fun d -> Journal_model.id (Journal_detail.root d)) detail)))
       ~copy_feedback
  |> Journal_asset_import.view
       ~key:(Ui.Key.string (scope ^ "import"))
       ~enabled:actions_enabled
       ~completion:import_completion
       ~request:import_request
       ~pending:[]
       ~on_select:(fun payload -> on_action (Import_asset payload))
  |> V.Body.static
  |> V.Body.with_test_id (Ui.Test_id.string "journal-detail-route")
;;
