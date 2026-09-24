module Tokens = Journal_visual_tokens
module Ui = Journal_view

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let test_sf_symbols_preserve_identity_and_appearance () =
  let cases =
    Journal_symbols.
      [ Account, "person.crop.circle"
      ; Add, "plus"
      ; Save, "arrow.up"
      ; Back, "chevron.left"
      ; Open, "chevron.right"
      ; Dot, "circle.fill"
      ; Delete, "trash"
      ; Expand, "chevron.down"
      ; Refresh, "arrow.clockwise"
      ]
  in
  List.iter
    (fun (role, expected) ->
       let color = Ui.Style.Color.rgb ~red:17 ~green:34 ~blue:51 in
       let key = "symbol:" ^ expected in
       let widget =
         Journal_symbols.create ~key:(Ui.Key.string key) ~size:19. ~color role
       in
       require
         (String.equal (Journal_symbols.name role) expected)
         "Unexpected SF Symbol %s"
         (Journal_symbols.name role);
       require
         (Option.equal String.equal (Ui.View.For_testing.key widget) (Some key))
         "Symbol key changed")
    cases
;;

let test_every_exact_status_maps_to_the_decided_rail_category () =
  let open Journal_model in
  List.iter
    (fun (status, expected) ->
       require
         (status_category status = expected)
         "exact status %s maps to the wrong rail category"
         (status_name status))
    [ No_status, None
    ; Todo, Some Todo_category
    ; Doing, Some Doing_category
    ; In_review, Some Doing_category
    ; Now, Some Doing_category
    ; Done, Some Done_category
    ; Canceled, Some Done_category
    ; Backlog, Some Later_category
    ; Waiting, Some Later_category
    ; Later, Some Later_category
    ]
;;

let test_header_context_copy_is_pure_product_state () =
  require
    (String.equal
       (Journal_header.Context.semantics_label Journal_header.Context.journals)
       "Journals")
    "Journals context must leave the date to the list";
  require
    (String.equal
       (Journal_header.Context.semantics_label Journal_header.Context.favorites)
       "Favorites")
    "Favorites context changed"
;;

(* Relative luminance and contrast are independent of palette implementation.
   [Ui.Style.Color.t] exposes no channel accessors on the lui shim; the
   "#rrggbb" channels are recovered with ordered probes through the public
   [rgb] constructor (a fully transparent color decodes to black). *)
let color_luminance color =
  if color = Ui.Style.Color.argb ~alpha:0 ~red:0 ~green:0 ~blue:0
  then 0.
  else (
    let channel probe =
      let rec scan value =
        if value > 255
        then 255
        else if Stdlib.compare (probe value) color <= 0
        then scan (value + 1)
        else value - 1
      in
      scan 0
    in
    let red = channel (fun red -> Ui.Style.Color.rgb ~red ~green:0 ~blue:0) in
    let green = channel (fun green -> Ui.Style.Color.rgb ~red ~green ~blue:0) in
    let blue = channel (fun blue -> Ui.Style.Color.rgb ~red ~green ~blue) in
    let linear byte =
      let value = Float.of_int byte /. 255. in
      if value <= 0.04045 then value /. 12.92 else ((value +. 0.055) /. 1.055) ** 2.4
    in
    (0.2126 *. linear red) +. (0.7152 *. linear green) +. (0.0722 *. linear blue))
;;

let color_contrast first second =
  let first = color_luminance first in
  let second = color_luminance second in
  (Float.max first second +. 0.05) /. (Float.min first second +. 0.05)
;;

let test_status_palette_contrast () =
  let rgb red green blue = Ui.Style.Color.rgb ~red ~green ~blue in
  let minimum_regular = ref Float.infinity in
  let minimum_increased = ref Float.infinity in
  let statuses =
    Journal_model.
      [ No_status; Todo; Doing; In_review; Now; Done; Canceled; Backlog; Waiting; Later ]
  in
  List.iter
    (fun (brightness, surfaces) ->
       let regular = Tokens.resolve ~brightness ~high_contrast:false in
       let increased = Tokens.resolve ~brightness ~high_contrast:true in
       List.iter
         (fun status ->
            let regular = Tokens.status_swipe_action regular status in
            let increased = Tokens.status_swipe_action increased status in
            let symbol (palette : Tokens.swipe_action_colors) =
              if status = Journal_model.No_status
              then palette.foreground
              else palette.background
            in
            List.iter
              (fun surface ->
                 let normal = color_contrast (symbol regular) surface in
                 let high = color_contrast (symbol increased) surface in
                 minimum_regular := Float.min !minimum_regular normal;
                 minimum_increased := Float.min !minimum_increased high;
                 require
                   (normal >= 4.5)
                   "Regular %s symbol contrast %.3f is below 4.5"
                   (Journal_model.status_name status)
                   normal;
                 require
                   (high >= 7.)
                   "Increased %s symbol contrast %.3f is below 7"
                   (Journal_model.status_name status)
                   high;
                 require
                   (high > normal)
                   "Increase Contrast did not improve %s (%.3f versus %.3f)"
                   (Journal_model.status_name status)
                   high
                   normal)
              surfaces;
            if status <> Journal_model.No_status
            then (
              require
                (color_contrast regular.background regular.foreground >= 4.5)
                "Regular status label has insufficient contrast";
              require
                (color_contrast increased.background increased.foreground >= 7.)
                "Increased status label has insufficient contrast"))
         statuses)
    [ Journal_environment.Light, [ rgb 255 255 255; rgb 242 242 247 ]
    ; Dark, [ rgb 0 0 0; rgb 28 28 30; rgb 44 44 46 ]
    ];
  Printf.printf
    "Minimum tested symbol contrast: regular %.3f, increased %.3f\n%!"
    !minimum_regular
    !minimum_increased
;;

let tests =
  [ ( "SF Symbols preserve identity and appearance"
    , test_sf_symbols_preserve_identity_and_appearance )
  ; ( "exact status rail categories"
    , test_every_exact_status_maps_to_the_decided_rail_category )
  ; "header context", test_header_context_copy_is_pure_product_state
  ; "status palette contrast", test_status_palette_contrast
  ]
;;

let () =
  List.iter
    (fun (name, test) ->
       Printf.printf "running %s\n%!" name;
       test ())
    tests
;;
