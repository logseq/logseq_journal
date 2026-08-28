include Planner_contract
open Graph_read
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

let require_entity db uuid =
  match entities_by_uuid db uuid with
  | [ entity ] -> Ok entity
  | [] -> Error (Invalid_selection "A delete root UUID does not exist.")
  | _ -> Error (Invalid_selection "A delete root UUID is ambiguous.")
;;

let entities_by_ident db expected =
  let find value =
    Datascript.datoms db Datascript.Avet ~a:"db/ident" ~v:value ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.e)
  in
  find (Datascript.Keyword expected) @ find (String expected)
  |> List.sort_uniq Int.compare
;;

let rec subtree db entity = entity :: List.concat_map (subtree db) (children db entity)

let rec ancestor_in selected db entity =
  match reference_value db entity "block/parent" with
  | None -> false
  | Some parent when parent = entity -> false
  | Some parent -> Int_set.mem parent selected || ancestor_in selected db parent
;;

let resolve_roots db root_uuids =
  if root_uuids = []
  then Error (Invalid_tree "Delete_blocks roots must be non-empty.")
  else if List.length root_uuids > Protocol.maximum_roots
  then Error (Invalid_tree "Delete_blocks exceeds the root-count limit.")
  else (
    let rec resolve seen result = function
      | [] -> Ok (List.rev result)
      | uuid :: rest ->
        if Uuid_set.mem uuid seen
        then Error (Invalid_tree "Delete_blocks contains a duplicate UUID.")
        else
          let* entity = require_entity db uuid in
          if is_page db entity
          then
            Error (Invalid_selection "Pages cannot be hard-deleted with Delete_blocks.")
          else if has_true db entity "logseq.property/built-in?"
          then Error Built_in_protected
          else resolve (Uuid_set.add uuid seen) (entity :: result) rest
    in
    let* selected_entities = resolve Uuid_set.empty [] root_uuids in
    let selected =
      List.fold_left
        (fun set entity -> Int_set.add entity set)
        Int_set.empty
        selected_entities
    in
    Ok
      (List.filter (fun entity -> not (ancestor_in selected db entity)) selected_entities))
;;

let has_tag_ident db entity expected =
  values db entity "block/tags"
  |> List.exists (function
    | Datascript.Ref tag -> ident db tag = Some expected
    | _ -> false)
;;

let comment_targets db entity =
  values db entity "logseq.property.comments/blocks"
  |> List.filter_map (function
    | Datascript.Ref target -> Some target
    | _ -> None)
;;

let orphaned_comment_areas db deleted =
  Datascript.datoms db Datascript.Aevt ~a:"logseq.property.comments/blocks" ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.sort_uniq Int.compare
  |> List.filter (fun entity ->
    let targets = comment_targets db entity in
    has_tag_ident db entity "logseq.class/Comments"
    && targets <> []
    && List.exists (fun target -> Int_set.mem target deleted) targets
    && List.for_all (fun target -> Int_set.mem target deleted) targets
    && not (Int_set.mem entity deleted))
;;

let replace_all value needle replacement =
  if String.length needle = 0
  then value
  else (
    let buffer = Buffer.create (String.length value) in
    let rec loop index =
      if index + String.length needle > String.length value
      then Buffer.add_substring buffer value index (String.length value - index)
      else if String.sub value index (String.length needle) = needle
      then (
        Buffer.add_string buffer replacement;
        loop (index + String.length needle))
      else (
        Buffer.add_char buffer value.[index];
        loop (index + 1))
    in
    loop 0;
    Buffer.contents buffer)
;;

let incoming_sources db deleted_entities =
  List.fold_left
    (fun result target ->
       Datascript.datoms db Datascript.Avet ~a:"block/refs" ~v:(Datascript.Ref target) ()
       |> List.of_seq
       |> List.fold_left
            (fun result datom ->
               let current =
                 Option.value (List.assoc_opt datom.Datascript.e result) ~default:[]
               in
               (datom.e, target :: current) :: List.remove_assoc datom.e result)
            result)
    []
    deleted_entities
;;

let rewrite_reference_title db source targets =
  match string_value db source "block/title" with
  | None -> None
  | Some title ->
    Some
      (List.fold_left
         (fun title target ->
            match uuid_of_entity db target, string_value db target "block/title" with
            | Ok uuid, Some replacement ->
              let text = Graph_types.Uuid.to_string uuid in
              title
              |> fun title ->
              replace_all title ("[[" ^ text ^ "]]") replacement
              |> fun title -> replace_all title ("((" ^ text ^ "))") replacement
            | _ -> title)
         title
         targets)
;;

let page_of db entity =
  if is_page db entity then Some entity else reference_value db entity "block/page"
;;

let tx_meta context =
  [ ( "db-sync/tx-id"
    , Datascript.Uuid
        (Graph_types.Uuid.to_string context.Logseq_db_types.Mutation.mutation_id) )
  ; "outliner-op", Datascript.Keyword "delete-blocks"
  ; "local-tx?", Datascript.Bool true
  ]
;;

let unique_entities values = List.sort_uniq Int.compare values

let changed_uuids db entities =
  let rec loop result = function
    | [] -> Ok (List.rev result)
    | entity :: rest ->
      (match uuid_of_entity db entity with
       | Error _ -> Error (Invalid_tree "A delete-related entity has no UUID.")
       | Ok uuid ->
         let result =
           if List.exists (Graph_types.Uuid.equal uuid) result
           then result
           else uuid :: result
         in
         loop result rest)
  in
  loop [] entities
;;

let touch_ops ~now ~next_tx pages =
  List.concat_map
    (fun page ->
       [ Datascript.Add (Entity_id page, "block/updated-at", Int now)
       ; Add (Entity_id page, "block/tx-id", Int next_tx)
       ])
    pages
;;

let default_property_path ~now_ms db root ~context =
  match
    ( reference_value db root "logseq.property/created-from-property"
    , values db root "block/closed-value-property" )
  with
  | Some property, [] ->
    (match
       reference_value db property "logseq.property/default-value", ident db property
     with
     | Some default, Some property_ident when default <> root ->
       (match entities_by_ident db "logseq.property/empty-placeholder" with
        | [ placeholder ] ->
          let holders =
            Datascript.datoms db Datascript.Aevt ~a:property_ident ()
            |> List.of_seq
            |> List.filter_map (fun datom ->
              match datom.Datascript.v with
              | Datascript.Ref entity when entity = root -> Some datom.e
              | _ -> None)
            |> List.sort_uniq Int.compare
          in
          let now = Int64.to_int now_ms in
          let next_tx = (Datascript.serializable db).serializable_max_tx + 1 in
          let holder_ops =
            List.concat_map
              (fun holder ->
                 [ Datascript.Add
                     (Entity_id holder, property_ident, Ref_to (Entity_id placeholder))
                 ; Add (Entity_id holder, "block/updated-at", Int now)
                 ; Add (Entity_id holder, "block/tx-id", Int next_tx)
                 ])
              holders
          in
          let pages = List.filter_map (page_of db) holders |> unique_entities in
          let* changed_uuids = changed_uuids db (holders @ pages) in
          Ok
            (Some
               { tx_ops = holder_ops @ touch_ops ~now ~next_tx pages
               ; tx_meta = tx_meta context
               ; changed_uuids
               ; status = Logseq_db_types.Mutation.Applied
               })
        | [] -> Error (Unsupported_semantics "The empty property placeholder is missing.")
        | _ -> Error (Invalid_tree "The empty property placeholder is ambiguous."))
     | Some _, None ->
       Error (Unsupported_semantics "The source property has no qualified ident.")
     | None, _ | Some _, Some _ -> Ok None)
  | Some _, _ :: _ -> Ok None
  | None, _ -> Ok None
;;

let hard_delete ~now_ms db roots ~context =
  let initial_deleted =
    List.concat_map (subtree db) roots
    |> List.fold_left (fun set entity -> Int_set.add entity set) Int_set.empty
  in
  let comment_areas = orphaned_comment_areas db initial_deleted in
  let deleted_entities =
    Int_set.elements initial_deleted @ List.concat_map (subtree db) comment_areas
    |> unique_entities
  in
  let deleted =
    List.fold_left
      (fun set entity -> Int_set.add entity set)
      Int_set.empty
      deleted_entities
  in
  let incoming =
    incoming_sources db deleted_entities
    |> List.filter (fun (source, _) -> not (Int_set.mem source deleted))
  in
  let now = Int64.to_int now_ms in
  let next_tx = (Datascript.serializable db).serializable_max_tx + 1 in
  let reference_ops =
    List.concat_map
      (fun (source, targets) ->
         let retracts =
           List.map
             (fun target ->
                Datascript.Retract
                  (Entity_id source, "block/refs", Some (Ref_to (Entity_id target))))
             targets
         in
         let title_ops =
           match rewrite_reference_title db source targets with
           | Some title when string_value db source "block/title" <> Some title ->
             [ Datascript.Add (Entity_id source, "block/title", String title) ]
           | Some _ -> []
           | None -> []
         in
         retracts
         @ title_ops
         @ [ Datascript.Add (Entity_id source, "block/updated-at", Int now)
           ; Add (Entity_id source, "block/tx-id", Int next_tx)
           ])
      incoming
  in
  let pages =
    List.filter_map (page_of db) (deleted_entities @ List.map fst incoming)
    |> List.filter (fun page -> not (Int_set.mem page deleted))
    |> unique_entities
  in
  let delete_ops =
    List.map (fun entity -> Datascript.RetractEntity (Entity_id entity)) deleted_entities
  in
  let* changed_uuids =
    changed_uuids db (deleted_entities @ List.map fst incoming @ pages)
  in
  Ok
    { tx_ops = reference_ops @ delete_ops @ touch_ops ~now ~next_tx pages
    ; tx_meta = tx_meta context
    ; changed_uuids
    ; status = Logseq_db_types.Mutation.Applied
    }
;;

let plan ~now_ms db ~roots ~context =
  let* roots = resolve_roots db roots in
  match roots with
  | [ root ] ->
    let* special = default_property_path ~now_ms db root ~context in
    (match special with
     | Some plan -> Ok plan
     | None -> hard_delete ~now_ms db roots ~context)
  | [] -> Error (Invalid_tree "Delete_blocks has no canonical roots.")
  | _ -> hard_delete ~now_ms db roots ~context
;;
