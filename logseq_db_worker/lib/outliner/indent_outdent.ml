type t =
  { tx_ops : Datascript.tx_op list
  ; tx_meta : Datascript.tx_meta
  ; changed_uuids : Graph_types.Uuid.t list
  ; status : Protocol.mutation_status
  }

type error =
  | Unsupported_semantics of string
  | Invalid_selection of string
  | Invalid_tree of string
  | Invalid_order of string
  | Invalid_position of string
  | Built_in_protected

type selection =
  { roots : int list
  ; parent : int
  ; page : int
  ; siblings : (string * int) list
  ; first_index : int
  ; last_index : int
  }

module Int_set = Set.Make (Int)

module Uuid_set = Set.Make (struct
    type t = Graph_types.Uuid.t

    let compare = Graph_types.Uuid.compare
  end)

let ( let* ) result f = Result.bind result f

let values db entity attr =
  Datascript.datoms db Datascript.Eavt ~e:entity ~a:attr ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.v)
;;

let one db entity attr =
  match values db entity attr with
  | [ value ] -> Some value
  | [] | _ :: _ :: _ -> None
;;

let string_value db entity attr =
  match one db entity attr with
  | Some (Datascript.String value) -> Some value
  | Some _ | None -> None
;;

let reference_value db entity attr =
  match one db entity attr with
  | Some (Datascript.Ref value) -> Some value
  | Some _ | None -> None
;;

let has_true db entity attr =
  match one db entity attr with
  | Some (Datascript.Bool true) -> true
  | Some _ | None -> false
;;

let is_page db entity = Option.is_some (string_value db entity "block/name")

let entities_by_uuid db uuid =
  let text = Graph_types.Uuid.to_string uuid in
  let find value =
    Datascript.datoms db Datascript.Avet ~a:"block/uuid" ~v:value ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.e)
  in
  find (Datascript.Uuid text) @ find (String text) |> List.sort_uniq Int.compare
;;

let require_entity db uuid =
  match entities_by_uuid db uuid with
  | [ entity ] -> Ok entity
  | [] -> Error (Invalid_selection "An indent/outdent block UUID does not exist.")
  | _ -> Error (Invalid_selection "An indent/outdent block UUID is ambiguous.")
;;

let uuid_of_entity db entity =
  match one db entity "block/uuid" with
  | Some (Datascript.Uuid value | String value) -> Graph_types.Uuid.of_string value
  | Some _ | None -> Error "entity has no UUID"
;;

let page_for db entity =
  if is_page db entity then Some entity else reference_value db entity "block/page"
;;

let children db parent =
  Datascript.datoms db Datascript.Avet ~a:"block/parent" ~v:(Datascript.Ref parent) ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.filter (fun entity -> entity <> parent)
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

let rec ancestor_in selected db entity =
  match reference_value db entity "block/parent" with
  | None -> false
  | Some parent when parent = entity -> false
  | Some parent -> Int_set.mem parent selected || ancestor_in selected db parent
;;

let resolve_selection db root_uuids =
  if root_uuids = []
  then Error (Invalid_tree "Indent_outdent roots must be non-empty.")
  else if List.length root_uuids > Protocol.maximum_roots
  then Error (Invalid_tree "Indent_outdent exceeds the root-count limit.")
  else (
    let rec resolve seen result = function
      | [] -> Ok (List.rev result)
      | uuid :: rest ->
        if Uuid_set.mem uuid seen
        then Error (Invalid_tree "Indent_outdent contains a duplicate UUID.")
        else
          let* entity = require_entity db uuid in
          resolve (Uuid_set.add uuid seen) (entity :: result) rest
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
    | [] -> Error (Invalid_tree "Indent_outdent has no canonical roots.")
    | first :: _ ->
      (match reference_value db first "block/parent", page_for db first with
       | Some parent, Some page ->
         if
           not
             (List.for_all
                (fun entity -> reference_value db entity "block/parent" = Some parent)
                top_roots)
         then Error (Invalid_tree "Indent_outdent roots must share one parent.")
         else
           let* siblings = ordered_children db parent in
           let selected =
             List.fold_left
               (fun set entity -> Int_set.add entity set)
               Int_set.empty
               top_roots
           in
           let indexed = List.mapi (fun index (_, entity) -> index, entity) siblings in
           let positions =
             List.filter_map
               (fun (index, entity) ->
                  if Int_set.mem entity selected then Some index else None)
               indexed
           in
           let rec continuous = function
             | [] | [ _ ] -> true
             | left :: (right :: _ as rest) -> right = left + 1 && continuous rest
           in
           if List.length positions <> List.length top_roots || not (continuous positions)
           then
             Error
               (Invalid_tree
                  "Indent_outdent roots must be a continuous canonical selection.")
           else (
             match positions with
             | [] -> Error (Invalid_tree "Indent_outdent has no canonical positions.")
             | first_index :: _ ->
               let last_index = List.fold_left Int.max first_index positions in
               let roots =
                 List.filter_map
                   (fun (_, entity) ->
                      if Int_set.mem entity selected then Some entity else None)
                   siblings
               in
               Ok { roots; parent; page; siblings; first_index; last_index })
       | _ ->
         Error (Invalid_tree "An indent/outdent root has no structural parent or page.")))
;;

let map_move_error = function
  | Move_blocks.Unsupported_semantics message -> Error (Unsupported_semantics message)
  | Invalid_selection message -> Error (Invalid_selection message)
  | Invalid_tree message -> Error (Invalid_tree message)
  | Invalid_order message -> Error (Invalid_order message)
  | Invalid_position message -> Error (Invalid_position message)
  | Built_in_protected -> Error Built_in_protected
;;

let roots_as_uuids db roots =
  let rec loop result = function
    | [] -> Ok (List.rev result)
    | entity :: rest ->
      (match uuid_of_entity db entity with
       | Ok uuid -> loop (uuid :: result) rest
       | Error _ -> Error (Invalid_tree "An indent/outdent root has no UUID."))
  in
  loop [] roots
;;

let replace_operation_meta context tx_meta =
  ("outliner-op", Datascript.Keyword "indent-outdent-blocks")
  :: ( "db-sync/tx-id"
     , Datascript.Uuid (Graph_types.Uuid.to_string context.Protocol.mutation_id) )
  :: ("local-tx?", Datascript.Bool true)
  :: List.filter
       (fun (attr, _) ->
          not (List.mem attr [ "outliner-op"; "db-sync/tx-id"; "local-tx?" ]))
       tx_meta
;;

let append_changed db plan entities =
  let rec collect result = function
    | [] -> Ok result
    | entity :: rest ->
      (match uuid_of_entity db entity with
       | Error _ -> Error (Invalid_tree "A touched indent/outdent entity has no UUID.")
       | Ok uuid ->
         let result =
           if List.exists (Graph_types.Uuid.equal uuid) result
           then result
           else result @ [ uuid ]
         in
         collect result rest)
  in
  collect plan.Move_blocks.changed_uuids entities
;;

let indent ~now_ms db selection ~context =
  if selection.first_index = 0
  then Error (Invalid_position "Indent requires a left sibling.")
  else (
    let _, left = List.nth selection.siblings (selection.first_index - 1) in
    let* roots = roots_as_uuids db selection.roots in
    let* left_uuid =
      match uuid_of_entity db left with
      | Ok uuid -> Ok uuid
      | Error _ -> Error (Invalid_position "The left sibling has no UUID.")
    in
    let had_children = children db left <> [] in
    match
      Move_blocks.plan ~now_ms db ~roots ~position:(Last_child left_uuid) ~context
    with
    | Error error -> map_move_error error
    | Ok move_plan ->
      let expand = had_children && has_true db left "block/collapsed?" in
      let next_tx = (Datascript.serializable db).serializable_max_tx + 1 in
      let now = Int64.to_int now_ms in
      let extra_ops =
        if expand
        then
          [ Datascript.Add (Entity_id left, "block/collapsed?", Bool false)
          ; Add (Entity_id left, "block/updated-at", Int now)
          ; Add (Entity_id left, "block/tx-id", Int next_tx)
          ]
        else []
      in
      let* changed_uuids =
        append_changed db move_plan (if expand then [ left ] else [])
      in
      Ok
        { tx_ops = move_plan.tx_ops @ extra_ops
        ; tx_meta = replace_operation_meta context move_plan.tx_meta
        ; changed_uuids
        ; status = Protocol.Applied
        })
;;

let direct_outdent ~now_ms db selection ~context =
  if is_page db selection.parent
  then Error (Invalid_position "A page-root block cannot be outdented.")
  else
    let* roots = roots_as_uuids db selection.roots in
    let* parent_uuid =
      match uuid_of_entity db selection.parent with
      | Ok uuid -> Ok uuid
      | Error _ -> Error (Invalid_position "The outdent parent has no UUID.")
    in
    match Move_blocks.plan ~now_ms db ~roots ~position:(After parent_uuid) ~context with
    | Error error -> map_move_error error
    | Ok move_plan ->
      let right_siblings =
        List.filter_map
          (fun (index, (_, entity)) ->
             if index > selection.last_index then Some entity else None)
          (List.mapi (fun index sibling -> index, sibling) selection.siblings)
      in
      let* last_root =
        match List.rev selection.roots with
        | last_root :: _ -> Ok last_root
        | [] -> Error (Invalid_tree "Direct outdent has no canonical roots.")
      in
      let* existing_children = ordered_children db last_root in
      let lower =
        match List.rev existing_children with
        | (order, _) :: _ -> Some order
        | [] -> None
      in
      let* orders =
        match
          Outliner_order.sequence_between ~lower ~upper:None (List.length right_siblings)
        with
        | Ok orders -> Ok orders
        | Error (Outliner_order.Invalid_key key) -> Error (Invalid_order key)
        | Error No_space -> Error (Invalid_order "No fractional order space remains.")
      in
      let now = Int64.to_int now_ms in
      let next_tx = (Datascript.serializable db).serializable_max_tx + 1 in
      let right_ops =
        List.concat
          (List.map2
             (fun entity order ->
                [ Datascript.Add
                    (Entity_id entity, "block/parent", Ref_to (Entity_id last_root))
                ; Add (Entity_id entity, "block/page", Ref_to (Entity_id selection.page))
                ; Add (Entity_id entity, "block/order", String order)
                ; Add (Entity_id entity, "block/updated-at", Int now)
                ; Add (Entity_id entity, "block/tx-id", Int next_tx)
                ])
             right_siblings
             orders)
      in
      let* changed_uuids = append_changed db move_plan right_siblings in
      Ok
        { tx_ops = move_plan.tx_ops @ right_ops
        ; tx_meta = replace_operation_meta context move_plan.tx_meta
        ; changed_uuids
        ; status = Protocol.Applied
        }
;;

let plan ~now_ms db ~roots ~direction ~context =
  let* selection = resolve_selection db roots in
  match direction with
  | Protocol.Indent -> indent ~now_ms db selection ~context
  | Direct_outdent -> direct_outdent ~now_ms db selection ~context
;;
