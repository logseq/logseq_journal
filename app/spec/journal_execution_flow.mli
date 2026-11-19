(** Journal execution owners.

    {!Journal_worker_coordination.Worker_pure_coordinator} owns typed App requests,
    presentation authority, receipts, observations and resource handoffs. Its
    runner borrows the shared Worker client; one App pump routes each response.
    Install each transition before interpreting its instructions. Deferred UI
    consumption must revalidate the original presentation.

    {!Journal_sync_lifecycle.Account} owns account admission and replacement.
    {!Journal_sync_lifecycle.Core} assembles each graph's Service, Execute,
    transport, crypto, asset and direct database owners. Worker does not embed a
    second Sync policy loop. {!Logseq_db_worker_effect_runner.Effect_runner}
    obtains the current owner through its services boundary.

    {!Logseq_sync_sync_service.Core} schedules {!Sync_dsl.Core} policy through
    {!Execute.Core}. Database work uses the checked database owner; native I/O
    uses the transport and asset owners. Local commit, server acceptance,
    authoritative application and current-presentation confirmation are separate
    facts. Cancellation neither rolls back a durable mutation nor proves cleanup.

    Persist immutable mutation/import identity and payload before first send.
    Unknown outcomes retain that original intent. Confirmation is bounded
    canonical readback, not another mutation. Observation/changefeed ACKs follow
    actual application or explicit retirement of every dependent consumer.

    Graph and account changes retain their exact handoff permission through the
    matching completion. A cleanup request, empty mailbox or shutdown flag is not
    a physical join receipt. Sync retires before an owned database closes; a
    borrowed upload store remains owned by its caller. Retained files and late
    acquisitions require their actual release acknowledgements.
*)
