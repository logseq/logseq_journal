type graph_id = Graph_types.Uuid.t [@@deriving yojson]

type cache_schema = Managed_graph.schema =
  { major : int
  ; minor : int
  ; exact : bool
  }
[@@deriving yojson]

type graph = Managed_graph.t =
  { graph_id : graph_id
  ; name : string
  ; schema : cache_schema
  ; encrypted : bool
  }
[@@deriving yojson]

type account_generation = int

type graph_generation = int

type connection_generation = int

type presentation_generation = int

type lifecycle_generation = int64

type account_scope =
  { managed_sync_origin : Uri.t
  ; user_id : string
  ; account_generation : account_generation
  ; presentation_generation : presentation_generation
  ; lifecycle_generation : lifecycle_generation
  }

type graph_scope =
  { account : account_scope
  ; graph_id : graph_id
  ; graph_generation : graph_generation
  }

type sync_phase =
  | Offline
  | Connecting
  | Pulling
  | Submitting
  | Current
  | Paused
  | Failed

type startup_failure_stage =
  | During_authentication
  | During_catalog
  | During_local_restore
  | During_bootstrap
  | During_e2ee

type local_unavailability =
  | No_local_account
  | Local_catalog_unavailable
  | Local_mirror_unavailable
  | Local_key_unavailable
  | Local_restore_failed

type local_access =
  | Local_pending
  | Local_available
  | Local_unavailable of local_unavailability

type startup_network_phase =
  | Local_only
  | Online_after_timeline
  | Online_by_user

type startup_facts =
  { authenticated : bool
  ; local_access : local_access
  ; network_phase : startup_network_phase
  ; catalog_loading : bool
  ; awaiting_selection : bool
  ; restoring_local : bool
  ; bootstrapping : bool
  ; awaiting_e2ee_password : bool
  ; failure : startup_failure_stage option
  ; account_generation : account_generation
  ; graph_generation : graph_generation
  ; presentation_generation : presentation_generation
  }

type catalog_cache =
  { cache_user_id : string
  ; cache_graphs : graph list
  ; cache_selected_graph : graph_id option
  ; cache_resident_graphs : graph_id list option [@default None]
  }
[@@deriving yojson]

type startup_scope =
  { account_generation : account_generation
  ; presentation_generation : presentation_generation
  }

type timeline_scope =
  { startup : startup_scope
  ; graph_id : graph_id
  ; graph_generation : graph_generation
  }

type local_deletion_stage =
  | Closing_graph
  | Deleting_mirror
  | Clearing_selection

type local_deletion =
  | Deletion_in_progress of local_deletion_stage
  | Deletion_failed of local_deletion_stage

type unlock_challenge =
  { challenge_scope : graph_scope
  ; challenge_id : int
  ; encrypted_graph_key : string
  ; private_key_package : string
  }

type unlock_stage = Private_key of int | Graph_key of int | Attachment

type unlock_submission =
  { challenge : unlock_challenge
  ; operation_id : int
  ; stage : unlock_stage
  }

type unlock_attached = { submission : unlock_submission; attached_scope : graph_scope }

type unlock_recovery =
  | Retry_password of unlock_challenge * string
  | Retry_preparation of string

type unlock_phase =
  | Unlock_inactive
  | Unlock_challenge of unlock_challenge
  | Unlock_running of unlock_submission
  | Unlock_bootstrapping of unlock_submission
  | Unlock_presentable of unlock_attached
  | Unlock_failed of unlock_recovery
  | Unlock_cancelled of unlock_submission

val unlock_challenge : unlock_phase -> unlock_challenge option
val equal_unlock_challenge : unlock_challenge -> unlock_challenge -> bool
val unlock_challenge_scope : unlock_challenge -> graph_scope
val unlock_submission_challenge : unlock_submission -> unlock_challenge
val equal_unlock_submission : unlock_submission -> unlock_submission -> bool
val unlock_attached_submission : unlock_attached -> unlock_submission
val unlock_attached_scope : unlock_attached -> graph_scope

(** Presentation only: retry eligibility is still determined by the original outcome.
    Unknown and security failures require attention even when transport retries them. *)
type error_attention = Transient_connection | Requires_attention

type snapshot =
  { sync_phase : sync_phase
  ; catalog : graph list
  ; selected_graph : graph_id option
  ; resident_graphs : graph_id list
  ; applied_server_t : Server_cursor.t option
  ; timeline_presentation_pending : bool
  ; unlock : unlock_phase
  ; startup : startup_facts
  ; last_error : string option
  ; last_error_attention : error_attention option
  ; local_deletion : local_deletion option
  }

type diagnostic_group =
  { title : string
  ; entries : (string * string) list
  }

type diagnostics = { groups : diagnostic_group list }

type state =
  { snapshot : snapshot
  ; diagnostics : diagnostics
  }

type coordination_state =
  { account : account_scope option
  ; desired_residents : graph_id list
  ; residents : (graph_scope * state) list
  ; selected : timeline_scope option
  ; deletion : (graph_scope * local_deletion) option
  }
