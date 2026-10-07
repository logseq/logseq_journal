(* Cache filesystem scenarios run through Core.step/Effect_runner.submit in
   runner_contract and transport_contract. This existing test entry checks the
   public compiler boundary, without including implementation/private CMIs. *)
let rec repository_root directory =
  if Sys.file_exists (Filename.concat directory ".git")
  then directory
  else (
    let parent = Filename.dirname directory in
    if parent = directory
    then failwith "repository root not found"
    else repository_root parent)
;;

let read_file path = In_channel.with_open_bin path In_channel.input_all

let contains text part =
  let rec loop offset =
    offset + String.length part <= String.length text
    && (String.sub text offset (String.length part) = part || loop (offset + 1))
  in
  loop 0
;;

let compile root source =
  let filename = Filename.temp_file "sync-public-boundary" ".ml" in
  let log = filename ^ ".log" in
  let output = filename ^ ".cmo" in
  let interface = filename ^ ".cmi" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun file -> if Sys.file_exists file then Sys.remove file)
        [ filename; log; output; interface ])
    (fun () ->
       Out_channel.with_open_bin filename (fun channel -> output_string channel source);
       let directories =
         [ "logseq_sync/spec/pure_reducer/.logseq_sync_pure_reducer.objs/byte"
         ; "logseq_sync/spec/effect_runner/.logseq_sync_effect_runner.objs/byte"
         ; "logseq_db_types/lib/.logseq_db_types.objs/byte"
         ]
         |> List.map (Filename.concat (Filename.concat root "_build/default"))
       in
       let arguments =
         Array.of_list
           (("ocamlc"
             :: "-c"
             :: "-o"
             :: output
             :: List.concat_map (fun directory -> [ "-I"; directory ]) directories)
            @ [ filename ])
       in
       let fd = Unix.openfile log [ Unix.O_CREAT; Unix.O_TRUNC; Unix.O_WRONLY ] 0o600 in
       let process = Unix.create_process "ocamlc" arguments Unix.stdin fd fd in
       Unix.close fd;
       let _, status = Unix.waitpid [] process in
       status, read_file log)
;;

let positive root source =
  let status, diagnostics = compile root source in
  Alcotest.(check bool) diagnostics true (status = Unix.WEXITED 0)
;;

let negative root source reason =
  let status, diagnostics = compile root source in
  Alcotest.(check bool) ("must fail: " ^ source) false (status = Unix.WEXITED 0);
  Alcotest.(check bool)
    ("rejected at intended boundary: " ^ diagnostics)
    true
    (contains diagnostics reason)
;;

let sealed_public_interface () =
  let root = repository_root (Sys.getcwd ()) in
  let prefix = "module C = Logseq_sync_pure_reducer.Core\n" in
  positive
    root
    (prefix
     ^ "let carry (x : C.runner_effect) = x\n\
        let inspect = C.runner_effect_diagnostic\n\
        let submit = Logseq_sync_effect_runner.Effect_runner.submit\n");
  positive
    root
    "module C = Logseq_sync_pure_reducer__Core\nlet carry (x : C.runner_effect) = x\n";
  negative root (prefix ^ "let forge scope = C.Cancel_effects scope\n") "private type";
  negative
    root
    (prefix
     ^ "let forge x = match x with C.Asset_io (ticket, request) -> C.Asset_io (ticket, \
        request) | _ -> x\n")
    "private type";
  negative
    root
    (prefix
     ^ "type alias = C.runner_effect\nlet forge scope : alias = C.Cancel_effects scope\n"
    )
    "private type";
  negative
    root
    "module C = Logseq_sync_pure_reducer__Core\n\
     let forge scope = C.Cancel_effects scope\n"
    "private type";
  negative
    root
    (prefix ^ "let forge : C.asset_ticket = { asset_serial = 1; asset_request = () }\n")
    "Unbound record field";
  negative
    root
    (prefix ^ "let forge : unit C.effect_ticket = { id = 1; scope = (); kind = () }\n")
    "Unbound record field";
  negative
    root
    "let bypass = Logseq_sync_effect_runner.Asset_cache.create\n"
    "Unbound value";
  negative root "module B = Logseq_sync_effect_runner.Bootstrap\n" "Unbound module";
  negative
    root
    "module B = Logseq_sync_effect_runner__logseq_sync_effect_runner_impl__Bootstrap\n"
    "Unbound module";
  negative root "module B = Logseq_sync_effect_runner_impl.Bootstrap\n" "Unbound module";
  List.iter
    (fun operation ->
       negative
         root
         ("let bypass = Logseq_sync_effect_runner.Effect_runner." ^ operation ^ "\n")
         "Unbound value")
    [ "submit_asset"
    ; "run_scoped_asset"
    ; "upload_asset"
    ; "stage_asset"
    ; "retain_asset_file"
    ; "release_asset_file"
    ; "staged_asset_path"
    ; "close_asset_scope"
    ; "delete_graph_assets"
    ; "release_staged_asset"
    ; "prune_staged_assets"
    ; "retain_staged_file"
    ; "encrypt_protected_values"
    ; "decrypt_protected_value"
    ; "authenticated_operation"
    ]
;;

let () =
  Alcotest.run
    "sync public interface"
    [ ( "external compilation"
      , [ Alcotest.test_case "sealed execution and cache" `Quick sealed_public_interface ]
      )
    ]
;;
