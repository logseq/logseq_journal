let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let has_substring string fragment =
  let string_length = String.length string in
  let fragment_length = String.length fragment in
  let rec loop index =
    if index + fragment_length > string_length
    then false
    else if String.sub string index fragment_length = fragment
    then true
    else loop (index + 1)
  in
  fragment_length = 0 || loop 0
;;

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Sys.readdir path |> Array.iter (fun name -> remove_tree (Filename.concat path name));
    Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
;;

let with_temp_directory f =
  let path = Filename.temp_file "logseq-journal-path-" "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f (Unix.realpath path))
;;

let resolve_exn ~support_root ~relative_path =
  match Journal_storage_path.resolve ~support_root ~relative_path with
  | Ok path -> path
  | Error error ->
    fail "unexpected path error: %s" (Journal_storage_path.Error.to_string error)
;;

let require_error ?contains ~support_root ~relative_path () =
  match Journal_storage_path.resolve ~support_root ~relative_path with
  | Ok path -> fail "expected path rejection, got %S" path
  | Error error ->
    (match contains with
     | None -> ()
     | Some fragment ->
       let message = Journal_storage_path.Error.to_string error in
       if not (has_substring message fragment)
       then fail "expected error containing %S, got %S" fragment message)
;;

let create_parent root = Unix.mkdir (Filename.concat root "logseq_journal") 0o700

let test_new_and_existing_leaf () =
  with_temp_directory (fun root ->
    let expected = Filename.concat root Journal_startup.database_relative_path in
    let resolved =
      resolve_exn ~support_root:root ~relative_path:Journal_startup.database_relative_path
    in
    require (String.equal expected resolved) "expected %S, got %S" expected resolved;
    require
      (Sys.is_directory (Filename.concat root "logseq_journal"))
      "path resolver did not create the private parent";
    let channel = open_out_bin resolved in
    close_out channel;
    let reopened =
      resolve_exn ~support_root:root ~relative_path:Journal_startup.database_relative_path
    in
    require (String.equal expected reopened) "existing leaf path changed")
;;

let test_relative_path_rejection () =
  with_temp_directory (fun root ->
    create_parent root;
    List.iter
      (fun relative_path ->
         require_error
           ~contains:"database relative path"
           ~support_root:root
           ~relative_path
           ())
      [ "../journal.sqlite3"
      ; "logseq_journal/../journal.sqlite3"
      ; "logseq_journal\\journal.sqlite3"
      ; "/tmp/journal.sqlite3"
      ; "logseq_journal/other.sqlite3"
      ; "./logseq_journal/journal.sqlite3"
      ])
;;

let test_support_root_rejection () =
  with_temp_directory (fun root ->
    create_parent root;
    require_error
      ~contains:"canonical"
      ~support_root:(Filename.concat root ".")
      ~relative_path:Journal_startup.database_relative_path
      ());
  let relative_path = Journal_startup.database_relative_path in
  require_error ~contains:"absolute" ~support_root:"tmp" ~relative_path ()
;;

let test_symlink_component_rejection () =
  with_temp_directory (fun root ->
    with_temp_directory (fun outside ->
      Unix.symlink outside (Filename.concat root "logseq_journal");
      require_error
        ~contains:"symlink"
        ~support_root:root
        ~relative_path:Journal_startup.database_relative_path
        ()))
;;

let test_symlink_leaf_rejection () =
  with_temp_directory (fun root ->
    with_temp_directory (fun outside ->
      create_parent root;
      let outside_file = Filename.concat outside "outside.sqlite3" in
      let channel = open_out_bin outside_file in
      close_out channel;
      Unix.symlink
        outside_file
        (Filename.concat root Journal_startup.database_relative_path);
      require_error
        ~contains:"symlink"
        ~support_root:root
        ~relative_path:Journal_startup.database_relative_path
        ()))
;;

let test_parent_creation_and_directory_leaf_rejection () =
  with_temp_directory (fun root ->
    ignore
      (resolve_exn
         ~support_root:root
         ~relative_path:Journal_startup.database_relative_path);
    require
      (Sys.is_directory (Filename.concat root "logseq_journal"))
      "missing parent was not created");
  with_temp_directory (fun root ->
    create_parent root;
    Unix.mkdir (Filename.concat root Journal_startup.database_relative_path) 0o700;
    require_error
      ~contains:"regular file"
      ~support_root:root
      ~relative_path:Journal_startup.database_relative_path
      ())
;;

let () =
  test_new_and_existing_leaf ();
  test_relative_path_rejection ();
  test_support_root_rejection ();
  test_symlink_component_rejection ();
  test_symlink_leaf_rejection ();
  test_parent_creation_and_directory_leaf_rejection ()
;;
