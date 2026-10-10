module Tokens = Journal_visual_tokens
module Ui = Journal_view

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

(* Environment wire contract tests: the Apple host sends only product inputs,
   independent of native geometry and keyboard layout. *)
let environment_fields ~platform ~brightness ~high_contrast ~accessible_navigation =
  [ "platform", `String platform
  ; "brightness", `String brightness
  ; "highContrast", `Bool high_contrast
  ; "accessibleNavigation", `Bool accessible_navigation
  ]
;;

let test_four_field_environment_roundtrip () =
  List.iter
    (fun platform ->
       List.iter
         (fun (brightness, expected_brightness) ->
            List.iter
              (fun high_contrast ->
                 List.iter
                   (fun accessible_navigation ->
                      let fields =
                        environment_fields
                          ~platform
                          ~brightness
                          ~high_contrast
                          ~accessible_navigation
                      in
                      let snapshot =
                        match Journal_environment.decode_json (`Assoc fields) with
                        | Ok snapshot -> snapshot
                        | Error error ->
                          failwith ("four-field host sample rejected: " ^ error)
                      in
                      require
                        (snapshot.platform = platform
                         && snapshot.brightness = expected_brightness
                         && snapshot.high_contrast = high_contrast
                         && snapshot.accessible_navigation = accessible_navigation)
                        "host preference changed across environment decode";
                      match Journal_environment.encode_json snapshot with
                      | `Assoc encoded ->
                        require
                          (List.sort Stdlib.compare encoded
                           = List.sort Stdlib.compare fields)
                          "canonical host sample must round-trip without retired fields"
                      | _ -> failwith "environment encoder did not produce an object")
                   [ false; true ])
              [ false; true ])
         [ "light", Journal_environment.Light; "dark", Dark ])
    [ "ios"; "macos" ]
;;

let test_environment_requires_valid_product_inputs () =
  let fields =
    environment_fields
      ~platform:"ios"
      ~brightness:"light"
      ~high_contrast:false
      ~accessible_navigation:false
  in
  let rejected json =
    require
      (Result.is_error (Journal_environment.decode_json json))
      "incomplete or invalid environment sample was accepted"
  in
  List.iter
    (fun (key, _) ->
       rejected (`Assoc (List.remove_assoc key fields));
       rejected (`Assoc ((key, `Null) :: List.remove_assoc key fields)))
    fields;
  rejected
    (`Assoc (("brightness", `String "automatic") :: List.remove_assoc "brightness" fields));
  rejected `Null;
  rejected (`List [])
;;

let test_environment_preference_changes_are_observable () =
  let initial = Journal_environment.fallback in
  require (Journal_environment.equal initial initial) "identical sample must deduplicate";
  List.iter
    (fun changed ->
       require
         (not (Journal_environment.equal initial changed))
         "changed product preference must reach the application")
    [ { initial with platform = "ios" }
    ; { initial with brightness = Journal_environment.Dark }
    ; { initial with high_contrast = true }
    ; { initial with accessible_navigation = true }
    ]
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

let test_ios_capsules_mount_outside_toolbars () =
  let module V = Ui.View in
  List.iter
    (fun context ->
       List.iter
         (fun (capture_enabled, capture_expanded, account_available, error_available) ->
            let batches = ref [] in
            let presses = ref [] in
            let handler name =
              Ui.Event.Handler.create (fun _ -> presses := name :: !presses)
            in
            let backend : Lui_protocol.backend =
              { backend_profile = Lui_protocol.profile IOS SwiftUIHost
              ; apply_batch =
                  (fun batch ->
                    batches := batch :: !batches;
                    true)
              }
            in
            let view =
              Journal_header.view
                ~key:(Ui.Key.string "bottom-capsules")
                ~platform:"ios"
                ~context
                ~sync_phase:None
                ~sync_error:None
                ~on_error_info:
                  (if error_available then Some (handler "Error info") else None)
                ~on_account_action:
                  (if account_available
                   then Some (fun _ -> presses := "Account menu" :: !presses)
                   else None)
                ~local_deletion_available:false
                ~on_journals:(handler "Journals")
                ~on_favorites:(handler "Favorites")
                ~on_capture:(handler "Capture")
                ~capture_enabled
                ~capture_expanded
                ~body:(V.Body.static (V.text "Page content"))
            in
            let app =
              Lui_app.create_with_extensions
                backend
                Journal_lui_native.registry
                ()
                (fun () () -> ())
                (fun _context _model _send -> Ui.mount (V.Body.Private.to_widget view))
            in
            Fun.protect
              ~finally:(fun () -> ignore (Lui_app.dispose app))
              (fun () ->
                 require (Lui_app.start app) "Header did not start";
                 ignore (Lui_app.flush app);
                 let ops =
                   List.concat_map
                     (fun (batch : Lui_protocol.patch_batch) -> batch.ops)
                     (List.rev !batches)
                 in
                 let parents = Hashtbl.create 16 in
                 let toolbars = Hashtbl.create 4 in
                 List.iter
                   (function
                     | Lui_protocol.InsertChild (parent, child, _) ->
                       Hashtbl.replace parents child parent
                     | CreateNode (node, Toolbar) -> Hashtbl.replace toolbars node ()
                     | _ -> ())
                   ops;
                 require
                   (Hashtbl.length toolbars = 0)
                   "iOS page controls and title must not create toolbars";
                 let surfaces =
                   List.filter_map
                     (function
                       | Lui_protocol.SetProp (node, BackgroundValue, StringValue "glass")
                         -> Some node
                       | _ -> None)
                     ops
                   |> List.sort_uniq Int.compare
                 in
                 require
                   (List.length surfaces
                    = (if Option.is_none capture_expanded then 2 else 0)
                      + if account_available || error_available then 1 else 0)
                   "Each buttons composite must supply exactly one glass surface";
                 let rec in_toolbar node =
                   Hashtbl.mem toolbars node
                   || Option.fold
                        ~none:false
                        ~some:in_toolbar
                        (Hashtbl.find_opt parents node)
                 in
                 List.iter
                   (fun label ->
                      let nodes =
                        List.filter_map
                          (function
                            | Lui_protocol.SetProp
                                (node, AccessibilityLabel, StringValue value)
                              when value = label -> Some node
                            | _ -> None)
                          ops
                        |> List.sort_uniq Int.compare
                      in
                      match capture_expanded, nodes with
                      | Some _, [] -> ()
                      | None, [ node ] ->
                        require
                          (not (in_toolbar node))
                          "%s must render outside toolbar glass"
                          label;
                        List.iter
                          (fun property ->
                             require
                               (List.exists
                                  (function
                                    | Lui_protocol.SetProp (id, key, IntValue 44) ->
                                      id = node && key = property
                                    | _ -> false)
                                  ops)
                               "%s must retain a 44pt hit cell"
                               label)
                          [ Lui_protocol.WidthValue; HeightValue ];
                        require
                          (Lui_app.dispatch_event app (Lui_protocol.Press node))
                          "%s press was not delivered"
                          label;
                        ignore (Lui_app.flush app);
                        require
                          (List.mem label !presses
                           = (label <> "Capture" || capture_enabled))
                          "%s press guard changed"
                          label
                      | _ ->
                        failwith
                          (label ^ " must occur exactly once while Capture is closed"))
                   [ "Journals"; "Favorites"; "Capture" ];
                 if error_available
                 then (
                   let error =
                     List.find_map
                       (function
                         | Lui_protocol.SetProp
                             (node, AccessibilityLabel, StringValue "Error info") ->
                           Some node
                         | _ -> None)
                       ops
                     |> Option.get
                   in
                   require
                     (not (in_toolbar error))
                     "Error must render outside toolbar glass";
                   require
                     (Lui_app.dispatch_event app (Lui_protocol.Press error))
                     "Error press was not delivered";
                   ignore (Lui_app.flush app);
                   require (List.mem "Error info" !presses) "Error handler was lost");
                 let menus =
                   List.filter_map
                     (function
                       | Lui_protocol.CreateNode (node, MenuTrigger) -> Some node
                       | _ -> None)
                     ops
                 in
                 require
                   (List.length menus = if account_available then 1 else 0)
                   "Account must retain exactly one native menu trigger";
                 List.iter
                   (fun menu ->
                      require
                        (not (in_toolbar menu))
                        "Account must render outside toolbar glass")
                   menus))
         (List.concat_map
            (fun (capture_enabled, capture_expanded) ->
               List.map
                 (fun (account_available, error_available) ->
                    capture_enabled, capture_expanded, account_available, error_available)
                 [ false, false; true, false; false, true; true, true ])
            [ true, None; false, None; true, Some (V.text "Expanded Capture") ]))
    [ Journal_header.Context.journals; Journal_header.Context.favorites ]
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
            let regular = Tokens.status_colors regular status in
            let increased = Tokens.status_colors increased status in
            let symbol (palette : Tokens.status_colors) =
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

let test_detail_capsules_mount_outside_toolbars () =
  let module V = Ui.View in
  let root =
    Journal_model.create
      ~id:"70000000-0000-4000-a000-000000000001"
      ~page_id:"70000000-0000-4000-b000-000020260809"
      ~journal_day:20260809
      ~parent_id:None
      ~sibling_order:"a"
      ~source:"Detail fixture"
      ~task_state:Journal_model.No_status
      ~child_count:0
      ~creation_time:
        (Journal_time.create
           ~instant_unix_ms:1_786_204_800_000L
           ~local_day:20260809
           ~local_minute_of_day:0
         |> Result.get_ok)
      ~revision:"block-1"
      ~last_mutation_id:"70000000-0000-4000-9000-000000000001"
    |> Result.get_ok
  in
  let loading =
    Journal_routes.open_detail
      (Journal_routes.create ())
      ~block_id:(Journal_model.id root)
      ~request_generation:1L
  in
  let loaded =
    Journal_routes.apply_detail_response
      loading
      ~request_generation:1L
      { root; children = { blocks = []; continuation = None } }
  in
  List.iter
    (fun (routes, write_enabled, actions_enabled) ->
       let batches = ref []
       and actions = ref [] in
       let dispatch action = actions := action :: !actions in
       let view = Application.For_testing.detail_page ~routes ~write_enabled dispatch in
       let backend : Lui_protocol.backend =
         { backend_profile = Lui_protocol.profile IOS SwiftUIHost
         ; apply_batch =
             (fun batch ->
               batches := batch :: !batches;
               true)
         }
       in
       let app =
         Lui_app.create_with_extensions
           backend
           Journal_lui_native.registry
           ()
           (fun () () -> ())
           (fun _context _model _send -> Ui.mount (V.Body.Private.to_widget view))
       in
       Fun.protect
         ~finally:(fun () -> ignore (Lui_app.dispose app))
         (fun () ->
            require (Lui_app.start app) "Detail did not start";
            ignore (Lui_app.flush app);
            let ops =
              List.concat_map
                (fun (batch : Lui_protocol.patch_batch) -> batch.ops)
                (List.rev !batches)
            in
            require
              (not
                 (List.exists
                    (function
                      | Lui_protocol.CreateNode (_, Toolbar) -> true
                      | _ -> false)
                    ops))
              "Detail controls must render outside toolbar glass";
            let surfaces =
              List.filter_map
                (function
                  | Lui_protocol.SetProp (node, BackgroundValue, StringValue "glass") ->
                    Some node
                  | _ -> None)
                ops
              |> List.sort_uniq Int.compare
            in
            require
              (List.length surfaces = 1)
              "Detail must have one action capsule; native navigation supplies Back";
            List.iter
              (fun (label, command, allowed) ->
                 let nodes =
                   List.filter_map
                     (function
                       | Lui_protocol.SetProp (node, AccessibilityLabel, StringValue value)
                         when value = label -> Some node
                       | _ -> None)
                     ops
                   |> List.sort_uniq Int.compare
                 in
                 require (List.length nodes = 1) "%s must appear exactly once" label;
                 let node = List.hd nodes in
                 List.iter
                   (fun property ->
                      require
                        (List.exists
                           (function
                             | Lui_protocol.SetProp (id, key, IntValue 44) ->
                               id = node && key = property
                             | _ -> false)
                           ops)
                        "%s must retain a 44pt hit cell"
                        label)
                   [ Lui_protocol.WidthValue; HeightValue ];
                 require
                   (Lui_app.dispatch_event app (Lui_protocol.Press node))
                   "%s press was not delivered"
                   label;
                 ignore (Lui_app.flush app);
                 require
                   (List.mem command !actions = allowed)
                   "%s action guard changed"
                   label)
              [ "Capture", Application.For_testing.Append, actions_enabled ]))
    [ loading, true, false; loaded, false, false; loaded, true, true ]
;;

let tests =
  [ "four-field environment roundtrip", test_four_field_environment_roundtrip
  ; ( "environment requires valid product inputs"
    , test_environment_requires_valid_product_inputs )
  ; ( "environment preference changes are observable"
    , test_environment_preference_changes_are_observable )
  ; ( "SF Symbols preserve identity and appearance"
    , test_sf_symbols_preserve_identity_and_appearance )
  ; ( "exact status rail categories"
    , test_every_exact_status_maps_to_the_decided_rail_category )
  ; "header context", test_header_context_copy_is_pure_product_state
  ; "iOS capsules outside toolbars", test_ios_capsules_mount_outside_toolbars
  ; "detail capsules outside toolbars", test_detail_capsules_mount_outside_toolbars
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
