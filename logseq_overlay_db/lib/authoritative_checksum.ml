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

let first_value db entity attr =
  Datascript.datoms db Datascript.Eavt ~e:entity ~a:attr ()
  |> Seq.uncons
  |> Option.map (fun (datom, _) -> datom.Datascript.v)
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

let page_tag_idents =
  [ "logseq.class/Journal"
  ; "logseq.class/Tag"
  ; "logseq.class/Property"
  ; "logseq.class/Page"
  ]
;;

let normalized_value db attr value =
  match attr, value with
  | ("block/parent" | "block/page"), Datascript.Ref entity ->
    Option.value (uuid db entity) ~default:""
  | "block/uuid", Uuid value
  | ("block/order" | "block/title" | "block/name"), String value -> value
  | _ -> ""
;;

let tuples ?(visit = fun () -> ()) db ~e2ee entity =
  let facts =
    Datascript.datoms db Datascript.Eavt ~e:entity ()
    |> Seq.map (fun (datom : Datascript.datom) ->
      visit ();
      datom.a, datom.v)
    |> List.of_seq
  in
  let first attr = List.assoc_opt attr facts in
  let page_tag = function
    | "block/tags", Datascript.Ref target ->
      (match first_value db target "db/ident" with
       | Some (Datascript.Keyword value) -> List.mem value page_tag_idents
       | _ -> false)
    | _ -> false
  in
  match first "block/uuid" with
  | Some (Datascript.Uuid entity_uuid)
    when first "logseq.property/built-in?" <> Some (Datascript.Bool true)
         && (Option.is_some (first "block/name")
             || Option.is_some (first "block/page")
             || List.exists page_tag facts) ->
    List.fold_left
      (fun tuples (attr, value) ->
         if
           List.mem
             attr
             (if e2ee
              then [ "block/uuid"; "block/parent"; "block/page"; "block/order" ]
              else
                [ "block/uuid"
                ; "block/parent"
                ; "block/page"
                ; "block/order"
                ; "block/title"
                ; "block/name"
                ])
         then Tuple_set.add (entity_uuid, attr, normalized_value db attr value) tuples
         else tuples)
      Tuple_set.empty
      facts
  | _ -> Tuple_set.empty
;;

let entities_with_uuid db =
  Datascript.datoms db Datascript.Aevt ~a:"block/uuid" ()
  |> Seq.map (fun (datom : Datascript.datom) -> datom.e)
  |> Seq.group Int.equal
  |> Seq.filter_map (fun group -> Seq.uncons group |> Option.map fst)
;;

let hex32 value = Printf.sprintf "%08lx" value

type t =
  { e2ee : bool
  ; fnv : int32
  ; djb : int32
  }

let to_string state = hex32 state.fnv ^ hex32 state.djb

let initialize ?(check_current = fun () -> ()) ~e2ee db =
  let state =
    entities_with_uuid db
    |> Seq.fold_left
         (fun state entity ->
            check_current ();
            Tuple_set.fold
              (fun tuple (sum_fnv, sum_djb) ->
                 let fnv, djb = tuple_digest tuple in
                 Int32.add sum_fnv fnv, Int32.add sum_djb djb)
              (tuples ~visit:check_current db ~e2ee entity)
              state)
         (0l, 0l)
  in
  let fnv, djb = state in
  { e2ee; fnv; djb }
;;

let recompute ?check_current ~e2ee db = initialize ?check_current ~e2ee db |> to_string

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

let advance ~maximum ~before ~after ~changes state =
  let exception Limit in
  let remaining = ref maximum in
  let visit () =
    if !remaining <= 0 then raise Limit;
    decr remaining
  in
  let entities = Hashtbl.create 32 in
  let add entity = Hashtbl.replace entities entity () in
  let dependents db attr entity =
    Datascript.datoms db Datascript.Avet ~a:attr ~v:(Datascript.Ref entity) ()
    |> Seq.iter (fun (datom : Datascript.datom) ->
      visit ();
      add datom.e)
  in
  try
    if graph_e2ee before <> state.e2ee || graph_e2ee after <> state.e2ee
    then Error "checksum mode change requires snapshot"
    else (
      List.iter
        (List.iter (fun (datom : Datascript.datom) ->
           visit ();
           if
             List.mem
               datom.a
               [ "block/uuid"
               ; "block/parent"
               ; "block/page"
               ; "block/order"
               ; "block/title"
               ; "block/name"
               ; "block/tags"
               ; "logseq.property/built-in?"
               ]
           then add datom.e;
           let attributes =
             match datom.a with
             | "block/uuid" -> [ "block/parent"; "block/page" ]
             | "db/ident" -> [ "block/tags" ]
             | _ -> []
           in
           List.iter
             (fun attr ->
                dependents before attr datom.e;
                dependents after attr datom.e)
             attributes))
        changes;
      let contribution db entity = tuples ~visit db ~e2ee:state.e2ee entity in
      let fnv, djb =
        Hashtbl.fold
          (fun entity () (fnv, djb) ->
             let subtract = contribution before entity
             and add = contribution after entity in
             let fnv, djb =
               Tuple_set.fold
                 (fun tuple (fnv, djb) ->
                    let a, b = tuple_digest tuple in
                    Int32.sub fnv a, Int32.sub djb b)
                 subtract
                 (fnv, djb)
             in
             Tuple_set.fold
               (fun tuple (fnv, djb) ->
                  let a, b = tuple_digest tuple in
                  Int32.add fnv a, Int32.add djb b)
               add
               (fnv, djb))
          entities
          (state.fnv, state.djb)
      in
      Ok { state with fnv; djb })
  with
  | Limit -> Error "checksum delta exceeds change budget"
;;
