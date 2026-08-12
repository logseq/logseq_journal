module Error = struct
  type t = Invalid of string

  let to_string (Invalid message) = message
end

let error format = Printf.ksprintf (fun message -> Error (Error.Invalid message)) format

let path_is_within ~root path =
  let prefix = if String.equal root "/" then root else root ^ "/" in
  String.starts_with ~prefix path
;;

let verify_no_symlink_components path =
  let rec loop current = function
    | [] -> Ok ()
    | component :: rest ->
      let next = Filename.concat current component in
      (match Unix.lstat next with
       | { Unix.st_kind = Unix.S_LNK; _ } ->
         error "path contains a symlink component: %s" next
       | { Unix.st_kind = Unix.S_DIR; _ } -> loop next rest
       | _ -> error "path component is not a directory: %s" next
       | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
         error "path component does not exist: %s" next
       | exception Unix.Unix_error (code, operation, _) ->
         error
           "cannot inspect path component during %s: %s"
           operation
           (Unix.error_message code))
  in
  match String.split_on_char '/' path with
  | "" :: components -> loop "/" components
  | _ -> error "support root must be absolute"
;;

let rec resolve ~support_root ~relative_path =
  if Filename.is_relative support_root
  then error "support root must be absolute"
  else if not (String.equal relative_path Journal_startup.database_relative_path)
  then error "unexpected database relative path"
  else (
    match Unix.realpath support_root with
    | canonical_root ->
      if not (String.equal canonical_root support_root)
      then error "support root must be canonical"
      else (
        match verify_no_symlink_components canonical_root with
        | Error _ as result -> result
        | Ok () ->
          let parent = Filename.concat canonical_root "logseq_journal" in
          (match Unix.lstat parent with
           | { Unix.st_kind = Unix.S_LNK; _ } -> error "database parent is a symlink"
           | { Unix.st_kind = Unix.S_DIR; _ } ->
             (match Unix.realpath parent with
              | canonical_parent ->
                if not (path_is_within ~root:canonical_root canonical_parent)
                then error "database parent escapes the support root"
                else (
                  let database_path =
                    Filename.concat canonical_parent (Filename.basename relative_path)
                  in
                  match Unix.lstat database_path with
                  | { Unix.st_kind = Unix.S_LNK; _ } -> error "database leaf is a symlink"
                  | { Unix.st_kind = Unix.S_REG; _ } -> Ok database_path
                  | _ -> error "database leaf must be a regular file"
                  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok database_path
                  | exception Unix.Unix_error (code, operation, _) ->
                    error
                      "cannot inspect database leaf during %s: %s"
                      operation
                      (Unix.error_message code))
              | exception Unix.Unix_error (code, operation, _) ->
                error
                  "cannot canonicalize database parent during %s: %s"
                  operation
                  (Unix.error_message code))
           | _ -> error "database parent must be a directory"
           | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
             (match Unix.mkdir parent 0o700 with
              | () -> resolve ~support_root ~relative_path
              | exception Unix.Unix_error (Unix.EEXIST, _, _) ->
                resolve ~support_root ~relative_path
              | exception Unix.Unix_error (code, operation, _) ->
                error
                  "cannot create database parent during %s: %s"
                  operation
                  (Unix.error_message code))
           | exception Unix.Unix_error (code, operation, _) ->
             error
               "cannot inspect database parent during %s: %s"
               operation
               (Unix.error_message code)))
    | exception Unix.Unix_error (code, operation, _) ->
      error
        "cannot canonicalize support root during %s: %s"
        operation
        (Unix.error_message code))
;;
