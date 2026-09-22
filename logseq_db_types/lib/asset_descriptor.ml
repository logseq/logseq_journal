type version =
  { checksum : string
  ; file_type : string
  }

type source =
  | Managed of version option
  | External of string

type t =
  { uuid : Graph_types.Uuid.t
  ; source : source
  ; current_checksum : string option
  ; size : int64 option
  ; dimensions : (int * int) option
  }

let valid_checksum value =
  String.length value = 64
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       value
;;

let version ~checksum ~file_type =
  if not (valid_checksum checksum)
  then Error "Invalid SHA-256 checksum"
  else if
    String.length file_type = 0
    || String.length file_type > 32
    || not
         (String.for_all
            (function
              | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
              | _ -> false)
            file_type)
  then Error "Invalid asset file type"
  else Ok { checksum; file_type }
;;

let create ~uuid ~source ~current_checksum ~size ~dimensions =
  if
    Option.fold
      ~none:false
      ~some:(fun value -> not (valid_checksum value))
      current_checksum
  then Error "Invalid current SHA-256 checksum"
  else if Option.fold ~none:false ~some:(fun value -> value < 0L) size
  then Error "Invalid asset size"
  else if
    Option.fold
      ~none:false
      ~some:(fun (width, height) -> width <= 0 || height <= 0)
      dimensions
  then Error "Invalid asset dimensions"
  else Ok { uuid; source; current_checksum; size; dimensions }
;;

let equal_version a b = a = b
