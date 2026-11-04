module U = Graph_types.Uuid

let ( let* ) = Result.bind

type t =
  { namespace : string
  ; mutation_id : U.t
  ; command : Protocol.command
  ; targets : U.t Rrbvec.t
  ; encoded : string
  }

let identity command =
  let single id target = Ok (id, Rrbvec.singleton target) in
  match command with
  | Protocol.V2_save_block { mutation_id; block; _ }
  | V2_set_task_status { mutation_id; block; _ }
  | V2_clear_task_status { mutation_id; block; _ }
  | V2_set_asset_reference { mutation_id; block; _ } -> single mutation_id block
  | V2_delete_blocks { mutation_id; root; _ } -> single mutation_id root
  | V2_create_journal_page { mutation_id; page; _ } -> single mutation_id page
  | V2_append_journal{mutation_id;root;_}->
    let rec collect nodes index found =
      if index=Rrbvec.length nodes then Ok(mutation_id,Rrbvec.sort_uniq U.compare found)
      else let node=Rrbvec.nth nodes index in
        collect(Rrbvec.append nodes node.Worker_pure_data.children)(index+1)(Rrbvec.push_back found node.block_id) in
    collect(Rrbvec.singleton root)0 Rrbvec.empty
  | V2_insert_blocks { mutation_id; roots = [ root ]; _ } ->
    let nodes = ref (Rrbvec.singleton root)
    and found = ref Rrbvec.empty
    and index = ref 0 in
    while !index < Rrbvec.length !nodes do
      let node = Rrbvec.nth !nodes !index in
      found := Rrbvec.push_back !found node.Worker_pure_data.uuid;
      nodes := List.fold_left Rrbvec.push_back !nodes node.children;
      incr index
    done;
    Ok (mutation_id, Rrbvec.sort_uniq U.compare !found)
  | _ -> Error "Not a supported durable mutation command"
;;

let canonical json = Yojson.Safe.sort json |> Yojson.Safe.to_string

let context ~origin ~user ~graph =
  `Assoc
    [ "origin", `String (Uri.to_string origin)
    ; "user", `String user
    ; "graph", `String (U.to_string graph)
    ]
;;

let namespace_for_owner ~origin ~user ~graph =
  Digestif.SHA256.digest_string(canonical(context ~origin ~user ~graph)) |> Digestif.SHA256.to_hex
;;

let create ~origin ~user ~graph command =
  if user = "" || String.length user > 4096 || String.length (Uri.to_string origin) > 8192
  then Error "Invalid logical mutation owner"
  else (
    (* Validate size/depth before walking a possibly hostile tree. *)
    let placeholder =
      U.of_string "00000000-0000-4000-8000-000000000001" |> Result.get_ok
    in
    let* checked =
      Protocol.request_of_yojson
        (Protocol.request_to_yojson
           { api_version = Protocol.api_version; request_id = placeholder; command })
      |> Result.map_error (fun _ -> "Invalid mutation domain or wire budget")
    in
    let* mutation_id, targets = identity checked.command in
    let owner = context ~origin ~user ~graph in
    let namespace =
      Digestif.SHA256.digest_string (canonical owner) |> Digestif.SHA256.to_hex
    in
    let request =
      Protocol.request_to_yojson
        { api_version = Protocol.api_version
        ; request_id = mutation_id
        ; command = checked.command
        }
    in
    let encoded =
      canonical (`Assoc [ "version", `Int 1; "owner", owner; "request", request ])
    in
    if String.length encoded > Worker_pure_data.maximum_request_bytes
    then Error "Complete mutation exceeds wire budget"
    else Ok { namespace; mutation_id; command = checked.command; targets; encoded })
;;

let restore ~origin ~user ~graph encoded =
  try
    if String.length encoded > Worker_pure_data.maximum_request_bytes
    then Error "Stored mutation exceeds wire budget"
    else (
      match Yojson.Safe.from_string encoded with
      | `Assoc fields
        when List.length fields = 3
             && List.assoc_opt "version" fields = Some (`Int 1)
             && List.assoc_opt "owner" fields
                = Some (context ~origin ~user ~graph |> Yojson.Safe.sort) ->
        let* request =
          match List.assoc_opt "request" fields with
          | None -> Error "Missing mutation command"
          | Some request ->
            Protocol.request_of_yojson request
            |> Result.map_error (fun _ -> "Invalid stored mutation command")
        in
        let* intent = create ~origin ~user ~graph request.command in
        if intent.encoded = encoded && U.equal intent.mutation_id request.request_id
        then Ok intent
        else Error "Stored mutation is not canonical"
      | _ -> Error "Stored mutation logical owner does not match")
  with
  | exn -> Error (Printexc.to_string exn)
;;

let encode intent = intent.encoded
let namespace intent = intent.namespace
let mutation_id intent = intent.mutation_id
let command intent = intent.command
let targets intent = intent.targets

type outcome =
  | Committed of Protocol.response
  | Rejected of Protocol.response
  | Unknown

type recovery_item = { intent : string; outcome : outcome }
type recovery_page = { items : recovery_item Rrbvec.t; next : int64 option }

(* A complete maximum-size immutable intent may double when escaped as a JSON
   string, alongside one bounded outcome and the fixed recovery envelope. This
   is a distinct artifact budget, not the smaller ordinary query response cap. *)
let maximum_recovery_bytes =
  (2 * Worker_pure_data.maximum_request_bytes) + Worker_pure_data.maximum_response_bytes + 4096

let recovery_page_bytes page =
  let outcome = function
    | Unknown -> `List[`String "Unknown"]
    | Committed response -> `List[`String "Committed";Protocol.response_to_yojson response]
    | Rejected response -> `List[`String "Rejected";Protocol.response_to_yojson response] in
  let item (item:recovery_item)=`Assoc["intent",`String item.intent;"outcome",outcome item.outcome] in
  String.length(Yojson.Safe.to_string(`Assoc[
    "items",`List(Rrbvec.to_list(Rrbvec.map item page.items));
    "next",(match page.next with None->`Null|Some value->`String(Int64.to_string value))]))
;;

type original_point =
  { generation : string
  ; before : string
  ; after : string
  }

let committed_point intent ~request_id response =
  let token prefix value =
    let prefix = prefix ^ ":v1:" in
    String.length value > String.length prefix && String.starts_with ~prefix value
  in
  if Protocol.encoded_response_bytes response > Worker_pure_data.maximum_response_bytes
  then Error "Original commit response exceeds wire budget"
  else (
    match response with
    | Protocol.V2_response
        { api_version
        ; request_id = actual
        ; outcome =
            V2_mutation_committed
              { mutation_id
              ; status
              ; generation
              ; before_projection_revision = before
              ; after_projection_revision = after
              }
        }
      when api_version = Protocol.api_version
           && U.equal actual request_id
           && U.equal mutation_id intent.mutation_id
           && token "generation" generation
           && token "projection" before
           && token "projection" after
           &&
           match status with
           | Worker_pure_data.V2_applied -> before <> after
           | Worker_pure_data.V2_no_change -> before = after
           | Worker_pure_data.V2_already_applied -> false -> Ok { generation; before; after }
    | _ -> Error "Response does not establish the exact original durable commit")
;;
