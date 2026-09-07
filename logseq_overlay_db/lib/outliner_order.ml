module Graph = Logseq_db_types.Graph_types

(* Base-62 behavior follows logseq.clj-fractional-indexing at
   1087f0fb18aa8e25ee3bbbb0db983b7a29bce270. *)
let digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
let minimum_integer = "A" ^ String.make 26 '0'

let integer_length = function
  | 'a' .. 'z' as head -> Char.code head - Char.code 'a' + 2
  | 'A' .. 'Z' as head -> Char.code 'Z' - Char.code head + 2
  | _ -> invalid_arg "invalid order key head"
;;

let digit = function
  | '0' .. '9' as c -> Char.code c - Char.code '0'
  | 'A' .. 'Z' as c -> Char.code c - Char.code 'A' + 10
  | 'a' .. 'z' as c -> Char.code c - Char.code 'a' + 36
  | _ -> invalid_arg "invalid base-62 order digit"
;;

let validate key =
  if key = "" then invalid_arg "empty order key";
  let size = integer_length key.[0] in
  if String.length key < size || key = minimum_integer
  then invalid_arg "invalid order integer";
  for index = 1 to String.length key - 1 do
    ignore (digit key.[index])
  done;
  if String.length key > size && key.[String.length key - 1] = '0'
  then invalid_arg "order fraction ends in zero"
;;

let validate_bounds lower upper =
  Option.iter validate lower;
  Option.iter validate upper;
  match lower, upper with
  | Some lower, Some upper when String.compare lower upper >= 0 ->
    invalid_arg "order bounds must be strictly increasing"
  | _ -> ()
;;

let suffix value start = String.sub value start (String.length value - start)

let split key =
  let size = integer_length key.[0] in
  String.sub key 0 size, suffix key size
;;

let increment integer =
  let value = Bytes.of_string integer in
  let rec carry index =
    if index = 0
    then (
      match integer.[0] with
      | 'z' -> None
      | 'Z' -> Some "a0"
      | head ->
        let head = Char.chr (Char.code head + 1) in
        Some (String.make 1 head ^ String.make (integer_length head - 1) '0'))
    else if Bytes.get value index = 'z'
    then (
      Bytes.set value index '0';
      carry (index - 1))
    else (
      Bytes.set value index digits.[digit (Bytes.get value index) + 1];
      Some (Bytes.to_string value))
  in
  carry (Bytes.length value - 1)
;;

let decrement integer =
  let value = Bytes.of_string integer in
  let rec borrow index =
    if index = 0
    then (
      match integer.[0] with
      | 'A' -> None
      | 'a' -> Some "Zz"
      | head ->
        let head = Char.chr (Char.code head - 1) in
        Some (String.make 1 head ^ String.make (integer_length head - 1) 'z'))
    else if Bytes.get value index = '0'
    then (
      Bytes.set value index 'z';
      borrow (index - 1))
    else (
      Bytes.set value index digits.[digit (Bytes.get value index) - 1];
      Some (Bytes.to_string value))
  in
  borrow (Bytes.length value - 1)
;;

let rec midpoint lower upper =
  let common =
    match upper with
    | None -> 0
    | Some upper ->
      let rec loop index =
        if
          index < String.length upper
          && (if index < String.length lower then lower.[index] else '0') = upper.[index]
        then loop (index + 1)
        else index
      in
      loop 0
  in
  match upper with
  | Some upper when common > 0 ->
    String.sub upper 0 common
    ^ midpoint
        (if common >= String.length lower then "" else suffix lower common)
        (Some (suffix upper common))
  | _ ->
    let left = if lower = "" then 0 else digit lower.[0] in
    let right = Option.fold ~none:62 ~some:(fun upper -> digit upper.[0]) upper in
    if right - left > 1
    then String.make 1 digits.[(left + right + 1) / 2]
    else (
      match upper with
      | Some upper when String.length upper > 1 -> String.sub upper 0 1
      | _ ->
        String.make 1 digits.[left]
        ^ midpoint (if lower = "" then "" else suffix lower 1) None)
;;

let between lower upper =
  match lower, upper with
  | None, None -> "a0"
  | None, Some upper ->
    let integer, fraction = split upper in
    if fraction <> ""
    then integer ^ midpoint "" (Some fraction)
    else (
      match decrement integer with
      (* The reference returns its forbidden sentinel here. Keep the key valid
         and below the upper bound so subsequent prepends remain possible. *)
      | Some previous when previous = minimum_integer -> previous ^ midpoint "" None
      | Some previous -> previous
      | None -> invalid_arg "cannot decrement order integer")
  | Some lower, None ->
    let integer, fraction = split lower in
    (match increment integer with
     | Some next -> next
     | None -> integer ^ midpoint fraction None)
  | Some lower, Some upper ->
    let left_integer, left_fraction = split lower in
    let right_integer, right_fraction = split upper in
    if left_integer = right_integer
    then left_integer ^ midpoint left_fraction (Some right_fraction)
    else (
      match increment left_integer with
      | Some next when String.compare next upper < 0 -> next
      | Some _ -> left_integer ^ midpoint left_fraction None
      | None -> invalid_arg "cannot increment order integer")
;;

let generate ~lower ~upper =
  validate_bounds lower upper;
  between lower upper
;;

let generate_n ~lower ~upper count =
  if count < 0 then invalid_arg "order count must be nonnegative";
  validate_bounds lower upper;
  let rec batch lower upper count =
    if count = 0
    then []
    else if count = 1
    then [ between lower upper ]
    else (
      match lower, upper with
      | _, None ->
        let rec append lower count reversed =
          if count = 0
          then List.rev reversed
          else (
            let key = between lower None in
            append (Some key) (count - 1) (key :: reversed))
        in
        append lower count []
      | None, _ ->
        let rec prepend upper count result =
          if count = 0
          then result
          else (
            let key = between None upper in
            prepend (Some key) (count - 1) (key :: result))
        in
        prepend upper count []
      | Some _, Some _ ->
        let key = between lower upper in
        let middle = count / 2 in
        batch lower (Some key) middle
        @ (key :: batch (Some key) upper (count - middle - 1)))
  in
  batch lower upper count
;;

let compare_member (left_order, left_uuid) (right_order, right_uuid) =
  let order = String.compare left_order right_order in
  if order <> 0 then order else Graph.Uuid.compare left_uuid right_uuid
;;
