module Graph = Logseq_db_types.Graph_types

type error =
  | Invalid
  | Invalid_or_stale

let maximum_offset = 10_000

let create ~projection ~offset =
  if offset < 0 || offset > maximum_offset
  then invalid_arg "query cursor offset is out of range"
  else
    Printf.sprintf "cursor:v2:%d:%d" projection offset
    |> Graph.Cursor.of_string
    |> Result.get_ok
;;

let offset ~projection cursor =
  match Graph.Cursor.to_string cursor |> String.split_on_char ':' with
  | [ "cursor"; "v2"; cursor_projection; cursor_offset ] ->
    (match int_of_string_opt cursor_projection, int_of_string_opt cursor_offset with
     | Some cursor_projection, Some cursor_offset
       when cursor_offset >= 0
            && cursor_offset <= maximum_offset
            && cursor_projection = projection -> Ok cursor_offset
     | Some cursor_projection, Some cursor_offset
       when cursor_offset >= 0
            && cursor_offset <= maximum_offset
            && cursor_projection <> projection -> Error Invalid_or_stale
     | _ -> Error Invalid)
  | _ -> Error Invalid
;;
