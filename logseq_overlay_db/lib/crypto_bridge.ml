let duplicate items =
  let rec loop seen = function
    | [] -> None
    | ((id, _) as item) :: rest ->
      if List.exists (Types.Crypto_item_id.equal id) seen
      then Some item
      else loop (id :: seen) rest
  in
  loop [] items
;;

let validate_results ~maximum_value_bytes ~expected ~actual =
  match duplicate actual with
  | Some (id, _) -> Error (Types.Crypto_result_duplicate_item id)
  | None ->
    let expected_ids = List.map fst expected in
    let actual_ids = List.map fst actual in
    (match
       List.find_opt
         (fun id -> not (List.exists (Types.Crypto_item_id.equal id) actual_ids))
         expected_ids
     with
     | Some id -> Error (Types.Crypto_result_missing_item id)
     | None ->
       (match
          List.find_opt
            (fun id -> not (List.exists (Types.Crypto_item_id.equal id) expected_ids))
            actual_ids
        with
        | Some id -> Error (Types.Crypto_result_extra_item id)
        | None when not (List.for_all2 Types.Crypto_item_id.equal expected_ids actual_ids)
          -> Error Types.Crypto_result_reordered
        | None ->
          if
            List.exists
              (fun (_, value) -> String.length value > maximum_value_bytes)
              actual
          then Error Types.Crypto_result_limit_exceeded
          else Ok ()))
;;
