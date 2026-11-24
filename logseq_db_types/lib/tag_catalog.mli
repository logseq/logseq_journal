(** {1:tldr TLDR}

    A bounded, immutable prefix index over tag summaries supplied by the graph
    read owner. This module does not discover tags or access the graph. *)

type t
type cursor
type error = Candidate_limit_exceeded | Invalid_limit | Invalid_cursor

(** {1:usage Minimal usage example}

    {[
      match Tag_catalog.create ~maximum_candidates:10_000 graph_tags with
      | Error error -> Error error
      | Ok catalog -> Tag_catalog.search catalog ~prefix:"work" ~limit:20 ~after:None
    ]} *)

(** {1:construction Construction and validation} *)

(** The source supplies one summary per tag UUID and must be lazy for the
    construction bound to apply upstream. Inspects at most [maximum_candidates + 1]
    sequence cells. Overflow fails rather than exposing an incomplete catalogue. *)
val create : maximum_candidates:int -> Graph_types.tag_summary Seq.t -> (t, error) result

(** {1:search Capability details} *)

val normalize : string -> string

(** Trims and ASCII-case-folds labels and the prefix. Results are sorted by
    normalized label, then UUID. The empty prefix matches everything. [limit]
    must be in [1, 200]. Cursors are in-process values bound to this index
    instance and normalized prefix; callers must discard them when replacing
    the index. *)
val search
  :  t
  -> prefix:string
  -> limit:int
  -> after:cursor option
  -> (Graph_types.tag_summary list * cursor option, error) result

(** Convert a cursor to a position. Carry it only with an independently validated
    owner, catalog version and normalized prefix. [resume] checks the position
    against the matching range, but cannot authenticate that external binding. *)
val cursor_offset : cursor -> int
val resume : t -> prefix:string -> int -> (cursor, error) result
