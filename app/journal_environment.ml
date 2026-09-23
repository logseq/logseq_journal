type edge_insets =
  { left : float
  ; top : float
  ; right : float
  ; bottom : float
  }

type brightness =
  | Light
  | Dark

type orientation =
  | Portrait
  | Landscape

type snapshot =
  { viewport_width : float
  ; viewport_height : float
  ; device_pixel_ratio : float
  ; text_scale : float
  ; brightness : brightness
  ; platform : string
  ; locale : string
  ; safe_area : edge_insets
  ; keyboard_insets : edge_insets
  ; accessible_navigation : bool
  ; bold_text : bool
  ; invert_colors : bool
  ; disable_animations : bool
  ; reduced_motion : bool
  ; high_contrast : bool
  ; orientation : orientation
  ; pointer_kinds : int
  }

let equal_edge_insets left right =
  Float.equal left.left right.left
  && Float.equal left.top right.top
  && Float.equal left.right right.right
  && Float.equal left.bottom right.bottom
;;

let equal left right =
  Float.equal left.viewport_width right.viewport_width
  && Float.equal left.viewport_height right.viewport_height
  && Float.equal left.device_pixel_ratio right.device_pixel_ratio
  && Float.equal left.text_scale right.text_scale
  && left.brightness = right.brightness
  && String.equal left.platform right.platform
  && String.equal left.locale right.locale
  && equal_edge_insets left.safe_area right.safe_area
  && equal_edge_insets left.keyboard_insets right.keyboard_insets
  && Bool.equal left.accessible_navigation right.accessible_navigation
  && Bool.equal left.bold_text right.bold_text
  && Bool.equal left.invert_colors right.invert_colors
  && Bool.equal left.disable_animations right.disable_animations
  && Bool.equal left.reduced_motion right.reduced_motion
  && Bool.equal left.high_contrast right.high_contrast
  && left.orientation = right.orientation
  && Int.equal left.pointer_kinds right.pointer_kinds
;;

let fallback =
  { viewport_width = 0.
  ; viewport_height = 0.
  ; device_pixel_ratio = 1.
  ; text_scale = 1.
  ; brightness = Light
  ; platform = "unknown"
  ; locale = "en_US"
  ; safe_area = { left = 0.; top = 0.; right = 0.; bottom = 0. }
  ; keyboard_insets = { left = 0.; top = 0.; right = 0.; bottom = 0. }
  ; accessible_navigation = false
  ; bold_text = false
  ; invert_colors = false
  ; disable_animations = false
  ; reduced_motion = false
  ; high_contrast = false
  ; orientation = Portrait
  ; pointer_kinds = 0
  }
;;

let number (fields : (string * Yojson.Basic.t) list) name =
  match List.assoc_opt name fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (Float.of_int value)
  | _ -> Error ("environment " ^ name ^ " is missing or not a number")
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

let insets (fields : (string * Yojson.Basic.t) list) name =
  match List.assoc_opt name fields with
  | Some (`Assoc values) ->
    let ( let* ) = Result.bind in
    let* left = number values "left" in
    let* top = number values "top" in
    let* right = number values "right" in
    let* bottom = number values "bottom" in
    Ok { left; top; right; bottom }
  | _ -> Error ("environment " ^ name ^ " is missing or not an object")
;;

let decode_json (json : Yojson.Basic.t) =
  match json with
  | `Assoc fields ->
    let ( let* ) = Result.bind in
    let* viewport_width = number fields "viewportWidth" in
    let* viewport_height = number fields "viewportHeight" in
    let* device_pixel_ratio = number fields "devicePixelRatio" in
    let* text_scale = number fields "textScale" in
    let* platform = string fields "platform" in
    let* locale = string fields "locale" in
    let* safe_area = insets fields "safeArea" in
    let* keyboard_insets = insets fields "keyboardInsets" in
    let* accessible_navigation = boolean fields "accessibleNavigation" in
    let* bold_text = boolean fields "boldText" in
    let* invert_colors = boolean fields "invertColors" in
    let* disable_animations = boolean fields "disableAnimations" in
    let* reduced_motion = boolean fields "reducedMotion" in
    let* high_contrast = boolean fields "highContrast" in
    let* pointer_kinds = number fields "pointerKinds" in
    let* brightness =
      match List.assoc_opt "brightness" fields with
      | Some (`String "light") -> Ok Light
      | Some (`String "dark") -> Ok Dark
      | _ -> Error "environment brightness is missing or unsupported"
    in
    let* orientation =
      match List.assoc_opt "orientation" fields with
      | Some (`String "portrait") -> Ok Portrait
      | Some (`String "landscape") -> Ok Landscape
      | _ -> Error "environment orientation is missing or unsupported"
    in
    Ok
      { viewport_width
      ; viewport_height
      ; device_pixel_ratio
      ; text_scale
      ; brightness
      ; platform
      ; locale
      ; safe_area
      ; keyboard_insets
      ; accessible_navigation
      ; bold_text
      ; invert_colors
      ; disable_animations
      ; reduced_motion
      ; high_contrast
      ; orientation
      ; pointer_kinds = int_of_float pointer_kinds
      }
  | _ -> Error "environment snapshot must be a JSON object"
;;

let encode_json snapshot =
  let insets value =
    `Assoc
      [ "left", `Float value.left
      ; "top", `Float value.top
      ; "right", `Float value.right
      ; "bottom", `Float value.bottom
      ]
  in
  `Assoc
    [ "viewportWidth", `Float snapshot.viewport_width
    ; "viewportHeight", `Float snapshot.viewport_height
    ; "devicePixelRatio", `Float snapshot.device_pixel_ratio
    ; "textScale", `Float snapshot.text_scale
    ; ( "brightness"
      , `String (match snapshot.brightness with Light -> "light" | Dark -> "dark") )
    ; "platform", `String snapshot.platform
    ; "locale", `String snapshot.locale
    ; "safeArea", insets snapshot.safe_area
    ; "keyboardInsets", insets snapshot.keyboard_insets
    ; "accessibleNavigation", `Bool snapshot.accessible_navigation
    ; "boldText", `Bool snapshot.bold_text
    ; "invertColors", `Bool snapshot.invert_colors
    ; "disableAnimations", `Bool snapshot.disable_animations
    ; "reducedMotion", `Bool snapshot.reduced_motion
    ; "highContrast", `Bool snapshot.high_contrast
    ; ( "orientation"
      , `String
          (match snapshot.orientation with Portrait -> "portrait" | Landscape -> "landscape")
      )
    ; "pointerKinds", `Int snapshot.pointer_kinds
    ]
;;
