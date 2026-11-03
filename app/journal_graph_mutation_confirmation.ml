module Graph = Logseq_db_types.Graph_types
module Protocol = Logseq_db_worker.Protocol
module Worker = Journal_worker_coordination.Worker_api

type purpose =
  | Updated of { block_id : string }
  | Update_conflict_refresh of { block_id : string }
  | Delete_conflict_refresh of { block_id : string }

type read =
  { purpose : purpose
  ; block_id : string
  ; children : Protocol.v2_child_member Rrbvec.t
  ; version : (string * string * string) option
  ; retries : int
  ; stamp : int64
  ; after : Protocol.v2_child_member Worker.continuation option
  }

type confirmation =
  { purpose : purpose
  ; block_id : string
  ; value : Protocol.v2_block_record
  ; revision : string
  ; page : Graph.page
  ; page_revision : string
  ; scope_revision : string
  ; children : Protocol.v2_child_member Rrbvec.t
  }

type planning = (Protocol.request, string) result

type step =
  | Continue of planning
  | Confirmed of confirmation
  | Absent of {purpose:purpose; block_id:string}
  | Failed of string

type ports =
  { now : unit -> int64
  ; plan_read : source_epoch:int64 -> read -> Protocol.command -> Protocol.request
  }

type t = { latest : (string, int64) Hashtbl.t }

let create () = { latest = Hashtbl.create 32 }
let reset t = Hashtbl.clear t.latest
let current t (read : read) = Hashtbl.find_opt t.latest read.block_id = Some read.stamp

let plan t ~ports (value : read) cursor =
  match Graph.Uuid.of_string value.block_id with
  | Error message -> Error ("block UUID: " ^ message)
  | Ok block ->
    let stamp = ports.now () in
    Hashtbl.replace t.latest value.block_id stamp;
    Ok
      (ports.plan_read
         ~source_epoch:stamp
         { value with stamp; after = cursor }
         (Protocol.V2_get_outline_block_summary
            { block; limit = Protocol.default_page_size; cursor = None }))
;;

let start t ~ports purpose =
  let block_id =
    match purpose with
    | Updated { block_id }
    | Update_conflict_refresh { block_id }
    | Delete_conflict_refresh { block_id } -> block_id
  in
  plan
    t
    ~ports
    { purpose
    ; block_id
    ; children = Rrbvec.empty
    ; version = None
    ; retries = 0
    ; stamp = 0L
    ; after = None
    }
    None
;;

let retry_stale t ~ports (value : read) =
  if value.retries >= 2
  then None
  else
    Some
      (plan
         t
         ~ports
         { value with
           children = Rrbvec.empty
         ; version = None
         ; retries = value.retries + 1
         }
         None)
;;

let receive_summary
      t
      ~ports
      (summary : read)
      ~lookup
      ~page
      ~items
      ~next_cursor
      ~scope_revision
      ~generation
      ~projection_revision
  =
  let version = generation, projection_revision, scope_revision in
  if Option.is_some next_cursor && next_cursor = summary.after
  then Failed "The target child cursor did not advance."
  else if Option.is_some summary.version && summary.version <> Some version
  then (
    match retry_stale t ~ports summary with
    | Some planning -> Continue planning
    | None -> Failed "The target changed repeatedly during confirmation.")
  else (
    match
      (lookup : Protocol.v2_block_lookup), (page : Protocol.v2_page_lookup option)
    with
    | ( V2_present_block { value; revision }
      , Some (V2_present_page { page; revision = page_revision }) )
      when String.equal (Graph.Uuid.to_string value.block.uuid) summary.block_id
           && Graph.Uuid.equal value.block.page page.uuid
           && List.to_seq items
              |> Seq.for_all (fun (item : Protocol.v2_child_member) ->
                Graph.Uuid.equal item.value.block.parent value.block.uuid
                && Graph.Uuid.equal item.value.block.page page.uuid) ->
      let children = Rrbvec.append_list summary.children items in
      (match next_cursor with
       | Some cursor ->
         Continue
           (plan t ~ports { summary with children; version = Some version } (Some cursor))
       | None ->
         Confirmed
           { purpose = summary.purpose
           ; block_id = summary.block_id
           ; value
           ; revision
           ; page
           ; page_revision
           ; scope_revision
           ; children
           })
    | V2_missing_block {uuid;_}, _
      when Graph.Uuid.to_string uuid = summary.block_id
           && summary.after = None
           && items = [] && next_cursor = None && Rrbvec.is_empty summary.children ->
      (match summary.purpose with
       | Delete_conflict_refresh _ -> Absent {purpose=summary.purpose;block_id=summary.block_id}
       | Updated _ | Update_conflict_refresh _ ->
         Failed "The canonical mutation target is unavailable.")
    | _ -> Failed "The canonical mutation target is unavailable or mismatched.")
;;

let worker_query (read : read) =
  Worker.Block_summary
    { block = Graph.Uuid.of_string read.block_id |> Result.get_ok; after = read.after }
;;

let reference_fragment (summary : read) ~target ~final_children =
  Rrbvec.push_front
    (Rrbvec.map
       (fun (item : Protocol.v2_child_member) -> item.value)
       (Rrbvec.append_list summary.children final_children))
    target
;;

module Pure_insertion = struct
  type choice =
    { revision : int64
    ; task_state : Journal_model.task_state
    ; resolved : Graph.Uuid.t option
    ; required : bool
    }
  type stage =
    { wire : Protocol.command
    ; choice : choice option
    ; binding : (Worker.mutation_intent * Worker.presentation) option
    ; outcome : Worker.mutation_progress option
    ; acknowledged : bool
    ; submission_recovered : bool
    ; acknowledgement_recovered : bool
    }
  type phase = Writing of int | Canonical of int * bool | Parent | Applying | Acknowledging of int | Finished
  type recovery = {mutation_id:string;round:int64;delay:float}
  type t =
    { command : Journal_graph_projection.create_child
    ; page : Graph.page option
    ; append_day : int option
    ; capture : Journal_graph_projection.capture option
    ; desired : choice
    ; stages : stage Rrbvec.t
    ; phase : phase
    ; round : int64
    ; canonical : Worker.block_summary option
    ; failure : Worker.error option
    ; current : Worker.presentation option
    ; applied : Worker.presentation option
    ; origin : Worker.session option
    ; read_recovered : bool
    ; recovery : recovery option
    ; recovery_armed : bool
    ; backoff : int
    }
  type action =
    | Write of int * int64 * Protocol.command
    | Read_child of int64
    | Read_parent of int64 * Worker.block_summary
    | Present of int64
    | Acknowledge of int * int64 * Worker.mutation_intent * Worker.presentation
    | Complete
    | Ignore
    | Wait of string

  let command t = t.command
  let page t = Option.get t.page
  let failure t = t.failure
  let stage t index = Rrbvec.nth t.stages index
  let wire_id = function
    | Protocol.V2_insert_blocks {mutation_id;_}
    | V2_append_journal {mutation_id;_}
    | V2_set_task_status {mutation_id;_}
    | V2_clear_task_status {mutation_id;_} -> mutation_id
    | _ -> assert false
  let stage_id stage = wire_id stage.wire
  let mutation = function
    | Protocol.V2_insert_blocks {parent;roots;preconditions;_} -> Worker.Insert_blocks {parent;roots;preconditions}
    | V2_set_task_status {block;status;preconditions;_} -> Set_task_status {block;status;preconditions}
    | V2_clear_task_status {block;preconditions;_} -> Clear_task_status {block;preconditions}
    | _ -> invalid_arg "Unsupported child mutation"
  let rec capture_node (node:Protocol.v2_append_node) : Worker.capture_node =
    {block_id=node.block_id;title=node.title;task_status=node.task_status;
      children=Rrbvec.map capture_node node.children}
  let wire_intent session wire = match wire with
    | Protocol.V2_append_journal{mutation_id;journal_day;root;_}->
      (match Worker.journal_day journal_day with
       | Error error->Error error
       | Ok day->match Worker.append_intent session ~mutation_id ~block_id:root.block_id
           ~day ~title:root.title ~task_status:root.task_status ~children:(Rrbvec.map capture_node root.children) with
         | Error error->Error error
         | Ok intent->Worker.restore_mutation_intent session (Worker.encode_append_intent intent))
    | (Protocol.V2_insert_blocks _|V2_set_task_status _|V2_clear_task_status _) as wire->
      Worker.mutation_intent session ~mutation_id:(wire_id wire)(mutation wire)
    | _->Error(Worker.Invalid_input "Unsupported durable insertion wire.")
  let stage_intent session stage = wire_intent session stage.wire
  let replace_stage t index value =
    {t with stages=Rrbvec.mapi (fun i old -> if i=index then value else old) t.stages}
  let status_mutation_id ~domain ~mutation_id ~revision ~block status =
    let selection=match status with None->"clear"|Some id->"set:" ^ Graph.Uuid.to_string id in
    let bytes=Printf.sprintf "logseq-journal:%s-status:v1:%s:%s:%Ld:%s"
      domain (String.lowercase_ascii mutation_id) (Graph.Uuid.to_string block) revision selection
      |> Digest.BLAKE128.string |> Bytes.of_string in
    Bytes.set bytes 6 (Char.chr ((Char.code(Bytes.get bytes 6) land 0x0f) lor 0x80));
    Bytes.set bytes 8 (Char.chr ((Char.code(Bytes.get bytes 8) land 0x3f) lor 0x80));
    let hex=Digest.BLAKE128.to_hex(Bytes.to_string bytes) in
    Printf.sprintf "%s-%s-%s-%s-%s" (String.sub hex 0 8) (String.sub hex 8 4)
      (String.sub hex 12 4) (String.sub hex 16 4) (String.sub hex 20 12)
      |> Graph.Uuid.of_string |> Result.get_ok
  let writing t index =
    if t.round=Int64.max_int then t,Wait "Child attempt counter exhausted."
    else let round=Int64.succ t.round in
      {t with phase=Writing index;round;recovery=None;recovery_armed=false},Write(index,round,(stage t index).wire)
  let choice_matches task_state resolved = match task_state,resolved with
    | Journal_model.No_status,None | Default_status,Some _ -> true
    | Status value,Some id -> String.lowercase_ascii value=Graph.Uuid.to_string id
    | _ -> false
  let fresh wire choice = {wire;choice;binding=None;outcome=None;acknowledged=false;submission_recovered=false;acknowledgement_recovered=false}
  let start_value ~(command:Journal_graph_projection.create_child) ~page ~resolved_status ~insert =
    let desired={revision=command.status_intent_revision;task_state=command.task_state;
      resolved=resolved_status;required=command.status_confirmation} in
    let append_day=match insert with Protocol.V2_append_journal{journal_day;_}->Some journal_day|_->None in
    let value=fresh insert (Option.map (fun _->desired) append_day) in
    let valid=match insert with
      | Protocol.V2_insert_blocks {mutation_id;parent;roots=[root];_}->
        Graph.Uuid.to_string mutation_id=String.lowercase_ascii command.mutation_id
        && Graph.Uuid.to_string parent=String.lowercase_ascii command.parent_block_id
        && Graph.Uuid.to_string root.uuid=String.lowercase_ascii command.block_id
        && root.title=command.source && root.children=[]
      | V2_append_journal{mutation_id;root;_}->
        Graph.Uuid.to_string mutation_id=String.lowercase_ascii command.mutation_id
        && Graph.Uuid.to_string root.block_id=String.lowercase_ascii command.block_id
        && root.title=command.source && root.task_status=resolved_status
        && Protocol.valid_append_node root
      | _->false in
    if not valid || command.status_intent_revision<0L || not(choice_matches command.task_state resolved_status)
    then Error "The initial child payload does not match its admitted business command."
    else Ok({command;page;append_day;capture=None;desired;stages=Rrbvec.singleton value;phase=Writing 0;round=1L;
      canonical=None;failure=None;current=None;applied=None;origin=None;read_recovered=false;recovery=None;recovery_armed=false;backoff=0}, Write(0,1L,insert))
  let start ~command ~page ~resolved_status ~insert =
    start_value ~command ~page:(Some page) ~resolved_status ~insert
  let capture_command (capture:Journal_graph_projection.capture) : Journal_graph_projection.create_child =
    {mutation_id=capture.mutation_id;calendar_generation=0L;block_id=capture.block_id;
      parent_block_id="";expected_parent_revision="";sibling_order=capture.sibling_order;
      source=capture.source;task_state=capture.task_state;status_confirmation=capture.status_confirmation;
      status_intent_revision=capture.status_intent_revision;creation_time=capture.creation_time}
  let start_capture ~(command:Journal_graph_projection.capture) ~resolved_status ~insert = match insert with
    | Protocol.V2_append_journal{journal_day;_}
      when journal_day=Journal_time.local_day command.Journal_graph_projection.creation_time ->
      (match insert with
       | V2_append_journal{root;_} when Rrbvec.length root.children=List.length command.children
         && Seq.for_all2 (fun (node:Protocol.v2_append_node) (child:Journal_graph_projection.capture_child)->
           Graph.Uuid.to_string node.block_id=String.lowercase_ascii child.block_id
           && node.title=child.source && Rrbvec.is_empty node.children
           && choice_matches child.task_state node.task_status)
           (Rrbvec.to_seq root.children)(List.to_seq command.children)->
         Result.map(fun(t,action)->{t with capture=Some command},action)
           (start_value ~command:(capture_command command) ~page:None ~resolved_status ~insert)
       | _->Error "The atomic Capture children do not match the admitted payload.")
    | _->Error "Capture requires its admitted day and atomic Append payload."
  let insert_rejected t = Rrbvec.exists (fun stage ->
    (match stage.wire with Protocol.V2_insert_blocks _|V2_append_journal _->true|_->false) &&
    match stage.outcome with Some(Worker.Rejected _)->true|_->false) t.stages
  let terminal t = t.phase=Finished
  let retarget t ~(command:Journal_graph_projection.create_child) ~resolved_status =
    let original=t.command in
    if terminal t then Error "This child operation is already settled."
    else if {command with task_state=original.task_state;status_intent_revision=original.status_intent_revision;
         status_confirmation=original.status_confirmation} <> original
    then Error "The retry does not belong to the frozen child insertion."
    else if command.status_intent_revision<t.desired.revision then Error "The child choice is obsolete."
    else if command.status_intent_revision=t.desired.revision then
      if command.task_state<>t.desired.task_state then Error "One child choice revision has two meanings."
      else Ok t
    else if not(choice_matches command.task_state resolved_status) then Error "The child status choice is invalid."
    else Ok {t with command;desired={revision=command.status_intent_revision;
      task_state=command.task_state;resolved=resolved_status;required=true};applied=None}
  let matches_child t (command:Journal_graph_projection.create_child) =
    let original=t.command in
    t.capture=None && t.append_day=None &&
      {command with task_state=original.task_state;status_confirmation=original.status_confirmation;
        status_intent_revision=original.status_intent_revision}=original
  let matches_capture t (command:Journal_graph_projection.capture) = match t.capture with
    | Some original->{command with task_state=original.task_state;
        status_confirmation=original.status_confirmation;
        status_intent_revision=original.status_intent_revision}=original
    | None->false
  let retarget_capture t ~(command:Journal_graph_projection.capture) ~resolved_status =
    match t.capture with
    | Some original when {command with task_state=original.task_state;
        status_confirmation=original.status_confirmation;
        status_intent_revision=original.status_intent_revision}=original ->
      Result.map(fun t->{t with capture=Some command})
        (retarget t ~command:(capture_command command) ~resolved_status)
    | _->Error "Capture retry does not belong to its frozen atomic payload."
  let bind t ~index ~round ~intent ~presentation =
    match t.phase with
    | Writing expected when expected=index && round=t.round ->
      let current=stage t index in
      let same_origin=Option.fold ~none:true ~some:(fun previous->Worker.same_logical_graph
        previous (Worker.presentation_session presentation)) t.origin in
      if not same_origin then None else
      (match stage_intent (Worker.presentation_session presentation) current with
       | Ok expected when Worker.encode_mutation_intent expected=Worker.encode_mutation_intent intent ->
         Some{(replace_stage t index {current with binding=Some(intent,presentation);acknowledged=false}) with current=Some presentation;origin=Some(Worker.presentation_session presentation)}
       | _ -> None)
    | _ -> None
  let exact_child t (summary:Worker.block_summary) =
    match summary.lookup,summary.page with
    | Protocol.V2_present_block {value;_},Some(V2_present_page {page;_}) ->
      Graph.Uuid.to_string value.block.uuid=t.command.block_id
      && value.block.page=page.uuid && not page.recycled
      && (match t.append_day with
        | Some day->value.block.parent=page.uuid && page.kind=Graph.Journal_page{journal_day=day}
        | None->Graph.Uuid.to_string value.block.parent=t.command.parent_block_id
          && Option.exists(fun (original:Graph.page)->page.uuid=original.uuid)t.page)
    | _ -> false
  let status_wire t (summary:Worker.block_summary) =
    match summary.lookup with
    | Protocol.V2_present_block {value;revision} ->
      let block=value.block.uuid in
      let mutation_id=status_mutation_id ~domain:(if t.append_day=None then "child" else "capture") ~mutation_id:t.command.mutation_id
        ~revision:t.desired.revision ~block t.desired.resolved in
      let preconditions:Protocol.v2_preconditions={blocks=[block,revision];pages=[];scopes=[]} in
      (match t.desired.resolved with
       | None->Protocol.V2_clear_task_status{mutation_id;block;preconditions}
       | Some status->V2_set_task_status{mutation_id;block;status;preconditions})
    | _ -> assert false
  let canonical_state t (summary:Worker.block_summary) =
    let page=match summary.page with Some(Protocol.V2_present_page{page;_})->Some page|_->t.page in
    {t with canonical=Some summary;page}
  let after_child t summary =
    if not(exact_child t summary) then t,Wait "The canonical child is absent or belongs to another parent."
    else if t.append_day<>None then {(canonical_state t summary) with phase=Applying},Present t.round
    else {(canonical_state t summary) with phase=Parent},Read_parent(t.round,summary)
  let next_choice t summary =
    if not(exact_child t summary) then t,Wait "The saved child is no longer available in its parent."
    else
      let previous=stage t (Rrbvec.length t.stages-1) in
      let next=fresh(status_wire t summary)(Some t.desired) in
      (* Only acknowledged history may be compacted. Rounds reject callbacks
         from earlier indices, while each wire retains its original intent. *)
      writing {(canonical_state t summary) with stages=Rrbvec.of_list [previous;next];
        failure=None;applied=None} 1
  let retry t = match t.phase with
    | Writing index->writing t index
    | Finished when terminal t ->t,Ignore
    | Canonical(index,next) ->
      if t.round=Int64.max_int then t,Wait "Child attempt counter exhausted."
      else let round=Int64.succ t.round in
        {t with phase=Canonical(index,next);round;recovery=None;recovery_armed=false},Read_child round
    | Parent|Applying|Acknowledging _|Finished->
      let index=Rrbvec.length t.stages-1 in
      writing {t with applied=None} index
  let recover t message =
    let next=match t.phase with
      | Writing index ->
        let current=stage t index in
        if current.submission_recovered then None
        else Some(replace_stage t index {current with submission_recovered=true})
      | Acknowledging index ->
        let current=stage t index in
        if current.acknowledgement_recovered then None
        else Some(replace_stage t index {current with acknowledgement_recovered=true})
      | Canonical _|Parent|Applying|Finished ->
        if t.read_recovered then None else Some{t with read_recovered=true} in
    match next with
    |Some next->retry next
    |None when t.recovery<>None->t,Wait message
    |None->let delay=min 30.(0.5 *. (2. ** float_of_int t.backoff))in
      {t with recovery=Some{mutation_id=t.command.mutation_id;round=t.round;delay};recovery_armed=false;backoff=min 6(t.backoff+1)},Wait message
  let take_recovery t = match t.recovery,t.recovery_armed with
    |Some recovery,false->{t with recovery_armed=true},Some recovery
    |_->t,None
  let resume_recovery t recovery =
    if t.recovery=Some recovery && t.recovery_armed then retry t else t,Ignore

  let receive t ~index ~round progress =
    match t.phase with
    | Writing expected when expected=index && round=t.round ->
      let current=stage t index in
      (match current.binding,progress with
       | Some(intent,presentation),Worker.Confirmed confirmation
         when Worker.confirmation_presentation confirmation=presentation
           && Worker.encode_mutation_intent(Worker.receipt_intent(Worker.confirmation_receipt confirmation))
              =Worker.encode_mutation_intent intent ->
         let original=match current.outcome with
           | Some(Worker.Confirmed value)->Some(Worker.confirmation_receipt value)
           | Some(Committed_pending_presentation receipt)->Some receipt
           | _->None in
         if Option.exists(fun old->Worker.receipt_revisions old<>
             Worker.receipt_revisions(Worker.confirmation_receipt confirmation)) original
         then t,Wait "The original child commit proof changed; it has been retained."
         else let next=replace_stage t index {current with outcome=Some progress} in
         (match Worker.confirmation_primary confirmation with
          | Worker.Confirmed_block summary when index<Rrbvec.length t.stages-1 ->
            if exact_child next summary then after_child next summary
            else next,Wait "The committed child is no longer available in its parent."
          | Worker.Confirmed_block summary->after_child next summary
          | _->next,Wait "The committed child is no longer available in its parent.")
       | Some _,Worker.Rejected _ when (match current.outcome with
           | Some(Worker.Confirmed _|Committed_pending_presentation _)->true|_->false) ->
         t,Wait "A committed child operation cannot become a rejection."
       | Some _,Worker.Rejected error ->
         let next=replace_stage t index {current with outcome=Some progress} in
         if (match current.wire with Protocol.V2_insert_blocks _|V2_append_journal _->true|_->false)
         then {next with failure=Some error;phase=Applying},Present t.round
         else {next with failure=Some error;phase=Canonical(index,false)},Read_child t.round
       | Some _,(Worker.Outcome_unknown|Committed_pending_presentation _) ->
         let outcome=match current.outcome with
           | Some(Worker.Confirmed _|Committed_pending_presentation _) as known->known
           | _->Some progress in
         let next=replace_stage t index {current with outcome} in
         recover next "The save could not be confirmed."
       | _->t,Wait "The child confirmation does not match its bound operation.")
    | _->t,Ignore
  let read_child t ~round summary =
    match t.phase with
    | Canonical(_,true) when round=t.round -> next_choice t summary
    | Canonical(_,false) when round=t.round -> after_child t summary
    | _->t,Ignore
  let projection_ready t ~round = match t.phase with
    | Parent when t.round=round ->{t with phase=Applying},Present t.round
    | _->t,Ignore
  let canonical t = t.canonical
  let presentation t = t.current
  let rec settle_from t presentation index =
    if index=Rrbvec.length t.stages then
      let latest=stage t (index-1) in
      let matches=match latest.choice with
        | Some choice->choice.revision=t.desired.revision
        | None->not t.desired.required && t.desired.resolved=None in
      if matches || insert_rejected t then {t with phase=Finished},Complete
      else if t.round=Int64.max_int then t,Wait "Child attempt counter exhausted."
      else let round=Int64.succ t.round in
        {t with phase=Canonical(index-1,true);round;applied=None},Read_child round
    else
      let current=stage t index in
      if current.acknowledged then settle_from t presentation (index+1)
      else match current.binding,current.outcome with
        | Some(intent,initiator),Some(Worker.Rejected _) when initiator=presentation ->
          if t.round=Int64.max_int then t,Wait "Child attempt counter exhausted."
          else let round=Int64.succ t.round in
            {t with phase=Acknowledging index;round},Acknowledge(index,round,intent,presentation)
        | Some(intent,_),Some(Worker.Confirmed proof)
          when Worker.confirmation_presentation proof=presentation ->
          if t.round=Int64.max_int then t,Wait "Child attempt counter exhausted."
          else let round=Int64.succ t.round in
            {t with phase=Acknowledging index;round},Acknowledge(index,round,intent,presentation)
        | Some _,Some(Worker.Rejected _|Confirmed _) ->
          writing {t with applied=None} index
        | _->t,Wait "An unknown child operation cannot be acknowledged."
  let applied t ~round presentation = match t.phase with
    | Applying when t.round=round && t.current=Some presentation ->
      settle_from {t with applied=Some presentation} presentation 0
    | _->t,Ignore
  let acknowledged t ~index ~round result = match t.phase,t.applied with
    | Acknowledging expected,Some presentation when expected=index && round=t.round ->
      (match result with
       | Error message->recover t message
       | Ok ()->settle_from (replace_stage t index {(stage t index)with acknowledged=true}) presentation (index+1))
    | _->t,Ignore

  let stage_wire stage = stage.wire
  let stage_mutation stage = mutation stage.wire
  let rebind_ack t ~index ~round ~intent ~presentation =
    match t.phase with
    | Acknowledging expected when expected=index && round=t.round ->
      bind {t with phase=Writing index;applied=None} ~index ~round ~intent ~presentation
    | _ -> None

  let resolved_status t = t.desired.resolved
  let interrupted t ~index ~round message = match t.phase with
    | Writing expected | Acknowledging expected when expected=index && t.round=round -> recover t message
    | _ -> t,Ignore
  let read_failed t ~round message =
    if t.round=round && (match t.phase with Parent|Canonical _|Writing _->true|_->false)
    then recover t message else t,Ignore

end

module Pure_child = Pure_insertion
