type error

type applied =
  { metadata : Sync_meta.t
  ; basis_before : int64
  ; basis_after : int64
  ; changed_uuids : Graph_types.Uuid.t list
  }

type duplicate =
  { metadata : Sync_meta.t
  ; basis : int64
  }

type paused =
  { metadata : Sync_meta.t
  ; basis : int64
  }

type outcome =
  | Applied of applied
  | Duplicate of duplicate
  | Paused of paused

val apply_pull
  :  ?before_commit:(unit -> (unit, string) result)
  -> ?decrypt_protected:
       (attribute:string -> string -> (Transit_core.Json.value, string) result)
  -> session:Storage_session.t
  -> metadata:Sync_meta.t
  -> Sync_protocol.server_message
  -> (outcome, error) result

val error_message : error -> string
