(** {1 TLDR}

    Explain the important Journal execution paths using existing specification
    types: App coordination, DB Worker execution, Sync, durable writes, observation
    and resource retirement. This file contains documentation only. It exports no
    types or values, adds no runtime owner and is not a new Dune virtual library.

    The examples use these aliases for existing modules, not new interfaces:
    {[
      module A = Journal_worker_coordination.Worker_api
      module AC = Journal_worker_coordination.Worker_pure_coordinator
      module AR = Journal_worker_coordination.Worker_effect_runner
      module W = Logseq_db_worker_pure_reducer.Core
      module WR = Logseq_db_worker_effect_runner.Effect_runner
      module S = Logseq_sync_pure_reducer.Core
      module SR = Logseq_sync_effect_runner.Effect_runner
    ]}

    There are three policy boundaries, not three independent App event loops:
    {ul
    {- App coordination owns typed tickets, sessions, presentation checks and
       request/resource retirement. The host owns UI/business state.}
    {- Worker owns graph lifecycle, scoped DB execution and the embedded Sync
       reducer. Reads and durable writes take different execution paths.}
    {- Sync decides network/bootstrap/outbox work. Its network runner performs
       I/O; database work is delegated back to Worker.}}

    Each reducer returns a next state plus ordered work. Install the state before
    interpreting the work. I/O callbacks enqueue later serialized events; they do
    not recursively call a reducer or directly update the UI.

    Admission, local durable commitment, confirmation for the current presentation
    and server synchronization are separate facts. Cancellation is not rollback.
    A cleanup request is not a physical release acknowledgement.

    OCaml blocks below are illustrative local functions built from the existing
    spec API; their helper names are not exported by this file or the repository.
    Trace blocks describe values produced/consumed by owners, not instructions to
    manufacture private constructors or sealed capabilities. Host-only operations
    are stated explicitly rather than replaced by fictional APIs.

    {1 Minimal usage example}

    Read one Journal page after real bootstrap has supplied an Open [A.session].
    The caller supplies the serialized coordinator state and its existing runner.
    This request never creates a missing Journal page.
    {[
      let request_journal
          (state : AC.t ref)
          (runner : AR.t)
          (session : A.session)
          ~yyyymmdd =
        match A.journal_day yyyymmdd with
        | Error error -> Error error
        | Ok day ->
          match A.read_budget session
                  ~maximum_items:1 ~maximum_bytes:4096 with
          | Error error -> Error error
          | Ok budget ->
            match AC.request !state session (A.Query (budget, A.Journal day)) with
            | Error error -> Error error
            | Ok (ticket, transition) ->
              state := transition.next;
              List.iter (AR.submit runner) transition.instructions;
              Ok ticket
    ]}

    The result is an [A.page option AC.ticket], not the page itself. The existing
    mailbox pump later calls [AR.on_event]; the runner queues [AC.Completed] and
    the host applies it through the same serialized coordinator turn:
    {[
      let app_turn (state : AC.t ref) (runner : AR.t) (event : AC.event) =
        let transition = AC.step !state event in
        state := transition.next;
        List.iter (AR.submit runner) transition.instructions

      let journal_reply
          (state : AC.t ref)
          (ticket : A.page option AC.ticket) =
        AC.reply (AC.view !state) ticket

      let forget_consumed_reply state runner ticket =
        let transition = AC.step !state (AC.Forget ticket) in
        state := transition.next;
        List.iter (AR.submit runner) transition.instructions
    ]}

    [None] from [AC.reply] means pending; [Answered (Ok None)] means the page is
    absent; [Answered (Ok (Some page))] carries the actual page. Handle
    [Not_admitted], [Answered (Error error)] and [Interrupted] separately. The host
    consumes the reply before calling the local [forget_consumed_reply] example.
    If consumption is deferred to another App turn, revalidate the reply with
    [AC.revalidate_reply] against that turn's view before applying it. Forgetting
    a ticket does not release an observation, demand or file lease.

    {1 Construction and validation}

    {2 Host startup and the first usable session}

    Native bridge startup, authenticated-user/token exchange, graph catalog,
    selection/unlock policy, the shared client and the single mailbox pump remain
    host responsibilities. They are not APIs of this document or the App
    coordination spec. The current integration starts the Worker runtime from
    [app/application.ml] and borrows that client in
    [app/journal_worker_coordination_host.ml].

    The following example accepts an already verified client/account. [post] is
    a host-supplied queue callback of type [AC.event -> unit]; [publish] consumes
    [AC.view]. Neither may synchronously re-enter a coordinator turn. Store the
    returned state/runner before draining the queued binding event.
    {[
      let create_coordination
          (client : AR.client)
          ~client_id ~managed_origin ~user_id ~post ~publish =
        let state = ref (AC.initial ~client_id) in
        match AR.create ~client ~managed_origin ~user_id ~post ~publish with
        | Error error -> Error error
        | Ok runner -> Ok (state, runner)
    ]}

    The actual sequence is:
    {v
      AR.create
        -> queued AC.Worker_bound binding
        -> AC.step
        -> private AC.Bootstrap instruction
        -> AR.submit
        -> existing Service registration + authoritative baseline/replay
        -> queued AC.Bootstrap_received (binding, A.Ready projection)
        -> AC.step
    v}

    [AR.create] success is not [Ready]. [Ready] with no resident graphs is valid
    and different from [Bootstrap_not_ready]. A usable session comes from an
    Open resident in [A.residents projection]; selected presentation is obtained
    with [A.selected projection], and its session with [A.presentation_session].
    [AC.validate_session] and request admission still check current authority.
    Do not construct a session from a UUID or optimistic UI selection.

    This App baseline is distinct from Sync graph bootstrap, which may restore a
    local mirror or download a snapshot. Registration can succeed while a graph
    is still Opening. [Bootstrap_failed] and [Binding_revoked] remain observable;
    an explicit [AC.Retry_bootstrap] respects old-registration release before
    replacement. Old binding callbacks cannot authorize the replacement.

    {2 Scope and data validation}

    [A.session] is execution authority; [A.presentation] is current-view authority.
    Focus changes can preserve a resident session while replacing presentation.
    Close/reopen, account replacement and rebinding invalidate execution identity.
    [A.read_budget], [A.journal_day], [A.append_intent] and [A.mutation_intent]
    validate input; DTOs, UUIDs and successful shape checks alone grant no authority.

    Some spec signatures deliberately refer to contracts outside [spec/], notably
    [AR.client], [Worker_pure_read.packed_query]/[answer],
    [Logseq_db_worker_contract.Config.t] and
    [Logseq_db_worker_contract.Worker_pure_mutation.durable_intent]/[outcome].
    Those are existing boundary inputs, not types defined here. The examples keep
    them opaque and never invent their representation or a packing function.

    {1 Capability details}

    {2 App request, Service transport and Worker read}

    [AC.request] returns the exact typed ticket together with its transition.
    Apply that transition before planning another request, including an identical
    concurrent request. Only the coordinator produces private [AC.Send].
    {v
      A.Query (budget, query)
        -> AC.request
        -> AC.Send (ticket, session, request)
        -> AR.submit
        -> Service.Coordination_query             [implementation boundary]
        -> scoped Worker read wrapper              [implementation boundary]
        -> WR.await_reply
        -> queued W.Graph_request_for_scope { scope; id; read }
        -> W.step
        -> W.Run_worker
             (W.Request (ticket, W.Execute_request { database; read }))
        -> WR.submit and DB I/O
        -> queued W.Runner_completed (W.Execute_request_completed ...)
        -> W.step
        -> W.Publish (W.Reply (id, answer))
        -> resolve the original await_reply waiter
        -> Service response and existing mailbox
        -> AR.on_event
        -> queued AC.Completed (ticket, reply)
        -> AC.step, AC.reply, business projection and UI
    v}

    App tickets, actual accepted mailbox IDs and Worker request/effect tickets are
    different identities. The transport associates real accepted IDs; it does not
    infer ownership from a response's shape or success. Worker validates pending
    identity/generation before publishing a reply. [W.Publish (W.Reply ...)] has a
    dedicated waiter-resolution path, not an ordinary broadcast-only callback.

    This boundary example accepts an existing packed read and a host queue callback;
    packing the App query is not an API in the selected spec files:
    {[
      let worker_read
          (runner : WR.t)
          (scope : S.graph_scope)
          (id : W.request_id)
          (read : Worker_pure_read.packed_query)
          ~(post : W.event -> unit) =
        WR.await_reply runner ~id ~read
          ~post:(fun () -> post (W.Graph_request_for_scope { scope; id; read }))
    ]}

    The shared App pump calls [AR.on_event] before legacy response dispatch:
    {ul
    {- [Consumed]: this owner handled the response, including owned failures,
       cancellation or malformed receipts. Never also run a generic failure path.}
    {- [Unowned_response]: forward only to another registered request owner.}
    {- [Broadcast]: other interested owners receive it once; this runner already
       processed its share.}
    {- [Dropped_envelope]: discard a foreign/stale envelope.}}
    An error in [delivery.error] does not erase its routing disposition.

    {2 Timeline, detail and bounded continuation}

    Business reducers still decide date ranges, feed order, Favorites, navigation,
    detail expansion and Capture editing. They translate those decisions into
    existing typed queries, rather than becoming part of Worker policy:
    {ul
    {- [A.Journals] reads a bounded date range and initial revision.}
    {- [A.Tree], [A.Children] and [A.Child_members] read bounded structure.}
    {- [A.Page] and [A.Outline_block] preserve present/missing results.}
    {- [A.Block_summary] reads a target, owning page and child slice atomically.}
    {- [A.Favorites], [A.Task_statuses] and [A.Task_status_definitions] retain their
       real DTOs, ordering, revisions and missing slots.}}

    A returned continuation is bound to the session, original query parameters,
    revision and budget. Use [A.continuation_budget] and the same query when
    continuing; a continuation does not renew a stale session or snapshot. Empty
    data is a successful observation. A partial slice is not a complete tree or an
    exact total child count. The host applies [page_data], [block_data] and other
    canonical DTOs through its existing graph projection, not a new UI model here.

    {2 Capture Append and durable mutation}

    Create stable mutation/block identities and the complete bounded intent before
    first send. The following local helper makes the host's persistence obligation
    explicit. [persist] is a caller-supplied [bytes -> (unit, A.error) result]; it
    returns [Ok ()] only after durable storage. It is not a spec module function.
    A failed [persist] must not send the request.
    {[
      let append_to_journal
          (state : AC.t ref) (runner : AR.t) (session : A.session)
          ~mutation_id ~block_id ~day ~title ~task_status ~children
          ~(persist : bytes -> (unit, A.error) result) =
        match A.append_intent session ~mutation_id ~block_id ~day ~title
                ~task_status ~children with
        | Error error -> Error error
        | Ok intent ->
          let durable = A.Append_intent intent in
          match persist (A.encode_durable_intent durable) with
          | Error error -> Error error
          | Ok () ->
            match AC.request !state session (A.Append intent) with
            | Error error -> Error error
            | Ok (ticket, transition) ->
              state := transition.next;
              List.iter (AR.submit runner) transition.instructions;
              Ok (durable, ticket)
    ]}

    Editing an existing block uses [A.mutation_intent session ~mutation_id
    (A.Save_block { block; title; preconditions })], persists the corresponding
    [A.Mutation_intent], then requests [A.Mutate intent]. Other mutations use the
    existing Insert/Delete/Create_journal/status/asset-reference constructors.
    Append is atomic: Worker resolves or creates the journal by day and commits
    the complete root/child/status payload. Separate create/insert/status calls
    are not an implementation of the same contract.

    Durable writes do not travel through [W.Execute_request]:
    {v
      A.Append / A.Mutate
        -> AC.request / AR.submit
        -> Service.Coordination_mutation           [implementation boundary]
        -> scoped durable-mutation wrapper          [implementation boundary]
        -> WR.durable_mutation
        -> persist immutable local intent
        -> commit local intent / outbox state
        -> queued W.Sync_event (S.Local_graph_outbox_changed scope)
        -> local committed proof returned through Service to App
    v}

    Posting the outbox notification precedes returning the local proof. Its later
    consumption and the App reply remain separate: neither proves completion of
    the other or server synchronization.

    The Worker runner API can be shown without inventing its referenced intent:
    {[
      let durable_write
          (runner : WR.t)
          (scope : S.graph_scope)
          (intent : Logseq_db_worker_contract.Worker_pure_mutation.durable_intent)
          ~(current : unit -> bool) =
        WR.durable_mutation runner ~scope ~intent ~current
    ]}

    [current] is a host-supplied check of the actual account/graph/binding owner,
    not a constant [true]. The DB owner deduplicates by immutable identity and
    bytes. The same ID with a different payload conflicts. On success it posts
    [Local_graph_outbox_changed]; a failed/unknown operation cannot invent that
    commit proof. Source callbacks and durable outcomes retain their real owner.

    {2 Local commitment versus presentation confirmation}

    [A.submission_outcome] is separate from [A.mutation_progress]:
    {ul
    {- [Submission_committed receipt] proves local durability, not current UI
       presentation or server acceptance.}
    {- [Submission_unknown] retains the original immutable intent for recovery.}
    {- [Submission_rejected error] requires evidence that the intent did not apply.}}

    [Not_admitted] concerns this attempt only. After an earlier admitted attempt,
    queue refusal, interruption, reply loss or an unvalidated error cannot prove
    rollback. A retry must not replace an unknown intent with a fresh ID.

    Confirm performs bounded canonical readback, not another mutation:
    {[
      let confirm_commit
          (state : AC.t ref) (runner : AR.t)
          (presentation : A.presentation) (receipt : A.receipt) =
        let session = A.presentation_session presentation in
        match AC.request !state session (A.Confirm (presentation, receipt)) with
        | Error error -> Error error
        | Ok (ticket, transition) ->
          state := transition.next;
          List.iter (AR.submit runner) transition.instructions;
          Ok ticket

      let confirmation_data (confirmation : A.confirmation) =
        A.confirmation_primary confirmation,
        A.confirmation_additional confirmation
    ]}

    The business owner applies that readback only to the still-current
    presentation. It need not query the same evidence again. Additional fragments
    are bounded: omitted targets are not absent, and child continuations retain
    their snapshot/budget. Readback failure preserves the committed receipt.
    Focus away/back creates a new presentation even if the session survives.
    [AC.reconcile_mutation] returns a [Submission_ticket] for unresolved intent or
    a [Confirmation_ticket] for known commitment. After actual UI application,
    [AC.settle_applied_mutation] determines acknowledgement versus reconciliation;
    neither a transport ACK nor merely reading a reply proves UI consumption.

    {2 Worker execution and its embedded Sync reducer}

    [W.initial config] validates the initial state. Its host creates [WR.t] from
    real dependencies and binds [WR.create]'s [post] to one serial event channel.
    Recovery/upload/asset predicates read the installed Worker state. The host
    then submits [W.Start] through the same turn function used for later events:
    {[
      let worker_turn
          (state : W.state ref) (runner : WR.t) (event : W.event) =
        let transition = W.step !state event in
        state := transition.next;
        List.iter (WR.submit runner) transition.effects
    ]}

    Worker owns the Sync reducer state. [W.Sync_event event] causes an internal
    [S.step] and translates its output; App must not create a second Sync state:
    {v
      S.Run network_effect
        -> W.Run_sync network_effect
        -> WR.submit -> configured Sync runner -> SR.submit

      S.Delegate worker_effect
        -> W.Run_worker
             (W.Request (ticket, W.Handle_sync_worker_effect worker_effect))
        -> WR.submit -> DB I/O
        -> W.Runner_completed (W.Sync_worker_effect_completed ...)
        -> apply the returned lifecycle_result
        -> feed sync_worker_result.event, if present, to the owned Sync reducer

      S.Publish output
        -> ordinary output: W.Publish (W.Sync_output output)
        -> protected/asset results: their existing dedicated delivery paths
    v}

    Detach/reset can wait for resource retirement rather than execute immediately.
    Network callbacks produce [S.event], queued as [W.Sync_event]. Database
    completions keep the original ticket; stale generations do not acquire fresh
    authority. [S.runner_effect] is private and its effect tickets are opaque.
    These traces describe reducer output, not legal external construction.

    {2 Graph selection, local restore and snapshot bootstrap}

    The host supplies authenticated-user, selection, online-recovery and unlock
    input through the existing Service owner. Sync chooses a local or online path:
    {v
      S.Graph_selected graph_id
        -> Delegate (Inspect_mirror mirror_request)
        -> Mirror_inspected (Mirror_available mirror_request)
        -> Delegate (Attach_graph mirror_request)
        -> Graph_attached { scope; sync }

      For an absent mirror when online bootstrap is permitted:
        -> Run (Request (ticket, Fetch_snapshot_metadata scope))
        -> Runner_completed (Completion (ticket, Ok metadata))
        -> Run (Request (ticket, Download_snapshot download))
        -> Runner_completed (Completion (ticket, Ok artifact))
        -> Delegate (Activate_snapshot activation_request)
        -> Snapshot_activated activation
        -> Delegate (Inspect_mirror mirror_request)
        -> Mirror_inspected (Mirror_available mirror_request)
        -> Delegate (Attach_graph mirror_request)
        -> Graph_attached { scope; sync }
    v}

    Activation is followed by a new mirror inspection, not an unconditional direct
    attach. Encrypted graphs additionally use Load_and_unlock_graph_key and, when
    needed, Fetch_e2ee_graph_key/Fetch_e2ee_user_keys and E2ee_password_submitted.
    Snapshot download/artifact/activation values are opaque, request-bound
    capabilities. Their owner uses the specified accessors and completion
    constructors; a fabricated path/UUID record is not an activation receipt.
    [Fetch_snapshot_baseline] exists but is not a mandatory step in the current
    normal metadata/download bootstrap path. Failure and explicit recovery remain
    distinct from successful local restore; an offline local graph can still be
    usable without network progress.

    {2 Local outbox, server acknowledgement and authoritative pull}

    The typical success path starts only after local commit. Exact request fields,
    keys and scopes are reducer-produced values; the trace omits their payloads:
    {v
      S.Local_graph_outbox_changed graph_scope
        -> Delegate (Inspect_sync graph_scope)
        -> Sync_inspected { scope; sync }
        -> Delegate (Apply_outbox_transition request)
             request.transition = Submit_group mutation_ids
        -> Outbox_transition_applied { scope; commit; sync }
        -> Run (Send_websocket ...)
             message = Sync_protocol.Client.Tx_batch ...
        -> Websocket_message (..., Sync_protocol.Server.Tx_batch_ok ...)
        -> Delegate (Apply_outbox_transition request)
             request.transition = Accept_group { batch_id; barrier }
        -> Outbox_transition_applied ...
        -> Run (Send_websocket ...)
             message = Sync_protocol.Client.Pull { since }
        -> Websocket_message (..., Sync_protocol.Server.Pull_ok ...)
        -> Delegate (Apply_authoritative_batch batch)
        -> Authoritative_batch_applied { scope; commit; sync }
    v}

    [Submit_group] is persisted before Tx_batch transmission. Server acceptance
    does not itself mean the authoritative batch is applied locally. Disconnects
    and rejection can require Retry_group/Reject_group or a blocked/deferred state;
    the arrows above are not unconditional retry policy. The opaque
    [Logseq_overlay_db.Types.sync_view] is inspected through its accessors, such as
    [sync_view_token], never through invented pending/token fields.

    [Websocket_opened], Server.Hello and Server.Changed can initiate Client.Pull.
    The current path does not require an invented initial Client.Hello send.
    Successful authoritative DB application produces the existing projection and
    change/observation facts; a network callback does not directly render UI.

    {2 Observations, changefeed and visible refresh}

    [A.Observe (budget, query)] registers and samples with a gap-free baseline or
    replay boundary. Check [A.supports_observation session query]; the coarse
    capability flag does not support every query. Observe Changes is rejected so
    changefeed pull/ACK retains one owner. The coordinator receives registration,
    invalidation and sampled facts through [AC.Observation_registered],
    [AC.Observation_notice] and [AC.Observation_received].

    [A.Refresh observation] retains its registered handle. Failed reads do not
    release the interest or discard retained reconciliation. Empty data remains a
    real result. [A.Release observation] requires its actual release ACK; late
    registration/acquisition racing cancellation remains owned for cleanup.

    The changefeed alternative uses [A.Query (budget, A.Changes { generation;
    after })], then [AC.begin_change_application] and its exact consumer tokens.
    Business owners report [Change_consumer_expanded], [Change_consumer_applied]
    or [Change_consumer_retired] as they actually create/apply/retire dependent
    work. Only after all affected state is applied or explicitly retired may
    [A.Acknowledge_changes batch] advance that exact generation/window chain.
    A read failure is not an ACK. One migrated interest cannot be independently
    rehydrated or acknowledged by both the legacy runtime and the new owner.

    {2 Media, import and retained files}

    Picker UI, editing and source staging remain host/business operations. Worker
    consumes existing descriptors and complete [A.asset_import_intent] values:
    {v
      Visible media demand:
        asset_consumer -> Replace_asset_demand -> checked asset_demand
        -> asset notice -> ready_asset_file -> Acquire_asset_file
        -> optional file_lease -> host consumes file_path/file_type
        -> Release_file -> actual release ACK + File_lease_returned
        -> Release_asset_demand -> actual demand cleanup ACK

      Durable import:
        persist encode_asset_import_intent before first Import
        -> Import_rejected / Import_unknown / Imported
        -> optional Acquire_imported_file -> tracked file_lease
        -> existing upload/Sync owners report later upload status
    v}

    A demand ACK is not download completion; an import receipt is not cloud upload
    completion. Source retirement requires a checked durable import/adoption proof
    or known rejection; Unknown retains the original source obligation. File paths
    alone grant no acquisition authority. [AC.File_lease_returned] and
    [AC.Observation_returned] mean the presentation no longer retains a capability,
    not that physical I/O cleanup finished. Keep physical releases, creator
    completion and finalization separately tracked; no retry may leak an orphan
    retain or silently replay a previously completed physical release.

    {1 Lifecycle and recovery}

    {2 Retry without changing identity}

    Preserve complete immutable intent bytes before first send. On restart,
    [A.restore_durable_intent] validates the same logical graph and original
    payload; restoration itself is read-only. [A.Recover_mutations] and import
    recovery expose persistent evidence. [AC.reconcile_mutation] does not authorize
    changing the intent, silently replacing an unknown ID or treating equal text
    after A -> B -> A as confirmation of the old action.

    [AC.Cancel ticket] requests cooperative stop, not rollback. [AC.Forget ticket]
    retires result presentation, not actual in-flight ownership or durable intent.
    Full/not-ready/stopping are typed admission results; keep retained logical
    dependencies and retry only under their specified capacity/recovery events.
    A remote rejection cannot erase an already locally committed receipt.

    {2 Graph close, account replacement and shutdown}

    Host authentication, deletion policy/confirmation and client lifetime remain
    outside coordination. Before retiring an execution owner, plan its exact
    change, apply the returned transition and retain the returned handoff ID:
    {[
      let prepare_change
          (state : AC.t ref) (runner : AR.t) (change : A.host_change) =
        match AC.prepare_host_change !state change with
        | Error error -> Error error
        | Ok (handoff, transition) ->
          state := transition.next;
          List.iter (AR.submit runner) transition.instructions;
          Ok handoff

      let consume_safe_receipt
          (state : AC.t ref) (runner : AR.t) (receipt : A.handoff_receipt) =
        match AC.authorize_host_change !state receipt with
        | Error error -> Error error
        | Ok transition ->
          state := transition.next;
          List.iter (AR.submit runner) transition.instructions;
          Ok ()
    ]}

    These local helpers are only the coordination portion. The host must join
    other existing owners, use the exact current handoff, and respect required
    confirmation. [Safe_to_proceed] is a scoped cleanup receipt; the consume call
    above does not itself prove action completion. Only the matching admitted
    completion publishes [Host_change_applied]. Do not send a second legacy
    Close/Delete after that action ACK. Unknown outcomes retain their original
    owner and permission; a stale receipt cannot authorize a reopened graph.

    [AR.shutdown runner] is nonblocking: [Draining] requires continued delivery of
    real cleanup callbacks and ACKs. Revisit after pump progress until [Stopped]
    or an observable failure; no busy loop and no premature shared-client close.
    All owners, including retired hosts, must reach their own fence. Worker
    [W.Shutdown] and Sync [S.Shutdown] still produce work that must be interpreted.
    [SR.shutdown] alone is not a checked join receipt. [Websocket_closed] reports
    connection closure; [Websocket_retired] reports actual resource/callback
    retirement. A shutdown flag or empty mailbox cannot substitute for these facts.

    {1 Observation and helpers}

    {2 Reading progress without creating another owner}

    [AC.view], [AC.bootstrap], [AC.projection], [AC.reply], [AC.intent_progress],
    [AC.import_progress] and [AC.handoff] expose coordination facts. [AC.query_origin]
    retains the exact session/budget actually sent, not a later selected session.
    [AC.current_presentation] and [AC.revalidate_reply] guard deferred business
    consumption. [AC.changefeed_updates] and [AC.asset_updates] report accepted
    original facts; they do not grant a second invalidation or cleanup owner.

    [W.view] exposes Worker graph state and the Sync projection; [S.state] is an
    observation of the owned Sync reducer, not a mutable replacement for it.
    Preserve concrete [A.Db_error] causes and typed failure/unknown distinctions
    across boundaries instead of turning every result into a generic string.

    {2 Contract and implementation reading map}

    Public contracts used above:
    {ul
    {- [app/spec/worker_coordination/worker_api.mli]: typed requests, authority,
       durable intent, canonical readback, observations/resources and handoff.}
    {- [app/spec/worker_coordination/worker_pure_coordinator.mli]: events,
       private transitions, request planning, reconciliation and ownership.}
    {- [app/spec/worker_coordination/worker_effect_runner.mli]: borrowed client,
       actual response routing, interpretation and nonblocking retirement.}
    {- [logseq_db_worker/spec/pure_reducer/core.mli] and
       [logseq_db_worker/spec/effect_runner/effect_runner.mli]: Worker events,
       execution, scoped reads/durable writes and Sync delegation.}
    {- [logseq_sync/spec/pure_reducer/core.mli], [sync_protocol.mli] in the same
       directory, and [logseq_sync/spec/effect_runner/effect_runner.mli]: Sync
       policy, network protocol and I/O ownership.}
    {- [logseq_overlay_db/spec/types.mli] and [database.mli] in the same directory:
       immutable local intent, outbox transitions and authoritative application.}}

    Current implementation seams, intentionally not presented as spec APIs:
    {ul
    {- [app/application.ml]: bridge/runtime startup, shared pump and business owners.}
    {- [app/journal_worker_coordination_host.ml]: serial state installation,
       runner binding and delivery of typed replies to business callbacks.}
    {- [app/impl/worker_coordination/worker_effect_authority.ml]: checked mapping
       between App typed requests and concrete Service requests.}
    {- [logseq_db_worker/lui/logseq_db_worker_lui_service.ml]: scoped Service
       routing and real coordination registration.}
    {- [logseq_db_worker/lib/logseq_db_worker.ml]: lifecycle, event channel,
       await-reply wrapper and direct durable-mutation wrapper.}
    {- Worker and Sync [lib/pure_reducer/core.ml] and
       [lib/effect_runner/effect_runner.ml]: the ordered transitions and effects
       described above.}}

    This document introduces no initialize/begin_sync/post_events/sync_now API.
    All control flow must continue through the owners and public boundaries that
    actually exist. It explains the major paths, not every UI branch, protocol
    error, asset codec or storage implementation detail.
*)
