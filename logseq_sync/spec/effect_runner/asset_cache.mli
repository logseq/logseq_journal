(** {1 TLDR}

    Name the opaque cache resources owned by the Sync effect runner.
    There is no public cache constructor or execution API here: business requests
    enter [Logseq_sync_pure_reducer.Core.step], and the runner performs cache I/O.
    Cache handles and staged values are process-local resources, not durable proofs. *)

type t

type handle
type error
type staged

(** {1 Minimal usage example}

    The caller supplies a current reducer [state], an [event], and the actual
    [runner]. This is the public execution path, not direct cache access:
    {[
      let transition = Logseq_sync_pure_reducer.Core.step !state event in
      state := transition.next;
      List.iter
        (function
          | Logseq_sync_pure_reducer.Core.Run runner_effect ->
            Effect_runner.submit runner runner_effect
          | instruction -> interpret_other instruction)
        transition.effects
    ]}
    The caller supplies [interpret_other] for delegated work and publications.
    Runner callbacks queue events for a later serialized reducer turn; the runner
    owns cache cleanup and is shut down by its lifecycle owner. *)
