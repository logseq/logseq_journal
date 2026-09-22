module P = Journal_platform

let hex bytes =
  Bytes.to_seq bytes
  |> Seq.map (fun byte -> Printf.sprintf "%02x" (Char.code byte))
  |> List.of_seq
  |> String.concat ""
;;

let unhex value =
  Bytes.init
    (String.length value / 2)
    (fun index -> Char.chr (int_of_string ("0x" ^ String.sub value (index * 2) 2)))
;;

let emit path =
  let fields =
    [ "authenticated-user", P.authenticated_user_request
    ; "sign-out", P.sign_out_request
    ; "termination-ready", P.termination_ready_request
    ; "local-account", P.local_account_binding_request
    ; "timeline-presented", P.timeline_presented_request
    ]
  in
  Yojson.Safe.to_file
    path
    (`Assoc (List.map (fun (key, bytes) -> key, `String (hex bytes)) fields))
;;

let verify path =
  let values = Yojson.Safe.from_file path |> Yojson.Safe.Util.to_assoc in
  let packet name = List.assoc name values |> Yojson.Safe.Util.to_string |> unhex in
  let require name actual expected =
    if actual <> expected then failwith ("Swift packet rejected by OCaml: " ^ name)
  in
  require
    "authenticated-user"
    (P.decode_authenticated_user (packet "authenticated-user"))
    (Ok (Some "fixture-user"));
  require
    "signed-out-user"
    (P.decode_authenticated_user (packet "signed-out-user"))
    (Ok None);
  require
    "id-token"
    (P.decode_id_token_response ~challenge_id:"challenge-1" (packet "id-token"))
    (Ok "fixture-token-中文");
  if Result.is_ok (P.decode_id_token_response ~challenge_id:"stale" (packet "id-token"))
  then failwith "Swift token accepted for a different challenge";
  require "sign-out" (P.decode_sign_out_response (packet "sign-out")) (Ok ());
  require
    "termination-ready"
    (P.decode_termination_ready_response (packet "termination-ready"))
    (Ok ());
  require
    "local-account"
    (P.decode_local_account_binding (packet "local-account"))
    (Ok
       (Some { P.user_id = "fixture-user"; managed_sync_origin = "https://api.logseq.io" }));
  require
    "no-local-account"
    (P.decode_local_account_binding (packet "no-local-account"))
    (Ok None);
  require
    "timeline-presented"
    (P.decode_timeline_presented (packet "timeline-presented"))
    (Ok ());
  require
    "prepare-to-terminate"
    (P.is_prepare_to_terminate_event (packet "prepare-to-terminate"))
    true;
  require
    "backgrounded"
    (P.decode_network_lifecycle (packet "backgrounded"))
    (Ok (P.Backgrounded { generation = 17L }));
  require
    "foreground-resumed"
    (P.decode_network_lifecycle (packet "foreground-resumed"))
    (Ok (P.Foreground_resumed { generation = Int64.max_int }));
  print_endline
    "OCaml: all Swift responses/events accepted; stale token challenge rejected"
;;

let () =
  match Sys.argv.(1) with
  | "emit" -> emit Sys.argv.(2)
  | "verify" -> verify Sys.argv.(2)
  | _ -> invalid_arg "expected emit or verify"
;;
