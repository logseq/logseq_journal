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

let uuid_of_entity db entity =
  match one db entity "block/uuid" with
  | Some (Datascript.Uuid value | String value) -> Graph_types.Uuid.of_string value
  | Some _ | None -> Error "entity has no UUID"
;;

let is_page db entity = Option.is_some (string_value db entity "block/name")

let children db parent =
  Datascript.datoms db Datascript.Avet ~a:"block/parent" ~v:(Datascript.Ref parent) ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.filter (fun entity -> entity <> parent)
;;
