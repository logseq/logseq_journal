(* JSON syntax validation shared by generated domain decoders. This traversal
   knows no domain fields or variant tags. *)
let validate json =
  let rec loop = function
    | [] -> Ok ()
    | `Assoc fields :: rest ->
      let names = Hashtbl.create (List.length fields) in
      let rec fields_loop values = function
        | [] -> loop values
        | (name, value) :: fields ->
          if not (String.is_valid_utf_8 name)
          then Error "invalid UTF-8 field name"
          else if Hashtbl.mem names name
          then Error "duplicate JSON field"
          else (
            Hashtbl.add names name ();
            fields_loop (value :: values) fields)
      in
      fields_loop rest fields
    | `List values :: rest -> loop (List.rev_append values rest)
    | `String value :: rest ->
      if String.is_valid_utf_8 value then loop rest else Error "invalid UTF-8 string"
    | `Float value :: rest ->
      if Float.is_finite value then loop rest else Error "non-finite JSON number"
    | (`Null | `Bool _ | `Int _ | `Intlit _) :: rest -> loop rest
    | (`Tuple _ | `Variant _) :: _ -> Error "nonstandard JSON value"
  in
  loop [ json ]
;;

let decode ?maximum_bytes parser json =
  try
    Result.bind (validate json) (fun () ->
      match maximum_bytes with
      | Some maximum when String.length (Yojson.Safe.to_string json) > maximum ->
        Error "JSON exceeds byte budget"
      | Some _ | None -> parser json)
  with
  | Failure _ | Invalid_argument _ | Yojson.Json_error _ | Stack_overflow ->
    Error "invalid JSON value"
;;
