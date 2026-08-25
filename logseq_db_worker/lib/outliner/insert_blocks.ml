include Planner_contract
open Graph_read

type placement =
  { parent : int
  ; page : int
  ; lower : string option
  ; upper : string option
  ; replacement : int option
  }

type relative_kind =
  | Sibling_before
  | Sibling_after
  | Child_first
  | Child_last

module Uuid_order = struct
  type t = Graph_types.Uuid.t

  let compare left right =
    String.compare (Graph_types.Uuid.to_string left) (Graph_types.Uuid.to_string right)
  ;;
end

module Uuid_map = Map.Make (Uuid_order)
module Uuid_set = Set.Make (Uuid_order)

let ( let* ) result f = Result.bind result f

let ordered_children db parent =
  let children = children db parent in
  let rec collect seen acc = function
    | [] -> Ok (List.sort (fun (left, _) (right, _) -> String.compare left right) acc)
    | entity :: rest ->
      (match string_value db entity "block/order" with
       | None -> Error (Invalid_order "A sibling has no valid block/order value.")
       | Some order when not (Outliner_order.is_valid order) ->
         Error (Invalid_order ("Invalid sibling order: " ^ order))
       | Some order when List.mem order seen ->
         Error (Invalid_order ("Duplicate sibling order: " ^ order))
       | Some order -> collect (order :: seen) ((order, entity) :: acc) rest)
  in
  collect [] [] children
;;

let require_entity db uuid =
  match entities_by_uuid db uuid with
  | [ entity ] -> Ok entity
  | [] -> Error (Invalid_selection "The insertion position UUID does not exist.")
  | _ -> Error (Invalid_selection "The insertion position UUID is ambiguous.")
;;

let page_for db entity =
  if is_page db entity then Some entity else reference_value db entity "block/page"
;;

let relative_placement db relation uuid =
  let* anchor = require_entity db uuid in
  if has_true db anchor "logseq.property/built-in?"
  then Error Built_in_protected
  else (
    match relation with
    | Sibling_before | Sibling_after ->
      if is_page db anchor
      then Error (Invalid_position "A page cannot be used as a sibling insertion anchor.")
      else (
        match reference_value db anchor "block/parent", page_for db anchor with
        | Some parent, Some page ->
          let* siblings = ordered_children db parent in
          let rec locate previous = function
            | [] ->
              Error
                (Invalid_position "The insertion anchor is not a child of its parent.")
            | (order, entity) :: rest when entity = anchor ->
              let next = Option.map fst (List.nth_opt rest 0) in
              let lower, upper =
                match relation with
                | Sibling_before -> Option.map fst previous, Some order
                | Sibling_after -> Some order, next
                | Child_first | Child_last -> assert false
              in
              Ok { parent; page; lower; upper; replacement = None }
            | sibling :: rest -> locate (Some sibling) rest
          in
          locate None siblings
        | _ ->
          Error
            (Invalid_position "The insertion anchor has no structural parent or page."))
    | Child_first | Child_last ->
      (match page_for db anchor with
       | None -> Error (Invalid_position "The insertion parent has no containing page.")
       | Some page ->
         let* siblings = ordered_children db anchor in
         let lower, upper =
           match relation, siblings with
           | Child_first, [] -> None, None
           | Child_first, (order, _) :: _ -> None, Some order
           | Child_last, [] -> None, None
           | Child_last, _ -> Some (fst (List.hd (List.rev siblings))), None
           | (Sibling_before | Sibling_after), _ -> assert false
         in
         Ok { parent = anchor; page; lower; upper; replacement = None }))
;;

let placement db roots = function
  | Protocol.Relative (Before uuid) -> relative_placement db Sibling_before uuid
  | Relative (After uuid) -> relative_placement db Sibling_after uuid
  | Relative (First_child uuid) -> relative_placement db Child_first uuid
  | Relative (Last_child uuid) -> relative_placement db Child_last uuid
  | Replace_empty uuid ->
    let* target = require_entity db uuid in
    if has_true db target "logseq.property/built-in?"
    then Error Built_in_protected
    else if is_page db target
    then Error (Invalid_position "A page cannot be replaced as an empty block.")
    else if List.length roots <> 1
    then Error (Invalid_tree "Replace_empty requires exactly one root.")
    else if not (Graph_types.Uuid.equal (List.hd roots).Protocol.uuid uuid)
    then Error (Invalid_position "The replacement root UUID must equal the target UUID.")
    else if
      Option.value (string_value db target "block/title") ~default:"not-empty"
      |> String.trim
      <> ""
    then Error (Invalid_position "The replacement target is not blank.")
    else if children db target <> []
    then Error (Invalid_position "The replacement target has children.")
    else (
      match
        ( reference_value db target "block/parent"
        , page_for db target
        , string_value db target "block/order" )
      with
      | Some parent, Some page, Some order when Outliner_order.is_valid order ->
        Ok { parent; page; lower = None; upper = None; replacement = Some target }
      | _, _, Some order -> Error (Invalid_order ("Invalid replacement order: " ^ order))
      | _ -> Error (Invalid_position "The replacement target is structurally incomplete."))
;;

let title_is_valid title =
  String.length title <= Protocol.maximum_title_bytes
  && Validation.valid_utf_8 title
  && not (String.contains title '\000')
;;

let validate_titles nodes =
  let rec loop = function
    | [] -> Ok ()
    | node :: rest ->
      if not (title_is_valid node.Tree.title)
      then
        Error
          (Unsupported_semantics
             "An inserted title is invalid or exceeds its byte budget.")
      else if Validation.contains_unsupported_save_effect node.title
      then
        Error
          (Unsupported_semantics
             "An inserted title requires an unsupported automatic effect.")
      else loop rest
  in
  loop nodes
;;

let find_substring value ~start needle =
  let rec loop index =
    if index + String.length needle > String.length value
    then None
    else if String.sub value index (String.length needle) = needle
    then Some index
    else loop (index + 1)
  in
  loop start
;;

let uuid_tokens title =
  let rec scan index acc =
    if index + 2 > String.length title
    then acc
    else (
      let closing =
        if String.sub title index 2 = "[["
        then Some "]]"
        else if String.sub title index 2 = "(("
        then Some "))"
        else None
      in
      match closing with
      | None -> scan (index + 1) acc
      | Some closing ->
        (match find_substring title ~start:(index + 2) closing with
         | None -> scan (index + 2) acc
         | Some finish ->
           let token = String.sub title (index + 2) (finish - index - 2) in
           let acc =
             match Graph_types.Uuid.of_string token with
             | Ok uuid -> Uuid_set.add uuid acc
             | Error _ -> acc
           in
           scan (finish + 2) acc))
  in
  scan 0 Uuid_set.empty
;;

let incoming_set nodes =
  List.fold_left
    (fun result node -> Uuid_set.add node.Tree.uuid result)
    Uuid_set.empty
    nodes
;;

let missing_reference_uuids db nodes =
  let incoming = incoming_set nodes in
  List.fold_left
    (fun result node ->
       Uuid_set.fold
         (fun uuid result ->
            if Uuid_set.mem uuid incoming || entities_by_uuid db uuid <> []
            then result
            else Uuid_set.add uuid result)
         (uuid_tokens node.Tree.title)
         result)
    Uuid_set.empty
    nodes
;;

let temp_ref prefix uuid = Datascript.Temp_id (prefix ^ Graph_types.Uuid.to_string uuid)

let provisional_db db nodes stubs replacement =
  let node_ops =
    List.concat_map
      (fun node ->
         match replacement with
         | Some (_, uuid) when Graph_types.Uuid.equal uuid node.Tree.uuid -> []
         | _ ->
           [ Datascript.Add
               ( temp_ref "insert:" node.uuid
               , "block/uuid"
               , Uuid (Graph_types.Uuid.to_string node.uuid) )
           ])
      nodes
  in
  let stub_ops =
    Uuid_set.elements stubs
    |> List.concat_map (fun uuid ->
      let text = Graph_types.Uuid.to_string uuid in
      [ Datascript.Add (temp_ref "stub:" uuid, "block/uuid", Uuid text)
      ; Add (temp_ref "stub:" uuid, "block/title", String text)
      ; Add (temp_ref "stub:" uuid, "block/name", String text)
      ])
  in
  Datascript.db_with (node_ops @ stub_ops) db
;;

let canonical_nodes planning_db nodes =
  let rec loop result = function
    | [] -> Ok (List.rev result)
    | node :: rest ->
      (match entities_by_uuid planning_db node.Tree.uuid with
       | [ self ] ->
         (match References.derive ~db:planning_db ~self ~title:node.title with
          | Ok derived -> loop ((node, derived) :: result) rest
          | Error (Missing_reference value) ->
            Error
              (Unsupported_semantics
                 ("The inserted title references a missing entity: " ^ value))
          | Error (Ambiguous_reference value) ->
            Error
              (Invalid_selection ("The inserted title reference is ambiguous: " ^ value))
          | Error (Invalid_reference value) ->
            Error
              (Unsupported_semantics ("The inserted title reference is invalid: " ^ value)))
       | [] -> Error (Invalid_tree "An inserted UUID could not be staged.")
       | _ -> Error (Conflict "An inserted UUID is ambiguous."))
  in
  loop [] nodes
;;

let requested_children nodes parent_uuid =
  List.filter_map
    (fun node ->
       match node.Tree.parent_uuid with
       | Some parent when Graph_types.Uuid.equal parent parent_uuid -> Some node.uuid
       | Some _ | None -> None)
    nodes
;;

let existing_children_uuids db entity =
  children db entity
  |> List.filter_map (fun child -> Result.to_option (uuid_of_entity db child))
  |> List.sort (fun left right ->
    let left_entity = List.hd (entities_by_uuid db left) in
    let right_entity = List.hd (entities_by_uuid db right) in
    String.compare
      (Option.value (string_value db left_entity "block/order") ~default:"")
      (Option.value (string_value db right_entity "block/order") ~default:""))
;;

let roots_are_at_position db roots position =
  let root_entities =
    List.map (fun root -> List.hd (entities_by_uuid db root.Protocol.uuid)) roots
  in
  let slice_matches values offset expected =
    let rec loop values offset expected =
      match expected with
      | [] -> true
      | expected :: rest ->
        (match List.nth_opt values offset with
         | Some actual when actual = expected -> loop values (offset + 1) rest
         | Some _ | None -> false)
    in
    loop values offset expected
  in
  match position with
  | Protocol.Replace_empty uuid ->
    (match roots with
     | [ root ] -> Graph_types.Uuid.equal root.uuid uuid
     | [] | _ :: _ :: _ -> false)
  | Relative relation ->
    let anchor_uuid, mode =
      match relation with
      | Before uuid -> uuid, `Before
      | After uuid -> uuid, `After
      | First_child uuid -> uuid, `First
      | Last_child uuid -> uuid, `Last
    in
    (match entities_by_uuid db anchor_uuid with
     | [ anchor ] ->
       let parent =
         match mode with
         | `Before | `After -> reference_value db anchor "block/parent"
         | `First | `Last -> Some anchor
       in
       (match parent with
        | None -> false
        | Some parent ->
          let siblings =
            ordered_children db parent |> Result.to_option |> Option.value ~default:[]
          in
          let entities = List.map snd siblings in
          let offset =
            match mode with
            | `First -> 0
            | `Last -> List.length entities - List.length root_entities
            | `Before ->
              Option.value
                (List.find_index (fun entity -> entity = anchor) entities)
                ~default:(-1)
            | `After ->
              Option.value
                (List.find_index (fun entity -> entity = anchor) entities)
                ~default:(-2)
              + 1
          in
          offset >= 0 && slice_matches entities offset root_entities)
     | [] | _ :: _ :: _ -> false)
;;

let exact_existing_tree db nodes roots position =
  roots_are_at_position db roots position
  && List.for_all
       (fun node ->
          match entities_by_uuid db node.Tree.uuid with
          | [ entity ] ->
            (match References.derive ~db ~self:entity ~title:node.title with
             | Ok derived ->
               string_value db entity "block/title" = Some derived.canonical_title
             | Error _ -> false)
            && existing_children_uuids db entity = requested_children nodes node.uuid
          | [] | _ :: _ :: _ -> false)
       nodes
;;

let ensure_new_uuids db nodes replacement =
  let existing =
    List.filter
      (fun node ->
         match replacement with
         | Some (_, uuid) when Graph_types.Uuid.equal uuid node.Tree.uuid -> false
         | _ -> entities_by_uuid db node.uuid <> [])
      nodes
  in
  if existing = []
  then Ok ()
  else Error (Conflict "An inserted UUID is already used by a different or partial tree.")
;;

let parent_ref placement replacement node =
  match node.Tree.parent_uuid with
  | None -> Datascript.Entity_id placement.parent
  | Some parent_uuid ->
    (match replacement with
     | Some (entity, uuid) when Graph_types.Uuid.equal uuid parent_uuid ->
       Entity_id entity
     | Some _ | None -> temp_ref "insert:" parent_uuid)
;;

let entity_ref replacement node =
  match replacement with
  | Some (entity, uuid) when Graph_types.Uuid.equal uuid node.Tree.uuid ->
    Datascript.Entity_id entity
  | Some _ | None -> temp_ref "insert:" node.uuid
;;

let ref_for_uuid db replacement stubs uuid =
  match replacement with
  | Some (entity, replaced_uuid) when Graph_types.Uuid.equal uuid replaced_uuid ->
    Datascript.Entity_id entity
  | Some _ | None ->
    if Uuid_set.mem uuid stubs
    then temp_ref "stub:" uuid
    else (
      match entities_by_uuid db uuid with
      | [ entity ] -> Entity_id entity
      | [] -> temp_ref "insert:" uuid
      | _ -> temp_ref "insert:" uuid)
;;

let orders_by_parent nodes placement =
  let groups =
    List.fold_left
      (fun groups node ->
         let key = node.Tree.parent_uuid in
         let current = Option.value (List.assoc_opt key groups) ~default:[] in
         (key, current @ [ node ]) :: List.remove_assoc key groups)
      []
      nodes
  in
  let rec build result = function
    | [] -> Ok result
    | (parent_uuid, siblings) :: rest ->
      let lower, upper =
        match parent_uuid with
        | None -> placement.lower, placement.upper
        | Some _ -> None, None
      in
      (match Outliner_order.sequence_between ~lower ~upper (List.length siblings) with
       | Error (Outliner_order.Invalid_key key) -> Error (Invalid_order key)
       | Error No_space -> Error (Invalid_order "No fractional order space remains.")
       | Ok orders ->
         let result =
           List.fold_left2
             (fun result node order -> Uuid_map.add node.Tree.uuid order result)
             result
             siblings
             orders
         in
         build result rest)
  in
  build Uuid_map.empty groups
;;

let tx_meta context =
  [ ( "db-sync/tx-id"
    , Datascript.Uuid (Graph_types.Uuid.to_string context.Protocol.mutation_id) )
  ; "outliner-op", Datascript.Keyword "insert-blocks"
  ; "local-tx?", Datascript.Bool true
  ]
;;

let unique_uuids values =
  List.fold_left
    (fun result uuid ->
       if List.exists (Graph_types.Uuid.equal uuid) result
       then result
       else result @ [ uuid ])
    []
    values
;;

let rec concat_map_result f = function
  | [] -> Ok []
  | value :: rest ->
    let* current = f value in
    let* rest = concat_map_result f rest in
    Ok (current @ rest)
;;

let reference_ops planning_db db replacement stubs entity attr targets =
  let operation target =
    match uuid_of_entity planning_db target with
    | Error _ -> Error (Invalid_tree "A derived reference target has no UUID.")
    | Ok uuid ->
      Ok
        [ Datascript.Add (entity, attr, Ref_to (ref_for_uuid db replacement stubs uuid)) ]
  in
  concat_map_result operation targets
;;

let order_for_node db replacement orders node =
  match replacement with
  | Some (entity, uuid) when Graph_types.Uuid.equal uuid node.Tree.uuid ->
    (match string_value db entity "block/order" with
     | Some order -> Ok order
     | None -> Error (Invalid_order "The replacement target has no block/order value."))
  | Some _ | None ->
    (match Uuid_map.find_opt node.uuid orders with
     | Some order -> Ok order
     | None -> Error (Invalid_order "No order was generated for an inserted block."))
;;

let node_operations
      ~now
      ~next_tx
      ~planning_db
      ~db
      ~placement
      ~replacement
      ~stubs
      ~orders
      (node, derived)
  =
  let entity = entity_ref replacement node in
  let* order = order_for_node db replacement orders node in
  let* refs =
    reference_ops
      planning_db
      db
      replacement
      stubs
      entity
      "block/refs"
      derived.References.content_refs
  in
  let* tags =
    reference_ops planning_db db replacement stubs entity "block/tags" derived.inline_tags
  in
  Ok
    ([ Datascript.Add (entity, "block/uuid", Uuid (Graph_types.Uuid.to_string node.uuid))
     ; Add (entity, "block/title", String derived.canonical_title)
     ; Add (entity, "block/parent", Ref_to (parent_ref placement replacement node))
     ; Add (entity, "block/page", Ref_to (Entity_id placement.page))
     ; Add (entity, "block/order", String order)
     ; Add (entity, "block/created-at", Int now)
     ; Add (entity, "block/updated-at", Int now)
     ; Add (entity, "block/tx-id", Int next_tx)
     ]
     @ refs
     @ tags)
;;

let plan ~now_ms db ~roots ~position ~context =
  let* nodes =
    match Tree.flatten roots with
    | Ok nodes -> Ok nodes
    | Error Tree.Empty_roots ->
      Error (Invalid_tree "Insert_blocks roots must be non-empty.")
    | Error Too_many_roots ->
      Error (Invalid_tree "Insert_blocks exceeds the root-count limit.")
    | Error Too_many_nodes ->
      Error (Invalid_tree "Insert_blocks exceeds the tree-node limit.")
    | Error Too_deep -> Error (Invalid_tree "Insert_blocks exceeds the tree-depth limit.")
    | Error (Duplicate_uuid uuid) ->
      Error (Invalid_tree ("Duplicate inserted UUID: " ^ Graph_types.Uuid.to_string uuid))
  in
  let* () = validate_titles nodes in
  let all_existing =
    List.for_all (fun node -> List.length (entities_by_uuid db node.Tree.uuid) = 1) nodes
  in
  if all_existing && exact_existing_tree db nodes roots position
  then
    Ok
      { tx_ops = []
      ; tx_meta = tx_meta context
      ; changed_uuids = []
      ; status = Protocol.Already_applied
      }
  else
    let* placement = placement db roots position in
    let replacement =
      Option.map
        (fun entity -> entity, (List.hd roots).Protocol.uuid)
        placement.replacement
    in
    let* () = ensure_new_uuids db nodes replacement in
    let stubs = missing_reference_uuids db nodes in
    let planning_db = provisional_db db nodes stubs replacement in
    let* canonical = canonical_nodes planning_db nodes in
    let* orders = orders_by_parent nodes placement in
    let now = Int64.to_int now_ms in
    let next_tx = (Datascript.serializable db).serializable_max_tx + 1 in
    let* node_ops =
      concat_map_result
        (node_operations
           ~now
           ~next_tx
           ~planning_db
           ~db
           ~placement
           ~replacement
           ~stubs
           ~orders)
        canonical
    in
    let stub_ops =
      Uuid_set.elements stubs
      |> List.concat_map (fun uuid ->
        let entity = temp_ref "stub:" uuid in
        let text = Graph_types.Uuid.to_string uuid in
        [ Datascript.Add (entity, "block/uuid", Uuid text)
        ; Add (entity, "block/title", String text)
        ; Add (entity, "block/name", String text)
        ; Add (entity, "block/created-at", Int now)
        ; Add (entity, "block/updated-at", Int now)
        ; Add (entity, "block/tx-id", Int next_tx)
        ])
    in
    let page_ops =
      [ Datascript.Add (Entity_id placement.page, "block/updated-at", Int now)
      ; Add (Entity_id placement.page, "block/tx-id", Int next_tx)
      ]
    in
    let* page_uuid =
      match uuid_of_entity db placement.page with
      | Ok uuid -> Ok uuid
      | Error _ -> Error (Invalid_position "The containing page has no UUID.")
    in
    let changed_uuids =
      unique_uuids
        (List.map (fun node -> node.Tree.uuid) nodes
         @ Uuid_set.elements stubs
         @ [ page_uuid ])
    in
    Ok
      { tx_ops = node_ops @ stub_ops @ page_ops
      ; tx_meta = tx_meta context
      ; changed_uuids
      ; status = Protocol.Applied
      }
;;
