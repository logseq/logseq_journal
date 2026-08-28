type t =
  { canonical_title : string
  ; content_refs : int list
  ; inline_tags : int list
  }

type error =
  | Missing_reference of string
  | Ambiguous_reference of string
  | Invalid_reference of string

open Graph_read

let uuid_text db entity =
  match values db entity "block/uuid" with
  | [ Datascript.Uuid value ] | [ String value ] -> Some value
  | _ -> None
;;

let entities_by_name db name =
  Datascript.datoms
    db
    Datascript.Avet
    ~a:"block/name"
    ~v:(Datascript.String (Validation.page_name name))
    ()
  |> List.of_seq
  |> List.map (fun datom -> datom.Datascript.e)
  |> List.sort_uniq Int.compare
;;

let resolve_uuid db text =
  match Graph_types.Uuid.of_string text with
  | Error _ -> Error (Invalid_reference text)
  | Ok uuid ->
    (match entities_by_uuid db uuid with
     | [ entity ] -> Ok entity
     | [] -> Error (Missing_reference text)
     | _ -> Error (Ambiguous_reference text))
;;

let resolve_page db text =
  match Graph_types.Uuid.of_string text with
  | Ok _ -> resolve_uuid db text
  | Error _ ->
    (match entities_by_name db text with
     | [ entity ] -> Ok entity
     | [] -> Error (Missing_reference text)
     | _ -> Error (Ambiguous_reference text))
;;

let ident db entity =
  match values db entity "db/ident" with
  | [ Datascript.Keyword value ] | [ String value ] -> Some value
  | _ -> None
;;

let starts_with value prefix =
  String.length value >= String.length prefix
  && String.sub value 0 (String.length prefix) = prefix
;;

let is_class db entity =
  match ident db entity with
  | Some value -> starts_with value "logseq.class/" || starts_with value "user.class/"
  | None -> false
;;

let find_substring value ~start needle =
  let needle_length = String.length needle in
  let rec search index =
    if index + needle_length > String.length value
    then None
    else if String.sub value index needle_length = needle
    then Some index
    else search (index + 1)
  in
  search start
;;

let simple_tag_end title start =
  let delimiter = function
    | ' ' | '\t' | '\r' | '\n' | ',' | '.' | ';' | ':' | ')' | ']' | '}' -> true
    | _ -> false
  in
  let rec loop index =
    if index >= String.length title || delimiter title.[index]
    then index
    else loop (index + 1)
  in
  loop start
;;

let tag_boundary title index =
  index = 0
  ||
  match title.[index - 1] with
  | ' ' | '\t' | '\r' | '\n' | '(' | '[' | '{' -> true
  | _ -> false
;;

let derive ~db ~self ~title =
  let buffer = Buffer.create (String.length title) in
  let refs = ref [] in
  let tags = ref [] in
  let add_reference ~tag entity =
    if entity <> self then refs := entity :: !refs;
    if tag && entity <> self then tags := entity :: !tags;
    match uuid_text db entity with
    | Some uuid ->
      Buffer.add_string buffer "[[";
      Buffer.add_string buffer uuid;
      Buffer.add_string buffer "]]";
      Ok ()
    | None -> Error (Invalid_reference "target has no UUID")
  in
  let ( let* ) result f = Result.bind result f in
  let resolve_and_add ~tag token =
    let* entity = resolve_page db token in
    if tag && not (is_class db entity)
    then Error (Invalid_reference ("tag is not a class: " ^ token))
    else add_reference ~tag entity
  in
  let rec parse index =
    if index >= String.length title
    then
      Ok
        { canonical_title = Buffer.contents buffer
        ; content_refs = List.sort_uniq Int.compare !refs
        ; inline_tags = List.sort_uniq Int.compare !tags
        }
    else if index + 3 <= String.length title && String.sub title index 3 = "#[["
    then (
      match find_substring title ~start:(index + 3) "]]" with
      | None -> Error (Invalid_reference "unterminated tag reference")
      | Some finish ->
        let token = String.sub title (index + 3) (finish - index - 3) in
        let* () = resolve_and_add ~tag:true token in
        parse (finish + 2))
    else if index + 2 <= String.length title && String.sub title index 2 = "[["
    then (
      match find_substring title ~start:(index + 2) "]]" with
      | None -> Error (Invalid_reference "unterminated page reference")
      | Some finish ->
        let token = String.sub title (index + 2) (finish - index - 2) in
        let* () = resolve_and_add ~tag:false token in
        parse (finish + 2))
    else if index + 2 <= String.length title && String.sub title index 2 = "(("
    then (
      match find_substring title ~start:(index + 2) "))" with
      | None -> Error (Invalid_reference "unterminated block reference")
      | Some finish ->
        let token = String.sub title (index + 2) (finish - index - 2) in
        let* entity = resolve_uuid db token in
        let* () = add_reference ~tag:false entity in
        parse (finish + 2))
    else if
      title.[index] = '#'
      && tag_boundary title index
      && index + 1 < String.length title
      && not (Char.equal title.[index + 1] ' ')
    then (
      let finish = simple_tag_end title (index + 1) in
      let token = String.sub title (index + 1) (finish - index - 1) in
      let* () = resolve_and_add ~tag:true token in
      parse finish)
    else (
      Buffer.add_char buffer title.[index];
      parse (index + 1))
  in
  parse 0
;;
