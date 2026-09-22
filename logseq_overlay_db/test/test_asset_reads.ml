module D = Logseq_overlay_db.Database
module Types = Logseq_overlay_db.Types
module T = Test_support
module G = Logseq_db_types.Graph_types
module A = Logseq_db_types.Asset_descriptor
module Transit = Transit_core.Json
module Codec = Transit_native.Transit.Json

let id n = T.uuid (Printf.sprintf "78000000-0000-4000-8000-%012d" n)
let get x = T.require_ok ~behavior:"asset discovery" x
let add n a v = Transit.Array [ Keyword "db/add"; Int (40000 + n); Keyword a; v ]

let apply database number ops =
  let transaction =
    Codec.to_string ~mode:Codec.Verbose (Transit.Array ops)
    |> Types.encoded_transaction_of_string ~maximum_bytes:4194304
    |> get
  in
  let cursor =
    Types.Server_cursor.of_string (Printf.sprintf "server-cursor:v1:%d" number) |> get
  in
  let batch =
    Types.authoritative_batch
      ~maximum_count:16
      ~maximum_bytes:4194304
      ~transactions:[ Types.authoritative_transaction ~cursor ~transaction ]
      ~through:cursor
      ~checksum:None
    |> get
  in
  let sync = D.inspect_sync database |> get in
  let preparation, crypto =
    D.begin_authoritative database ~expected:(Types.sync_view_token sync) batch |> get
  in
  let decrypted = Option.map (fun r -> r, D.unprotection_ciphertexts r) crypto in
  match D.apply_authoritative database preparation ~decrypted |> get with
  | D.Authoritative_applied _ -> ()
  | _ -> Alcotest.fail "fixture deferred"
;;

let seed database =
  let lookup name = Transit.Array [ Keyword "db/ident"; Keyword name ] in
  let asset n =
    [ add n "block/uuid" (Uuid (G.Uuid.to_string (id n)))
    ; add n "block/title" (String "Image")
    ; add n "block/tags" (lookup "logseq.class/Asset")
    ; add n "logseq.property.asset/type" (String "png")
    ; add n "logseq.property.asset/checksum" (String (String.make 64 'b'))
    ; add
        n
        "logseq.property.asset/remote-metadata"
        (Map
           [ Keyword "checksum", String (String.make 64 'a')
           ; Keyword "type", String "png"
           ])
    ]
  in
  let page n =
    [ add n "block/uuid" (Uuid (G.Uuid.to_string (id n)))
    ; add n "block/name" (String ("asset-page-" ^ string_of_int n))
    ; add n "block/title" (String "Page")
    ]
  in
  let block n parent =
    [ add n "block/uuid" (Uuid (G.Uuid.to_string (id n)))
    ; add n "block/title" (String "Block")
    ; add n "block/parent" (Int (40000 + parent))
    ; add n "block/page" (Int 40000)
    ; add n "block/order" (String ("a" ^ string_of_int n))
    ]
  in
  apply
    database
    1
    (page 0
     @ page 9
     @ block 1 0
     @ block 2 1
     @ asset 3
     @ asset 4
     @ asset 5
     @ asset 6
     @ [ add 1 "block/refs" (Int 40003)
       ; add 2 "logseq.property/asset" (Int 40004)
       ; add 1 "block/refs" (Int 40009)
       ; add 9 "logseq.property/asset" (Int 40005)
       ; add 0 "logseq.property/asset" (Int 40006)
       ])
;;

let with_snapshot database f =
  let s = D.current_snapshot database |> get in
  Fun.protect ~finally:(fun () -> D.release_snapshot s) (fun () -> f s)
;;

let collect ?(recursive = true) snapshot roots =
  let rec loop cursor acc count =
    T.require (count < 200) "asset cursor never terminates";
    let page =
      D.get_assets_under_roots snapshot ~recursive ~roots ~limit:1 ~cursor |> get
    in
    T.require (List.length page.assets <= 1) "asset page overflow";
    let acc = List.rev_append page.assets acc in
    match page.next_cursor with
    | None -> acc
    | Some _ as cursor -> loop cursor acc (count + 1)
  in
  loop None [] 0 |> List.map (fun a -> a.A.uuid) |> List.sort_uniq G.Uuid.compare
;;

let discovery database =
  seed database;
  with_snapshot database (fun snapshot ->
    Alcotest.(check bool)
      "subtree and page properties without ordinary links"
      true
      (collect snapshot [ id 0 ] = [ id 3; id 4; id 6 ]);
    Alcotest.(check bool)
      "favorite block includes descendants"
      true
      (collect snapshot [ id 1 ] = [ id 3; id 4 ]);
    match D.get_asset_descriptors snapshot [ id 3 ] |> get with
    | [ { A.source = Managed (Some version); current_checksum = Some current; _ } ] ->
      Alcotest.(check string)
        "remote descriptor selected"
        (String.make 64 'a')
        version.checksum;
      Alcotest.(check string) "pending version retained" (String.make 64 'b') current
    | _ -> Alcotest.fail "asset descriptor missing")
;;

let direct_assets database =
  seed database;
  with_snapshot database (fun snapshot ->
    Alcotest.(check bool)
      "visible page excludes descendant assets"
      true
      (collect ~recursive:false snapshot [ id 0 ] = [ id 6 ]);
    Alcotest.(check bool)
      "visible block excludes collapsed children and ordinary links"
      true
      (collect ~recursive:false snapshot [ id 1 ] = [ id 3 ]);
    Alcotest.(check bool)
      "visible asset resolves itself"
      true
      (collect ~recursive:false snapshot [ id 3 ] = [ id 3 ]);
    let first =
      D.get_assets_under_roots
        snapshot
        ~recursive:true
        ~roots:[ id 0 ]
        ~limit:1
        ~cursor:None
      |> get
    in
    Alcotest.(check bool)
      "cursor cannot change discovery scope"
      true
      (Result.is_error
         (D.get_assets_under_roots
            snapshot
            ~recursive:false
            ~roots:[ id 0 ]
            ~limit:1
            ~cursor:first.next_cursor)))
;;

let stale database =
  seed database;
  with_snapshot database (fun old ->
    let first =
      D.get_assets_under_roots old ~recursive:true ~roots:[ id 0 ] ~limit:1 ~cursor:None
      |> get
    in
    T.require (Option.is_some first.next_cursor) "missing bounded continuation";
    (match
       D.get_assets_under_roots
         old
         ~recursive:true
         ~roots:[ id 9 ]
         ~limit:1
         ~cursor:first.next_cursor
     with
     | Error (Types.Invalid_read_request _) -> ()
     | _ -> Alcotest.fail "cursor escaped selected roots");
    apply database 2 [ add 1 "block/title" (String "Changed") ];
    with_snapshot database (fun current ->
      match
        D.get_assets_under_roots
          current
          ~recursive:true
          ~roots:[ id 0 ]
          ~limit:1
          ~cursor:first.next_cursor
      with
      | Error Types.Stale_read_cursor -> ()
      | _ -> Alcotest.fail "stale cursor accepted"))
;;

let deletion database =
  seed database;
  with_snapshot database (fun before ->
    let revision =
      match D.get_blocks before [ id 1 ] |> get with
      | [ Types.Present_block b ] -> b.revision
      | _ -> Alcotest.fail "missing block"
    in
    let expected =
      D.write_precondition ~blocks:[ id 1, revision ] ~pages:[] ~scopes:[] |> get
    in
    ignore
      (D.commit_local
         database
         ~expected
         (Types.Delete_blocks { mutation_id = T.mutation_uuid 980; root = id 1 })
       |> get);
    with_snapshot database (fun after ->
      Alcotest.(check bool)
        "effective overlay excludes deleted subtree"
        true
        (collect after [ id 0 ] = [ id 6 ]));
    Alcotest.(check bool)
      "pinned projection unchanged"
      true
      (collect before [ id 0 ] = [ id 3; id 4; id 6 ]))
;;

let large_reference_set database =
  seed database;
  let class_ref = Transit.Array [ Keyword "db/ident"; Keyword "logseq.class/Asset" ] in
  let assets =
    List.init 210 (fun offset ->
      let n = 100 + offset in
      [ add n "block/uuid" (Uuid (G.Uuid.to_string (id n)))
      ; add n "block/tags" class_ref
      ; add
          n
          "logseq.property.asset/remote-metadata"
          (Map
             [ Keyword "checksum", String (String.make 64 'a')
             ; Keyword "type", String "png"
             ])
      ; add 1 "block/refs" (Int (40000 + n))
      ])
    |> List.concat
  in
  apply database 2 assets;
  with_snapshot database (fun snapshot ->
    let rec pages cursor all empty count =
      T.require (count < 1000) "large asset enumeration failed to terminate";
      let page =
        D.get_assets_under_roots snapshot ~recursive:true ~roots:[ id 0 ] ~limit:1 ~cursor
        |> get
      in
      T.require (List.length page.assets <= 1) "large query exceeded page bound";
      let all = List.rev_append page.assets all in
      let empty = empty || (page.assets = [] && Option.is_some page.next_cursor) in
      match page.next_cursor with
      | None -> all, empty
      | cursor -> pages cursor all empty (count + 1)
    in
    let all, _ = pages None [] false 0 in
    let unique = List.map (fun a -> a.A.uuid) all |> List.sort_uniq G.Uuid.compare in
    Alcotest.(check int)
      "complete references beyond UI result limits"
      213
      (List.length unique))
;;

let local_asset_import database =
  seed database;
  let version = A.version ~checksum:(String.make 64 'c') ~file_type:"png" |> get in
  let mutation =
    Types.Insert_blocks
      { mutation_id = T.mutation_uuid 990
      ; parent = id 0
      ; tree = { uuid = id 90; title = "Local image"; children = [] }
      ; asset = Some { replace_reference = None; version; size = 7L }
      }
  in
  let expected = T.insert_precondition database ~parent:(id 0) ~behavior:"import asset" in
  T.require
    (D.inspect_local_mutation database mutation |> get = None)
    "fresh import has a receipt";
  ignore (D.commit_local database ~expected mutation |> get);
  T.require
    (Option.is_some (D.inspect_local_mutation database mutation |> get))
    "durable import receipt missing";
  with_snapshot database (fun snapshot ->
    match D.get_asset_descriptors snapshot [ id 90 ] |> get with
    | [ { A.uuid
        ; source = Managed None
        ; current_checksum = Some checksum
        ; size = Some 7L
        ; _
        }
      ] ->
      T.require
        (uuid = id 90 && checksum = version.checksum)
        "local asset metadata differs from staged source";
      T.require
        (List.mem (id 90) (collect snapshot [ id 0 ]))
        "local asset missing from subtree"
    | _ -> Alcotest.fail "pending asset descriptor missing");
  ignore (D.commit_local database ~expected mutation |> get);
  with_snapshot database (fun snapshot ->
    T.require
      (List.length (D.get_asset_descriptors snapshot [ id 90 ] |> get) = 1)
      "duplicate import created another asset");
  let expected =
    with_snapshot database (fun snapshot ->
      match D.get_blocks snapshot [ id 90 ] |> get with
      | [ Types.Present_block b ] ->
        D.write_precondition ~blocks:[ id 90, b.revision ] ~pages:[] ~scopes:[] |> get
      | _ -> Alcotest.fail "imported asset block missing")
  in
  ignore
    (D.publish_asset_metadata
       database
       ~expected
       ~mutation_id:(T.mutation_uuid 991)
       ~asset:(id 90)
       ~version
     |> get);
  with_snapshot database (fun snapshot ->
    match D.get_asset_descriptors snapshot [ id 90 ] |> get with
    | [ { A.source = Managed (Some actual); _ } ] ->
      T.require (actual = version) "published metadata differs from uploaded version"
    | _ -> Alcotest.fail "uploaded metadata missing")
;;

let reuse_asset_reference database =
  seed database;
  let expected block =
    with_snapshot database (fun snapshot ->
      match D.get_blocks snapshot [ block ] |> get with
      | [ Types.Present_block b ] ->
        D.write_precondition ~blocks:[ block, b.revision ] ~pages:[] ~scopes:[] |> get
      | _ -> Alcotest.fail "reference holder missing")
  in
  let before =
    with_snapshot database (fun s -> D.get_asset_descriptors s [ id 3; id 4 ] |> get)
  in
  let first_precondition = expected (id 1) in
  let link ~mutation_id ~expected ~previous ~asset =
    D.set_asset_reference database ~expected ~mutation_id ~block:(id 1) ~previous ~asset
  in
  ignore
    (link
       ~mutation_id:(T.mutation_uuid 992)
       ~expected:first_precondition
       ~previous:None
       ~asset:(id 4)
     |> get);
  with_snapshot database (fun s ->
    T.require
      (collect ~recursive:false s [ id 1 ] = [ id 3; id 4 ])
      "new reference is not discoverable";
    T.require
      (D.get_asset_descriptors s [ id 3; id 4 ] |> get = before)
      "reference reuse changed asset metadata");
  (match
     link
       ~mutation_id:(T.mutation_uuid 992)
       ~expected:first_precondition
       ~previous:None
       ~asset:(id 4)
     |> get
   with
   | Types.Local_existing (Existing_applied _) -> ()
   | _ -> Alcotest.fail "reference retry was not idempotent");
  T.require
    (Result.is_error
       (link
          ~mutation_id:(T.mutation_uuid 993)
          ~expected:(expected (id 1))
          ~previous:None
          ~asset:(id 3)))
    "stale reference intent overwrote the current reference";
  T.require
    (Result.is_error
       (link
          ~mutation_id:(T.mutation_uuid 994)
          ~expected:(expected (id 1))
          ~previous:(Some (id 4))
          ~asset:(id 9)))
    "ordinary page was accepted as an asset";
  ignore
    (link
       ~mutation_id:(T.mutation_uuid 995)
       ~expected:(expected (id 1))
       ~previous:(Some (id 4))
       ~asset:(id 3)
     |> get);
  with_snapshot database (fun s ->
    T.require
      (collect ~recursive:false s [ id 1 ] = [ id 3 ])
      "intended reference did not change";
    T.require
      (collect ~recursive:false s [ id 2 ] = [ id 4 ])
      "replacement changed another holder";
    T.require
      (D.get_asset_descriptors s [ id 3; id 4 ] |> get = before)
      "replacement mutated the old asset")
;;

let reference_pending_asset database =
  local_asset_import database;
  let expected =
    with_snapshot database (fun s ->
      match D.get_blocks s [ id 1 ] |> get with
      | [ Types.Present_block holder ] ->
        D.write_precondition ~blocks:[ id 1, holder.revision ] ~pages:[] ~scopes:[] |> get
      | _ -> Alcotest.fail "holder missing")
  in
  ignore
    (D.set_asset_reference
       database
       ~expected
       ~mutation_id:(T.mutation_uuid 996)
       ~block:(id 1)
       ~previous:None
       ~asset:(id 90)
     |> get);
  with_snapshot database (fun s ->
    T.require
      (collect ~recursive:false s [ id 1 ] = [ id 3; id 90 ])
      "reference to a local asset without a remote entity was lost")
;;

let replace_asset_binary database =
  seed database;
  apply database 2 [ add 1 "logseq.property/asset" (Int 40004) ];
  let parent = id 2 in
  let version = A.version ~checksum:(String.make 64 'd') ~file_type:"pdf" |> get in
  let expected =
    with_snapshot database (fun snapshot ->
      let revision =
        match D.get_blocks snapshot [ parent ] |> get with
        | [ Types.Present_block holder ] -> holder.revision
        | _ -> Alcotest.fail "replacement holder missing"
      in
      match
        D.get_structure snapshot (Types.Children { parent; limit = 1; cursor = None })
        |> get
      with
      | Types.Children_result { revision_scope; scope_revision; _ } ->
        D.write_precondition
          ~blocks:[ parent, revision ]
          ~pages:[]
          ~scopes:[ revision_scope, scope_revision ]
        |> get
      | _ -> Alcotest.fail "replacement children missing")
  in
  let old = with_snapshot database (fun s -> D.get_asset_descriptors s [ id 4 ] |> get) in
  let mutation =
    Types.Insert_blocks
      { mutation_id = T.mutation_uuid 997
      ; parent
      ; tree = { uuid = id 91; title = "Replacement PDF"; children = [] }
      ; asset = Some { version; size = 5L; replace_reference = Some (id 4) }
      }
  in
  let stale =
    match mutation with
    | Types.Insert_blocks fields ->
      Types.Insert_blocks
        { fields with
          asset = Some { version; size = 5L; replace_reference = Some (id 3) }
        }
    | _ -> assert false
  in
  T.require
    (Result.is_error (D.commit_local database ~expected stale))
    "stale binary replacement was accepted";
  with_snapshot database (fun s ->
    T.require
      (D.get_asset_descriptors s [ id 91 ] |> get = [])
      "failed replacement left an orphan asset");
  ignore (D.commit_local database ~expected mutation |> get);
  with_snapshot database (fun s ->
    T.require
      (collect ~recursive:false s [ parent ] = [ id 91 ])
      "binary replacement did not atomically redirect the intended reference";
    T.require
      (collect ~recursive:false s [ id 1 ] = [ id 3; id 4 ])
      "binary replacement changed another holder";
    T.require
      (D.get_asset_descriptors s [ id 4 ] |> get = old)
      "binary replacement overwrote the old asset");
  match D.commit_local database ~expected mutation |> get with
  | Types.Local_existing (Existing_applied _) -> ()
  | _ -> Alcotest.fail "binary replacement retry duplicated insertion"
;;

let reference_replan database =
  reuse_asset_reference database;
  apply database 2 [ add 1 "logseq.property/asset" (Int 40005) ];
  with_snapshot database (fun s ->
    T.require
      (collect ~recursive:false s [ id 1 ] = [ id 3; id 5 ])
      "queued replacement overwrote a remote reference edit";
    T.require
      (collect ~recursive:false s [ id 2 ] = [ id 4 ])
      "remote replanning changed another reference")
;;

let replacement_replan database =
  replace_asset_binary database;
  apply database 3 [ add 2 "logseq.property/asset" (Int 40005) ];
  with_snapshot database (fun s ->
    T.require
      (collect ~recursive:false s [ id 2 ] = [ id 5 ])
      "binary replacement overwrote remote reference";
    T.require
      (D.get_asset_descriptors s [ id 91 ] |> get = [])
      "blocked atomic replacement retained an orphan insertion")
;;

let restore_binary_replacement () =
  T.with_temp_directory "asset-replacement-restart" (fun support ->
    ignore (T.seed_mirror support);
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let open_db () =
          let inspection =
            D.inspect_mirror ~application_support_directory:support ~graph_id:T.graph_uuid
            |> get
          in
          D.open_
            ~sw
            (T.dependencies ~behavior:"binary replacement restart")
            inspection
            ~graph_name:"replacement restart"
          |> get
        in
        let database = open_db () in
        replace_asset_binary database;
        D.close database |> get;
        let restored = open_db () in
        Fun.protect
          ~finally:(fun () -> D.close restored |> get)
          (fun () ->
             with_snapshot restored (fun s ->
               T.require
                 (collect ~recursive:false s [ id 2 ] = [ id 91 ])
                 "restart lost the atomic replacement";
               T.require
                 (collect ~recursive:false s [ id 1 ] = [ id 3; id 4 ])
                 "restart modified another holder")))))
;;

let restore_asset_references () =
  T.with_temp_directory "asset-reference-restart" (fun support ->
    ignore (T.seed_mirror support);
    let dependencies = T.dependencies ~behavior:"asset reference restart" in
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let open_database () =
          let inspection =
            D.inspect_mirror ~application_support_directory:support ~graph_id:T.graph_uuid
            |> get
          in
          D.open_ ~sw dependencies inspection ~graph_name:"reference restart" |> get
        in
        let database = open_database () in
        reuse_asset_reference database;
        D.close database |> get;
        let restored = open_database () in
        Fun.protect
          ~finally:(fun () -> D.close restored |> get)
          (fun () ->
             with_snapshot restored (fun s ->
               T.require
                 (collect ~recursive:false s [ id 1 ] = [ id 3 ])
                 "restored reference differs";
               T.require
                 (collect ~recursive:false s [ id 2 ] = [ id 4 ])
                 "restored unrelated reference differs");
             apply restored 2 [ add 1 "logseq.property/asset" (Int 40005) ];
             with_snapshot restored (fun s ->
               T.require
                 (collect ~recursive:false s [ id 1 ] = [ id 3; id 5 ])
                 "restored intent overwrote remote reference")))))
;;

let restore_asset_mutations () =
  T.with_temp_directory "asset-outbox-restart" (fun support ->
    ignore (T.seed_mirror support);
    let dependencies = T.dependencies ~behavior:"asset outbox restart" in
    Eio_main.run (fun _ ->
      Eio.Switch.run (fun sw ->
        let open_database () =
          let inspection =
            D.inspect_mirror ~application_support_directory:support ~graph_id:T.graph_uuid
            |> get
          in
          D.open_ ~sw dependencies inspection ~graph_name:"asset restart" |> get
        in
        let database = open_database () in
        local_asset_import database;
        D.close database |> get;
        let restored = open_database () in
        Fun.protect
          ~finally:(fun () -> D.close restored |> get)
          (fun () ->
             with_snapshot restored (fun snapshot ->
               match D.get_asset_descriptors snapshot [ id 90 ] |> get with
               | [ { A.source = Managed (Some version); size = Some 7L; _ } ] ->
                 T.require
                   (version.checksum = String.make 64 'c')
                   "restored upload version changed";
                 T.require
                   (List.mem (id 90) (collect snapshot [ id 0 ]))
                   "restored attachment missing"
               | _ -> Alcotest.fail "asset mutations did not survive reopen")))))
;;

let () =
  Alcotest.run
    "asset reads"
    [ ( "durable asset mutations"
      , [ Alcotest.test_case "reopen pending outbox" `Quick restore_asset_mutations
        ; Alcotest.test_case "reopen references" `Quick restore_asset_references
        ; Alcotest.test_case "reopen replacement" `Quick restore_binary_replacement
        ] )
    ; ( "bounded graph metadata"
      , List.map
          (fun (n, f) -> T.database_case n f)
          [ "replacement remote conflict", replacement_replan
          ; "atomic binary replacement", replace_asset_binary
          ; "reference to local asset", reference_pending_asset
          ; "reference remote conflict", reference_replan
          ; "reuse asset reference", reuse_asset_reference
          ; "direct visible assets", direct_assets
          ; "local asset import", local_asset_import
          ; "direct and subtree discovery", discovery
          ; "cursor fences", stale
          ; "effective overlay", deletion
          ; "complete large reference set", large_reference_set
          ] )
    ]
;;
