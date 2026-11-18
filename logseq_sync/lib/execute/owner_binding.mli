module Dsl = Sync_dsl.Core

type ('database, 'inspection, 'input, 'prepared) backend =
  { same_input : 'input -> 'input -> bool
  ; prepare : 'inspection -> 'input -> ('prepared, Dsl.error) result
  ; commit : 'prepared -> ('inspection, Dsl.error) result
  ; cancel : 'prepared -> unit
  ; open_committed : 'inspection -> ('database, Dsl.error) result
  }

type ('database, 'inspection, 'input, 'prepared) t

val active : 'database -> ('database, 'inspection, 'input, 'prepared) t

val absent
  :  'inspection
  -> ('database, 'inspection, 'input, 'prepared) backend
  -> ('database, 'inspection, 'input, 'prepared) t

val database
  :  ('database, 'inspection, 'input, 'prepared) t
  -> ('database, Dsl.error) result

val with_database
  :  ('database, 'inspection, 'input, 'prepared) t
  -> check_current:(unit -> (unit, Dsl.error) result)
  -> ('database -> ('value, Dsl.error) result)
  -> ('value, Dsl.error) result

(** Prepare may suspend. Commit follows a fresh check under the sole queue.
    Committed inspection and opened binding survive cancellation; recovery never prepares or commits again.
    The original owner supplies every backend operation; callers cannot replace it during recovery. *)
val activate
  :  ('database, 'inspection, 'input, 'prepared) t
  -> check_current:(unit -> (unit, Dsl.error) result)
  -> 'input
  -> ('database, Dsl.error) result
