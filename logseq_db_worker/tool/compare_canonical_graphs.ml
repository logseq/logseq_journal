let fail format = Printf.ksprintf (fun message -> prerr_endline message; exit 1) format

type mode =
  | Pair of
      { expected : string
      ; actual : string
      }
  | Fixtures of string

let parse_args () =
  let rec loop expected actual fixtures index =
    if index >= Array.length Sys.argv
    then expected, actual, fixtures
    else
      match Sys.argv.(index) with
      | "--expected" when index + 1 < Array.length Sys.argv ->
        loop (Some Sys.argv.(index + 1)) actual fixtures (index + 2)
      | "--actual" when index + 1 < Array.length Sys.argv ->
        loop expected (Some Sys.argv.(index + 1)) fixtures (index + 2)
      | "--fixtures" when index + 1 < Array.length Sys.argv ->
        loop expected actual (Some Sys.argv.(index + 1)) (index + 2)
      | argument -> fail "Unknown argument: %s" argument
  in
  match loop None None None 1 with
  | Some expected, Some actual, None -> Pair { expected; actual }
  | None, None, Some fixtures -> Fixtures fixtures
  | _ ->
    fail
      "Usage: compare_canonical_graphs (--expected FILE --actual FILE | --fixtures \
       DIRECTORY)"
;;

let rec canonicalize = function
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, canonicalize value)
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonicalize values)
  | value -> value
;;

let projection path =
  match Yojson.Safe.from_file path with
  | `Assoc fields ->
    (match List.assoc_opt "projection" fields with
     | Some (`List values) -> List.map canonicalize values
     | Some _ -> fail "%s has a non-array projection" path
     | None -> fail "%s has no projection" path)
  | _ -> fail "%s is not a canonical graph object" path
;;

let difference left right =
  List.filter (fun value -> not (List.mem value right)) left
;;

let json_list values = Yojson.Safe.pretty_to_string (`List values)

let compare_pair expected_path actual_path =
  let expected = projection expected_path in
  let actual = projection actual_path in
  if expected <> actual
  then
    fail
      "Canonical graph mismatch.\nExpected-only (%s):\n%s\nActual-only (%s):\n%s"
      expected_path
      (json_list (difference expected actual))
      actual_path
      (json_list (difference actual expected))
;;

let pinned_logseq_commit = "4f21d068aed43bb2ea5823247cae73ecdd8d60f8"

let fixture_commit path fields =
  match List.assoc_opt "pinnedLogseqCommit" fields with
  | Some (`String commit) -> commit
  | Some _ -> fail "%s has an invalid pinnedLogseqCommit" path
  | None ->
    (match List.assoc_opt "source" fields with
     | Some (`Assoc source) ->
       (match List.assoc_opt "logseqCommit" source with
        | Some (`String commit) -> commit
        | _ -> fail "%s has no source.logseqCommit" path)
     | _ -> fail "%s has no pinned Logseq commit" path)
;;

let validate_fixture path =
  match Yojson.Safe.from_file path with
  | `Assoc fields ->
    (match List.assoc_opt "apiVersion" fields, List.assoc_opt "formatVersion" fields with
     | Some (`Int 1), None | None, Some (`Int 1) -> ()
     | _ -> fail "%s does not declare exactly one supported fixture version" path);
    let commit = fixture_commit path fields in
    if not (String.equal commit pinned_logseq_commit)
    then fail "%s was generated from unexpected Logseq commit %s" path commit;
    (match List.assoc_opt "projection" fields with
     | None -> false
     | Some (`List values) ->
       let canonical = List.map canonicalize values in
       if List.length canonical <> List.length (List.sort_uniq compare canonical)
       then fail "%s contains duplicate canonical projection entities" path;
       true
     | Some _ -> fail "%s has a non-array projection" path)
  | _ -> fail "%s is not a versioned fixture object" path
;;

let validate_fixtures directory =
  if not (Sys.file_exists directory && Sys.is_directory directory)
  then fail "Fixture path is not a directory: %s" directory;
  let fixtures =
    Sys.readdir directory
    |> Array.to_list
    |> List.filter (fun name -> Filename.check_suffix name ".json")
    |> List.sort String.compare
    |> List.map (Filename.concat directory)
  in
  if fixtures = [] then fail "Fixture directory contains no JSON documents: %s" directory;
  if not (List.exists validate_fixture fixtures)
  then fail "Fixture directory contains no canonical graph projection: %s" directory
;;

let () =
  match parse_args () with
  | Pair { expected; actual } -> compare_pair expected actual
  | Fixtures directory -> validate_fixtures directory
