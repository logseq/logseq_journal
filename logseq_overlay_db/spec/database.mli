(** The lifecycle and transaction boundary of the logical Logseq database.

    A value of this module presents one coherent graph assembled from two durable
    sources: the authoritative mirror and the ordered local outbox. Callers do not
    choose between those sources. They inspect a mirror, open the logical database,
    capture an immutable snapshot, and read the projection represented by that
    snapshot.

    Writes commit in one serialized operation. Synchronization uses a preparation
    only when external cryptography must occur between observation and durable
    application. Snapshot activation remains explicitly cancelable because it owns
    staged filesystem resources.

    No Datascript database, entity id, filesystem handle, or outbox record crosses
    this interface.

    Examples use [require_ok] to keep attention on resource ownership and protocol
    order. Production callers should preserve and handle the typed errors instead.

    {[
      let require_ok = function
        | Ok value -> value
        | Error _ -> failwith "database operation failed"
    ]} *)

module Graph = Logseq_db_types.Graph_types

(** {1 Establishing the operating envelope}

    Limits and dependencies are validated before any path is inspected or any
    resource is acquired. Keeping them immutable makes every later admission,
    batching, cursor, and clock decision part of the database's construction. *)

type dependencies

(** [dependencies] validates and fixes the clocks and public capability limits used
    by one database. Every bound must be positive, and a wire batch must fit within
    the outbox byte budget. *)
val dependencies
  :  epoch_ms:(unit -> int64)
  -> monotonic_ns:(unit -> int64)
  -> limits:Types.capability_limits
  -> (dependencies, Types.limits_error) result

(** {1 Discovering a durable mirror}

    Opening begins with observation rather than mutation. An inspection records
    what was found at the graph's canonical database path. The recorded mirror
    generation prevents a stale observation from opening, deleting, or collecting
    a different mirror. *)

type mirror_inspection

(** [inspect_mirror ~application_support_directory ~graph_id] derives the canonical
    path and records whether the mirror is absent or available. An available
    inspection includes its graph identity, checkpoint, checksum, and generation. *)
val inspect_mirror
  :  application_support_directory:string
  -> graph_id:Graph.Uuid.t
  -> (mirror_inspection, Types.mirror_error) result

(** Returns the immutable observation carried by an inspection. *)
val mirror_presence : mirror_inspection -> Types.mirror_presence

(** {2 Activating a downloaded snapshot}

    Activation is deliberately separate from opening. It can populate only a
    location inspected as absent. Parsing and optional decryption happen in a
    staging area; [commit_snapshot_activation] is the sole step that publishes the
    staged mirror at the canonical location. *)

type prepared_snapshot_activation
type unprotection_request

(** Validates the snapshot input and parses it into a generation-bound staging
    lease. [path] must name an absolute, single-linked regular file and
    [expected_rows] must be nonnegative. The operation fails before allocating
    staging resources when those inputs are invalid, or when the inspected
    location is no longer absent. *)
val prepare_snapshot_activation
  :  dependencies
  -> mirror_inspection
  -> path:string
  -> applied_server_cursor:Types.server_cursor
  -> expected_checksum:Types.checksum option
  -> expected_rows:int
  -> (prepared_snapshot_activation, Types.snapshot_activation_error) result

(** Returns the next bounded ciphertext batch that the caller must decrypt, or
    [None] once snapshot unprotection is complete. Each returned request must be
    supplied exactly once before asking for another batch. *)
val next_snapshot_unprotection_batch
  :  prepared_snapshot_activation
  -> (unprotection_request option, Types.snapshot_activation_error) result

(** Supplies plaintexts for the outstanding snapshot request. Foreign, stale,
    incomplete, reordered, or oversized crypto results are rejected. *)
val supply_snapshot_unprotection_batch
  :  prepared_snapshot_activation
  -> request:unprotection_request
  -> plaintexts:(Types.crypto_item_id * string) list
  -> (unit, Types.snapshot_activation_error) result

(** Finishes validation and persistence in the staging area, then atomically
    publishes the snapshot. All requested plaintext batches must have been supplied
    first. A failed publication remains retryable through the same preparation. *)
val commit_snapshot_activation
  :  prepared_snapshot_activation
  -> (mirror_inspection, Types.snapshot_activation_error) result

(** Releases any uncommitted snapshot staging lease, including one already
    persisted in staging after a failed publication. *)
val cancel_snapshot_activation : prepared_snapshot_activation -> unit

(** {3 Example: activating a downloaded snapshot}

    The crypto callback stays outside the database.

    {[
      let install_snapshot
            ~decrypt
            dependencies
            inspection
            ~path
            ~applied_server_cursor
            ~expected_checksum
            ~expected_rows
        =
        let preparation =
          prepare_snapshot_activation
            dependencies
            inspection
            ~path
            ~applied_server_cursor
            ~expected_checksum
            ~expected_rows
          |> require_ok
        in
        Fun.protect
          ~finally:(fun () -> cancel_snapshot_activation preparation)
          (fun () ->
             let rec supply_all_plaintexts () =
               match
                 next_snapshot_unprotection_batch preparation |> require_ok
               with
               | None -> ()
               | Some request ->
                 let ciphertexts = unprotection_ciphertexts request in
                 let plaintexts = decrypt ciphertexts in
                 supply_snapshot_unprotection_batch
                   preparation
                   ~request
                   ~plaintexts
                 |> require_ok;
                 supply_all_plaintexts ()
             in
             supply_all_plaintexts ();
             commit_snapshot_activation preparation |> require_ok)
    ]} *)

(** {2 Maintaining a closed mirror}

    Destructive maintenance consumes the generation recorded by an inspection.
    It therefore applies only while the mirror is closed and still denotes the
    filesystem object that was inspected. *)

(** Deletes the inspected mirror if its generation is current and no process owns
    it. *)
val delete_mirror
  :  mirror_inspection
  -> (Types.mirror_delete, Types.mirror_delete_error) result

(** Collects eligible durable garbage without removing mutation receipts needed
    to classify late synchronization responses. *)
val collect_garbage
  :  mirror_inspection
  -> (Types.garbage_collection, Types.garbage_collection_error) result

(** {1 Opening the logical database}

    An open database owns the mirror, the authoritative Datascript lineage, the
    queryable outbox, and the ordered change dispatcher. A snapshot is a leased,
    immutable pair of authoritative and outbox roots; every read through it sees
    that same pair even while later commits advance the open database. *)

type t
type snapshot

(** [open_ ~sw dependencies inspection ~graph_name] validates the display name,
    acquires exclusive ownership, and restores an available inspected mirror.
    Resources are tied to [sw], but callers should still use [close] to observe
    shutdown errors. *)
val open_
  :  sw:Eio.Switch.t
  -> dependencies
  -> mirror_inspection
  -> graph_name:string
  -> (t, Types.open_error) result

(** Closes storage and invalidates the database's outstanding snapshots and
    subscriptions. *)
val close : t -> (unit, Types.close_error) result

(** Captures the current coherent logical projection as a read lease. *)
val current_snapshot : t -> (snapshot, Types.read_error) result

(** Returns the generation and projection revision captured by the snapshot. *)
val snapshot_version : snapshot -> Types.snapshot_version

(** Prevents new reads from starting through [snapshot] and releases its pinned
    roots after already-started reads finish. *)
val release_snapshot : snapshot -> unit

(** Reads graph identity, schema, admission facts, limits, and version from the
    snapshot. *)
val graph_info : snapshot -> (Types.graph_info, Types.read_error) result

(** Reports current outbox occupancy and the limits against which future local
    commits and submissions will be admitted. *)
val inspect_admission
  :  t
  -> (Types.admission_inspection, Types.admission_inspection_error) result

(** {2 Reading one captured projection} *)

(** Looks up blocks by UUID in the captured projection. *)
val get_blocks
  :  snapshot
  -> Graph.block_uuid list
  -> (Types.block_lookup list, Types.read_error) result

(** Looks up pages by UUID in the captured projection. *)
val get_pages
  :  snapshot
  -> Graph.page_uuid list
  -> (Types.page_lookup list, Types.read_error) result

(** Reads one bounded page of journals. A continuation cursor is an opaque,
    projection-bound offset from zero through 10,000. [limit] must be between one
    and 200 inclusive. *)
val get_journals
  :  snapshot
  -> limit:int
  -> cursor:Graph.Cursor.t option
  -> (Types.journal_list_result, Types.read_error) result

(** Reads one bounded children or page-tree structure request. A continuation
    cursor is an opaque, projection-bound offset from zero through 10,000 and may
    be reused as the same numeric offset with another request shape. Each request
    limit must be between one and 200 inclusive. *)
val get_structure
  :  snapshot
  -> Types.structure_request
  -> (Types.structure_result, Types.read_error) result

(** {3 Example: reading one coherent projection}

    Every read in the callback observes the roots captured by the same snapshot.
    Releasing the lease in [finally] also covers read errors and exceptions.

    {[
      let read_blocks database uuids =
        match current_snapshot database with
        | Error error -> Error error
        | Ok snapshot ->
          Fun.protect
            ~finally:(fun () -> release_snapshot snapshot)
            (fun () -> get_blocks snapshot uuids)
    ]} *)

(** {1 Crossing from a snapshot to live changes}

    Subscription registration and predecessor capture are one atomic operation.
    The returned subscription starts paused, so a consumer can hydrate from the
    predecessor snapshot before allowing later projection changes to reach its
    callback. *)

type subscription

(** Registers a paused subscriber and returns the immediate predecessor snapshot
    for its event cursor. *)
val listen : t -> (subscription * snapshot, Types.listen_error) result

(** Installs the callback and drains changes retained since [listen]. Retention
    overflow is represented as one resync notification. *)
val activate_subscription
  :  subscription
  -> notify:(Types.projection_change -> unit)
  -> (unit, Types.listen_error) result

(** Stops delivery and releases subscription resources. *)
val unlisten : subscription -> unit

(** {2 Example: hydrating without a read/listen gap}

    Hydration precedes activation, but changes committed during hydration remain
    queued behind the subscription cursor. The owner later calls [unlisten] on the
    returned subscription.

    {[
      let subscribe database ~hydrate ~notify =
        match listen database with
        | Error error -> Error error
        | Ok (subscription, predecessor) ->
          (try
             Fun.protect
               ~finally:(fun () -> release_snapshot predecessor)
               (fun () -> hydrate predecessor);
             match activate_subscription subscription ~notify with
             | Ok () -> Ok subscription
             | Error error ->
               unlisten subscription;
               Error error
           with
           | exn ->
             unlisten subscription;
             raise exn)
    ]} *)

(** {1 Committing optimistic local intent}

    A local mutation is checked against equality tokens obtained from earlier
    logical reads. One serialized operation validates identity and preconditions,
    freezes the semantic effect and delete artifacts, admits the durable record,
    persists it, and publishes any logical change. *)

type write_precondition

(** Builds a canonical, duplicate-free read set from block, page, and structure
    revision tokens. *)
val write_precondition
  :  blocks:(Graph.block_uuid * Types.block_state_revision) list
  -> pages:(Graph.page_uuid * Types.page_state_revision) list
  -> scopes:(Types.structure_revision_scope * Types.scope_revision) list
  -> (write_precondition, Types.precondition_error) result

(** Validates and durably publishes a local mutation. Reusing a mutation ID with
    the same fingerprint returns its durable outcome; reusing it for different
    intent is an error. A successful logical change advances the projection exactly
    once. *)
val commit_local
  :  t
  -> expected:write_precondition
  -> Types.local_mutation
  -> (Types.local_commit_outcome, Types.local_commit_error) result

(** Requeues an eligible blocked mutation after validating a fresh read set. *)
val retry_blocked
  :  t
  -> expected:write_precondition
  -> mutation_id:Graph.Uuid.t
  -> (Types.local_commit, Types.blocked_retry_error) result

(** Removes a blocked record from retry consideration and records its terminal
    discarded outcome. *)
val discard_blocked
  :  t
  -> mutation_id:Graph.Uuid.t
  -> (Types.blocked_discard_commit, Types.blocked_discard_error) result

(** {2 Example: appending a block tree to a page}

    Structure mutations retain both the page revision and the children revision
    observed while planning. An unrelated commit may advance the global projection
    without invalidating either target-local token.

    {[
      let append_to_page database ~page ~mutation_id ~tree =
        let snapshot = current_snapshot database |> require_ok in
        let page_revision, revision_scope, scope_revision =
          Fun.protect
            ~finally:(fun () -> release_snapshot snapshot)
            (fun () ->
               let page_revision =
                 match get_pages snapshot [ page ] |> require_ok with
                 | [ Types.Present_page { revision; _ } ] -> revision
                 | _ -> failwith "append target page is missing"
               in
               match
                 get_structure
                   snapshot
                   (Types.Children { parent = page; limit = 64; cursor = None })
                 |> require_ok
               with
               | Types.Children_result
                   { revision_scope; scope_revision; _ } ->
                 page_revision, revision_scope, scope_revision
               | Types.Page_tree_result _ -> assert false)
        in
        let expected =
          write_precondition
            ~blocks:[]
            ~pages:[ page, page_revision ]
            ~scopes:[ revision_scope, scope_revision ]
          |> require_ok
        in
        commit_local
          database
          ~expected
          (Types.Insert_blocks { mutation_id; tree; parent = page })
        |> require_ok
    ]} *)

(** {1 Handing cryptography to the caller}

    The database owns durable records and crypto item identities, while the sync
    layer owns encryption and decryption. Requests expose only bounded strings.
    The operation consuming returned values binds them to the exact request and
    rejects stale, foreign, duplicated, missing, reordered, or oversized output. *)

type protection_request

(** Returns the identified plaintexts in a protection request. *)
val protection_plaintexts : protection_request -> (Types.crypto_item_id * string) list

(** Returns the identified ciphertexts in an unprotection request. *)
val unprotection_ciphertexts
  :  unprotection_request
  -> (Types.crypto_item_id * string) list

(** {1 Advancing synchronization}

    Sync reads one opaque token and uses it as the compare-and-set boundary for
    either direction. Outbox transitions prepare client submissions and terminal
    responses. Authoritative transitions prepare server batches and rebase the
    remaining local overlay. Neither path mutates durable state until application. *)

(** Returns the current transport view and synchronization token. *)
val inspect_sync : t -> (Types.sync_view, Types.sync_read_error) result

(** {2 Sending the outbox} *)

type prepared_outbox_transition

(** Validates an outbox transport transition against [expected]. Submission may
    return a protection request whose result is required by
    [apply_outbox_transition]. *)
val begin_outbox_transition
  :  t
  -> expected:Types.sync_token
  -> Types.outbox_transition
  -> ( prepared_outbox_transition * protection_request option
       , Types.outbox_transition_error )
       result

(** Validates optional encryption and atomically applies the prepared transport
    transition. The presence and identity of [encrypted] must exactly match the
    request returned by the begin step. *)
val apply_outbox_transition
  :  t
  -> prepared_outbox_transition
  -> encrypted:(protection_request * (Types.crypto_item_id * string) list) option
  -> (Types.outbox_commit, Types.outbox_transition_error) result

(** {2 Receiving authoritative history} *)

type authoritative_preparation

type authoritative_application =
  | Authoritative_applied of Types.authoritative_commit
  | Authoritative_deferred of Types.authoritative_defer

(** Stages an authoritative batch against [expected]. Encrypted values are
    returned as one optional unprotection request. *)
val begin_authoritative
  :  t
  -> expected:Types.sync_token
  -> Types.authoritative_batch
  -> ( authoritative_preparation * unprotection_request option
       , Types.authoritative_transition_error )
       result

(** Validates optional decryption, replans the overlay, and atomically persists the
    authoritative candidate, checkpoint, and logical change. A result is deferred
    when a submitted delete still awaits its terminal transport outcome. *)
val apply_authoritative
  :  t
  -> authoritative_preparation
  -> decrypted:(unprotection_request * (Types.crypto_item_id * string) list) option
  -> (authoritative_application, Types.authoritative_transition_error) result

(** {2 Examples: completing the two synchronization directions}

    An outbox submission encrypts only when the begin step requests it. The final
    operation validates the exact request and returned items before persistence.

    {[
      let apply_outbox_transition database ~encrypt transition =
        let expected = inspect_sync database |> require_ok |> Types.sync_view_token in
        let preparation, request =
          begin_outbox_transition database ~expected transition |> require_ok
        in
        let encrypted =
          match request with
          | None -> None
          | Some request ->
            Some (request, encrypt (protection_plaintexts request))
        in
        apply_outbox_transition database preparation ~encrypted |> require_ok
    ]}

    Authoritative input follows the same shape, except application may defer the
    batch until a pending submission receives its terminal outcome.

    {[
      let apply_authoritative database ~decrypt batch =
        let expected = inspect_sync database |> require_ok |> Types.sync_view_token in
        let preparation, request =
          begin_authoritative database ~expected batch |> require_ok
        in
        let decrypted =
          match request with
          | None -> None
          | Some request ->
            let plaintexts = decrypt (unprotection_ciphertexts request) in
            Some (request, plaintexts)
        in
        apply_authoritative database preparation ~decrypted |> require_ok
    ]} *)
