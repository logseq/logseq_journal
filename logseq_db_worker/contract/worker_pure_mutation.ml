module Uuid = Graph_types.Uuid
module Data = Worker_pure_data
let (let*)=Result.bind

type mutation_command =
  | Save_block of
      { block : Uuid.t
      ; title : string
      ; preconditions : Worker_pure_data.preconditions
      }
  | Insert_blocks of
      { parent : Uuid.t
      ; roots : Worker_pure_data.block_tree list
      ; preconditions : Worker_pure_data.preconditions
      }
  | Delete_blocks of
      { root : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }
  | Create_journal of
      { page : Uuid.t
      ; day : Worker_pure_day.t
      ; title : string
      ; preconditions : Worker_pure_data.preconditions
      }
  | Set_task_status of
      { block : Uuid.t
      ; status : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }
  | Clear_task_status of
      { block : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }
  | Set_asset_reference of
      { block : Uuid.t
      ; previous : Uuid.t option
      ; asset : Uuid.t
      ; preconditions : Worker_pure_data.preconditions
      }

type append_parameters =
  { page : Uuid.t
  ; day : Worker_pure_day.t
  ; root : Data.append_node
  }

type immutable =
  { namespace : string
  ; id : Uuid.t
  ; targets : Uuid.t Rrbvec.t
  ; encoded : string
  }
type mutation_intent = { immutable : immutable; command : mutation_command }
type append_intent = { immutable : immutable; append : append_parameters }
type durable_intent = Append_intent of append_intent | Mutation_intent of mutation_intent

let immutable = function Append_intent value->value.immutable|Mutation_intent value->value.immutable
let encode value=(immutable value).encoded
let namespace value=(immutable value).namespace
let mutation_id value=(immutable value).id
let targets value=(immutable value).targets
let append_intent_id (value:append_intent)=value.immutable.id
let mutation_intent_id (value:mutation_intent)=value.immutable.id
let mutation_command (value:mutation_intent)=value.command
let append_parameters (value:append_intent)=value.append

let canonical json=Yojson.Safe.sort json |> Yojson.Safe.to_string
let context ~origin ~user ~graph=`Assoc[
  "origin",`String(Uri.to_string origin);"user",`String user;"graph",`String(Uuid.to_string graph)]
let namespace_for_owner ~origin ~user ~graph=
  Digestif.SHA256.digest_string(canonical(context ~origin ~user ~graph)) |> Digestif.SHA256.to_hex

let uuid id=`String(Uuid.to_string id)
let option encode=function None->`Null|Some value->encode value
let persisted_command = function
  |Save_block{block;title;preconditions}->"V2_save_block",[
    "block",uuid block;"title",`String title;"preconditions",Data.preconditions_to_yojson preconditions]
  |Insert_blocks{parent;roots;preconditions}->"V2_insert_blocks",[
    "parent",uuid parent;"roots",`List(List.map Data.block_tree_to_yojson roots);
    "preconditions",Data.preconditions_to_yojson preconditions]
  |Delete_blocks{root;preconditions}->"V2_delete_blocks",[
    "root",uuid root;"preconditions",Data.preconditions_to_yojson preconditions]
  |Create_journal{page;day;title;preconditions}->"V2_create_journal_page",[
    "page",uuid page;"journal_day",`Int(Worker_pure_day.value day);"title",`String title;
    "preconditions",Data.preconditions_to_yojson preconditions]
  |Set_task_status{block;status;preconditions}->"V2_set_task_status",[
    "block",uuid block;"status",uuid status;"preconditions",Data.preconditions_to_yojson preconditions]
  |Clear_task_status{block;preconditions}->"V2_clear_task_status",[
    "block",uuid block;"preconditions",Data.preconditions_to_yojson preconditions]
  |Set_asset_reference{block;previous;asset;preconditions}->"V2_set_asset_reference",[
    "block",uuid block;"previous",option uuid previous;"asset",uuid asset;
    "preconditions",Data.preconditions_to_yojson preconditions]

let stored_request id (tag,fields)=`Assoc[
  "api_version",`Int 2;"request_id",uuid id;
  "command",`List[`String tag;`Assoc(("mutation_id",uuid id)::fields)]]

let seal ~origin ~user ~graph id targets stored =
  if user="" || String.length user>4096 || String.length(Uri.to_string origin)>8192
  then Error "Invalid logical mutation owner" else
  let* ()=Logseq_db_types.Json_codec.validate stored |> Result.map_error(fun _->"Invalid mutation domain or wire budget")in
  let owner=context ~origin ~user ~graph in
  let encoded=canonical(`Assoc["version",`Int 1;"owner",owner;"request",stored])in
  if String.length encoded>Data.maximum_request_bytes then Error "Complete mutation exceeds wire budget"
  else Ok{namespace=namespace_for_owner ~origin ~user ~graph;id;targets;encoded}

let valid_tree roots =
  let rec visit count = function
    |[]->true
    |(depth,(node:Data.block_tree))::remaining->
      depth<=Data.maximum_tree_depth && count<Data.maximum_tree_nodes
      && String.length node.title<=Data.maximum_title_bytes
      && visit(count+1)(List.fold_left(fun tail child->(depth+1,child)::tail)remaining node.children)
  in
  List.length roots<=Data.maximum_roots && visit 0(List.map(fun root->0,root)roots)

let mutation_targets = function
  |Save_block{title;_} when String.length title>Data.maximum_title_bytes->Error "Invalid mutation domain or wire budget"
  |Create_journal{title;_} when String.length title>Data.maximum_title_bytes->Error "Invalid mutation domain or wire budget"
  |Insert_blocks{roots;_} when not(valid_tree roots)->Error "Invalid mutation domain or wire budget"
  |Insert_blocks{roots=[root];_}->
    let rec walk nodes index found=
      if index=Rrbvec.length nodes then Ok(Rrbvec.sort_uniq Uuid.compare found)else
      let node:Data.block_tree=Rrbvec.nth nodes index in
      walk(List.fold_left Rrbvec.push_back nodes node.Data.children)(index+1)(Rrbvec.push_back found node.uuid)
    in walk(Rrbvec.singleton root)0 Rrbvec.empty
  |Insert_blocks _->Error "Not a supported durable mutation command"
  |Save_block{block;_}|Set_task_status{block;_}|Clear_task_status{block;_}|Set_asset_reference{block;_}->Ok(Rrbvec.singleton block)
  |Delete_blocks{root;_}->Ok(Rrbvec.singleton root)
  |Create_journal{page;_}->Ok(Rrbvec.singleton page)

let create_mutation ~origin ~user ~graph ~mutation_id command =
  let* targets=mutation_targets command in
  let* immutable=seal ~origin ~user ~graph mutation_id targets(stored_request mutation_id(persisted_command command))in
  Ok{immutable;command}

let create_append ~origin ~user ~graph ~mutation_id ~page ~day ~root =
  if not(Data.valid_append_node root)then Error "Invalid mutation domain or wire budget"else
  let rec walk nodes index found=
    if index=Rrbvec.length nodes then Rrbvec.sort_uniq Uuid.compare found else
    let node:Data.append_node=Rrbvec.nth nodes index in
    walk(Rrbvec.append nodes node.Data.children)(index+1)(Rrbvec.push_back found node.block_id)
  in
  let targets=walk(Rrbvec.singleton root)0 Rrbvec.empty in
  let stored=stored_request mutation_id("V2_append_journal",[
    "page",uuid page;"journal_day",`Int(Worker_pure_day.value day);"root",Data.append_node_to_yojson root])in
  let* immutable=seal ~origin ~user ~graph mutation_id targets stored in
  Ok{immutable;append={page;day;root}}

let readback_target = function
  |Append_intent intent->`Block intent.append.root.block_id
  |Mutation_intent intent->match intent.command with
    |Create_journal{page;_}->`Page page
    |Insert_blocks{roots=[root];_}->`Block root.uuid
    |Save_block{block;_}|Set_task_status{block;_}|Clear_task_status{block;_}|Set_asset_reference{block;_}->`Block block
    |Delete_blocks{root;_}->`Block root
    |Insert_blocks _->assert false

(* Only stored v1 bytes use the original tag/field vocabulary. Internal callers
   pass the actual typed intent; there is no command envelope in memory. *)
let restore ~origin ~user ~graph encoded =
  let invalid message=Error message in
  let field name=function `Assoc fields->(match List.assoc_opt name fields with Some value->Ok value|None->invalid("Missing stored "^name))|_->invalid "Invalid stored object"in
  let text=function `String value->Ok value|_->invalid "Invalid stored string"in
  let integer=function `Int value->Ok value|_->invalid "Invalid stored day"in
  let id value=let* value=text value in Uuid.of_string value in
  let nullable decode=function `Null->Ok None|value->Result.map Option.some(decode value)in
  let list decode=function
    |`List values->List.fold_right(fun value rest->let* value=decode value in let* rest=rest in Ok(value::rest))values(Ok[])
    |_->invalid "Invalid stored array"in
  try
    if String.length encoded>Data.maximum_request_bytes then invalid "Stored mutation exceeds wire budget"else
    let json=Yojson.Safe.from_string encoded in
    let* ()=Logseq_db_types.Json_codec.validate json in
    let* version=field "version" json in
    let* owner=field "owner" json in
    if version<>`Int 1 || owner<>Yojson.Safe.sort(context ~origin ~user ~graph)
    then invalid "Stored mutation logical owner does not match"else
    let* request=field "request" json in
    let* version=field "api_version" request in
    let* request_id=(let* value=field "request_id" request in id value) in
    let* command=field "command" request in
    let* tag,fields=match command with `List[`String tag;(`Assoc _ as fields)]->Ok(tag,fields)|_->invalid "Invalid stored command"in
    let get name decode=let* value=field name fields in decode value in
    let* mutation_id=get "mutation_id" id in
    if version<>`Int 2 || not(Uuid.equal mutation_id request_id)then invalid "Invalid stored mutation identity"else
    let finish command=Result.map(fun intent->Mutation_intent intent)(create_mutation ~origin ~user ~graph ~mutation_id command)in
    let* intent=match tag with
      |"V2_append_journal"->
        let* page=get "page" id in let* day=(let* value=get "journal_day" integer in Worker_pure_day.create value) in
        let* root=get "root" Data.append_node_of_yojson in
        Result.map(fun intent->Append_intent intent)(create_append ~origin ~user ~graph ~mutation_id ~page ~day ~root)
      |"V2_save_block"->let* block=get "block" id in let* title=get "title" text in let* preconditions=get "preconditions" Data.preconditions_of_yojson in finish(Save_block{block;title;preconditions})
      |"V2_insert_blocks"->let* parent=get "parent" id in let* roots=get "roots"(list Data.block_tree_of_yojson)in let* preconditions=get "preconditions" Data.preconditions_of_yojson in finish(Insert_blocks{parent;roots;preconditions})
      |"V2_delete_blocks"->let* root=get "root" id in let* preconditions=get "preconditions" Data.preconditions_of_yojson in finish(Delete_blocks{root;preconditions})
      |"V2_create_journal_page"->let* page=get "page" id in let* day=(let* value=get "journal_day" integer in Worker_pure_day.create value) in let* title=get "title" text in let* preconditions=get "preconditions" Data.preconditions_of_yojson in finish(Create_journal{page;day;title;preconditions})
      |"V2_set_task_status"->let* block=get "block" id in let* status=get "status" id in let* preconditions=get "preconditions" Data.preconditions_of_yojson in finish(Set_task_status{block;status;preconditions})
      |"V2_clear_task_status"->let* block=get "block" id in let* preconditions=get "preconditions" Data.preconditions_of_yojson in finish(Clear_task_status{block;preconditions})
      |"V2_set_asset_reference"->let* block=get "block" id in let* asset=get "asset" id in let* previous=get "previous"(nullable id)in let* preconditions=get "preconditions" Data.preconditions_of_yojson in finish(Set_asset_reference{block;asset;previous;preconditions})
      |_->invalid "Not a supported durable mutation command"in
    if encode intent=encoded then Ok intent else invalid "Stored mutation is not canonical"
  with exn->invalid(Printexc.to_string exn)

type commit =
  { mutation_id : Uuid.t
  ; status : Data.local_status
  ; generation : string
  ; before : string
  ; after : string
  }
type outcome = Committed of commit | Rejected of Error.t | Unknown
type recovery_item={intent:durable_intent;outcome:outcome}
type recovery_page={items:recovery_item Rrbvec.t;next:int64 option}
type original_point={generation:string;before:string;after:string}

let commit_json (value:commit)=`Assoc[
  "mutation_id",uuid value.mutation_id;"status",Data.local_status_to_yojson value.status;
  "generation",`String value.generation;"before",`String value.before;"after",`String value.after]
let commit_bytes value=String.length(Yojson.Safe.to_string(commit_json value))
let maximum_recovery_bytes=2*Data.maximum_request_bytes + Data.maximum_response_bytes + 4096
let recovery_page_bytes page=
  let outcome=function Unknown->`List[`String "Unknown"]
    |Committed proof->`List[`String "Committed";commit_json proof]
    |Rejected error->`List[`String "Rejected";Error.to_yojson error]in
  let item row=`Assoc["intent",`String(encode row.intent);"outcome",outcome row.outcome]in
  String.length(Yojson.Safe.to_string(`Assoc[
    "items",`List(Rrbvec.to_list(Rrbvec.map item page.items));
    "next",option(fun value->`String(Int64.to_string value))page.next]))
let committed_point intent (proof:commit)=
  let token prefix text=let prefix=prefix^":v1:"in String.length text>String.length prefix && String.starts_with ~prefix text in
  if commit_bytes proof>Data.maximum_response_bytes then Error "Original commit exceeds byte budget"else
  if Uuid.equal proof.mutation_id(mutation_id intent) && token "generation" proof.generation
    && token "projection" proof.before && token "projection" proof.after
    && (match proof.status with Data.V2_applied->proof.before<>proof.after|V2_no_change->proof.before=proof.after|V2_already_applied->false)
  then Ok{generation=proof.generation;before=proof.before;after=proof.after}
  else Error "Result does not establish the exact original durable commit"
module For_worker=struct
  let commit ~mutation_id ~status ~generation ~before ~after={mutation_id;status;generation;before;after}
end
