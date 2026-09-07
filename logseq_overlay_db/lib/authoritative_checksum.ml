module Tuple = struct
  type t = string * string * string

  let compare = compare
end

module Tuple_set = Set.Make (Tuple)

let fnv_offset = Int32.of_string "0x811c9dc5"
let djb_offset = 5381l
let field_separator = 31

let fold_utf16 f state value =
  let decoder = Uutf.decoder ~encoding:`UTF_8 (`String value) in
  let rec loop state =
    match Uutf.decode decoder with
    | `Uchar uchar ->
      let scalar = Uchar.to_int uchar in
      if scalar <= 0xffff
      then loop (f state scalar)
      else (
        let adjusted = scalar - 0x10000 in
        let high = 0xd800 + (adjusted lsr 10) in
        let low = 0xdc00 + (adjusted land 0x3ff) in
        loop (f (f state high) low))
    | `End -> state
    | `Malformed _ -> invalid_arg "checksum input contains invalid UTF-8"
    | `Await -> assert false
  in
  loop state
;;

let hash_code (fnv, djb) code =
  ( Int32.mul (Int32.logxor fnv (Int32.of_int code)) 16777619l
  , Int32.add (Int32.mul djb 33l) (Int32.of_int code) )
;;

let digest_string state value = fold_utf16 hash_code state value

let tuple_digest (entity_uuid, attr, value) =
  (fnv_offset, djb_offset)
  |> fun state ->
  digest_string state entity_uuid
  |> fun state ->
  hash_code state field_separator
  |> fun state ->
  digest_string state (":" ^ attr)
  |> fun state ->
  hash_code state field_separator |> fun state -> digest_string state value
;;

let datoms db ~e ~a = Datascript.datoms db Datascript.Eavt ~e ~a () |> List.of_seq

let first_value db entity attr =
  match datoms db ~e:entity ~a:attr with
  | datom :: _ -> Some datom.Datascript.v
  | [] -> None
;;

let uuid db entity =
  match first_value db entity "block/uuid" with
  | Some (Datascript.Uuid value) -> Some value
  | _ -> None
;;

let boolean db entity attr =
  match first_value db entity attr with
  | Some (Datascript.Bool value) -> Some value
  | _ -> None
;;

let has_value db entity attr = not (List.is_empty (datoms db ~e:entity ~a:attr))

let ident db entity =
  match first_value db entity "db/ident" with
  | Some (Datascript.Keyword value) -> Some value
  | _ -> None
;;

let page_tag_idents =
  [ "logseq.class/Journal"
  ; "logseq.class/Tag"
  ; "logseq.class/Property"
  ; "logseq.class/Page"
  ]
;;

let page_entity db entity =
  datoms db ~e:entity ~a:"block/tags"
  |> List.exists (fun datom ->
    match datom.Datascript.v with
    | Datascript.Ref target ->
      (match ident db target with
       | Some value -> List.mem value page_tag_idents
       | None -> false)
    | _ -> false)
;;

let eligible db entity =
  Option.is_some (uuid db entity)
  && boolean db entity "logseq.property/built-in?" <> Some true
  && (has_value db entity "block/name"
      || has_value db entity "block/page"
      || page_entity db entity)
;;

let normalized_value db attr value =
  match attr, value with
  | ("block/parent" | "block/page"), Datascript.Ref entity ->
    Option.value (uuid db entity) ~default:""
  | "block/uuid", Uuid value
  | ("block/order" | "block/title" | "block/name"), String value -> value
  | _ -> ""
;;

let tuples db ~e2ee entity =
  match uuid db entity with
  | None -> Tuple_set.empty
  | Some entity_uuid ->
    let relevant =
      if e2ee
      then [ "block/uuid"; "block/parent"; "block/page"; "block/order" ]
      else
        [ "block/uuid"
        ; "block/parent"
        ; "block/page"
        ; "block/order"
        ; "block/title"
        ; "block/name"
        ]
    in
    List.fold_left
      (fun tuples attr ->
         datoms db ~e:entity ~a:attr
         |> List.fold_left
              (fun tuples datom ->
                 Tuple_set.add
                   (entity_uuid, attr, normalized_value db attr datom.Datascript.v)
                   tuples)
              tuples)
      Tuple_set.empty
      relevant
;;

let entities_with_uuid db =
  let _, entities =
    Datascript.datoms db Datascript.Aevt ~a:"block/uuid" ()
    |> Seq.fold_left
         (fun (previous, entities) (datom : Datascript.datom) ->
            match previous with
            | Some entity when Int.equal entity datom.e -> previous, entities
            | _ -> Some datom.e, datom.e :: entities)
         (None, [])
  in
  entities
;;

let hex32 value = Printf.sprintf "%08lx" value

let recompute ~e2ee db =
  let state =
    entities_with_uuid db
    |> List.fold_left
         (fun state entity ->
            if not (eligible db entity)
            then state
            else
              Tuple_set.fold
                (fun tuple (sum_fnv, sum_djb) ->
                   let fnv, djb = tuple_digest tuple in
                   Int32.add sum_fnv fnv, Int32.add sum_djb djb)
                (tuples db ~e2ee entity)
                state)
         (0l, 0l)
  in
  let fnv, djb = state in
  hex32 fnv ^ hex32 djb
;;

let graph_e2ee db =
  match
    Datascript.datoms
      db
      Datascript.Avet
      ~a:"db/ident"
      ~v:(Datascript.Keyword "logseq.kv/graph-rtc-e2ee?")
      ()
    |> Seq.uncons
  with
  | Some (datom, _) -> boolean db datom.Datascript.e "kv/value" = Some true
  | None -> false
;;
