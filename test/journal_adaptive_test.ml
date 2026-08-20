module Tokens = Journal_visual_tokens
module Ui = Bonsai_flutter_ui

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let argb color = Ui.Style.Color.Private.to_argb32 color

let require_color name expected actual =
  require
    (Int32.equal expected (argb actual))
    "%s expected 0x%lx, got 0x%lx"
    name
    expected
    (argb actual)
;;

let relative_luminance color =
  let packed = argb color in
  let channel shift =
    let value = Int32.(logand (shift_right_logical packed shift) 0xffl) |> Int32.to_int in
    let srgb = Float.of_int value /. 255. in
    if Float.compare srgb 0.04045 <= 0
    then srgb /. 12.92
    else Float.pow ((srgb +. 0.055) /. 1.055) 2.4
  in
  (0.2126 *. channel 16) +. (0.7152 *. channel 8) +. (0.0722 *. channel 0)
;;

let contrast_ratio left right =
  let left = relative_luminance left in
  let right = relative_luminance right in
  (Float.max left right +. 0.05) /. (Float.min left right +. 0.05)
;;

let test_light_palette_and_interaction_tokens () =
  let tokens = Tokens.resolve ~high_contrast:false in
  let palette = Tokens.palette tokens in
  require_color "background" 0xfffdfdfdl palette.background;
  require_color "header" 0xfffdfdfdl palette.header;
  require_color "text primary" 0xff0d142fl palette.text_primary;
  require_color "text secondary" 0xff656b8fl palette.text_secondary;
  require_color "timestamp" 0xff6e7388l palette.text_timestamp;
  require_color "divider" 0xffe8e9edl palette.divider;
  require_color "FAB" 0xff181e34l palette.fab;
  require_color "on FAB" 0xfffcfcfdl palette.on_fab;
  require_color "status todo" 0xff64748bl palette.status_todo;
  require_color "status doing" 0xff2563ebl palette.status_doing;
  require_color "status done" 0xff058e46l palette.status_done;
  require_color "status later" 0xff7c3aedl palette.status_later;
  let interaction = Tokens.interaction tokens in
  require_color "pressed" 0x1f0d142fl interaction.pressed;
  require_color "focused" 0xff315ef5l interaction.focused;
  require_color "disabled" 0xffa5a8b6l interaction.disabled;
  require_color "error" 0xffb3261el interaction.error
;;

let test_light_high_contrast_palette_is_explicit () =
  let light_high = Tokens.resolve ~high_contrast:true |> Tokens.palette in
  require_color "light HC background" 0xffffffffl light_high.background;
  require_color "light HC primary" 0xff000000l light_high.text_primary;
  require_color "light HC secondary" 0xff313131l light_high.text_secondary;
  require_color "light HC timestamp" 0xff313131l light_high.text_timestamp;
  require_color "light HC divider" 0xff666666l light_high.divider;
  require_color "light HC status todo" 0xff1f2937l light_high.status_todo;
  require_color "light HC status doing" 0xff0047abl light_high.status_doing;
  require_color "light HC status done" 0xff006b33l light_high.status_done;
  require_color "light HC status later" 0xff5b21b6l light_high.status_later
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

let test_timestamp_contrast_meets_small_text_target () =
  let palette = Tokens.resolve ~high_contrast:false |> Tokens.palette in
  require
    (Float.compare (contrast_ratio palette.text_timestamp palette.background) 4.5 >= 0)
    "light timestamp contrast is below 4.5:1"
;;

let test_capture_sheet_palette_roles_and_contrast () =
  let cases =
    [ ( false
      , "light"
      , 0xffffffffl
      , 0xffe8e9edl
      , 0x470d142fl
      , 0xff181e34l
      , 0xfff5f5f6l
      , 0xffb3261el )
    ; ( true
      , "light high contrast"
      , 0xffffffffl
      , 0xff666666l
      , 0x8c000000l
      , 0xff000000l
      , 0xffeeeeeel
      , 0xff800000l )
    ]
  in
  List.iter
    (fun ( high_contrast
         , name
         , sheet_surface
         , sheet_outline
         , modal_scrim
         , sheet_primary_action
         , sheet_secondary_action
         , sheet_error ) ->
       let palette = Tokens.resolve ~high_contrast |> Tokens.palette in
       require_color (name ^ " sheet surface") sheet_surface palette.sheet_surface;
       require_color (name ^ " sheet outline") sheet_outline palette.sheet_outline;
       require_color (name ^ " modal scrim") modal_scrim palette.modal_scrim;
       require_color
         (name ^ " sheet primary action")
         sheet_primary_action
         palette.sheet_primary_action;
       require_color
         (name ^ " sheet secondary action")
         sheet_secondary_action
         palette.sheet_secondary_action;
       require_color (name ^ " sheet error") sheet_error palette.sheet_error;
       require
         (Float.compare (contrast_ratio palette.text_primary palette.sheet_surface) 4.5
          >= 0)
         "%s sheet primary text contrast is below 4.5:1"
         name;
       require
         (Float.compare (contrast_ratio palette.sheet_error palette.sheet_surface) 4.5
          >= 0)
         "%s sheet error contrast is below 4.5:1"
         name;
       require
         (Float.compare (contrast_ratio palette.on_fab palette.sheet_primary_action) 4.5
          >= 0)
         "%s sheet action contrast is below 4.5:1"
         name)
    cases
;;

let test_typography_spacing_motion_and_hit_regions () =
  let typography = Tokens.typography in
  require
    (typography.header_title.font_size = 22.
     && typography.header_title.line_height = 28.
     && typography.header_title.weight = Ui.Style.Font_weight.Bold)
    "header title typography changed";
  require
    (typography.entry.font_size = 15.
     && typography.entry.line_height = 20.
     && typography.entry.weight = Ui.Style.Font_weight.Normal)
    "entry typography changed";
  require
    (typography.supporting.font_size = 14.
     && typography.supporting.line_height = 20.
     && typography.supporting.weight = Ui.Style.Font_weight.Normal)
    "supporting typography changed";
  require
    (typography.disclosure.font_size = 11.
     && typography.disclosure.line_height = 16.
     && typography.disclosure.weight = Ui.Style.Font_weight.Medium)
    "disclosure typography changed";
  require
    (typography.timestamp.font_size = 13.
     && typography.timestamp.line_height = 18.
     && typography.timestamp.weight = Ui.Style.Font_weight.Normal)
    "timestamp typography changed";
  let spacing = Tokens.spacing in
  require
    ([ spacing.x1
     ; spacing.x2
     ; spacing.x3
     ; spacing.x4
     ; spacing.x5
     ; spacing.x6
     ; spacing.x7
     ]
     = [ 4.; 8.; 12.; 16.; 20.; 24.; 28. ])
    "spacing grid changed";
  let hit = Tokens.hit_regions in
  require
    (hit.header_visual = 30. && hit.minimum_target = 44.)
    "hit-region tokens changed";
  let row = Tokens.row_geometry in
  require
    (row.time_slot_base = 52.
     && row.disclosure_visual = 14.
     && row.status_rail_width = 4.
     && row.status_rail_radius = 2.
     && row.trailing_inset = 24.)
    "row geometry tokens changed";
  let preview = Tokens.preview_geometry in
  require
    (preview.connector_leading = 32.
     && preview.bullet_center_leading = 50.
     && preview.bullet_diameter = 3.
     && preview.text_leading = 68.
     && preview.narrow_leading_delta = 8.)
    "preview geometry tokens changed";
  let composer = Tokens.composer_geometry in
  require
    (composer.horizontal_margin = 12.
     && composer.bottom_inset = 12.
     && composer.minimum_height = 48.
     && composer.reserved_extent = 68.)
    "Capture composer geometry tokens changed";
  let standard = Tokens.motion ~reduced_motion:false in
  let reduced = Tokens.motion ~reduced_motion:true in
  require
    (standard.press_release_ms = 80
     && standard.route_transition_ms = 180
     && standard.capture_sheet_enter_ms = 220
     && standard.capture_sheet_exit_ms = 180)
    "standard motion tokens changed";
  require
    (reduced.press_release_ms = 0
     && reduced.route_transition_ms = 0
     && reduced.capture_sheet_enter_ms = 0
     && reduced.capture_sheet_exit_ms = 0)
    "reduced-motion tokens are not disabled"
;;

let test_dividers_resolve_to_one_physical_pixel () =
  List.iter
    (fun device_pixel_ratio ->
       let logical = Tokens.physical_divider_thickness ~device_pixel_ratio in
       require
         (Float.equal (logical *. device_pixel_ratio) 1.)
         "divider is not one physical pixel at %.0fx"
         device_pixel_ratio)
    [ 1.; 2.; 3.; 4. ];
  require
    (Float.equal (Tokens.physical_divider_thickness ~device_pixel_ratio:0.) 1.)
    "invalid DPR does not retain the safe one-pixel fallback"
;;

let require_profile
      ~width
      ~scale
      ~kind
      ~block_line_height
      ~continuation_extent
      ~day_header_extent
      ~content_leading
      ~time_slot_width
  =
  let profile = Tokens.select_row_profile ~viewport_width:width ~text_scale:scale in
  require (profile.kind = kind) "profile kind changed at %.0f/%.2f" width scale;
  require
    (profile.block_line_height = block_line_height)
    "block line height changed at %.0f/%.2f"
    width
    scale;
  require
    (profile.continuation_extent = continuation_extent)
    "continuation extent changed at %.0f/%.2f"
    width
    scale;
  require
    (profile.day_header_extent = day_header_extent)
    "day extent changed at %.0f/%.2f"
    width
    scale;
  require
    (profile.content_leading = content_leading)
    "content leading changed at %.0f/%.2f"
    width
    scale;
  require
    (profile.time_slot_width = time_slot_width)
    "time slot width changed at %.0f/%.2f"
    width
    scale
;;

let test_known_row_profile_selection () =
  require_profile
    ~width:360.
    ~scale:1.3
    ~kind:Tokens.Compact
    ~block_line_height:26.
    ~continuation_extent:54.
    ~day_header_extent:36.
    ~content_leading:32.
    ~time_slot_width:52.;
  require_profile
    ~width:359.
    ~scale:1.
    ~kind:Tokens.Adaptive
    ~block_line_height:20.
    ~continuation_extent:48.
    ~day_header_extent:48.
    ~content_leading:24.
    ~time_slot_width:52.;
  require_profile
    ~width:390.
    ~scale:1.3
    ~kind:Tokens.Compact
    ~block_line_height:26.
    ~continuation_extent:54.
    ~day_header_extent:36.
    ~content_leading:32.
    ~time_slot_width:52.;
  require_profile
    ~width:744.
    ~scale:2.
    ~kind:Tokens.Adaptive
    ~block_line_height:40.
    ~continuation_extent:68.
    ~day_header_extent:72.
    ~content_leading:32.
    ~time_slot_width:104.;
  require_profile
    ~width:1_200.
    ~scale:3.2
    ~kind:Tokens.Adaptive
    ~block_line_height:64.
    ~continuation_extent:92.
    ~day_header_extent:101.
    ~content_leading:32.
    ~time_slot_width:167.
;;

let test_row_profiles_cover_required_width_and_scale_matrix () =
  let cases =
    [ 320., 1., Tokens.Adaptive, 20., 48., 48., 24., 52.
    ; 320., 1.3, Tokens.Adaptive, 26., 54., 56., 24., 68.
    ; 320., 2., Tokens.Adaptive, 40., 68., 72., 24., 104.
    ; 320., 3.2, Tokens.Adaptive, 64., 92., 101., 24., 167.
    ; 390., 1., Tokens.Compact, 20., 48., 36., 32., 52.
    ; 390., 1.3, Tokens.Compact, 26., 54., 36., 32., 52.
    ; 390., 2., Tokens.Adaptive, 40., 68., 72., 32., 104.
    ; 390., 3.2, Tokens.Adaptive, 64., 92., 101., 32., 167.
    ; 744., 1., Tokens.Compact, 20., 48., 36., 32., 52.
    ; 744., 1.3, Tokens.Compact, 26., 54., 36., 32., 52.
    ; 744., 2., Tokens.Adaptive, 40., 68., 72., 32., 104.
    ; 744., 3.2, Tokens.Adaptive, 64., 92., 101., 32., 167.
    ; 1_200., 1., Tokens.Compact, 20., 48., 36., 32., 52.
    ; 1_200., 1.3, Tokens.Compact, 26., 54., 36., 32., 52.
    ; 1_200., 2., Tokens.Adaptive, 40., 68., 72., 32., 104.
    ; 1_200., 3.2, Tokens.Adaptive, 64., 92., 101., 32., 167.
    ]
  in
  List.iter
    (fun ( width
         , scale
         , kind
         , block_line_height
         , continuation_extent
         , day_header_extent
         , content_leading
         , time_slot_width ) ->
       require_profile
         ~width
         ~scale
         ~kind
         ~block_line_height
         ~continuation_extent
         ~day_header_extent
         ~content_leading
         ~time_slot_width)
    cases
;;

let test_zero_viewport_and_profile_growth_remain_known_extent () =
  require_profile
    ~width:0.
    ~scale:0.
    ~kind:Tokens.Adaptive
    ~block_line_height:20.
    ~continuation_extent:48.
    ~day_header_extent:48.
    ~content_leading:24.
    ~time_slot_width:52.;
  let scales = [ 1.; 1.3; 2.; 3.2 ] in
  let profiles =
    List.map
      (fun text_scale -> Tokens.select_row_profile ~viewport_width:320. ~text_scale)
      scales
  in
  let rec require_monotonic (profiles : Tokens.row_profile list) =
    match profiles with
    | left :: (right :: _ as rest) ->
      require
        (Float.compare left.block_line_height right.block_line_height <= 0
         && Float.compare left.day_header_extent right.day_header_extent <= 0
         && Float.compare left.time_slot_width right.time_slot_width <= 0)
        "known extents shrink as text scale increases";
      require_monotonic rest
    | [] | [ _ ] -> ()
  in
  require_monotonic profiles;
  require
    (Journal_timeline_state.extent_strategy = Journal_timeline_state.Known_profile_extents)
    "adaptive behavior introduced intrinsic measurement"
;;

let test_every_sparse_role_has_one_authoritative_exact_extent () =
  let check ~width ~scale ~safe_bottom ~block_extents expected =
    let profile = Tokens.select_row_profile ~viewport_width:width ~text_scale:scale in
    List.iteri
      (fun index expected ->
         require
           (Float.equal
              (Tokens.block_extent ~profile ~visible_lines:(index + 1))
              expected)
           "block extent changed for %d lines at %.0f/%.1f"
           (index + 1)
           width
           scale)
      block_extents;
    List.iter
      (fun (role, extent) ->
         let actual = Tokens.fixed_extent ~profile ~safe_bottom role in
         require
           (Float.equal actual extent)
           "role extent %.1f, expected %.1f at %.0f/%.1f"
           actual
           extent
           width
           scale)
      expected
  in
  check
    ~width:390.
    ~scale:1.
    ~safe_bottom:34.
    ~block_extents:[ 44.; 56.; 76.; 96. ]
    [ Tokens.Children_loading, 44.
    ; Tokens.Children_more, 44.
    ; Tokens.Day_heading, 36.
    ; Tokens.Day_continuation, 48.
    ; Tokens.Feed_continuation, 48.
    ; Tokens.Bottom_clearance, 102.
    ];
  check
    ~width:320.
    ~scale:3.2
    ~safe_bottom:0.
    ~block_extents:[ 80.; 144.; 208.; 272. ]
    [ Tokens.Children_loading, 80.
    ; Tokens.Children_more, 80.
    ; Tokens.Day_heading, 101.
    ; Tokens.Day_continuation, 92.
    ; Tokens.Feed_continuation, 92.
    ; Tokens.Bottom_clearance, 68.
    ]
;;

let test_header_context_copy_is_pure_product_state () =
  let today = Journal_header.Context.today ~subtitle:"Sunday, August 9" in
  require (Journal_header.Context.is_today today) "Today context lost its state";
  require
    (String.equal (Journal_header.Context.title today) "Today")
    "Today title changed";
  require
    (String.equal
       (Journal_header.Context.semantics_label today)
       "Today, Sunday, August 9")
    "Today semantics changed";
  let selected =
    Journal_header.Context.selected ~title:"August 8" ~subtitle:"Saturday, 2026"
  in
  require (not (Journal_header.Context.is_today selected)) "selected context became Today";
  require
    (String.equal (Journal_header.Context.title selected) "August 8")
    "selected title changed";
  require
    (String.equal (Journal_header.Context.subtitle selected) "Saturday, 2026")
    "selected subtitle changed"
;;

let tests =
  [ "light palette and interaction", test_light_palette_and_interaction_tokens
  ; "light high contrast", test_light_high_contrast_palette_is_explicit
  ; "exact status rail categories", test_every_exact_status_maps_to_the_decided_rail_category
  ; "timestamp contrast", test_timestamp_contrast_meets_small_text_target
  ; "Capture sheet palette and contrast", test_capture_sheet_palette_roles_and_contrast
  ; ( "typography, spacing, motion, and hit regions"
    , test_typography_spacing_motion_and_hit_regions )
  ; "one-physical-pixel dividers", test_dividers_resolve_to_one_physical_pixel
  ; "known row profiles", test_known_row_profile_selection
  ; "required row profile matrix", test_row_profiles_cover_required_width_and_scale_matrix
  ; ( "zero viewport and monotonic known extents"
    , test_zero_viewport_and_profile_growth_remain_known_extent )
  ; ( "authoritative role-specific exact extents"
    , test_every_sparse_role_has_one_authoritative_exact_extent )
  ; "header context", test_header_context_copy_is_pure_product_state
  ]
;;

let () =
  List.iter
    (fun (name, test) ->
       Printf.printf "running %s\n%!" name;
       test ())
    tests
;;
