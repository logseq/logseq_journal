module Graph = Logseq_db_types.Graph_types

let values database entity attribute =
  Datascript.datoms database Datascript.Eavt ~e:entity ~a:attribute ()
  |> List.of_seq
  |> List.map (fun (datom : Datascript.datom) -> datom.v)
;;

let one database entity attribute =
  match values database entity attribute with
  | [ value ] -> Some value
  | [] | _ :: _ :: _ -> None
;;

let entity_datoms database entity =
  Datascript.datoms database Datascript.Eavt ~e:entity () |> List.of_seq
;;

let values_in_datoms datoms attribute =
  List.filter_map
    (fun (datom : Datascript.datom) ->
       if String.equal datom.a attribute then Some datom.v else None)
    datoms
;;

let one_in_datoms datoms attribute =
  match values_in_datoms datoms attribute with
  | [ value ] -> Some value
  | [] | _ :: _ :: _ -> None
;;

let uuid_of_value = function
  | Datascript.Uuid value | String value -> Graph.Uuid.of_string value |> Result.to_option
  | _ -> None
;;

let string_of_value = function
  | Datascript.String value -> Some value
  | _ -> None
;;

let int_of_value = function
  | Datascript.Int value -> Some value
  | _ -> None
;;

let bool_of_value = function
  | Datascript.Bool value -> Some value
  | _ -> None
;;

let ident_of_value = function
  | Datascript.Keyword value | String value -> Some value
  | _ -> None
;;

let reference_of_value = function
  | Datascript.Ref entity -> Some entity
  | _ -> None
;;

let entity_of_uuid database uuid =
  Datascript.find_datom
    database
    Datascript.Avet
    ~a:"block/uuid"
    ~v:(Datascript.Uuid (Graph.Uuid.to_string uuid))
    ()
  |> Option.map (fun (datom : Datascript.datom) -> datom.e)
;;

let entity_of_ident database ident =
  let find value =
    Datascript.find_datom database Datascript.Avet ~a:"db/ident" ~v:value ()
    |> Option.map (fun (datom : Datascript.datom) -> datom.e)
  in
  match find (Datascript.Keyword ident) with
  | Some _ as entity -> entity
  | None -> find (Datascript.String ident)
;;

let uuid_of_entity database entity =
  Option.bind (one database entity "block/uuid") uuid_of_value
;;

let entity_has_ref database entity attribute target =
  Datascript.find_datom
    database
    Datascript.Eavt
    ~e:entity
    ~a:attribute
    ~v:(Datascript.Ref target)
    ()
  |> Option.is_some
;;

let referenced_entities_in_datoms datoms attribute =
  values_in_datoms datoms attribute
  |> List.filter_map (function
    | Datascript.Ref entity -> Some entity
    | _ -> None)
;;
