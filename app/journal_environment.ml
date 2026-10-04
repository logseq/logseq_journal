type brightness =
  | Light
  | Dark

type snapshot =
  { brightness : brightness
  ; platform : string
  ; accessible_navigation : bool
  ; high_contrast : bool
  }

let equal left right =
  left.brightness = right.brightness
  && String.equal left.platform right.platform
  && Bool.equal left.accessible_navigation right.accessible_navigation
  && Bool.equal left.high_contrast right.high_contrast
;;

let fallback =
  { brightness = Light
  ; platform = "unknown"
  ; accessible_navigation = false
  ; high_contrast = false
  }
;;

let boolean (fields : (string * Yojson.Basic.t) list) name =
  match List.assoc_opt name fields with
  | Some (`Bool value) -> Ok value
  | _ -> Error ("environment " ^ name ^ " is missing or not a bool")
;;

let string (fields : (string * Yojson.Basic.t) list) name =
  match List.assoc_opt name fields with
  | Some (`String value) -> Ok value
  | _ -> Error ("environment " ^ name ^ " is missing or not a string")
;;

let decode_json (json : Yojson.Basic.t) =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* platform = string fields "platform" in
    let* accessible_navigation = boolean fields "accessibleNavigation" in
    let* high_contrast = boolean fields "highContrast" in
    let* brightness =
      match List.assoc_opt "brightness" fields with
      | Some (`String "light") -> Ok Light
      | Some (`String "dark") -> Ok Dark
      | _ -> Error "environment brightness is missing or unsupported"
    in
    Ok { brightness; platform; accessible_navigation; high_contrast }
  | _ -> Error "environment snapshot must be a JSON object"
;;

let encode_json snapshot =
  `Assoc
    [ ( "brightness"
      , `String
          (match snapshot.brightness with
           | Light -> "light"
           | Dark -> "dark") )
    ; "platform", `String snapshot.platform
    ; "accessibleNavigation", `Bool snapshot.accessible_navigation
    ; "highContrast", `Bool snapshot.high_contrast
    ]
;;
