type t =
  { tx_ops : Datascript.tx_op list
  ; tx_meta : Datascript.tx_meta
  ; changed_uuids : Graph_types.Uuid.t list
  }

type error =
  | Unsupported_semantics of string
  | Invalid_selection of string
  | Built_in_protected

let values db entity attr =
  Datascript.datoms db Datascript.Eavt ~e:entity ~a:attr ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.v)
;;

let one db entity attr =
  match values db entity attr with
  | [ value ] -> Some value
  | [] -> None
  | _ -> None
;;

let reference_values db entity attr =
  values db entity attr
  |> List.filter_map (function
    | Datascript.Ref entity -> Some entity
    | _ -> None)
  |> List.sort_uniq Int.compare
;;

let uuid_of_entity db entity =
  match one db entity "block/uuid" with
  | Some (Datascript.Uuid value | String value) -> Graph_types.Uuid.of_string value
  | _ -> Error "entity has no UUID"
;;

let entities_by_uuid db uuid =
  let text = Graph_types.Uuid.to_string uuid in
  let find value =
    Datascript.datoms db Datascript.Avet ~a:"block/uuid" ~v:value ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.e)
  in
  find (Datascript.Uuid text) @ find (String text) |> List.sort_uniq Int.compare
;;

let entity_by_ident db ident =
  let find value =
    Datascript.datoms db Datascript.Avet ~a:"db/ident" ~v:value ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.e)
  in
  match
    find (Datascript.Keyword ident) @ find (String ident) |> List.sort_uniq Int.compare
  with
  | [ entity ] -> Some entity
  | [] | _ :: _ :: _ -> None
;;

let has_true db entity attr =
  match one db entity attr with
  | Some (Datascript.Bool true) -> true
  | Some _ | None -> false
;;

let is_page db entity =
  match one db entity "block/name" with
  | Some (Datascript.String _) -> true
  | Some _ | None -> false
;;

let starts_with value prefix =
  String.length value >= String.length prefix
  && String.sub value 0 (String.length prefix) = prefix
;;

let property_is_reference_source db ident entity =
  if starts_with ident "user.property/"
  then not (has_true db entity "logseq.property/hide?")
  else List.mem ident [ "logseq.property/scheduled"; "logseq.property/deadline" ]
;;

let structural_attrs =
  [ "block/uuid"
  ; "block/title"
  ; "block/name"
  ; "block/parent"
  ; "block/page"
  ; "block/order"
  ; "block/created-at"
  ; "block/updated-at"
  ; "block/tx-id"
  ; "block/refs"
  ; "block/tags"
  ; "block/link"
  ; "block/alias"
  ; "block/journal-day"
  ; "db/ident"
  ]
;;

let property_refs db entity =
  Datascript.datoms db Datascript.Eavt ~e:entity ()
  |> List.of_seq
  |> List.fold_left
       (fun refs datom ->
          if List.mem datom.Datascript.a structural_attrs
          then refs
          else (
            match entity_by_ident db datom.a with
            | Some property when property_is_reference_source db datom.a property ->
              let refs = property :: refs in
              (match datom.v with
               | Datascript.Ref value -> value :: refs
               | _ -> refs)
            | Some _ | None -> refs))
       []
  |> List.sort_uniq Int.compare
;;

let current_page db entity =
  match one db entity "block/page" with
  | Some (Datascript.Ref page) -> Some page
  | Some _ | None -> None
;;

let safe_old_content_refs db entity title =
  match References.derive ~db ~self:entity ~title with
  | Ok derived -> derived.content_refs
  | Error _ -> []
;;

let incoming_refs db target =
  Datascript.datoms db Datascript.Avet ~a:"block/refs" ~v:(Datascript.Ref target) ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.sort_uniq Int.compare
;;

let has_children db entity =
  Datascript.datoms db Datascript.Avet ~a:"block/parent" ~v:(Datascript.Ref entity) ()
  |> Seq.exists (fun datom -> datom.Datascript.e <> entity)
;;

let ordinary_orphan_candidate db ~source entity =
  incoming_refs db entity = [ source ]
  && is_page db entity
  && (not (has_children db entity))
  && one db entity "db/ident" = None
  && one db entity "block/journal-day" = None
  && reference_values db entity "block/tags" = []
  && not (has_true db entity "logseq.property/built-in?")
;;

let unique values = List.sort_uniq Int.compare values

let without values removed =
  List.filter (fun value -> not (List.mem value removed)) values
;;

let tx_meta context =
  [ ( "db-sync/tx-id"
    , Datascript.Uuid (Graph_types.Uuid.to_string context.Protocol.mutation_id) )
  ; "outliner-op", Datascript.Keyword "save-block"
  ; "local-tx?", Datascript.Bool true
  ]
;;

let normalize_heading title =
  let rec hashes index =
    if index < String.length title && title.[index] = '#'
    then hashes (index + 1)
    else index
  in
  let count = hashes 0 in
  if count > 0 && count < String.length title && title.[count] = ' '
  then String.sub title (count + 1) (String.length title - count - 1)
  else title
;;

let title_is_valid title =
  String.length title <= Protocol.maximum_title_bytes
  && Validation.valid_utf_8 title
  && not (String.contains title '\000')
;;

let plan ~now_ms db ~block ~title ~context =
  match entities_by_uuid db block with
  | [] -> Error (Invalid_selection "The block UUID does not exist.")
  | _ :: _ :: _ -> Error (Invalid_selection "The block UUID is ambiguous.")
  | [ entity ] ->
    if has_true db entity "logseq.property/built-in?"
    then Error Built_in_protected
    else if not (title_is_valid title)
    then
      Error
        (Unsupported_semantics "The block title is invalid or exceeds its byte budget.")
    else if Validation.contains_unsupported_save_effect title
    then
      Error (Unsupported_semantics "The title requires an unsupported automatic effect.")
    else (
      match one db entity "block/title" with
      | None -> Error (Invalid_selection "The selected entity has no block title.")
      | Some (Datascript.String old_title) ->
        if String.equal old_title title
        then Ok { tx_ops = []; tx_meta = tx_meta context; changed_uuids = [] }
        else (
          let title = if is_page db entity then title else normalize_heading title in
          match References.derive ~db ~self:entity ~title with
          | Error (Missing_reference value) ->
            Error
              (Unsupported_semantics ("The title references a missing entity: " ^ value))
          | Error (Ambiguous_reference value) ->
            Error (Invalid_selection ("The title reference is ambiguous: " ^ value))
          | Error (Invalid_reference value) ->
            Error (Unsupported_semantics ("The title reference is invalid: " ^ value))
          | Ok derived ->
            let existing_tags = reference_values db entity "block/tags" in
            let old_inline_tags =
              safe_old_content_refs db entity old_title
              |> List.filter (fun target -> List.mem target existing_tags)
            in
            let tags =
              unique (without existing_tags old_inline_tags @ derived.inline_tags)
            in
            let tag_attribute_refs =
              if tags = [] then [] else Option.to_list (entity_by_ident db "block/tags")
            in
            let aliases = reference_values db entity "block/alias" in
            let page = current_page db entity in
            let refs =
              derived.content_refs
              @ tags
              @ tag_attribute_refs
              @ property_refs db entity
              @ reference_values db entity "block/link"
              |> unique
              |> List.filter (fun target -> target <> entity)
              |> List.filter (fun target -> not (List.mem target aliases))
              |> List.filter (fun target -> Some target <> page)
            in
            let old_content_refs = safe_old_content_refs db entity old_title in
            let orphaned =
              without old_content_refs derived.content_refs
              |> List.filter (ordinary_orphan_candidate db ~source:entity)
            in
            let next_tx = (Datascript.serializable db).serializable_max_tx + 1 in
            let now = Int64.to_int now_ms in
            let page_entity = Option.value page ~default:entity in
            let base_ops =
              [ Datascript.Add
                  (Entity_id entity, "block/title", String derived.canonical_title)
              ; Add (Entity_id entity, "block/updated-at", Int now)
              ; RetractAttr (Entity_id entity, "block/refs")
              ]
            in
            let page_ops =
              if page_entity = entity
              then []
              else [ Datascript.Add (Entity_id page_entity, "block/updated-at", Int now) ]
            in
            let page_name_ops =
              if is_page db entity
              then
                [ Datascript.Add
                    ( Entity_id entity
                    , "block/name"
                    , String (Validation.page_name derived.canonical_title) )
                ]
              else []
            in
            let ref_ops =
              List.map
                (fun target ->
                   Datascript.Add
                     (Entity_id entity, "block/refs", Ref_to (Entity_id target)))
                refs
            in
            let tag_ops =
              if tags = existing_tags
              then []
              else
                Datascript.RetractAttr (Entity_id entity, "block/tags")
                :: List.map
                     (fun target ->
                        Datascript.Add
                          (Entity_id entity, "block/tags", Ref_to (Entity_id target)))
                     tags
            in
            let orphan_ops =
              List.map
                (fun target -> Datascript.RetractEntity (Entity_id target))
                orphaned
            in
            let tx_id_ops =
              [ Datascript.Add (Entity_id entity, "block/tx-id", Int next_tx) ]
              @
              if page_entity = entity
              then []
              else [ Datascript.Add (Entity_id page_entity, "block/tx-id", Int next_tx) ]
            in
            let changed_entities = unique (entity :: page_entity :: orphaned) in
            let changed_uuids =
              List.filter_map
                (fun entity ->
                   match uuid_of_entity db entity with
                   | Ok uuid -> Some uuid
                   | Error _ -> None)
                changed_entities
            in
            Ok
              { tx_ops =
                  base_ops
                  @ page_ops
                  @ page_name_ops
                  @ ref_ops
                  @ tag_ops
                  @ orphan_ops
                  @ tx_id_ops
              ; tx_meta = tx_meta context
              ; changed_uuids
              })
      | Some _ -> Error (Invalid_selection "The selected entity has a malformed title."))
;;
