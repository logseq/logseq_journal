module Graph_service = Logseq_db_worker_lui.Logseq_db_worker_lui_service

type network_lifecycle =
  | Backgrounded of { generation : int64 }
  | Foreground_resumed of { generation : int64 }

type local_account_binding =
  { user_id : string
  ; managed_sync_origin : string
  }

let envelope_header_size = 32
let maximum_envelope_payload_bytes = 256 * 1024

let encode_versioned_envelope ~runtime_generation ~graph_generation tag payload =
  let payload_length = Bytes.length payload in
  if
    payload_length > maximum_envelope_payload_bytes
    || Int64.compare runtime_generation 0L < 0
    || Int64.compare graph_generation 0L < 0
  then Error "application platform payload exceeds 256 KiB"
  else (
    let bytes = Bytes.make (envelope_header_size + payload_length) '\000' in
    Bytes.blit_string "LJP2" 0 bytes 0 4;
    Bytes.set_uint16_le bytes 4 2;
    Bytes.set_uint16_le bytes 6 tag;
    Bytes.set_int64_le bytes 8 runtime_generation;
    Bytes.set_int64_le bytes 16 graph_generation;
    Bytes.set_int32_le bytes 24 (Int32.of_int payload_length);
    Bytes.blit payload 0 bytes envelope_header_size payload_length;
    Ok bytes)
;;

let encode_envelope tag payload =
  encode_versioned_envelope ~runtime_generation:0L ~graph_generation:0L tag payload
;;

let decode_versioned_envelope bytes =
  let length = Bytes.length bytes in
  if length < envelope_header_size
  then Error "application platform envelope is truncated"
  else if length > envelope_header_size + maximum_envelope_payload_bytes
  then Error "application platform envelope exceeds its bound"
  else if not (Bytes.sub_string bytes 0 4 = "LJP2")
  then Error "application platform envelope magic is invalid"
  else if Bytes.get_uint16_le bytes 4 <> 2
  then Error "application platform envelope version is unsupported"
  else if Bytes.get_int32_le bytes 28 <> 0l
  then Error "application platform envelope reserved field is invalid"
  else (
    let tag = Bytes.get_uint16_le bytes 6 in
    let runtime_generation = Bytes.get_int64_le bytes 8 in
    let graph_generation = Bytes.get_int64_le bytes 16 in
    let payload_length = Bytes.get_int32_le bytes 24 in
    if
      Int64.compare runtime_generation 0L < 0
      || Int64.compare graph_generation 0L < 0
      || Int32.compare payload_length 0l < 0
      || Int32.to_int payload_length <> length - envelope_header_size
    then Error "application platform envelope payload length is invalid"
    else
      Ok
        ( tag
        , runtime_generation
        , graph_generation
        , Bytes.sub bytes envelope_header_size (Int32.to_int payload_length) ))
;;

let decode_envelope accepted_tags bytes =
  Result.bind (decode_versioned_envelope bytes) (fun (tag, runtime, graph, payload) ->
    if not (List.mem tag accepted_tags)
    then Error "application platform envelope tag is unsupported"
    else if runtime <> 0L || graph <> 0L
    then Error "application platform envelope generation fields are invalid"
    else Ok payload)
;;

let decode_network_lifecycle bytes =
  Result.bind (decode_envelope [ 15 ] bytes) (fun payload ->
    if Bytes.length payload <> 16
    then Error "application network lifecycle packet has an invalid length"
    else if Bytes.sub_string payload 0 4 <> "LJP1"
    then Error "application network lifecycle magic is invalid"
    else if Bytes.get_uint16_le payload 4 <> 1
    then Error "application network lifecycle version is unsupported"
    else (
      let generation = Bytes.get_int64_le payload 8 in
      if Int64.compare generation 0L < 0
      then Error "application network lifecycle generation is invalid"
      else (
        match Bytes.get_uint16_le payload 6 with
        | 1 -> Ok (Backgrounded { generation })
        | 2 -> Ok (Foreground_resumed { generation })
        | _ -> Error "application network lifecycle transition is unsupported")))
;;

let authenticated_user_request = encode_envelope 6 Bytes.empty |> Result.get_ok
let local_account_binding_request = encode_envelope 20 Bytes.empty |> Result.get_ok
let online_requested_request = encode_envelope 30 Bytes.empty |> Result.get_ok
let online_cancelled_request = encode_envelope 32 Bytes.empty |> Result.get_ok
let scope_json (scope : Graph_service.startup_scope) =
  `Assoc ["accountGeneration",`Int scope.account_generation;"presentationGeneration",`Int scope.presentation_generation]
;;
let decode_scope = function
  | `Assoc fields ->
    (match List.assoc_opt "accountGeneration" fields,List.assoc_opt "presentationGeneration" fields with
     | Some (`Int account_generation),Some (`Int presentation_generation) when account_generation>=0 && presentation_generation>=0 ->
       Ok ({account_generation;presentation_generation} : Graph_service.startup_scope)
     | _ -> Error "Invalid startup scope")
  | _ -> Error "Invalid startup scope"
;;
let scoped_request tag scope =
  encode_envelope tag (Bytes.of_string (Yojson.Safe.to_string (scope_json scope))) |> Result.get_ok
;;
let scoped_online_requested_request = scoped_request 30
let scoped_online_cancelled_request = scoped_request 32
let scoped_timeline_presented_request = scoped_request 22
let decode_online_event bytes =
  Result.bind (decode_versioned_envelope bytes) (fun (tag,_,_,payload) ->
    if tag<>34 && tag<>35 then Error "Not an online intent" else
    try Result.map (fun scope -> tag=34,scope) (decode_scope (Yojson.Safe.from_string (Bytes.to_string payload)))
    with Yojson.Json_error _ -> Error "Invalid online intent")
;;
let decode_authenticated_scope bytes =
  Result.bind (decode_envelope [7] bytes) (fun payload ->
    try match Yojson.Safe.from_string (Bytes.to_string payload) with
      | `Assoc fields -> (match List.assoc_opt "startupScope" fields with
          | Some scope -> decode_scope scope | None -> Error "Missing authentication scope")
      | _ -> Error "Invalid authentication scope"
    with Yojson.Json_error _ -> Error "Invalid authentication scope")
;;

let timeline_presented_request = encode_envelope 22 Bytes.empty |> Result.get_ok

module Json = struct
  type account = { userId : string option; managedSyncOrigin : string option }
  [@@deriving yojson]
  type startup_scope = { accountGeneration : int; presentationGeneration : int }
  [@@deriving yojson]
  type user =
    { userId : string option
    ; startupScope : startup_scope option [@default None]
    }
  [@@deriving yojson]
  type challenge = { challengeId : string } [@@deriving yojson]
  type token = { challengeId : string; token : string } [@@deriving yojson]
  type sign_out = { signedOut : bool } [@@deriving yojson]
  type ready = { ready : bool } [@@deriving yojson]
  type presented = { presented : bool } [@@deriving yojson]
  type copied = { copied : bool } [@@deriving yojson]
end

let decode_json label decoder bytes =
  try Logseq_db_types.Json_codec.decode decoder (Yojson.Safe.from_string (Bytes.to_string bytes))
  with Yojson.Json_error _ -> Error (label ^ " is not valid JSON")
;;

let bounded_string maximum value =
  if String.length value > 0 && String.length value <= maximum
     && Journal_validation.is_valid_utf_8 value && not (String.contains value '\000')
  then Ok value else Error "platform auth text is invalid"
;;

let secure_origin value =
  let uri = Uri.of_string value in
  match Uri.scheme uri, Uri.host uri with
  | Some "https", Some _ when String.length value <= 2048 -> Ok value
  | _ -> Error "managed-sync origin must be one bounded HTTPS origin"
;;

let decode_local_account_binding bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [21] bytes in
  let* wire = decode_json "local-account-binding response" Json.account_of_yojson payload in
  match wire.userId, wire.managedSyncOrigin with
  | None, None -> Ok None
  | Some user_id, Some managed_sync_origin ->
    let* user_id = bounded_string 512 user_id in
    let* managed_sync_origin = secure_origin managed_sync_origin in
    Ok (Some { user_id; managed_sync_origin })
  | _ -> Error "local-account-binding response fields are invalid"
;;

let decode_timeline_presented bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [23] bytes in
  let* wire = decode_json "Timeline-presented response" Json.presented_of_yojson payload in
  if wire.presented then Ok () else Error "Timeline-presented response is malformed"
;;

let decode_authenticated_user bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [7] bytes in
  let* wire = decode_json "authenticated-user response" Json.user_of_yojson payload in
  match wire.userId with
  | None -> Ok None
  | Some user -> Result.map Option.some (bounded_string 512 user)
;;

let json_request tag encoder value =
  encoder value |> Yojson.Safe.to_string |> Bytes.of_string |> encode_envelope tag
;;

let id_token_request (challenge : Graph_service.token_request) =
  json_request 8 Json.challenge_to_yojson
    { challengeId = Graph_service.token_request_id challenge } |> Result.get_ok
;;

let decode_id_token_response ~challenge_id bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [9] bytes in
  let* wire = decode_json "ID-token response" Json.token_of_yojson payload in
  if String.equal wire.challengeId challenge_id
  then bounded_string maximum_envelope_payload_bytes wire.token
  else Error "ID-token response is unsolicited"
;;

let sign_out_request = encode_envelope 10 Bytes.empty |> Result.get_ok

let decode_sign_out_response bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [11] bytes in
  let* wire = decode_json "sign-out response" Json.sign_out_of_yojson payload in
  if wire.signedOut then Ok () else Error "sign-out response fields are invalid"
;;

let is_prepare_to_terminate_event bytes =
  match decode_envelope [12] bytes with
  | Ok payload -> Bytes.length payload = 0
  | Error _ -> false
;;

let termination_ready_request = encode_envelope 13 Bytes.empty |> Result.get_ok

let decode_termination_ready_response bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [14] bytes in
  let* wire = decode_json "termination-ready response" Json.ready_of_yojson payload in
  if wire.ready then Ok () else Error "termination-ready response fields are invalid"
;;

let decode_environment_event bytes =
  Result.bind (decode_envelope [24] bytes) (fun payload ->
    match Yojson.Basic.from_string (Bytes.to_string payload) |> Journal_environment.decode_json with
    | Ok snapshot -> Ok snapshot
    | Error error -> Error ("environment event: " ^ error)
    | exception Yojson.Json_error _ -> Error "environment event is not valid JSON")
;;

let is_environment_event bytes = Result.is_ok (decode_envelope [24] bytes)

let copy_text_request ~text =
  Result.bind (Journal_pure_copy.clipboard_payload ~text) (encode_envelope 28)
;;

let decode_copy_text_response bytes =
  let ( let* ) = Result.bind in
  let* payload = decode_envelope [29] bytes in
  let* wire = decode_json "clipboard response" Json.copied_of_yojson payload in
  if wire.copied then Ok () else Error "Clipboard write was not acknowledged."
;;

module Draft_store = struct
  type t = { directory : string; binding : local_account_binding
    ; directory_sync : (string -> unit) option
    ; cleanup_pending : string list option ref }
  type draft = { graph : string; parent : string option; capture : Journal_capture.t }

  module Wire = struct
    type asset = { name : string; title : string; kind : string } [@@deriving yojson]
    type draft =
      { graph : string; parent : string option; source : string; task : string option
      ; interrupted : bool; assets : asset list }
    [@@deriving yojson]
    type snapshot = { version : int; origin : string; user : string; drafts : draft list }
    [@@deriving yojson]
  end

  let create ~directory ~binding = {directory;binding;directory_sync=None;cleanup_pending=ref None}
  module For_testing = struct
    let with_directory_sync t synchronize = {t with directory_sync=Some synchronize}
  end
  let maximum_metadata = 2 * 1024 * 1024
  let maximum_media = 128 * 1024 * 1024
  let maximum_file = 32 * 1024 * 1024
  let fail cause = invalid_arg cause
  let protect operation =
    try Ok(operation ()) with
    | Invalid_argument cause -> Error cause
    | Unix.Unix_error(cause,_,_) -> Error("Draft storage: " ^ Unix.error_message cause)
    | Sys_error _ -> Error "Draft storage file access failed."
    | Yojson.Json_error _ -> Error "Draft recovery metadata is malformed."
    | End_of_file -> Error "Draft recovery file is truncated."

  let parent t = Filename.concat t.directory "JournalDrafts-v1"
  let directory t = Filename.concat (parent t)
    (Digest.to_hex(Digest.string(t.binding.managed_sync_origin ^ "\000" ^ t.binding.user_id)))
  let exists path = try ignore(Unix.lstat path);true with
    | Unix.Unix_error(Unix.ENOENT,_,_) -> false
  let private_directory path =
    if not(exists path) then Unix.mkdir path 0o700;
    let stat=Unix.lstat path in
    if stat.st_kind<>Unix.S_DIR || stat.st_uid<>Unix.getuid() || stat.st_perm land 0o077<>0
    then fail "Draft storage directory is not private."
  let prepare t = private_directory(parent t);private_directory(directory t)
  let regular path limit =
    let stat=Unix.lstat path in
    if stat.st_kind<>Unix.S_REG || stat.st_uid<>Unix.getuid() || stat.st_size>limit
    then fail "Draft recovery file is unsafe or exceeds its size limit.";
    stat.st_size
  let media_name name =
    String.length name=38 && String.ends_with ~suffix:".media" name
    && String.for_all(fun character->match character with '0'..'9'|'a'..'f'->true|_->false)
      (String.sub name 0 32)
  let owned name = name="state.json" || media_name name
    || String.starts_with ~prefix:"pending-" name
  let sync_directory path =
    let descriptor=Unix.openfile path [Unix.O_RDONLY] 0 in
    Fun.protect ~finally:(fun()->Unix.close descriptor)(fun()->Unix.fsync descriptor)
  let atomic ?(committed=fun()->()) ?(synchronize=sync_directory) path write =
    let temporary,channel=Filename.open_temp_file ~temp_dir:(Filename.dirname path)
      ~mode:[Open_binary] "pending-" ".tmp" in
    Fun.protect ~finally:(fun()->close_out_noerr channel;
      if exists temporary then Unix.unlink temporary) (fun()->
      Unix.chmod temporary 0o600;
      write channel;
      flush channel;Unix.fsync(Unix.descr_of_out_channel channel);close_out channel;
      Unix.rename temporary path;committed();synchronize(Filename.dirname path))
  let read path limit =
    let size=regular path limit in
    let channel=open_in_bin path in
    Fun.protect ~finally:(fun()->close_in_noerr channel)(fun()->
      if (Unix.fstat(Unix.descr_of_in_channel channel)).st_size<>size
      then fail "Draft recovery file changed while reading.";
      really_input_string channel size)
  let copy source destination =
    ignore(regular source maximum_file);
    let channel=open_in_bin source in
    Fun.protect ~finally:(fun()->close_in_noerr channel)(fun()->
      atomic destination (fun output->
        let buffer=Bytes.create 65536 in
        let rec loop total =
          let count=input channel buffer 0 (Bytes.length buffer) in
          if total+count>maximum_file then fail "Draft attachment exceeds 32 MiB.";
          if count>0 then (output_bytes output (Bytes.sub buffer 0 count);loop(total+count)) in
        loop 0))
  let uuid text = Result.is_ok(Logseq_db_types.Graph_types.Uuid.of_string text)
  let validate drafts =
    if List.length drafts>128 then fail "Draft recovery exceeds 128 drafts.";
    let keys=Hashtbl.create 128 in
    let media_count=ref 0 in
    List.iter(fun (draft:Wire.draft)->
      if not(uuid draft.graph) || not(Option.fold ~none:true ~some:uuid draft.parent)
      then fail "Draft recovery graph or parent identity is invalid.";
      media_count:= !media_count+List.length draft.assets;
      if !media_count>256 then fail "Draft recovery exceeds 256 attachments.";
      let key=draft.graph,draft.parent in
      if Hashtbl.mem keys key then fail "Draft recovery contains duplicate owners.";
      Hashtbl.add keys key ();
      if String.length draft.source>256*1024 || List.length draft.assets>Journal_capture.attachment_limit
      then fail "Draft text or attachment count exceeds its recovery limit.";
      Option.iter(fun task->if task<>"default" && not(uuid task)
        then fail "Draft task identity is invalid.")draft.task;
      List.iter(fun(asset:Wire.asset)->
        if not(media_name asset.name) || String.length asset.title>4096 || String.length asset.kind>256
        then fail "Draft attachment metadata is invalid.")draft.assets)drafts
  let snapshot t drafts = Wire.{version=1;origin=t.binding.managed_sync_origin;user=t.binding.user_id;drafts}
  let read_snapshot t =
    let path=Filename.concat(directory t)"state.json" in
    if not(exists path) then [] else
    let json=read path maximum_metadata |> Yojson.Safe.from_string in
    let wire=match Logseq_db_types.Json_codec.decode Wire.snapshot_of_yojson json with
      | Ok value->value | Error _->fail "Draft recovery metadata is invalid." in
    if wire.version<>1 then fail "Draft recovery version is unsupported.";
    if wire.origin<>t.binding.managed_sync_origin || wire.user<>t.binding.user_id
    then fail "Draft recovery account binding does not match.";
    validate wire.drafts;wire.drafts
  let entries path =
    let handle=Unix.opendir path in
    Fun.protect ~finally:(fun()->Unix.closedir handle)(fun()->
      let rec loop count names =
        match Unix.readdir handle with
        |"."|".."->loop count names
        |name->if count>=768 then fail "Draft storage exceeds its file count limit.";
          loop(count+1)(name::names)
        |exception End_of_file->names in
      loop 0 [])
  let sweep t keep =
    List.iter(fun name->
      if not(owned name) then fail "Draft storage contains an unexpected file.";
      if name<>"state.json" && not(List.mem name keep) then (
        let path=Filename.concat(directory t)name in
        ignore(regular path maximum_file);Unix.unlink path)) (entries(directory t))
  let clear t = protect(fun()->
    if exists(directory t) then (
      private_directory(parent t);private_directory(directory t);
      let names=entries(directory t) in
      List.iter(fun name->if not(owned name) then fail "Draft storage contains an unexpected file.";
        ignore(regular(Filename.concat(directory t)name)(max maximum_file maximum_metadata)))names;
      List.iter(fun name->Unix.unlink(Filename.concat(directory t)name))names;
      Unix.rmdir(directory t);sync_directory(parent t)))
  let report_cleanup_warning cause =
    Printf.eprintf "journal: draft committed; cleanup pending: %s\n%!" cause
  let retry_cleanup t on_cleanup_warning =
    match !(t.cleanup_pending) with
    |None->()
    |Some keep->
      (match protect(fun()->sweep t keep) with
      |Ok()->t.cleanup_pending:=None
      |Error cause->
        let warning="Draft saved, but cleanup is pending: " ^ cause in
        (try on_cleanup_warning warning with _->report_cleanup_warning warning))
  let save ?(on_cleanup_warning=report_cleanup_warning) t drafts = protect(fun()->
    prepare t;
    let drafts=List.filter(fun (draft:draft)->
      Journal_capture.can_checkpoint draft.capture)drafts in
    let copies=ref [] in
    let wire=List.map(fun (draft:draft)->
      let capture=draft.capture in
      let assets=List.map(fun staged->
        let name=Digest.to_hex(Digest.string(Journal_asset_import.staged_token staged)) ^ ".media" in
        copies:=(Journal_asset_import.staged_path staged,name)::!copies;
        Wire.{name;title=Journal_asset_import.staged_title staged;kind=Journal_asset_import.staged_type staged})
        (Journal_capture.pending_attachments capture) in
      let task=match Journal_capture.task_state capture with
        |Journal_model.No_status->None |Default_status->Some "default"
        |Status id->Some id |Invalid_status _->fail "Draft task status is invalid." in
      Wire.{graph=draft.graph;parent=draft.parent;source=Journal_capture.source capture;task;
        interrupted=false;assets})drafts in
    validate wire;
    let encoded=Yojson.Safe.to_string(Wire.snapshot_to_yojson(snapshot t wire)) in
    if String.length encoded>maximum_metadata then fail "Draft metadata exceeds 2 MiB.";
    let copies=List.sort_uniq(fun (_,left) (_,right)->String.compare left right)!copies in
    let total=List.fold_left(fun total (source,name)->
      let destination=Filename.concat(directory t)name in
      let size=regular (if exists destination then destination else source) maximum_file in
      if total+size>maximum_media then fail "Draft attachments exceed 128 MiB.";total+size)0 copies in
    ignore total;
    let created=ref [] in
    let published=ref false in
    (try
      List.iter(fun(source,name)->let destination=Filename.concat(directory t)name in
        if not(exists destination) then (created:=destination::!created;copy source destination))copies;
      atomic ~committed:(fun()->published:=true)
        ~synchronize:(Option.value t.directory_sync ~default:sync_directory)
        (Filename.concat(directory t)"state.json")
        (fun channel->output_string channel encoded)
    with error->
      if !published then
        fail "Draft manifest was published, but directory synchronization failed. Its restart durability is unknown; do not submit."
      else (
        List.iter(fun path->if exists path then Unix.unlink path)!created;
        raise error));
    t.cleanup_pending:=Some(List.map snd copies);
    retry_cleanup t on_cleanup_warning)
  let fresh_uuid () =
    let channel=open_in_bin "/dev/urandom" in
    let bytes=Fun.protect ~finally:(fun()->close_in_noerr channel)(fun()->really_input_string channel 16) in
    let hex=String.concat "" (List.init 16(fun index->Printf.sprintf "%02x" (Char.code bytes.[index]))) in
    Printf.sprintf "%s-%s-4%s-8%s-%s" (String.sub hex 0 8)(String.sub hex 8 4)
      (String.sub hex 13 3)(String.sub hex 17 3)(String.sub hex 20 12)
  let load t = protect(fun()->
    if not(exists(directory t)) then [] else (
      private_directory(parent t);private_directory(directory t);
      let stored=read_snapshot t in
      let drafts=List.filter(fun (draft:Wire.draft)->not draft.interrupted)stored in
      let total=ref 0 in
      List.iter(fun (draft:Wire.draft)->List.iter(fun(asset:Wire.asset)->
        total:= !total+regular(Filename.concat(directory t)asset.name)maximum_file;
        if !total>maximum_media then fail "Draft attachments exceed 128 MiB.")draft.assets)drafts;
      let staged_files=ref [] in
      try
        let recovered=List.mapi(fun index (draft:Wire.draft)->
        let capture=Journal_capture.create ~session_number:(Int64.of_int(index+1)) ~source:draft.source in
        let task=match draft.task with None->Journal_model.No_status
          |Some "default"->Default_status |Some id->Status id in
        let capture=Journal_capture.with_task_state capture task in
        let capture=List.fold_left(fun capture(asset:Wire.asset)->
          let temporary=Filename.temp_file "journal-import-recovered-" ".tmp" in
          staged_files:=temporary::!staged_files;
          copy(Filename.concat(directory t)asset.name)temporary;
          let selection=`Assoc["operation",`String(fresh_uuid());"asset",`String(fresh_uuid());
            "localMutation",`String(fresh_uuid());"metadataMutation",`String(fresh_uuid());
            "path",`String temporary;"title",`String asset.title;"type",`String asset.kind] in
          let payload=Yojson.Safe.to_string(`Assoc["action",`String "picked";"selection",selection]) in
          match Journal_asset_import.decode_event payload with
          |Ok(Picked(staged,_))->Journal_capture.add_attachment capture staged
          |_->fail "Draft attachment could not be recovered.")capture draft.assets in
        {graph=draft.graph;parent=draft.parent;capture})drafts in
        if List.length drafts<>List.length stored then (
          match save t recovered with Ok()->() |Error cause->fail cause);
        recovered
      with error->List.iter(fun path->if exists path then Unix.unlink path)!staged_files;raise error))

  module Writer = struct
    type store = t
    type job = { revision : int; snapshot : unit -> draft list }
    type t =
      { pending : job option Atomic.t
      ; completed : (int * (unit, string) result) Atomic.t
      ; running : bool Atomic.t
      ; mutable revision : int
      ; mutable thread : Thread.t option
      }
    let create ?(on_complete=fun _->()) ?(on_cleanup_warning=report_cleanup_warning) store =
      let writer={pending=Atomic.make None;completed=Atomic.make(0,Ok());
        running=Atomic.make true;revision=0;thread=None} in
      let last_saved = ref None in
      let same_snapshot left right =
        List.length left=List.length right && List.for_all2(fun left right->
          left.graph=right.graph && left.parent=right.parent && left.capture==right.capture)left right in
      let rec work () =
        match Atomic.exchange writer.pending None with
        |Some job->
          let result=try
            let drafts=job.snapshot () in
            if Option.fold ~none:false ~some:(same_snapshot drafts) !last_saved then (
              retry_cleanup store on_cleanup_warning;Ok()) else
            let result=save ~on_cleanup_warning store drafts in
            (match result with Ok()->last_saved:=Some drafts|Error _->last_saved:=None);result
          with _->last_saved:=None;Error "Draft storage worker failed; restart recovery is unavailable." in
          Atomic.set writer.completed (job.revision,result);
          (try on_complete result with _->());work ()
        |None when Atomic.get writer.running->Unix.sleepf 0.005;work ()
        |None->() in
      writer.thread<-Some(Thread.create work ());writer
    let enqueue writer snapshot =
      if not(Atomic.get writer.running) then Error "Draft storage writer is closed."
      else (
        writer.revision<-writer.revision+1;
        Atomic.set writer.pending (Some{revision=writer.revision;snapshot});Ok())
    let flush writer =
      let target=writer.revision in
      let rec wait () =
        let revision,result=Atomic.get writer.completed in
        if revision>=target then result else (Unix.sleepf 0.001;wait ()) in
      wait ()
    let close writer =
      let result=flush writer in
      Atomic.set writer.running false;
      Option.iter Thread.join writer.thread;writer.thread<-None;result
  end
end
