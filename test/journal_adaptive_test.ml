module Tokens = Journal_visual_tokens
module Ui = Bonsai_swiftui_ui

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
       let key = Ui.Key.string ("symbol:" ^ expected) in
       let widget = Journal_symbols.create ~key ~size:19. ~color role in
       let (Av view) = Ui.View.Private.view widget in
       (match view.node with
        | Ui.View.Private.Symbol { name; size; color; _ } ->
          require (name = expected) "Unexpected SF Symbol %s" name;
          require (size = Some 19.) "Symbol size changed";
          require (color = Some 0xff112233l) "Symbol tint changed"
        | _ -> failwith "Expected a native symbol");
       require
         (Option.equal Ui.Key.equal (Ui.View.For_testing.key widget) (Some key))
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

(* Relative luminance and contrast are independent of palette implementation. *)
let color_luminance color =
  let value = Ui.Style.Color.Private.to_argb32 color in
  let channel shift =
    let byte = Int32.(to_int (logand (shift_right_logical value shift) 0xffl)) in
    let value = Float.of_int byte /. 255. in
    if value <= 0.04045 then value /. 12.92 else ((value +. 0.055) /. 1.055) ** 2.4
  in
  (0.2126 *. channel 16) +. (0.7152 *. channel 8) +. (0.0722 *. channel 0)
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
    [ Bonsai_swiftui.Environment.Light, [ rgb 255 255 255; rgb 242 242 247 ]
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
