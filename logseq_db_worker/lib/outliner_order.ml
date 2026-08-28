type error =
  | Invalid_key of string
  | No_space

let digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
let zero = digits.[0]

exception Invalid of string

let digit_index character =
  match String.index_opt digits character with
  | Some index -> index
  | None -> raise (Invalid "character outside base-62 alphabet")
;;

let integer_length = function
  | 'a' .. 'z' as head -> Char.code head - Char.code 'a' + 2
  | 'A' .. 'Z' as head -> Char.code 'Z' - Char.code head + 2
  | _ -> raise (Invalid "invalid order key head")
;;

let integer_part key =
  if String.length key = 0 then raise (Invalid "empty order key");
  let length = integer_length key.[0] in
  if length > String.length key then raise (Invalid "truncated integer part");
  String.sub key 0 length
;;

let validate_integer value =
  if String.length value = 0 || String.length value <> integer_length value.[0]
  then raise (Invalid "invalid integer part");
  String.iteri
    (fun index character -> if index > 0 then ignore (digit_index character))
    value
;;

let validate key =
  if String.equal key ("A" ^ String.make 26 zero)
  then raise (Invalid "reserved minimum key");
  let integer = integer_part key in
  validate_integer integer;
  let fractional =
    String.sub key (String.length integer) (String.length key - String.length integer)
  in
  String.iter (fun character -> ignore (digit_index character)) fractional;
  if
    String.length fractional > 0
    && Char.equal fractional.[String.length fractional - 1] zero
  then raise (Invalid "trailing zero")
;;

let is_valid key =
  try
    validate key;
    true
  with
  | Invalid _ -> false
;;

let increment_integer value =
  validate_integer value;
  let head = value.[0] in
  let suffix = Bytes.of_string (String.sub value 1 (String.length value - 1)) in
  let carry = ref true in
  for index = Bytes.length suffix - 1 downto 0 do
    if !carry
    then (
      let next = digit_index (Bytes.get suffix index) + 1 in
      if next = String.length digits
      then Bytes.set suffix index zero
      else (
        Bytes.set suffix index digits.[next];
        carry := false))
  done;
  if not !carry
  then Some (String.make 1 head ^ Bytes.to_string suffix)
  else if Char.equal head 'Z'
  then Some ("a" ^ String.make 1 zero)
  else if Char.equal head 'z'
  then None
  else (
    let new_head = Char.chr (Char.code head + 1) in
    let suffix = Bytes.to_string suffix in
    let suffix =
      if Char.compare new_head 'a' > 0
      then suffix ^ String.make 1 zero
      else String.sub suffix 0 (String.length suffix - 1)
    in
    Some (String.make 1 new_head ^ suffix))
;;

let decrement_integer value =
  validate_integer value;
  let head = value.[0] in
  let suffix = Bytes.of_string (String.sub value 1 (String.length value - 1)) in
  let borrow = ref true in
  for index = Bytes.length suffix - 1 downto 0 do
    if !borrow
    then (
      let previous = digit_index (Bytes.get suffix index) - 1 in
      if previous < 0
      then Bytes.set suffix index digits.[String.length digits - 1]
      else (
        Bytes.set suffix index digits.[previous];
        borrow := false))
  done;
  if not !borrow
  then Some (String.make 1 head ^ Bytes.to_string suffix)
  else if Char.equal head 'a'
  then Some ("Z" ^ String.make 1 digits.[String.length digits - 1])
  else if Char.equal head 'A'
  then None
  else (
    let new_head = Char.chr (Char.code head - 1) in
    let suffix = Bytes.to_string suffix in
    let suffix =
      if Char.compare new_head 'Z' < 0
      then suffix ^ String.make 1 digits.[String.length digits - 1]
      else String.sub suffix 0 (String.length suffix - 1)
    in
    Some (String.make 1 new_head ^ suffix))
;;

let rec midpoint lower upper =
  (match upper with
   | Some upper when String.compare lower upper >= 0 -> raise (Invalid "lower >= upper")
   | _ -> ());
  if String.length lower > 0 && Char.equal lower.[String.length lower - 1] zero
  then raise (Invalid "lower has trailing zero");
  (match upper with
   | Some upper
     when String.length upper > 0 && Char.equal upper.[String.length upper - 1] zero ->
     raise (Invalid "upper has trailing zero")
   | _ -> ());
  let common =
    match upper with
    | None -> 0
    | Some upper ->
      let limit = min (String.length lower) (String.length upper) in
      let rec loop index =
        if index = limit || not (Char.equal lower.[index] upper.[index])
        then index
        else loop (index + 1)
      in
      loop 0
  in
  if common > 0
  then (
    let prefix = Option.get upper |> fun value -> String.sub value 0 common in
    let lower = String.sub lower common (String.length lower - common) in
    let upper =
      Option.map
        (fun value -> String.sub value common (String.length value - common))
        upper
    in
    prefix ^ midpoint lower upper)
  else (
    let lower_digit = if String.length lower = 0 then 0 else digit_index lower.[0] in
    let upper_digit =
      match upper with
      | None -> String.length digits
      | Some value -> digit_index value.[0]
    in
    if upper_digit - lower_digit > 1
    then String.make 1 digits.[(lower_digit + upper_digit + 1) / 2]
    else (
      match upper with
      | Some value when String.length value > 1 -> String.sub value 0 1
      | _ ->
        let rest =
          if String.length lower = 0
          then ""
          else String.sub lower 1 (String.length lower - 1)
        in
        String.make 1 digits.[lower_digit] ^ midpoint rest None))
;;

let generate lower upper =
  Option.iter validate lower;
  Option.iter validate upper;
  (match lower, upper with
   | Some lower, Some upper when String.compare lower upper >= 0 ->
     raise (Invalid "lower >= upper")
   | _ -> ());
  match lower, upper with
  | None, None -> "a" ^ String.make 1 zero
  | None, Some upper ->
    let integer = integer_part upper in
    if String.compare integer upper < 0
    then integer
    else (
      match decrement_integer integer with
      | Some value -> value
      | None -> raise (Invalid "cannot decrement"))
  | Some lower, None ->
    let integer = integer_part lower in
    let fractional =
      String.sub
        lower
        (String.length integer)
        (String.length lower - String.length integer)
    in
    (match increment_integer integer with
     | Some value -> value
     | None -> integer ^ midpoint fractional None)
  | Some lower, Some upper ->
    let lower_integer = integer_part lower in
    let lower_fraction =
      String.sub
        lower
        (String.length lower_integer)
        (String.length lower - String.length lower_integer)
    in
    let upper_integer = integer_part upper in
    let upper_fraction =
      String.sub
        upper
        (String.length upper_integer)
        (String.length upper - String.length upper_integer)
    in
    if String.equal lower_integer upper_integer
    then lower_integer ^ midpoint lower_fraction (Some upper_fraction)
    else (
      match increment_integer lower_integer with
      | None -> raise (Invalid "cannot increment")
      | Some candidate ->
        if String.compare candidate upper < 0
        then candidate
        else lower_integer ^ midpoint lower_fraction None)
;;

let between ~lower ~upper =
  try Ok (generate lower upper) with
  | Invalid message ->
    let key =
      match lower, upper with
      | Some value, _ | None, Some value -> value
      | None, None -> message
    in
    Error (Invalid_key key)
;;

let rec generate_n lower upper count =
  if count = 0
  then []
  else if count = 1
  then [ generate lower upper ]
  else (
    match lower, upper with
    | _, None ->
      let rec loop current remaining acc =
        if remaining = 0
        then List.rev acc
        else (
          let next = generate current None in
          loop (Some next) (remaining - 1) (next :: acc))
      in
      loop lower count []
    | None, _ ->
      let rec loop current remaining acc =
        if remaining = 0
        then acc
        else (
          let next = generate None current in
          loop (Some next) (remaining - 1) (next :: acc))
      in
      loop upper count []
    | Some _, Some _ ->
      let middle_count = count / 2 in
      let middle = generate lower upper in
      generate_n lower (Some middle) middle_count
      @ [ middle ]
      @ generate_n (Some middle) upper (count - middle_count - 1))
;;

let sequence_between ~lower ~upper count =
  if count < 0
  then Error No_space
  else (
    try Ok (generate_n lower upper count) with
    | Invalid message -> Error (Invalid_key message))
;;
