module Tokens = Journal_visual_tokens
module Ui = Bonsai_flutter_ui

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let test_material_icon_catalog_matches_flutter_3_44_8 () =
  let cases =
    Material_icon_catalog.
      [ Account_circle, 0xe043
      ; Add, 0xe047
      ; Arrow_upward, 0xe0a0
      ; Chevron_left, 0xe15e
      ; Chevron_right, 0xe15f
      ; Circle, 0xe163
      ; Delete, 0xe1b9
      ; Expand_more, 0xe246
      ; Refresh, 0xe514
      ]
  in
  List.iter
    (fun (role, expected_code_point) ->
       let color = Ui.Style.Color.rgb ~red:17 ~green:34 ~blue:51 in
       let key = Ui.Key.string (Printf.sprintf "material-icon:%x" expected_code_point) in
       let widget = Material_icon_catalog.create ~key ~size:19. ~color role in
       let (Av view) = Ui.Widget.Private.view widget in
       (match view.node with
        | Ui.Widget.Private.Icon
            { code_point; font_family = Some font_family; size; color = Some argb } ->
          require
            (code_point = expected_code_point)
            "catalog role resolved to U+%04X instead of U+%04X"
            code_point
            expected_code_point;
          require
            (String.equal font_family "MaterialIcons")
            "catalog role uses font family %S"
            font_family;
          require (size = Some 19.) "catalog role did not preserve its requested size";
          require
            (Int32.equal argb 0xff112233l)
            "catalog role did not preserve its requested color"
        | Icon _ -> failwith "catalog role omitted required icon properties"
        | _ -> failwith "catalog role did not produce an icon");
       require
         (Option.equal Ui.Key.equal (Ui.Widget.For_testing.key widget) (Some key))
         "catalog role did not preserve its requested key")
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

let test_typography_spacing_motion_and_hit_regions () =
  let typography = Tokens.typography Tokens.Balanced in
  require
    (typography.header_title.font_size = 22.
     && typography.header_title.line_height = 28.
     && typography.header_title.weight = Ui.Style.Font_weight.Semi_bold)
    "header title typography changed";
  require
    (typography.entry.font_size = 16.
     && typography.entry.line_height = 22.
     && typography.entry.weight = Ui.Style.Font_weight.Normal)
    "entry typography changed";
  require
    (typography.supporting.font_size = 14.
     && typography.supporting.line_height = 20.
     && typography.supporting.weight = Ui.Style.Font_weight.Normal)
    "supporting typography changed";
  require
    (typography.timestamp.font_size = 13.
     && typography.timestamp.line_height = 18.
     && typography.timestamp.weight = Ui.Style.Font_weight.Normal)
    "timestamp typography changed";
  List.iter
    (fun preset ->
       let input = (Tokens.typography preset).input in
       require
         (input.font_size = 16.
          && input.line_height = 24.
          && input.weight = Ui.Style.Font_weight.Normal)
         "text input typography changed")
    [ Tokens.Dense; Balanced; Comfortable ];
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
    (composer.horizontal_margin = 12. && composer.maximum_lines = 5)
    "Capture affordance geometry tokens changed";
  let standard = Tokens.motion ~reduced_motion:false in
  let reduced = Tokens.motion ~reduced_motion:true in
  require
    (standard.press_release_ms = 80 && standard.route_transition_ms = 180)
    "standard motion tokens changed";
  require
    (reduced.press_release_ms = 0 && reduced.route_transition_ms = 0)
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
  let profile =
    Tokens.select_row_profile
      ~preset:Tokens.Balanced
      ~viewport_width:width
      ~text_scale:scale
  in
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
    ~block_line_height:28.6
    ~continuation_extent:54.
    ~day_header_extent:36.
    ~content_leading:32.
    ~time_slot_width:52.;
  require_profile
    ~width:359.
    ~scale:1.
    ~kind:Tokens.Adaptive
    ~block_line_height:22.
    ~continuation_extent:48.
    ~day_header_extent:44.
    ~content_leading:24.
    ~time_slot_width:52.;
  require_profile
    ~width:390.
    ~scale:1.3
    ~kind:Tokens.Compact
    ~block_line_height:28.6
    ~continuation_extent:54.
    ~day_header_extent:36.
    ~content_leading:32.
    ~time_slot_width:52.;
  require_profile
    ~width:744.
    ~scale:2.
    ~kind:Tokens.Adaptive
    ~block_line_height:44.
    ~continuation_extent:68.
    ~day_header_extent:64.
    ~content_leading:32.
    ~time_slot_width:104.;
  require_profile
    ~width:1_200.
    ~scale:3.2
    ~kind:Tokens.Adaptive
    ~block_line_height:70.4
    ~continuation_extent:92.
    ~day_header_extent:88.
    ~content_leading:32.
    ~time_slot_width:167.
;;

let test_row_profiles_cover_required_width_and_scale_matrix () =
  let cases =
    [ 320., 1., Tokens.Adaptive, 22., 48., 44., 24., 52.
    ; 320., 1.3, Tokens.Adaptive, 28.6, 54., 50., 24., 68.
    ; 320., 2., Tokens.Adaptive, 44., 68., 64., 24., 104.
    ; 320., 3.2, Tokens.Adaptive, 70.4, 92., 88., 24., 167.
    ; 390., 1., Tokens.Compact, 22., 48., 36., 32., 52.
    ; 390., 1.3, Tokens.Compact, 28.6, 54., 36., 32., 52.
    ; 390., 2., Tokens.Adaptive, 44., 68., 64., 32., 104.
    ; 390., 3.2, Tokens.Adaptive, 70.4, 92., 88., 32., 167.
    ; 744., 1., Tokens.Compact, 22., 48., 36., 32., 52.
    ; 744., 1.3, Tokens.Compact, 28.6, 54., 36., 32., 52.
    ; 744., 2., Tokens.Adaptive, 44., 68., 64., 32., 104.
    ; 744., 3.2, Tokens.Adaptive, 70.4, 92., 88., 32., 167.
    ; 1_200., 1., Tokens.Compact, 22., 48., 36., 32., 52.
    ; 1_200., 1.3, Tokens.Compact, 28.6, 54., 36., 32., 52.
    ; 1_200., 2., Tokens.Adaptive, 44., 68., 64., 32., 104.
    ; 1_200., 3.2, Tokens.Adaptive, 70.4, 92., 88., 32., 167.
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
    ~block_line_height:22.
    ~continuation_extent:48.
    ~day_header_extent:44.
    ~content_leading:24.
    ~time_slot_width:52.;
  let scales = [ 1.; 1.3; 2.; 3.2 ] in
  let profiles =
    List.map
      (fun text_scale ->
         Tokens.select_row_profile
           ~preset:Tokens.Balanced
           ~viewport_width:320.
           ~text_scale)
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
  let check ~width ~scale ~block_extents expected =
    let profile =
      Tokens.select_row_profile
        ~preset:Tokens.Balanced
        ~viewport_width:width
        ~text_scale:scale
    in
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
         let actual = Tokens.fixed_extent ~profile role in
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
    ~block_extents:[ 44.; 60.; 82.; 104. ]
    [ Tokens.Children_loading, 44.
    ; Tokens.Children_more, 44.
    ; Tokens.Day_heading, 36.
    ; Tokens.Day_continuation, 48.
    ; Tokens.Feed_continuation, 48.
    ];
  check
    ~width:320.
    ~scale:3.2
    ~block_extents:[ 87.; 157.; 228.; 298. ]
    [ Tokens.Children_loading, 87.
    ; Tokens.Children_more, 87.
    ; Tokens.Day_heading, 88.
    ; Tokens.Day_continuation, 92.
    ; Tokens.Feed_continuation, 92.
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
  [ ( "Material icon catalog matches Flutter 3.44.8"
    , test_material_icon_catalog_matches_flutter_3_44_8 )
  ; ( "exact status rail categories"
    , test_every_exact_status_maps_to_the_decided_rail_category )
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
