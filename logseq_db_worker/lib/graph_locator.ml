type platform =
  | Desktop of { home_directory : string }
  | Ios of { application_data_directory : string }

type resolved =
  { graph_name : string
  ; graph_dir : string
  ; database_path : string
  }

type error =
  | Invalid_graph_name of string
  | Invalid_utf8
  | Path_escape
  | Symlink_escape
  | Basename_mismatch
  | Graph_directory_missing
  | Database_missing

let valid_utf8 value =
  Uutf.String.fold_utf_8
    (fun valid _ -> function
       | `Uchar _ -> valid
       | `Malformed _ -> false)
    true
    value
;;

let validate_graph_name graph_name =
  if not (valid_utf8 graph_name)
  then Error Invalid_utf8
  else if
    String.length graph_name = 0
    || String.equal graph_name "."
    || String.equal graph_name ".."
    || String.contains graph_name '/'
    || String.contains graph_name '\\'
    || String.contains graph_name '\000'
  then Error (Invalid_graph_name graph_name)
  else Ok ()
;;

let is_directory path =
  try (Unix.stat path).st_kind = Unix.S_DIR with
  | Unix.Unix_error _ -> false
;;

let is_regular path =
  try (Unix.stat path).st_kind = Unix.S_REG with
  | Unix.Unix_error _ -> false
;;

let realpath path =
  try Some (Unix.realpath path) with
  | Unix.Unix_error _ -> None
;;

let validate_native ~graph_name ~graph_dir =
  match validate_graph_name graph_name with
  | Error _ as error -> error
  | Ok () ->
    if not (is_directory graph_dir)
    then Error Graph_directory_missing
    else (
      match realpath graph_dir with
      | None -> Error Graph_directory_missing
      | Some canonical_graph_dir ->
        if not (String.equal (Filename.basename canonical_graph_dir) graph_name)
        then Error Basename_mismatch
        else (
          let database_path = Filename.concat canonical_graph_dir "db.sqlite" in
          if not (is_regular database_path)
          then Error Database_missing
          else Ok { graph_name; graph_dir = canonical_graph_dir; database_path }))
;;

let resolve platform ~graph_name =
  match validate_graph_name graph_name with
  | Error _ as error -> error
  | Ok () ->
    let root =
      match platform with
      | Desktop { home_directory } -> Filename.concat home_directory "logseq"
      | Ios { application_data_directory } ->
        Filename.concat application_data_directory "graphs"
    in
    let graph_dir = Filename.concat root graph_name in
    (match realpath root, realpath graph_dir with
     | Some canonical_root, Some canonical_graph_dir ->
       if not (String.equal (Filename.dirname canonical_graph_dir) canonical_root)
       then Error Symlink_escape
       else validate_native ~graph_name ~graph_dir:canonical_graph_dir
     | _, None -> Error Graph_directory_missing
     | None, _ -> Error Path_escape)
;;
