include Planner_contract
open Graph_read

type selection =
  { roots : int list
  ; source_parent : int
  ; source_page : int
  ; source_siblings : (string * int) list
  }

type destination =
  { parent : int
  ; page : int
  ; remaining_siblings : (string * int) list
  ; insertion_index : int
  }

module Int_set = Set.Make (Int)

module Uuid_set = Set.Make (struct
    type t = Graph_types.Uuid.t

    let compare = Graph_types.Uuid.compare
  end)

let ( let* ) result f = Result.bind result f

let ident db entity =
  match one db entity "db/ident" with
  | Some (Datascript.Keyword value | String value) -> Some value
  | Some _ | None -> None
;;

let has_tag_ident db entity expected =
  values db entity "block/tags"
  |> List.exists (function
    | Datascript.Ref tag -> ident db tag = Some expected
    | _ -> false)
;;

let protected_comment_entity db entity =
  has_tag_ident db entity "logseq.class/Comment"
  || has_tag_ident db entity "logseq.class/Comments"
  ||
  match reference_value db entity "block/parent" with
  | Some parent -> has_tag_ident db parent "logseq.class/Comments"
  | None -> false
;;

let require_entity db uuid =
  match entities_by_uuid db uuid with
  | [ entity ] -> Ok entity
  | [] -> Error (Invalid_selection "A selected block UUID does not exist.")
  | _ -> Error (Invalid_selection "A selected block UUID is ambiguous.")
;;

let ordered_children db parent =
  let rec collect seen result = function
    | [] -> Ok (List.sort (fun (left, _) (right, _) -> String.compare left right) result)
    | entity :: rest ->
      (match string_value db entity "block/order" with
       | None -> Error (Invalid_order "A sibling has no block/order value.")
       | Some order when not (Outliner_order.is_valid order) ->
         Error (Invalid_order ("Invalid sibling order: " ^ order))
       | Some order when List.mem order seen ->
         Error (Invalid_order ("Duplicate sibling order: " ^ order))
       | Some order -> collect (order :: seen) ((order, entity) :: result) rest)
  in
  collect [] [] (children db parent)
;;

let page_for db entity =
  if is_page db entity then Some entity else reference_value db entity "block/page"
;;

let rec ancestor_in selected db entity =
  match reference_value db entity "block/parent" with
  | None -> false
  | Some parent when parent = entity -> false
  | Some parent -> Int_set.mem parent selected || ancestor_in selected db parent
;;

let indices values selected =
  List.mapi (fun index (_, entity) -> index, entity) values
  |> List.filter_map (fun (index, entity) ->
    if Int_set.mem entity selected then Some index else None)
;;

let consecutive = function
  | [] | [ _ ] -> true
  | first :: rest ->
    let _, valid =
      List.fold_left
        (fun (previous, valid) current -> current, valid && current = previous + 1)
        (first, true)
        rest
    in
    valid
;;

let first = function
  | value :: _ -> Ok value
  | [] -> Error (Invalid_tree "A canonical move selection is unexpectedly empty.")
;;

let last values =
  match List.rev values with
  | value :: _ -> Ok value
  | [] -> Error (Invalid_tree "A canonical move selection is unexpectedly empty.")
;;

let resolve_selection db root_uuids =
  if root_uuids = []
  then Error (Invalid_tree "Move_blocks roots must be non-empty.")
  else if List.length root_uuids > Protocol.maximum_roots
  then Error (Invalid_tree "Move_blocks exceeds the root-count limit.")
  else (
    let rec resolve seen result = function
      | [] -> Ok (List.rev result)
      | uuid :: rest ->
        if Uuid_set.mem uuid seen
        then Error (Invalid_tree "Move_blocks contains a duplicate UUID.")
        else
          let* entity = require_entity db uuid in
          if is_page db entity
          then Error (Invalid_selection "Pages cannot be moved through Move_blocks.")
          else if has_true db entity "logseq.property/built-in?"
          then Error Built_in_protected
          else if values db entity "logseq.property/created-from-property" <> []
          then
            Error
              (Unsupported_semantics
                 "Property-value blocks cannot be moved by this operation.")
          else if protected_comment_entity db entity
          then
            Error
              (Unsupported_semantics
                 "Protected comment nodes cannot be moved by this operation.")
          else resolve (Uuid_set.add uuid seen) (entity :: result) rest
    in
    let* selected_entities = resolve Uuid_set.empty [] root_uuids in
    let selected =
      List.fold_left
        (fun set entity -> Int_set.add entity set)
        Int_set.empty
        selected_entities
    in
    let top_roots =
      List.filter (fun entity -> not (ancestor_in selected db entity)) selected_entities
    in
    match top_roots with
    | [] -> Error (Invalid_tree "Move_blocks has no canonical roots.")
    | first :: _ ->
      (match reference_value db first "block/parent", page_for db first with
       | Some source_parent, Some source_page ->
         if
           not
             (List.for_all
                (fun entity ->
                   reference_value db entity "block/parent" = Some source_parent)
                top_roots)
         then Error (Invalid_tree "Move_blocks roots must share one parent.")
         else
           let* source_siblings = ordered_children db source_parent in
           let top_set =
             List.fold_left
               (fun set entity -> Int_set.add entity set)
               Int_set.empty
               top_roots
           in
           let positions = indices source_siblings top_set in
           if
             List.length positions <> List.length top_roots || not (consecutive positions)
           then
             Error
               (Invalid_tree "Move_blocks roots must be a continuous canonical selection.")
           else (
             let roots =
               List.filter_map
                 (fun (_, entity) ->
                    if Int_set.mem entity top_set then Some entity else None)
                 source_siblings
             in
             Ok { roots; source_parent; source_page; source_siblings })
       | _ -> Error (Invalid_tree "A move root has no structural parent or page.")))
;;

let rec subtree_entities db entity =
  entity :: List.concat_map (subtree_entities db) (children db entity)
;;

let moved_entities db roots =
  List.concat_map (subtree_entities db) roots
  |> List.fold_left (fun set entity -> Int_set.add entity set) Int_set.empty
;;

let index_of entity values =
  List.find_index (fun (_, candidate) -> candidate = entity) values
;;

let destination db selection position =
  let target_uuid, mode =
    match position with
    | Protocol.Before uuid -> uuid, `Before
    | After uuid -> uuid, `After
    | First_child uuid -> uuid, `First
    | Last_child uuid -> uuid, `Last
  in
  let* target = require_entity db target_uuid in
  let moved = moved_entities db selection.roots in
  if has_true db target "logseq.property/built-in?"
  then Error Built_in_protected
  else if values db target "logseq.property/created-from-property" <> []
  then Error (Unsupported_semantics "Property-value blocks cannot be move targets.")
  else if protected_comment_entity db target
  then Error (Unsupported_semantics "Protected comment nodes cannot be move targets.")
  else if Int_set.mem target moved
  then Error (Invalid_position "A move target cannot be the source or its descendant.")
  else
    let* parent, page =
      match mode with
      | `Before | `After ->
        if is_page db target
        then Error (Invalid_position "A page cannot be used as a sibling move target.")
        else (
          match reference_value db target "block/parent", page_for db target with
          | Some parent, Some page -> Ok (parent, page)
          | _ ->
            Error (Invalid_position "The move target has no structural parent or page."))
      | `First | `Last ->
        (match page_for db target with
         | Some page -> Ok (target, page)
         | None -> Error (Invalid_position "The move target has no containing page."))
    in
    let* siblings = ordered_children db parent in
    let root_set =
      List.fold_left
        (fun set entity -> Int_set.add entity set)
        Int_set.empty
        selection.roots
    in
    let remaining =
      List.filter (fun (_, entity) -> not (Int_set.mem entity root_set)) siblings
    in
    let* insertion_index =
      match mode with
      | `First -> Ok 0
      | `Last -> Ok (List.length remaining)
      | `Before ->
        (match index_of target remaining with
         | Some index -> Ok index
         | None -> Error (Invalid_position "The move target disappeared from its parent."))
      | `After ->
        (match index_of target remaining with
         | Some index -> Ok (index + 1)
         | None -> Error (Invalid_position "The move target disappeared from its parent."))
    in
    Ok { parent; page; remaining_siblings = remaining; insertion_index }
;;

let insert_at index inserted values =
  let rec loop current before = function
    | rest when current = index -> List.rev_append before (inserted @ rest)
    | [] -> List.rev_append before inserted
    | value :: rest -> loop (current + 1) (value :: before) rest
  in
  loop 0 [] values
;;

let same_entities left right = List.map snd left = List.map snd right

let order_bounds destination =
  let lower =
    if destination.insertion_index = 0
    then None
    else
      Option.map
        fst
        (List.nth_opt destination.remaining_siblings (destination.insertion_index - 1))
  in
  let upper =
    Option.map
      fst
      (List.nth_opt destination.remaining_siblings destination.insertion_index)
  in
  lower, upper
;;

let tx_meta context operation =
  [ ( "db-sync/tx-id"
    , Datascript.Uuid (Graph_types.Uuid.to_string context.Protocol.mutation_id) )
  ; "outliner-op", Datascript.Keyword operation
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

let uuid_or_error db entity message =
  match uuid_of_entity db entity with
  | Ok uuid -> Ok uuid
  | Error _ -> Error (Invalid_tree message)
;;

let plan_resolved ~now_ms db selection destination ~context ~operation =
  let desired =
    insert_at
      destination.insertion_index
      (List.map (fun entity -> "", entity) selection.roots)
      destination.remaining_siblings
  in
  if
    destination.parent = selection.source_parent
    && same_entities desired selection.source_siblings
  then Error (Invalid_position "The blocks are already at the requested position.")
  else (
    let lower, upper = order_bounds destination in
    let* orders =
      match
        Outliner_order.sequence_between ~lower ~upper (List.length selection.roots)
      with
      | Ok orders -> Ok orders
      | Error (Outliner_order.Invalid_key key) -> Error (Invalid_order key)
      | Error No_space -> Error (Invalid_order "No fractional order space remains.")
    in
    let now = Int64.to_int now_ms in
    let next_tx = (Datascript.serializable db).serializable_max_tx + 1 in
    let root_ops =
      List.concat
        (List.map2
           (fun entity order ->
              [ Datascript.Add
                  (Entity_id entity, "block/parent", Ref_to (Entity_id destination.parent))
              ; Add (Entity_id entity, "block/page", Ref_to (Entity_id destination.page))
              ; Add (Entity_id entity, "block/order", String order)
              ; Add (Entity_id entity, "block/updated-at", Int now)
              ; Add (Entity_id entity, "block/tx-id", Int next_tx)
              ])
           selection.roots
           orders)
    in
    let descendants =
      List.concat_map (subtree_entities db) selection.roots
      |> List.filter (fun entity -> not (List.mem entity selection.roots))
    in
    let rewritten_descendants =
      List.filter
        (fun entity -> reference_value db entity "block/page" <> Some destination.page)
        descendants
    in
    let descendant_ops =
      List.concat_map
        (fun entity ->
           [ Datascript.Add
               (Entity_id entity, "block/page", Ref_to (Entity_id destination.page))
           ; Add (Entity_id entity, "block/updated-at", Int now)
           ; Add (Entity_id entity, "block/tx-id", Int next_tx)
           ])
        rewritten_descendants
    in
    let touched_pages =
      if selection.source_page = destination.page
      then [ selection.source_page ]
      else [ selection.source_page; destination.page ]
    in
    let page_ops =
      List.concat_map
        (fun page ->
           [ Datascript.Add (Entity_id page, "block/updated-at", Int now)
           ; Add (Entity_id page, "block/tx-id", Int next_tx)
           ])
        touched_pages
    in
    let changed_entities = selection.roots @ rewritten_descendants @ touched_pages in
    let rec changed_uuids result = function
      | [] -> Ok (unique_uuids (List.rev result))
      | entity :: rest ->
        let* uuid = uuid_or_error db entity "A moved entity has no UUID." in
        changed_uuids (uuid :: result) rest
    in
    let* changed_uuids = changed_uuids [] changed_entities in
    Ok
      { tx_ops = root_ops @ descendant_ops @ page_ops
      ; tx_meta = tx_meta context operation
      ; changed_uuids
      ; status = Protocol.Applied
      })
;;

let plan_with_operation ~now_ms db ~roots ~position ~context ~operation =
  let* selection = resolve_selection db roots in
  let* destination = destination db selection position in
  plan_resolved ~now_ms db selection destination ~context ~operation
;;

let plan ~now_ms db ~roots ~position ~context =
  plan_with_operation ~now_ms db ~roots ~position ~context ~operation:"move-blocks"
;;

let no_change context =
  Ok
    { tx_ops = []
    ; tx_meta = tx_meta context "move-blocks-up-down"
    ; changed_uuids = []
    ; status = Protocol.No_change
    }
;;

let plan_up_down ~now_ms db ~roots ~direction ~context =
  let* selection = resolve_selection db roots in
  let selected =
    List.fold_left
      (fun set entity -> Int_set.add entity set)
      Int_set.empty
      selection.roots
  in
  let positions = indices selection.source_siblings selected in
  let* first_index = first positions in
  let* last_index = last positions in
  let delegate position =
    plan_with_operation
      ~now_ms
      db
      ~roots
      ~position
      ~context
      ~operation:"move-blocks-up-down"
  in
  match direction with
  | Protocol.Up ->
    if first_index > 0
    then (
      let _, target = List.nth selection.source_siblings (first_index - 1) in
      let* uuid = uuid_or_error db target "The previous sibling has no UUID." in
      delegate (Before uuid))
    else if is_page db selection.source_parent
    then no_change context
    else (
      match reference_value db selection.source_parent "block/parent" with
      | None -> no_change context
      | Some grandparent ->
        let* parent_siblings = ordered_children db grandparent in
        (match index_of selection.source_parent parent_siblings with
         | Some index when index > 0 ->
           let _, target = List.nth parent_siblings (index - 1) in
           let* uuid =
             uuid_or_error db target "The previous parent sibling has no UUID."
           in
           delegate (Last_child uuid)
         | Some _ | None -> no_change context))
  | Down ->
    if last_index + 1 < List.length selection.source_siblings
    then (
      let _, target = List.nth selection.source_siblings (last_index + 1) in
      let* uuid = uuid_or_error db target "The next sibling has no UUID." in
      delegate (After uuid))
    else if is_page db selection.source_parent
    then no_change context
    else (
      match reference_value db selection.source_parent "block/parent" with
      | None -> no_change context
      | Some grandparent ->
        let* parent_siblings = ordered_children db grandparent in
        (match index_of selection.source_parent parent_siblings with
         | Some index when index + 1 < List.length parent_siblings ->
           let _, target = List.nth parent_siblings (index + 1) in
           let* uuid = uuid_or_error db target "The next parent sibling has no UUID." in
           delegate (First_child uuid)
         | Some _ | None -> no_change context))
;;
