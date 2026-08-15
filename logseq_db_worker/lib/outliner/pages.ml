type t =
  { tx_ops : Datascript.tx_op list
  ; tx_meta : Datascript.tx_meta
  ; changed_uuids : Graph_types.Uuid.t list
  ; status : Protocol.mutation_status
  }

type error =
  | Unsupported_semantics of string
  | Invalid_selection of string
  | Invalid_order of string
  | Conflict of string
  | Built_in_protected

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

let int_value db entity attr =
  match one db entity attr with
  | Some (Datascript.Int value) -> Some value
  | Some _ | None -> None
;;

let reference_value db entity attr =
  match one db entity attr with
  | Some (Datascript.Ref value) -> Some value
  | Some _ | None -> None
;;

let has_true db entity attr = one db entity attr = Some (Datascript.Bool true)

let entities_by_uuid db uuid =
  let text = Graph_types.Uuid.to_string uuid in
  let find value =
    Datascript.datoms db Datascript.Avet ~a:"block/uuid" ~v:value ()
    |> List.of_seq
    |> List.map (fun datom -> datom.Datascript.e)
  in
  find (Datascript.Uuid text) @ find (String text) |> List.sort_uniq Int.compare
;;

let entities_by_name db name =
  Datascript.datoms db Datascript.Avet ~a:"block/name" ~v:(Datascript.String name) ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.sort_uniq Int.compare
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

let uuid_of_entity db entity =
  match one db entity "block/uuid" with
  | Some (Datascript.Uuid value | String value) -> Graph_types.Uuid.of_string value
  | Some _ | None -> Error "entity has no UUID"
;;

let require_page db uuid =
  match entities_by_uuid db uuid with
  | [] -> Error (Invalid_selection "page UUID does not exist")
  | _ :: _ :: _ -> Error (Invalid_selection "page UUID is ambiguous")
  | [ entity ] ->
    (match string_value db entity "block/name", string_value db entity "block/title" with
     | Some _, Some _ -> Ok entity
     | _ -> Error (Invalid_selection "selected UUID is not a page"))
;;

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

let is_class db entity = has_tag_ident db entity "logseq.class/Tag"
let is_property db entity = has_tag_ident db entity "logseq.class/Property"

let tx_meta context operation =
  [ ( "db-sync/tx-id"
    , Datascript.Uuid (Graph_types.Uuid.to_string context.Protocol.mutation_id) )
  ; "outliner-op", Datascript.Keyword operation
  ; "local-tx?", Datascript.Bool true
  ]
;;

let trim_title title = String.trim title

let valid_title title =
  String.length title > 0
  && String.length title <= Protocol.maximum_title_bytes
  && Validation.valid_utf_8 title
  && not (String.contains title '\000')
;;

let contains_slash title = String.contains title '/' || String.contains title '\\'

let journal_uuid journal_day =
  let text = Printf.sprintf "%08d" journal_day in
  Graph_types.Uuid.of_string
    (Printf.sprintf
       "00000001-%s-%s-0000-000000000000"
       (String.sub text 0 4)
       (String.sub text 4 4))
;;

let next_tx db = (Datascript.serializable db).serializable_max_tx + 1

let tag_for_kind db = function
  | Protocol.Create_ordinary_page _ -> entity_by_ident db "logseq.class/Page"
  | Create_journal_page _ -> entity_by_ident db "logseq.class/Journal"
  | Create_class_page _ -> entity_by_ident db "logseq.class/Tag"
;;

let uuid_for_kind = function
  | Protocol.Create_ordinary_page { uuid } | Create_class_page { uuid } -> Ok uuid
  | Create_journal_page { journal_day; supplied_uuid } ->
    if journal_day <= 0 || journal_day > 99_991_231
    then Error (Unsupported_semantics "journal day is invalid")
    else (
      match journal_uuid journal_day with
      | Error _ -> Error (Unsupported_semantics "journal day is invalid")
      | Ok expected ->
        (match supplied_uuid with
         | None -> Ok expected
         | Some supplied when Graph_types.Uuid.equal supplied expected -> Ok expected
         | Some _ -> Error (Conflict "journal UUID does not match its journal day")))
;;

let valid_ident_character = function
  | '0' .. '9'
  | 'a' .. 'z'
  | 'A' .. 'Z'
  | '*' | '+' | '!' | '_' | '\'' | '?' | '<' | '>' | '=' | '-' -> true
  | _ -> false
;;

let normalized_ident_name title =
  let buffer = Buffer.create (String.length title + 4) in
  (match title.[0] with
   | '0' .. '9' -> Buffer.add_string buffer "NUM-"
   | _ -> ());
  String.iter
    (fun character ->
       if valid_ident_character character then Buffer.add_char buffer character)
    title;
  Buffer.contents buffer
;;

let class_ident db title =
  let base = "user.class/" ^ normalized_ident_name title in
  if Option.is_none (entity_by_ident db base)
  then base
  else (
    let rec choose suffix =
      let candidate = base ^ "-" ^ string_of_int suffix in
      if Option.is_none (entity_by_ident db candidate)
      then candidate
      else choose (suffix + 1)
    in
    choose 1)
;;

let create_page ~now_ms db ~title ~kind ~context =
  let title = trim_title title in
  if not (valid_title title)
  then Error (Unsupported_semantics "page title is invalid")
  else if contains_slash title
  then Error (Unsupported_semantics "implicit namespace parent creation is unsupported")
  else (
    let name = Validation.page_name title in
    match entities_by_name db name with
    | _ :: _ :: _ -> Error (Invalid_selection "ambiguous page selector")
    | [ _ ] -> Error (Conflict "page title already exists")
    | [] ->
      (match uuid_for_kind kind with
       | Error _ as error -> error
       | Ok uuid ->
         if entities_by_uuid db uuid <> []
         then Error (Conflict "page UUID already exists")
         else (
           match tag_for_kind db kind with
           | None -> Error (Unsupported_semantics "required page class is missing")
           | Some tag ->
             let id = Datascript.Temp_id ("page-" ^ Graph_types.Uuid.to_string uuid) in
             let block_tags = entity_by_ident db "block/tags" in
             let class_effects =
               match kind with
               | Protocol.Create_class_page _ ->
                 (match
                    ( entity_by_ident db "logseq.class/Root"
                    , entity_by_ident db "logseq.property.class/extends" )
                  with
                  | Some root, Some extends ->
                    Ok
                      [ Datascript.Add (id, "db/ident", Keyword (class_ident db title))
                      ; Add (id, "logseq.property.class/extends", Ref_to (Entity_id root))
                      ; Add (id, "block/refs", Ref_to (Entity_id root))
                      ; Add (id, "block/refs", Ref_to (Entity_id extends))
                      ]
                  | _ ->
                    Error
                      (Unsupported_semantics
                         "required class inheritance entities are missing"))
               | Create_ordinary_page _ | Create_journal_page _ -> Ok []
             in
             (match block_tags, class_effects with
              | None, _ ->
                Error
                  (Unsupported_semantics "required block/tags attribute entity is missing")
              | _, (Error _ as error) -> error
              | Some block_tags, Ok class_effects ->
                let now = Int64.to_int now_ms in
                let base_ops =
                  [ Datascript.Add
                      (id, "block/uuid", Uuid (Graph_types.Uuid.to_string uuid))
                  ; Add (id, "block/title", String title)
                  ; Add (id, "block/name", String name)
                  ; Add (id, "block/created-at", Int now)
                  ; Add (id, "block/updated-at", Int now)
                  ; Add (id, "block/tx-id", Int (next_tx db))
                  ; Add (id, "block/tags", Ref_to (Entity_id tag))
                  ; Add (id, "block/refs", Ref_to (Entity_id tag))
                  ; Add (id, "block/refs", Ref_to (Entity_id block_tags))
                  ]
                in
                let kind_ops =
                  match kind with
                  | Protocol.Create_journal_page { journal_day; _ } ->
                    [ Datascript.Add (id, "block/journal-day", Int journal_day) ]
                  | Create_class_page _ | Create_ordinary_page _ -> []
                in
                Ok
                  { tx_ops = base_ops @ kind_ops @ class_effects
                  ; tx_meta = tx_meta context "create-page"
                  ; changed_uuids = [ uuid ]
                  ; status = Protocol.Applied
                  }))))
;;

let replace_all value needle replacement =
  if String.length needle = 0
  then value
  else (
    let buffer = Buffer.create (String.length value) in
    let rec loop offset =
      if offset + String.length needle > String.length value
      then Buffer.add_substring buffer value offset (String.length value - offset)
      else if String.sub value offset (String.length needle) = needle
      then (
        Buffer.add_string buffer replacement;
        loop (offset + String.length needle))
      else (
        Buffer.add_char buffer value.[offset];
        loop (offset + 1))
    in
    loop 0;
    Buffer.contents buffer)
;;

let incoming_ref_sources db target =
  Datascript.datoms db Datascript.Avet ~a:"block/refs" ~v:(Datascript.Ref target) ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.sort_uniq Int.compare
;;

let rename_page ~now_ms db ~page ~title ~context =
  match require_page db page with
  | Error _ as error -> error
  | Ok entity ->
    if
      has_true db entity "logseq.property/built-in?"
      || has_true db entity "logseq.property/hide?"
    then Error Built_in_protected
    else (
      let title = trim_title title in
      if (not (valid_title title)) || contains_slash title
      then Error (Unsupported_semantics "page title is invalid")
      else (
        let name = Validation.page_name title in
        let collisions =
          entities_by_name db name |> List.filter (fun candidate -> candidate <> entity)
        in
        match collisions with
        | _ :: _ -> Error (Conflict "page title already exists")
        | [] ->
          (match Save_block.plan ~now_ms db ~block:page ~title ~context with
           | Error Save_block.Built_in_protected -> Error Built_in_protected
           | Error (Unsupported_semantics message) ->
             Error (Unsupported_semantics message)
           | Error (Invalid_selection message) -> Error (Invalid_selection message)
           | Ok saved ->
             let old_title =
               Option.value (string_value db entity "block/title") ~default:""
             in
             let canonical_ref = "[[" ^ Graph_types.Uuid.to_string page ^ "]]" in
             let inbound_ops, inbound_entities =
               incoming_ref_sources db entity
               |> List.filter_map (fun source ->
                 match string_value db source "block/title" with
                 | None -> None
                 | Some source_title ->
                   let rewritten =
                     source_title
                     |> fun value ->
                     replace_all value ("[[" ^ old_title ^ "]]") canonical_ref
                   in
                   if String.equal rewritten source_title
                   then None
                   else
                     Some
                       ( [ Datascript.Add
                             (Entity_id source, "block/title", String rewritten)
                         ; Add
                             ( Entity_id source
                             , "block/updated-at"
                             , Int (Int64.to_int now_ms) )
                         ; Add (Entity_id source, "block/tx-id", Int (next_tx db))
                         ]
                       , source ))
               |> List.split
             in
             let inbound_uuids =
               List.filter_map
                 (fun source -> Result.to_option (uuid_of_entity db source))
                 inbound_entities
             in
             Ok
               { tx_ops = saved.tx_ops @ List.concat inbound_ops
               ; tx_meta = tx_meta context "rename-page"
               ; changed_uuids =
                   List.sort_uniq
                     Graph_types.Uuid.compare
                     (saved.changed_uuids @ inbound_uuids)
               ; status =
                   (if saved.tx_ops = [] && inbound_ops = [] then No_change else Applied)
               })))
;;

let children db parent =
  Datascript.datoms db Datascript.Avet ~a:"block/parent" ~v:(Datascript.Ref parent) ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.filter (fun entity -> entity <> parent)
  |> List.sort_uniq Int.compare
;;

let blocks_on_page db page =
  Datascript.datoms db Datascript.Avet ~a:"block/page" ~v:(Datascript.Ref page) ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.sort_uniq Int.compare
;;

let rec subtree db entity = entity :: List.concat_map (subtree db) (children db entity)

let page_tree db page =
  List.sort_uniq Int.compare (subtree db page @ blocks_on_page db page)
;;

let today_journal_day now_ms =
  let tm = Unix.gmtime (Int64.to_float now_ms /. 1000.) in
  ((tm.tm_year + 1900) * 10_000) + ((tm.tm_mon + 1) * 100) + tm.tm_mday
;;

let changed_uuids db entities =
  List.filter_map (fun entity -> Result.to_option (uuid_of_entity db entity)) entities
  |> List.sort_uniq Graph_types.Uuid.compare
;;

let recycle_page db =
  match entities_by_name db "recycle" with
  | [ entity ] -> Some entity
  | [] | _ :: _ :: _ -> None
;;

let next_recycle_order db recycle =
  children db recycle
  |> List.filter_map (fun child -> string_value db child "block/order")
  |> List.sort String.compare
  |> List.rev
  |> function
  | [] -> "a0"
  | last :: _ -> last ^ "a"
;;

let delete_page ~now_ms db ~page ~context =
  match require_page db page with
  | Error _ as error -> error
  | Ok entity ->
    if
      has_true db entity "logseq.property/built-in?"
      || has_true db entity "logseq.property/hide?"
    then Error Built_in_protected
    else (
      let tree = page_tree db entity in
      let hard_delete = is_class db entity || is_property db entity in
      let today =
        int_value db entity "block/journal-day" = Some (today_journal_day now_ms)
      in
      if hard_delete
      then
        Ok
          { tx_ops = List.map (fun item -> Datascript.RetractEntity (Entity_id item)) tree
          ; tx_meta = tx_meta context "delete-page"
          ; changed_uuids = changed_uuids db tree
          ; status = Protocol.Applied
          }
      else if today
      then (
        let descendants = List.filter (fun item -> item <> entity) tree in
        Ok
          { tx_ops =
              List.map (fun item -> Datascript.RetractEntity (Entity_id item)) descendants
          ; tx_meta = tx_meta context "delete-page"
          ; changed_uuids = changed_uuids db (entity :: descendants)
          ; status = (if descendants = [] then Protocol.No_change else Applied)
          })
      else (
        match recycle_page db with
        | None -> Error (Unsupported_semantics "Recycle page is missing or ambiguous")
        | Some recycle ->
          let preserve_ref attr =
            match reference_value db entity attr with
            | None -> []
            | Some value ->
              [ Datascript.Add
                  ( Entity_id entity
                  , "logseq.property.recycle/original-"
                    ^ String.sub attr 6 (String.length attr - 6)
                  , Ref_to (Entity_id value) )
              ]
          in
          let original_order =
            match string_value db entity "block/order" with
            | None -> []
            | Some value ->
              [ Datascript.Add
                  ( Entity_id entity
                  , "logseq.property.recycle/original-order"
                  , String value )
              ]
          in
          Ok
            { tx_ops =
                [ Datascript.Add
                    (Entity_id entity, "block/parent", Ref_to (Entity_id recycle))
                ; Add
                    ( Entity_id entity
                    , "block/order"
                    , String (next_recycle_order db recycle) )
                ; Add
                    ( Entity_id entity
                    , "logseq.property/deleted-at"
                    , Int (Int64.to_int now_ms) )
                ; Add
                    ( Entity_id entity
                    , "logseq.property.recycle/original-page"
                    , Ref_to (Entity_id entity) )
                ; Add (Entity_id entity, "block/updated-at", Int (Int64.to_int now_ms))
                ; Add (Entity_id entity, "block/tx-id", Int (next_tx db))
                ]
                @ preserve_ref "block/parent"
                @ original_order
            ; tx_meta = tx_meta context "delete-page"
            ; changed_uuids = [ page ]
            ; status = Protocol.Applied
            }))
;;

let is_recycled db entity =
  Option.is_some (int_value db entity "logseq.property/deleted-at")
;;

let sibling_order_collision db ~entity ~parent order =
  children db parent
  |> List.exists (fun sibling ->
    sibling <> entity && string_value db sibling "block/order" = Some order)
;;

let clear_recycle_ops entity =
  [ Datascript.RetractAttr (Entity_id entity, "block/parent")
  ; RetractAttr (Entity_id entity, "block/order")
  ; RetractAttr (Entity_id entity, "logseq.property/deleted-at")
  ; RetractAttr (Entity_id entity, "logseq.property/deleted-by-ref")
  ; RetractAttr (Entity_id entity, "logseq.property.recycle/original-parent")
  ; RetractAttr (Entity_id entity, "logseq.property.recycle/original-page")
  ; RetractAttr (Entity_id entity, "logseq.property.recycle/original-order")
  ]
;;

let restore_page ~now_ms db ~page ~context =
  match require_page db page with
  | Error _ as error -> error
  | Ok entity when not (is_recycled db entity) ->
    Error (Invalid_selection "page is not recycled")
  | Ok entity ->
    let original_parent =
      reference_value db entity "logseq.property.recycle/original-parent"
    in
    let original_order =
      string_value db entity "logseq.property.recycle/original-order"
    in
    let parent_valid =
      match original_parent with
      | Some parent ->
        (not (is_recycled db parent))
        && Option.is_some (uuid_of_entity db parent |> Result.to_option)
      | None -> false
    in
    let parent = if parent_valid then original_parent else None in
    (match parent, original_order with
     | Some parent, Some order when sibling_order_collision db ~entity ~parent order ->
       Error (Invalid_order "recorded page order collides with an existing sibling")
     | _ ->
       let restore_structure =
         Option.to_list
           (Option.map
              (fun parent ->
                 Datascript.Add
                   (Entity_id entity, "block/parent", Ref_to (Entity_id parent)))
              parent)
         @ Option.to_list
             (Option.map
                (fun order ->
                   Datascript.Add (Entity_id entity, "block/order", String order))
                (if Option.is_some parent then original_order else None))
       in
       Ok
         { tx_ops =
             clear_recycle_ops entity
             @ restore_structure
             @ [ Datascript.Add
                   (Entity_id entity, "block/updated-at", Int (Int64.to_int now_ms))
               ; Add (Entity_id entity, "block/tx-id", Int (next_tx db))
               ]
         ; tx_meta = tx_meta context "restore-recycled"
         ; changed_uuids = [ page ]
         ; status = Protocol.Applied
         })
;;

let permanent_delete db ~page ~context =
  match require_page db page with
  | Error _ as error -> error
  | Ok entity when not (is_recycled db entity) ->
    Error (Invalid_selection "page is not recycled")
  | Ok entity ->
    let tree = page_tree db entity in
    Ok
      { tx_ops = List.map (fun item -> Datascript.RetractEntity (Entity_id item)) tree
      ; tx_meta = tx_meta context "recycle-delete-permanently"
      ; changed_uuids = changed_uuids db tree
      ; status = Protocol.Applied
      }
;;

let plan ~now_ms db = function
  | Protocol.Create_page { title; kind; context } ->
    create_page ~now_ms db ~title ~kind ~context
  | Rename_page { page; title; context } -> rename_page ~now_ms db ~page ~title ~context
  | Delete_page { page; context } -> delete_page ~now_ms db ~page ~context
  | Restore_recycled_page { page; context } -> restore_page ~now_ms db ~page ~context
  | Permanently_delete_recycled_page { page; context } ->
    permanent_delete db ~page ~context
;;
