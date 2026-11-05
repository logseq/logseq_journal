(** Upload checkpoints are durable local worker state, never synchronized datoms. *)
val initialize_database : Sqlite3.db -> (unit, string) result

val save
  :  Sqlite3.db
  -> expected:int option
  -> Logseq_db_types.Asset_upload_intent.t
  -> (unit, string) result

val read
  :  Sqlite3.db
  -> operation:Logseq_db_types.Graph_types.Uuid.t
  -> (Logseq_db_types.Asset_upload_intent.t option, string) result

val list
  :  Sqlite3.db
  -> origin:string
  -> account:string
  -> graph:Logseq_db_types.Graph_types.Uuid.t
  -> after:Logseq_db_types.Graph_types.Uuid.t option
  -> limit:int
  -> (Logseq_db_types.Asset_upload_intent.t list, string) result

(** Retires checkpoints and complete inputs atomically. The caller supplies
    namespaces derived from this account and its existing graph identities;
    source bytes cannot establish account ownership on their own. *)
val delete_account
  :  Sqlite3.db
  -> origin:string
  -> account:string
  -> input_namespaces:string Seq.t
  -> (unit, string) result

(** Immutable complete source input and original Prepared proof share this
    store's SQLite connection. Namespace authorization belongs to the caller;
    stored source paths never grant file access or deletion authority. *)
module Inputs : sig
  module Input = Logseq_db_types.Asset_import.Pure_intent
  type owner={namespace:string;origin:string;account:string;graph:Logseq_db_types.Graph_types.Uuid.t}
  type record = private
    { sequence:int64; input:Input.t
    ; prepared:Logseq_db_types.Asset_upload_intent.t option
    ; evidence:string option; acknowledged:bool }
  type page = private {items:record list;next:int64 option}
  val reserve:Sqlite3.db -> owner:owner -> input:Input.t -> (record,string)result
  (** Atomically saves the first Prepared checkpoint and its immutable evidence.
      Reservation must already exist; a failure rolls both writes back. *)
  val commit_prepared:Sqlite3.db -> owner:owner -> input:Input.t -> Logseq_db_types.Asset_upload_intent.t -> (record,string)result
  val read:Sqlite3.db -> owner:owner -> operation:Logseq_db_types.Graph_types.Uuid.t -> (record option,string)result
  val pending:Sqlite3.db -> owner:owner -> after:int64 option -> maximum_items:int -> maximum_bytes:int -> (page,string)result
  val encoded_bytes:record -> int
  val acknowledge:Sqlite3.db -> owner:owner -> input:Input.t -> evidence:string -> (unit,string)result
end

(** A frozen set of exact checkpoint payloads for coordinated local retirement. *)
type captured_graph
val capture_graph : Sqlite3.db -> namespace:string -> origin:string -> account:string -> graph:Logseq_db_types.Graph_types.Uuid.t -> (captured_graph, string) result
val captured_graph_to_yojson : captured_graph -> Yojson.Safe.t
val captured_graph_of_yojson : Yojson.Safe.t -> (captured_graph, string) result
val captured_graph_matches : captured_graph -> namespace:string -> origin:string -> account:string -> graph:Logseq_db_types.Graph_types.Uuid.t -> bool
(** Fails without deleting if any captured operation acquired a different payload.
    Missing rows are already retired. Uncaptured operations are never removed. *)
val delete_captured_graph : Sqlite3.db -> captured_graph -> (unit, string) result
