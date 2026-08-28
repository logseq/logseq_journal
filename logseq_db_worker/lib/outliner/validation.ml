let valid_utf_8 value =
  let valid = ref true in
  Uutf.String.fold_utf_8
    (fun () _ -> function
       | `Uchar _ -> ()
       | `Malformed _ -> valid := false)
    ()
    value;
  !valid
;;

let case_map map value =
  let buffer = Buffer.create (String.length value) in
  Uutf.String.fold_utf_8
    (fun () _ -> function
       | `Malformed _ -> ()
       | `Uchar uchar ->
         (match map uchar with
          | `Self -> Buffer.add_utf_8_uchar buffer uchar
          | `Uchars uchars -> List.iter (Buffer.add_utf_8_uchar buffer) uchars))
    ()
    value;
  Buffer.contents buffer
;;

let normalize_nfc value =
  let normalizer = Uunf.create `NFC in
  let buffer = Buffer.create (String.length value) in
  let rec add input =
    match Uunf.add normalizer input with
    | `Uchar uchar ->
      Buffer.add_utf_8_uchar buffer uchar;
      add `Await
    | `Await | `End -> ()
  in
  Uutf.String.fold_utf_8
    (fun () _ -> function
       | `Malformed _ -> ()
       | `Uchar uchar -> add (`Uchar uchar))
    ()
    value;
  add `End;
  Buffer.contents buffer
;;

let remove_boundary_slashes value =
  let start = if String.length value > 0 && value.[0] = '/' then 1 else 0 in
  let finish =
    if String.length value > start && value.[String.length value - 1] = '/'
    then String.length value - 1
    else String.length value
  in
  String.sub value start (finish - start)
;;

let page_name value =
  value |> case_map Uucp.Case.Map.to_lower |> remove_boundary_slashes |> normalize_nfc
;;

let contains value needle =
  let needle_length = String.length needle in
  let rec search offset =
    offset + needle_length <= String.length value
    && (String.sub value offset needle_length = needle || search (offset + 1))
  in
  needle_length = 0 || search 0
;;

let contains_unsupported_save_effect value =
  List.exists
    (contains value)
    [ "{{renderer"
    ; "{{command"
    ; "{{template"
    ; "../assets/"
    ; "assets://"
    ; "logseq://asset/"
    ]
;;
