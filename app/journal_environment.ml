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

type wire_snapshot =
  { brightness : string
  ; platform : string
  ; accessibleNavigation : bool
  ; highContrast : bool
  }
[@@deriving yojson]

let decode_json (json : Yojson.Basic.t) =
  let ( let* ) = Result.bind in
  let* wire = Logseq_db_types.Json_codec.decode wire_snapshot_of_yojson (json :> Yojson.Safe.t)
    |> Result.map_error (function
      | ("invalid UTF-8 field name" | "duplicate JSON field" | "invalid UTF-8 string"
        | "non-finite JSON number" | "nonstandard JSON value" | "JSON exceeds byte budget"
        | "invalid JSON value") as source -> source
      | _ -> "Native event shape is invalid") in
  let* brightness =
    match wire.brightness with
    | "light" -> Ok Light
    | "dark" -> Ok Dark
    | _ -> Error "environment brightness is unsupported"
  in
  Ok
    { brightness; platform = wire.platform
    ; accessible_navigation = wire.accessibleNavigation
    ; high_contrast = wire.highContrast }
;;

let encode_json (snapshot : snapshot) =
  wire_snapshot_to_yojson
    { brightness = (match snapshot.brightness with Light -> "light" | Dark -> "dark")
    ; platform = snapshot.platform
    ; accessibleNavigation = snapshot.accessible_navigation
    ; highContrast = snapshot.high_contrast }
  |> Yojson.Safe.to_basic
;;
