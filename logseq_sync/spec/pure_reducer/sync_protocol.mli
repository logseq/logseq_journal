(** Typed application-level WebSocket protocol shared by the sync client and server. *)

(** A non-negative authoritative transaction cursor. Codec functions reject negative values. *)
type cursor = int

(** A 16-character hexadecimal entity checksum. *)
type checksum = string

(** A server transaction rejection category. *)
type rejection_reason =
  | Stale
  | Db_transact_failed
  | Empty_tx_data
  | Invalid_tx
  | Invalid_t_before
  | Snapshot_upload_in_progress

(** The complete typed payload of a [tx/reject] server message. *)
type rejection =
  { reason : rejection_reason
  ; t : cursor option
  ; checksum : checksum option
  ; success_tx_ids : Logseq_db_types.Graph_types.Uuid.t list
  ; failed_tx_id : Logseq_db_types.Graph_types.Uuid.t option
  ; missing_block_uuids : Logseq_db_types.Graph_types.Uuid.t list
  ; error_detail : string option
  ; data : string option
  }

(** One entry in the [online-users] server message. *)
type user_presence =
  { user_id : string
  ; email : string option
  ; username : string option
  ; name : string option
  }

(** Messages sent from a sync client to the server. *)
module Client : sig
  (** One Transit-encoded entry in a [tx/batch] message. *)
  type transaction =
    { tx : string
    ; tx_id : Logseq_db_types.Graph_types.Uuid.t option
    ; outliner_op : string option
    }

  (** The complete client message ADT.

      Constructors correspond to the wire discriminators [hello], [presence],
      [pull], [tx/batch], and [ping]. *)
  type message =
    | Hello of { client : string }
    | Presence of { editing_block_uuid : string option }
    | Pull of { since : cursor option }
    | Tx_batch of
        { client_revision : string option
        ; t_before : cursor
        ; txs : transaction list
        }
    | Ping
end

(** Messages sent from the sync server to a client. *)
module Server : sig
  (** One Transit-encoded authoritative entry in a [pull/ok] message. *)
  type pull_transaction =
    { t : cursor
    ; tx : string
    ; outliner_op : string option
    }

  (** The complete server message ADT.

      Constructors correspond to the wire discriminators [hello], [online-users],
      [presence], [pull/ok], [tx/batch/ok], [changed], [tx/reject], [pong], and
      [error]. *)
  type message =
    | Hello of
        { t : cursor
        ; checksum : checksum option
        }
    | Online_users of { online_users : user_presence list }
    | Presence of
        { user_id : string
        ; editing_block_uuid : string option
        }
    | Pull_ok of
        { t : cursor
        ; checksum : checksum option
        ; txs : pull_transaction list
        }
    | Tx_batch_ok of
        { t : cursor
        ; checksum : checksum option
        }
    | Changed of { t : cursor }
    | Tx_reject of rejection
    | Pong
    | Error of { message : string }
end

(** The direction in which a rejected wire message travels. *)
type direction =
  | Client
  | Server

(** A stable codec failure category. Invalid field values are intentionally omitted. *)
type error_kind =
  | Invalid_json
  | Expected_object
  | Missing_field of string
  | Unexpected_fields of string list
  | Unsupported_message_type of string
  | Invalid_field of { expected : string }
  | Limit_exceeded of { maximum : int }

(** Safe structured codec diagnostics.

    [path] identifies the containing object for missing and unexpected fields and
    the value itself for an invalid field. Array indexes are decimal path segments. *)
type codec_error =
  { direction : direction
  ; message_type : string option
  ; path : string list
  ; kind : error_kind
  }

(** Encode a typed client message to its canonical JSON wire representation. *)
val encode_client_message : Client.message -> (string, codec_error) result

(** Strictly decode one bounded client JSON message. *)
val decode_client_message : string -> (Client.message, codec_error) result

(** Encode a typed server message to its canonical JSON wire representation. *)
val encode_server_message : Server.message -> (string, codec_error) result

(** Strictly decode one bounded server JSON message. *)
val decode_server_message : string -> (Server.message, codec_error) result

(** Render safe diagnostic text without including raw payloads or invalid field values. *)
val error_to_string : codec_error -> string
