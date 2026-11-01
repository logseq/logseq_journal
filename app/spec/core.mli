(** Pure App request/observation and presentation owner. This is a target virtual
    contract, not a signature claimed by today's [Application] implementation.
    No DB/network/filesystem/clock calls or mutable callbacks occur in [step]. *)

module Worker = Worker_api

type t
type view
type 'a ticket

(** The host supplies a fresh client identity for each Core lifetime. Request IDs
    derive from it and a pure counter; durable mutation IDs do not. *)
val initial : client_id:Worker.Uuid.t -> t
val view : t -> view
val projection : view -> Worker.projection option
val mutation_progress : view -> Worker.append_intent -> Worker.mutation_progress option
val ticket_id : 'a ticket -> Worker.request_id

(** One-shot and observation results stay typed and are available to rendering.
    Retired/unknown tickets or released handles return None. *)
val reply : view -> 'a ticket -> 'a Worker.reply option
val observed : view -> 'a Worker.observation -> 'a Worker.observed option

(** Equality covers every observable projection/request/observation/write fact,
    including deletion failure/completion and removal of the final graph. It must
    not hide a transition because the selected graph or DB is absent. *)
val equal_view : view -> view -> bool

type event =
  | Worker_bound of Worker.worker_incarnation
  | Request : Worker.session * 'a Worker.request -> event
  | Completed : 'a ticket * 'a Worker.reply -> event
  | Projection_received of Worker.projection
  | Observation_received : 'a Worker.observed -> event
  | Cancel : 'a ticket -> event
  | Release : 'a Worker.observation -> event
  | Drain

type instruction =
  | Send : 'a ticket * Worker.session * 'a Worker.request -> instruction
  | Cancel_request : 'a ticket -> instruction
  | Publish of view
  | Schedule_drain

type transition =
  { next : t
  ; instructions : instruction list
  }

(** Creates planned request tickets only for live session ownership and consumes a
    completion at most once. The result index prevents response-kind mismatch;
    runtime checks still compare ticket ID, session, incarnation, mutation receipt
    and observation epoch. A ticket is not Worker queue acceptance. Cancel requests cooperative stop, not write rollback:
    an accepted mutation remains unknown or committed until reconciled.

    The trusted runner posts [Worker_bound] only after revoking its predecessor;
    old-binding projections/completions are ignored before version comparison.
    Projection application reconciles session membership and phases as one version
    before admitting reads. Revocation retires pending work and releases interests;
    stale completions cannot resurrect a session or removed local graph. Query does
    not alter observation ownership/epoch. Explicit release is idempotent, survives
    reordered updates and remains pending until the Worker acknowledges it through
    a [Send] of [Worker.Release] and its unit-indexed [Completed]. Interrupted
    release is safely retried with the same handle, never assumed complete.

    Input-derived instruction batches contain fewer than 1000 elements. Remaining
    work is retained in [t] and the batch reserves a [Schedule_drain] instruction;
    its interpreter posts [Drain] on a later coordinator turn without waiting for
    an unrelated external event. All instructions are interpreted externally. *)
val step : t -> event -> transition
