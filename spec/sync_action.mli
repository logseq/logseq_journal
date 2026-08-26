(** Capability-indexed sync actions.

    This file is the canonical virtual-module contract. The production
    implementation must be selected through Dune [virtual_modules] and
    [(implements ...)] rather than by copying this interface. *)

type local
type network
type account = Sync_startup_phase.account
type graph_level = Sync_startup_phase.graph
type connection = Sync_startup_phase.connection

(** Boundary-owned catalog data. The virtual specification deliberately does
    not depend on the production catalog, authentication, or bootstrap modules. *)
type graph =
  { graph_id : string
  ; name : string
  ; schema_major : int
  ; schema_minor : int
  ; schema_exact : bool
  ; encrypted : bool
  }

type snapshot_baseline = { server_t : int }

type content_encoding =
  [ `Gzip
  | `Identity
  ]

type snapshot_metadata =
  { key : string
  ; url : Uri.t
  ; content_encoding : content_encoding
  }

(** The wrapped value is ciphertext. Construction validates its encoding and
    size; plaintext graph keys have no representation in this interface. *)
type wrapped_graph_key

val wrapped_graph_key_of_string : string -> wrapped_graph_key option
val wrapped_graph_key_to_string : wrapped_graph_key -> string

type _ auth_purpose =
  | Catalog_discovery : account auth_purpose
  | Snapshot_bootstrap : graph_level auth_purpose
  | E2ee_key_access : graph_level auth_purpose
  | Http_pull : connection auth_purpose
  | Transaction_submission : connection auth_purpose
  | Websocket_connect : connection auth_purpose

type auth_purpose_name =
  | Catalog_discovery_name
  | Snapshot_bootstrap_name
  | E2ee_key_access_name
  | Http_pull_name
  | Transaction_submission_name
  | Websocket_connect_name

type network_scope =
  | Account_scope of Sync_startup_phase.account_scope_view
  | Graph_scope of Sync_startup_phase.graph_scope_view
  | Connection_scope of Sync_startup_phase.connection_scope_view

type scoped_challenge =
  { challenge_id : string
  ; purpose : auth_purpose_name
  ; scope : network_scope
  }

type inspect_mirror =
  { request : Sync_startup_phase.mirror Sync_startup_phase.local_request
  ; graph : graph
  }

type wrapped_key_lookup =
  { wrapped_key_request :
      Sync_startup_phase.wrapped_graph_key Sync_startup_phase.local_request
  ; private_key_request :
      Sync_startup_phase.local_private_key Sync_startup_phase.local_request
  }

type wrapped_key_save =
  { scope : Sync_startup_phase.graph_scope_view
  ; encrypted_graph_key : wrapped_graph_key
  }

type graph_cleanup = { scope : Sync_startup_phase.graph_scope_view }
type account_cleanup = { scope : Sync_startup_phase.account_scope_view }

type open_graph =
  { request : Sync_startup_phase.graph_open Sync_startup_phase.local_request
  ; graph : graph
  ; encrypted_graph_key : wrapped_graph_key option
  }

type fetch_graph =
  { scope : Sync_startup_phase.graph_scope_view
  ; graph : graph
  ; token : string
  }

type download_snapshot =
  { scope : Sync_startup_phase.graph_scope_view
  ; graph : graph
  ; baseline : snapshot_baseline
  ; metadata : snapshot_metadata
  ; token : string
  }

type activate_snapshot =
  { scope : Sync_startup_phase.graph_scope_view
  ; graph : graph
  ; server_t : int
  ; snapshot_path : string
  ; expected_rows : int
  ; encrypted_graph_key : wrapped_graph_key option
  }

type connection_token =
  { scope : Sync_startup_phase.connection_scope_view
  ; token : string
  }

type reconnect =
  { scope : Sync_startup_phase.connection_scope_view
  ; delay_seconds : float
  }

type http_pull =
  { scope : Sync_startup_phase.connection_scope_view
  ; since : int
  ; token : string
  }

type http_transaction =
  { scope : Sync_startup_phase.connection_scope_view
  ; payload : string
  ; token : string
  }

(** Constructors are private: executors may inspect actions, while planners can
    create them only through the smart constructors below. *)
type _ t = private
  | Inspect_mirror : inspect_mirror -> local t
  | Load_and_verify_wrapped_graph_key : wrapped_key_lookup -> local t
  | Verify_and_save_wrapped_graph_key : wrapped_key_save -> local t
  | Delete_wrapped_graph_key : graph_cleanup -> local t
  | Delete_account_secrets : account_cleanup -> local t
  | Open_graph : open_graph -> local t
  | Close_graph : local t
  | Delete_mirror : graph_cleanup -> local t
  | Need_id_token : scoped_challenge -> network t
  | Fetch_catalog :
      { scope : Sync_startup_phase.account_scope_view
      ; token : string
      }
      -> network t
  | Fetch_snapshot_baseline : fetch_graph -> network t
  | Fetch_snapshot_metadata : fetch_graph -> network t
  | Download_snapshot_artifact : download_snapshot -> network t
  | Activate_snapshot : activate_snapshot -> network t
  | Fetch_e2ee_graph_key : fetch_graph -> network t
  | Fetch_e2ee_user_keys :
      { scope : Sync_startup_phase.graph_scope_view
      ; token : string
      }
      -> network t
  | Connect_websocket : connection_token -> network t
  | Close_websocket : network t
  | Send_websocket :
      { scope : Sync_startup_phase.connection_scope_view
      ; payload : string
      }
      -> network t
  | Schedule_reconnect : reconnect -> network t
  | Schedule_foreground_probe : reconnect -> network t
  | Apply_sync_frame :
      { scope : Sync_startup_phase.connection_scope_view
      ; frame : string
      }
      -> network t
  | Recover_submitted :
      { scope : Sync_startup_phase.connection_scope_view
      ; transaction_ids : string list
      }
      -> network t
  | Fetch_http_pull : http_pull -> network t
  | Submit_http_transaction : http_transaction -> network t

(** The general worker queue uses existential packing only after a typed planner
    has produced an action. Offline startup planners return [local t list]. *)
type packed = Pack : 'capability t -> packed

val pack : 'capability t -> packed

(** Capability-preserving elimination for the serialized worker queue. *)
type classified =
  | Local_action : local t -> classified
  | Network_action : network t -> classified

val classify : packed -> classified

type construction_error =
  [ `Invalid_payload
  | `Scope_mismatch
  ]

val inspect_mirror
  :  Sync_startup_phase.mirror Sync_startup_phase.local_request
  -> graph
  -> (local t, construction_error) result

(** Both requests must have been minted from the same restoring witness. *)
val load_and_verify_wrapped_graph_key
  :  Sync_startup_phase.wrapped_graph_key Sync_startup_phase.local_request
  -> Sync_startup_phase.local_private_key Sync_startup_phase.local_request
  -> (local t, construction_error) result

val verify_and_save_wrapped_graph_key
  :  Sync_startup_phase.graph_scope
  -> wrapped_graph_key
  -> local t

val delete_wrapped_graph_key : Sync_startup_phase.graph_scope -> local t
val delete_account_secrets : Sync_startup_phase.account_scope -> local t

val open_graph
  :  Sync_startup_phase.graph_open Sync_startup_phase.local_request
  -> graph
  -> encrypted_graph_key:wrapped_graph_key option
  -> (local t, construction_error) result

val close_graph : local t
val delete_mirror : Sync_startup_phase.graph_scope -> local t

(** Permit-indexed purposes prevent an account permit from authorizing graph or
    connection work. Identity and generations are always derived from [permit]. *)
val need_id_token
  :  'level Sync_startup_phase.network_permit
  -> challenge_id:string
  -> 'level auth_purpose
  -> (network t, construction_error) result

val fetch_catalog
  :  account Sync_startup_phase.network_permit
  -> token:string
  -> (network t, construction_error) result

val fetch_snapshot_baseline
  :  graph_level Sync_startup_phase.network_permit
  -> graph
  -> token:string
  -> (network t, construction_error) result

val fetch_snapshot_metadata
  :  graph_level Sync_startup_phase.network_permit
  -> graph
  -> token:string
  -> (network t, construction_error) result

val download_snapshot_artifact
  :  graph_level Sync_startup_phase.network_permit
  -> graph
  -> baseline:snapshot_baseline
  -> metadata:snapshot_metadata
  -> token:string
  -> (network t, construction_error) result

val activate_snapshot
  :  graph_level Sync_startup_phase.network_permit
  -> graph
  -> server_t:int
  -> snapshot_path:string
  -> expected_rows:int
  -> encrypted_graph_key:wrapped_graph_key option
  -> (network t, construction_error) result

val fetch_e2ee_graph_key
  :  graph_level Sync_startup_phase.network_permit
  -> graph
  -> token:string
  -> (network t, construction_error) result

val fetch_e2ee_user_keys
  :  graph_level Sync_startup_phase.network_permit
  -> token:string
  -> (network t, construction_error) result

val connect_websocket
  :  connection Sync_startup_phase.network_permit
  -> token:string
  -> (network t, construction_error) result

(** Closing an existing transport cannot initiate online work and therefore does
    not require a permit, but remains classified in the network lane. *)
val close_websocket : network t

val send_websocket
  :  connection Sync_startup_phase.network_permit
  -> payload:string
  -> (network t, construction_error) result

val schedule_reconnect
  :  connection Sync_startup_phase.network_permit
  -> delay_seconds:float
  -> (network t, construction_error) result

val schedule_foreground_probe
  :  connection Sync_startup_phase.network_permit
  -> delay_seconds:float
  -> (network t, construction_error) result

val apply_sync_frame
  :  connection Sync_startup_phase.network_permit
  -> frame:string
  -> (network t, construction_error) result

val recover_submitted
  :  connection Sync_startup_phase.network_permit
  -> transaction_ids:string list
  -> (network t, construction_error) result

val fetch_http_pull
  :  connection Sync_startup_phase.network_permit
  -> since:int
  -> token:string
  -> (network t, construction_error) result

val submit_http_transaction
  :  connection Sync_startup_phase.network_permit
  -> payload:string
  -> token:string
  -> (network t, construction_error) result
