module A = Logseq_db_types.Asset_descriptor

let get = function
  | Ok x -> x
  | Error e -> failwith e
;;

let uuid =
  get (Logseq_db_types.Graph_types.Uuid.of_string "00000000-0000-4000-8000-000000000001")
;;

let checksum = String.make 64 'a'

let invalid_version () =
  List.iter
    (fun (checksum, file_type) ->
       Alcotest.(check bool)
         "reject unsafe remote version"
         true
         (Result.is_error (A.version ~checksum ~file_type)))
    [ "", "png"
    ; "xyz", "png"
    ; checksum, "../png"
    ; checksum, ""
    ; checksum, "png?token=x"
    ; String.make 64 'Z', "png"
    ]
;;

let invalid_metadata () =
  List.iter
    (fun (size, dimensions, current_checksum) ->
       Alcotest.(check bool)
         "reject invalid metadata"
         true
         (Result.is_error
            (A.create ~uuid ~source:(Managed None) ~size ~dimensions ~current_checksum)))
    [ Some (-1L), None, None
    ; None, Some (0, 2), None
    ; None, Some (2, -1), None
    ; None, None, Some "invalid"
    ]
;;

let pending_version () =
  let remote = get (A.version ~checksum ~file_type:"png") in
  let asset =
    get
      (A.create
         ~uuid
         ~source:(Managed (Some remote))
         ~current_checksum:(Some (String.make 64 'b'))
         ~size:(Some 15L)
         ~dimensions:None)
  in
  match asset.source with
  | Managed (Some version) ->
    Alcotest.(check string) "retain published version" checksum version.checksum
  | _ -> Alcotest.fail "lost remote descriptor"
;;

let () =
  Alcotest.run
    "asset descriptor"
    [ ( "validation"
      , [ Alcotest.test_case "remote version" `Quick invalid_version
        ; Alcotest.test_case "metadata" `Quick invalid_metadata
        ; Alcotest.test_case "pending local version" `Quick pending_version
        ] )
    ]
;;
