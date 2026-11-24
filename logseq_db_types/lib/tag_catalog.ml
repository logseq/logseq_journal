module Graph = Graph_types

type entry =
  { key : string
  ; tag : Graph.tag_summary
  }

type t =
  { identity : unit ref
  ; entries : entry array
  }

type cursor =
  { owner : unit ref
  ; prefix : string
  ; offset : int
  }

type error = Candidate_limit_exceeded | Invalid_limit | Invalid_cursor

let normalize value = String.trim value |> String.lowercase_ascii

let compare_entries left right =
  match String.compare left.key right.key with
  | 0 -> Graph.Uuid.compare left.tag.uuid right.tag.uuid
  | order -> order
;;

let create ~maximum_candidates candidates =
  let rec collect remaining entries candidates =
    match candidates () with
    | Seq.Nil ->
      let entries = Array.of_list entries in
      Array.sort compare_entries entries;
      Ok { identity = ref (); entries }
    | Seq.Cons _ when remaining = 0 -> Error Candidate_limit_exceeded
    | Seq.Cons ((tag : Graph.tag_summary), rest) ->
      collect (remaining - 1) ({ key = normalize tag.title; tag } :: entries) rest
  in
  if maximum_candidates < 0 || maximum_candidates > Sys.max_array_length
  then Error Invalid_limit
  else collect maximum_candidates [] candidates
;;

let lower_bound entries prefix =
  let rec find left right =
    if left = right
    then left
    else (
      let middle = left + ((right - left) / 2) in
      if String.compare entries.(middle).key prefix < 0
      then find (middle + 1) right
      else find left middle)
  in
  find 0 (Array.length entries)
;;

let search catalog ~prefix ~limit ~after =
  if limit < 1 || limit > 200
  then Error Invalid_limit
  else (
    let prefix = normalize prefix in
    let entries = catalog.entries in
    let matches offset =
      offset < Array.length entries && String.starts_with ~prefix entries.(offset).key
    in
    let rec read offset remaining tags =
      if not (matches offset)
      then Ok (List.rev tags, None)
      else if remaining = 0
      then Ok (List.rev tags, Some { owner = catalog.identity; prefix; offset })
      else read (offset + 1) (remaining - 1) (entries.(offset).tag :: tags)
    in
    match after with
    | None -> read (lower_bound entries prefix) limit []
    | Some cursor when cursor.owner == catalog.identity && String.equal cursor.prefix prefix ->
      read cursor.offset limit []
    | Some _ -> Error Invalid_cursor)
;;

let cursor_offset cursor = cursor.offset

let resume catalog ~prefix offset =
  let prefix = normalize prefix in
  if offset <= lower_bound catalog.entries prefix || offset >= Array.length catalog.entries
     || not (String.starts_with ~prefix catalog.entries.(offset).key)
  then Error Invalid_cursor
  else Ok { owner = catalog.identity; prefix; offset }
;;
