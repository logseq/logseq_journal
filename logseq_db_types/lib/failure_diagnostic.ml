type t =
  { operation_name : string
  ; reason_name : string
  ; source_name : string
  ; cursor : string option
  ; http_status : int option
  }

let operations =
  [ "inspectMirror", "sync"
  ; "attachGraph", "sync"
  ; "inspectSync", "sync"
  ; "applyOutbox", "sync"
  ; "applyAuthoritative", "sync"
  ; "commitLocal", "mutation"
  ; "closeDatabase", "lifecycle"
  ; "deleteMirror", "storage"
  ; "activateSnapshot", "sync"
  ; "resetAccount", "account"
  ; "assetPreview", "asset"
  ; "assetMetadata", "asset"
  ; "assetRelease", "asset"
  ; "restoreUploads", "upload"
  ; "assetUpload", "upload"
  ; "assetDownload", "asset"
  ; "loadCatalog", "storage"
  ; "saveCatalog", "storage"
  ; "prepareCatalog", "storage"
  ; "platformCrypto", "crypto"
  ; "decryptValue", "crypto"
  ; "decodeSnapshot", "sync"
  ; "assetCache", "asset"
  ; "projectGraph", "presentation"
  ; "decodeListEvent", "native"
  ; "decodeListRowEvent", "native"
  ; "decodeExtensionEvent", "native"
  ; "decodeAttachmentSelection", "native"
  ; "decodeEnvironment", "native"
  ; "workerOperation", "worker"
  ]
;;

let reasons =
  [ "unknown", "Operation failed"
  ; "databaseClosed", "Database is closed"
  ; "tokenConflict", "Sync version changed"
  ; "generationInvalidated", "Database generation changed"
  ; "busy", "Storage is busy"
  ; "persistenceFailed", "Persistence failed"
  ; "fatalState", "Storage requires recovery"
  ; "transitionInvalid", "Transition is invalid"
  ; "integrityFailed", "Integrity validation failed"
  ; "cryptoRequired", "Decrypted or protected values are required"
  ; "cryptoUnexpected", "Unexpected cryptographic values"
  ; "cryptoInvalid", "Cryptographic result is invalid"
  ; "preparationConsumed", "Preparation was already consumed"
  ; "capacityUnavailable", "Capacity is unavailable"
  ; "invalidRequest", "Request is invalid"
  ; "invalidMutation", "Mutation is invalid"
  ; "missingPrecondition", "Required precondition is missing"
  ; "preconditionConflict", "Precondition changed"
  ; "identityConflict", "Mutation identity conflicts"
  ; "limitExceeded", "Resource limit exceeded"
  ; "unsupportedFootprint", "Mutation footprint is unsupported"
  ; "mirrorAbsent", "Local mirror is absent"
  ; "ownershipConflict", "Local mirror is owned by another session"
  ; "attachmentStale", "Graph attachment is stale"
  ; "restoreFailed", "Graph restoration failed"
  ; "corruptStore", "Authoritative storage is invalid"
  ; "corruptOutbox", "Outbox storage is invalid"
  ; "corruptReceipt", "Mutation receipt storage is invalid"
  ; "resourceFailed", "Resource could not be opened"
  ; "invalidPath", "Storage path is invalid"
  ; "invalidExpectedRows", "Expected row count is invalid"
  ; "inputTooLarge", "Input exceeds its size limit"
  ; "mirrorExists", "Local mirror already exists"
  ; "staleInspection", "Mirror inspection is stale"
  ; "stateError", "Operation state is invalid"
  ; "parseFailed", "Input could not be parsed"
  ; "cancelled", "Operation was cancelled"
  ; "staleCommit", "Commit is stale"
  ; "commitConsumed", "Commit was already consumed"
  ; "inspectionFailed", "Mirror inspection failed"
  ; "deleteFailed", "Local deletion failed"
  ; "closeFailed", "Storage could not be closed"
  ; "unavailable", "Resource is unavailable"
  ; "networkFailed", "Network operation failed"
  ; "authenticationFailed", "Authentication failed"
  ; "checksumMismatch", "Checksum does not match"
  ; "notFound", "Asset was not found"
  ; "locked", "Graph key is locked"
  ; "storageFull", "Storage is full"
  ; "missingSource", "Attachment source is missing"
  ; "sizeRejected", "Attachment exceeds its size limit"
  ; "revokedAccess", "Attachment source access was revoked"
  ; "invalidContent", "Content is invalid"
  ; "cleanupFailed", "Cleanup could not finish"
  ; "pragmaMismatch", "SQLite configuration does not match"
  ; "storageCorrupt", "SQLite storage is invalid"
  ; "storageBeginFailed", "SQLite transaction could not begin"
  ; "storageWriteFailed", "SQLite storage write failed"
  ; "storageCommitFailed", "SQLite transaction could not commit"
  ; "storageCheckpointFailed", "SQLite checkpoint failed"
  ; "storageCloseFailed", "SQLite storage could not close"
  ]
;;

(* These are exact producer-owned literals, never substrings of graph values. *)
let producer_sources =
  [ "empty-submit-group", "empty submit group"
  ; "duplicate-submit-member", "duplicate submit member"
  ; "submit-member-missing", "submit member is missing"
  ; "submit-member-not-queued", "submit member is not queued"
  ; "cursor-overflow", "server cursor interval overflows int64"
  ; "submit-members-reordered", "submit members are reordered"
  ; "retry-batch-missing", "retry batch is missing"
  ; "retry-batch-not-uncertain", "retry batch is not transport-uncertain"
  ; "retry-protected-bytes-missing", "retry batch has no protected bytes"
  ; "acceptance-after-stale", "acceptance contradicts settled Stale evidence"
  ; "terminal-acceptance-mismatch", "terminal acceptance mismatch"
  ; ( "acceptance-after-nonexecution"
    , "acceptance contradicts proven conditional non-execution" )
  ; "accept-batch-missing", "accept batch is missing"
  ; "acceptance-checksum-mismatch", "acceptance checksum mismatch"
  ; "terminal-stale-mismatch", "terminal Stale rejection mismatch"
  ; "batch-already-accepted", "batch already accepted"
  ; "reject-batch-missing", "reject batch is missing"
  ; "stale-barrier-not-advancing", "Stale barrier does not advance the submitted baseline"
  ; "stale-after-acceptance", "Stale rejection contradicts acceptance"
  ; "pending-stale-mismatch", "pending Stale rejection mismatch"
  ; "crypto-preparation-inconsistent", "preparation crypto state is inconsistent"
  ; ( "own-submission-interval-missing"
    , "own transaction omitted its frozen submission interval" )
  ; "negative-cursor-interval", "negative server cursor interval"
  ; ( "acceptance-before-own-interval"
    , "acceptance barrier precedes its own submission interval" )
  ; ( "covered-acceptance-origin-missing"
    , "covered acceptance has no durable origin evidence" )
  ; "asset-destination-changed", "Asset reference or destination changed"
  ; "uploaded-version-changed", "Uploaded version no longer matches the live asset"
  ; "legacy-status-replay-only", "Legacy status is replay-only"
  ; ( "invalid-status-definition"
    , "Status is missing, recycled or belongs to another property" )
  ; "attachment-reference-changed", "Attachment reference changed"
  ; "snapshot-crypto-incomplete", "snapshot crypto input is incomplete"
  ; "snapshot-database-commit", "snapshot database commit failed"
  ; "snapshot-metadata-commit", "snapshot metadata commit failed"
  ; "restore-open-failed", "unable to open mirror"
  ; "restore-database-failed", "unable to restore authoritative database"
  ; "lower-storage-close-failed", "lower storage close failed"
  ; "legacy-status-identity-invalid", "invalid legacy status identity"
  ; "asset-insertion-invalid", "Asset insertion requires one block and a bounded size"
  ; "insert-tree-duplicate-uuids", "insert tree contains duplicate block UUIDs"
  ; ( "snapshot-row-address-type"
    , "snapshot row address must be a non-negative Transit integer" )
  ; "snapshot-row-addresses-type", "snapshot row addresses must be JSON text or nil"
  ; "snapshot-row-shape", "snapshot row must be [addr, content, addresses]"
  ; "snapshot-frame-shape", "snapshot frame payload must be a Transit row array"
  ; "snapshot-frame-limit", "snapshot frame exceeds configured size limit"
  ; "snapshot-stream-incomplete", "incomplete framed snapshot stream"
  ; "snapshot-address-order", "snapshot row addresses must be strictly increasing"
  ; "snapshot-extra-rows", "snapshot contains more rows than advertised"
  ; "snapshot-negative-row-count", "snapshot expected row count must be non-negative"
  ; "snapshot-row-count-mismatch", "snapshot row count does not match server metadata"
  ; "snapshot-root-missing", "snapshot is missing DataScript root row 0"
  ; "snapshot-tail-missing", "snapshot is missing DataScript tail row 1"
  ; "snapshot-row-count-header", "snapshot row-count header is invalid"
  ; "snapshot-gzip-empty", "snapshot gzip layer is empty"
  ; "snapshot-gzip-invalid", "snapshot gzip layer is invalid"
  ; "snapshot-decompression-bound", "snapshot decompressed bound must be positive"
  ; "snapshot-gzip-layer-limit", "snapshot exceeds the supported gzip layer count"
  ; "snapshot-gzip-staging-paths", "two private gzip staging paths are required"
  ; "snapshot-sqlite-open", "snapshot SQLite storage cannot be opened"
  ; "snapshot-sqlite-corrupt", "snapshot SQLite storage is corrupt"
  ; "snapshot-import-failed", "The downloaded graph snapshot could not be imported."
  ; "snapshot-remote-identity", "The downloaded graph has an unexpected remote identity."
  ; ( "snapshot-sync-identity"
    , "The downloaded graph has an invalid synchronization identity." )
  ; "snapshot-unsupported-value", "The downloaded graph contains unsupported values."
  ; "snapshot-store-corrupt", "The downloaded graph storage is corrupt."
  ; "snapshot-close-failed", "snapshot storage cannot be closed"
  ; "snapshot-storage-closed", "snapshot storage is already closed"
  ; "snapshot-plaintext-incomplete", "snapshot plaintext batch is incomplete"
  ; "snapshot-plaintext-target-type", "snapshot plaintext target is not a string"
  ; "snapshot-already-activated", "snapshot staging artifact is already activated"
  ; "active-mirror-exists", "active mirror already exists"
  ; "snapshot-checksum-mismatch", "snapshot checksum mismatch"
  ; "storage-table-contract", "unexpected kvs table contract"
  ; "storage-nested-staging", "nested storage staging is forbidden"
  ; "storage-staging-missing", "storage staging has not begun"
  ; "storage-root-missing", "storage root address 0 is missing"
  ; "storage-root-payload", "storage root address 0 has the wrong payload"
  ; "storage-tail-missing", "storage tail address 1 is missing"
  ; "storage-tail-payload", "storage tail address 1 has the wrong payload"
  ; "storage-root-index-metadata", "storage root index metadata is malformed"
  ; "storage-root-metadata", "storage root metadata is malformed"
  ; "storage-restore-empty", "DataScript restore returned no database"
  ; "storage-eavt-root-type", "EAVT root address is not an index node"
  ; "storage-eavt-root-missing", "EAVT root address is missing"
  ; "storage-aevt-root-type", "AEVT root address is not an index node"
  ; "storage-aevt-root-missing", "AEVT root address is missing"
  ; "storage-avet-root-type", "AVET root address is not an index node"
  ; "storage-avet-root-missing", "AVET root address is missing"
  ; "crypto-item-missing", "missing cryptographic item"
  ; "crypto-item-extra", "extra cryptographic item"
  ; "crypto-item-duplicate", "duplicate cryptographic item"
  ; "crypto-items-reordered", "reordered cryptographic items"
  ; "crypto-result-stale", "stale cryptographic result"
  ; "crypto-result-limit", "cryptographic result limit exceeded"
  ; "decode-protected-value-failed", "decode protected value failed"
  ; "decode-decrypted-value-failed", "decode decrypted value failed"
  ; "decode-encrypted-private-key-failed", "decode encrypted private key failed"
  ; "decode-encrypted-graph-key-failed", "decode encrypted graph key failed"
  ; "e2ee-graph-key-response-shape-is-invalid", "E2EE graph key response shape is invalid"
  ; "e2ee-user-keys-response-shape-is-invalid", "E2EE user keys response shape is invalid"
  ; "asset-http-status", "Asset HTTP response status"
  ; "invalid-plaintext-size-limit", "Invalid plaintext size limit"
  ; "asset-exceeds-wire-size-limit", "Asset exceeds wire size limit"
  ; "invalid-asset-aes-gcm-envelope", "Invalid asset AES-GCM envelope"
  ; "asset-transit-payload-is-invalid", "Asset Transit payload is invalid"
  ; "asset-checksum-mismatch", "Asset checksum mismatch"
  ; "asset-namespace-is-not-a-directory", "asset namespace is not a directory"
  ; "unsupported-asset-retirement", "unsupported asset retirement"
  ; "retired-asset-identity-changed", "retired asset identity changed"
  ; "canonical-asset-identity-changed", "canonical asset identity changed"
  ; "asset-retirement-rename-failed", "asset retirement rename failed"
  ; "asset-restore-conflict-retirement-retained", "asset restore conflict; retirement retained"
  ; "asset-restore-is-incomplete-retirement-retained", "asset restore is incomplete; retirement retained"
  ; "invalid-cache-size-limits", "Invalid cache size limits"
  ; "asset-exceeds-cache-file-limit", "Asset exceeds cache file limit"
  ; "invalid-staged-file", "Invalid staged file"
  ; "invalid-staged-file-type", "Invalid staged file type"
  ; "invalid-staging-budget", "Invalid staging budget"
  ; "staged-import-already-exists", "Staged import already exists"
  ; "import-source-must-be-a-regular-file", "Import source must be a regular file"
  ; "import-exceeds-file-size-limit", "Import exceeds file size limit"
  ; "import-source-changed-during-staging", "Import source changed during staging"
  ; "asset-key-handle-missing", "Asset graph key handle is missing"
  ; "asset-key-scope-mismatch", "Asset graph key scope does not match"
  ; "asset-key-unavailable", "graph key handle is unavailable or out of scope"
  ; "authentication-failed", "Authentication failed."
  ; "authorization-failed", "Authorization failed."
  ; "decrypted-transit-is-invalid", "decrypted Transit is invalid"
  ; "catalog-directory-is-not-a-directory", "catalog directory is not a directory"
  ; "asset-upload-source-is-not-a-regular-file", "Asset upload source is not a regular file"
  ; "asset-upload-source-grew-during-reading", "Asset upload source grew during reading"
  ; "asset-upload-source-ended-during-reading", "Asset upload source ended during reading"
  ; "asset-upload-checksum-mismatch", "Asset upload checksum mismatch"
  ; "asset-upload-base-url-is-invalid", "Asset upload base URL is invalid"
  ; "asset-staging-storage-is-full", "Asset staging storage is full"
  ; "asset-staging-scope-is-stale", "Asset staging scope is stale"
  ; "asset-staging-checksum-mismatch", "Asset staging checksum mismatch"
  ; "asset-exceeds-plaintext-size-limit", "Asset exceeds plaintext size limit"
  ; "invalid-aes-gcm-output", "Invalid AES-GCM output"
  ; "asset-cache-manifest-exceeds-size-limit", "Asset cache manifest exceeds size limit"
  ; "asset-cache-manifest-shape-is-invalid", "Asset cache manifest shape is invalid"
  ; "asset-cache-manifest-asset-version-is-invalid", "Asset cache manifest asset version is invalid"
  ; "asset-cache-manifest-size-is-invalid", "Asset cache manifest size is invalid"
  ; "asset-cache-manifest-filename-does-not-match-its-identity", "Asset cache manifest filename does not match its identity"
  ; "asset-cache-manifest-json-is-invalid", "Asset cache manifest JSON is invalid"
  ; "asset-cache-metadata-shape-is-invalid", "Asset cache metadata shape is invalid"
  ; "upload-checkpoint-shape-is-invalid", "Upload checkpoint shape is invalid"
  ; "upload-checkpoint-asset-version-is-invalid", "Upload checkpoint asset version is invalid"
  ; "upload-checkpoint-intent-is-invalid", "Upload checkpoint intent is invalid"
  ; "upload-checkpoint-phase-is-invalid", "Upload checkpoint phase is invalid"
  ; "upload-checkpoint-json-is-invalid", "Upload checkpoint JSON is invalid"
  ; "unsupported-upload-checkpoint-format", "Unsupported upload checkpoint format"
  ; "upload-checkpoint-exceeds-size-limit", "Upload checkpoint exceeds size limit"
  ; "retirement-capture-graph-identity-is-invalid", "Retirement capture graph identity is invalid"
  ; "retirement-capture-operation-identity-is-invalid", "Retirement capture operation identity is invalid"
  ; "retirement-capture-row-shape-is-invalid", "Retirement capture row shape is invalid"
  ; "retirement-capture-shape-is-invalid", "Retirement capture shape is invalid"
  ; "unsupported-retirement-capture-format", "Unsupported retirement capture format"
  ; "retirement-capture-scope-mismatch", "Retirement capture scope mismatch"
  ; "duplicate-retirement-checkpoint", "Duplicate retirement checkpoint"
  ; "snapshot-gzip-input-could-not-be-opened", "snapshot gzip input could not be opened"
  ; "snapshot-gzip-output-could-not-be-opened", "snapshot gzip output could not be opened"
  ; "snapshot-gzip-decode-failed", "snapshot gzip decode failed"
  ; "snapshot-gzip-output-write-failed", "snapshot gzip output write failed"
  ; "snapshot-gzip-decompressed-limit-exceeded", "snapshot gzip decompressed limit exceeded"
  ; "snapshot-artifact-exceeds-its-decompressed-bound", "snapshot artifact exceeds its decompressed bound"
  ; "platform-crypto-response-json-is-invalid", "platform crypto response JSON is invalid"
  ; "platform-crypto-response-shape-is-invalid", "platform crypto response shape is invalid"
  ; "platform-crypto-response-error-is-missing", "platform crypto response error is missing"
  ; "platform-crypto-provider-failed", "platform crypto provider failed"
  ; "platform-crypto-returned-invalid-data", "platform crypto returned invalid data"
  ; "platform-crypto-response-is-incomplete", "platform crypto response is incomplete"
  ; "platform-crypto-unavailable", "platform crypto unavailable"
  ; "crypto-invalid-request", "cryptoInvalidRequest"
  ; "crypto-authentication-failed", "cryptoAuthenticationFailed"
  ; "crypto-invalid-private-key", "cryptoInvalidPrivateKey"
  ; "crypto-rsadecryption-failed", "cryptoRSADecryptionFailed"
  ; "crypto-invalid-graph-key-length", "cryptoInvalidGraphKeyLength"
  ; "crypto-key-store-locked", "cryptoKeyStoreLocked"
  ; "crypto-key-store-permission-denied", "cryptoKeyStorePermissionDenied"
  ; "crypto-key-store-unavailable", "cryptoKeyStoreUnavailable"
  ; "crypto-key-store-decode-failed", "cryptoKeyStoreDecodeFailed"
  ; "crypto-key-store-failed", "cryptoKeyStoreFailed"
  ; "crypto-key-store-invalid-type", "cryptoKeyStoreInvalidType"
  ; "crypto-operation-failed", "cryptoOperationFailed"
  ; "wrapped-graph-key-unavailable", "wrappedGraphKeyUnavailable"
  ; "crypto-invalid-aesinput", "cryptoInvalidAESInput"
  ; "crypto-engine-private-key-unavailable", "cryptoEnginePrivateKeyUnavailable"
  ; "crypto-allocation-failed", "cryptoAllocationFailed"
  ; "crypto-native-unavailable", "cryptoNativeUnavailable"
  ; "crypto-native-response-unavailable", "cryptoNativeResponseUnavailable"
  ; "platform-binary-crypto-invalid-request", "platform binary crypto invalid request"
  ; "platform-binary-crypto-authentication-failed", "platform binary crypto authentication failed"
  ; "platform-binary-crypto-allocation-failed", "platform binary crypto allocation failed"
  ; "platform-binary-crypto-operation-failed", "platform binary crypto operation failed"
  ; "platform-binary-crypto-unavailable", "platform binary crypto unavailable"
  ; "platform-binary-crypto-invalid-response", "platform binary crypto invalid response"
  ; "snapshot-root-unavailable", "snapshot root directory is unavailable"
  ; "snapshot-next-after-persist-or-commit", "snapshot next batch requested after persist or commit"
  ; "snapshot-crypto-pending", "snapshot crypto batch is pending"
  ; "snapshot-supply-after-persist-or-commit", "snapshot supply requested after persist or commit"
  ; "snapshot-persist-awaiting-crypto", "snapshot persist requested while awaiting crypto"
  ; "snapshot-checkpoint-invalid", "snapshot checkpoint is invalid"
  ; "snapshot-schema-negative", "sync schema version must be non-negative"
  ; "snapshot-checksum-invalid", "sync checksum must be 16 lowercase hexadecimal characters"
  ; "retirement-directory-type", "Local retirement path is not a physical directory"
  ; "retirement-write-stalled", "retirement journal write stalled"
  ; "retirement-journal-unsupported", "Unsupported retirement journal"
  ; "retirement-account-mismatch", "Retirement journal account mismatch"
  ; "import-identity-used", "This import identity is already in use"
  ; "retirement-response-unexpected", "Unexpected attachment retirement response"
  ; "native-event-json", "Native event JSON syntax is invalid"
  ; "native-event-shape", "Native event shape is invalid"
  ; "native-event-utf8-field", "invalid UTF-8 field name"
  ; "native-event-duplicate-field", "duplicate JSON field"
  ; "native-event-utf8-value", "invalid UTF-8 string"
  ; "native-event-number", "non-finite JSON number"
  ; "native-event-nonstandard", "nonstandard JSON value"
  ; "native-event-bound", "JSON exceeds byte budget"
  ; "native-event-value", "invalid JSON value"
  ; "native-attachment-identity", "Invalid import identity"
  ; "native-attachment-selection", "Invalid attachment selection"
  ; "native-attachment-batch", "Invalid attachment batch"
  ; "native-attachment-source", "Invalid attachment source"
  ; "native-attachment-action", "Invalid attachment action"
  ; "native-environment-shape", "environment event: Native event shape is invalid"
  ; "native-environment-brightness", "environment event: environment brightness is unsupported"
  ; "native-environment-json", "environment event is not valid JSON"
  ; "native-environment-utf8-field", "environment event: invalid UTF-8 field name"
  ; "native-environment-duplicate-field", "environment event: duplicate JSON field"
  ; "native-environment-utf8-value", "environment event: invalid UTF-8 string"
  ; "native-environment-number", "environment event: non-finite JSON number"
  ; "native-environment-nonstandard", "environment event: nonstandard JSON value"
  ; "native-environment-bound", "environment event: JSON exceeds byte budget"
  ; "native-environment-value", "environment event: invalid JSON value"
  ; "native-envelope-truncated", "application platform envelope is truncated"
  ; "native-envelope-exceeds-its-bound", "application platform envelope exceeds its bound"
  ; "native-envelope-magic-invalid", "application platform envelope magic is invalid"
  ; "native-envelope-version-unsupported", "application platform envelope version is unsupported"
  ; "native-envelope-reserved-field-invalid", "application platform envelope reserved field is invalid"
  ; "native-envelope-payload-length-invalid", "application platform envelope payload length is invalid"
  ; "native-envelope-tag-unsupported", "application platform envelope tag is unsupported"
  ; "native-envelope-generation-fields-are-invalid", "application platform envelope generation fields are invalid"
  ; "projection-uuid-invalid", "invalid UUID"
  ; "projection-capture-not-visible", "The captured block was not visible after commit."
  ; "projection-update-not-visible", "The updated block was not visible after commit."
  ; "projection-calendar-unavailable", "The host calendar is unavailable."
  ; "projection-block-revision-missing", "The block revision is not retained."
  ; "projection-page-revision-missing", "The page revision is not retained."
  ; "projection-structure-revision-missing", "The structure revision is not retained."
  ; "projection-status-unavailable", "This task status is unavailable. Choose another status before saving."
  ; "projection-default-status-missing", "Choose a task status; this graph has no available default."
  ; "projection-status-invalid", "Choose a valid task status before saving."
  ; "projection-feed-day-limit", "The feed day limit must be positive."
  ; "projection-feed-block-limit", "The feed block limit must be positive."
  ; "projection-feed-slot-limit", "The feed slot limit must reserve one day and one block."
  ; "projection-journal-page-missing", "The requested journal page is not retained."
  ; "projection-capture-calendar-changed", "The local calendar changed before capture admission."
  ; "projection-block-page-missing", "The block page is not retained."
  ; "projection-child-calendar-changed", "The local calendar changed before child admission."
  ; "projection-append-parent-missing", "The append parent is unavailable."
  ; "projection-conflict-block-missing", "The conflicted block was not visible during reconciliation."
  ; "projection-append-parent-mismatch", "The append completion does not match the selected parent."
  ; "projection-page-unavailable", "This page is unavailable."
  ; "projection-block-page-unavailable", "This block's page is unavailable."
  ; "projection-target-page-unavailable", "The target journal page is unavailable."
  ; "projection-favorite-ancestry-limit", "Favorite ancestry is cyclic or exceeds the read limit."
  ; "projection-capture-block-missing", "The captured block is unavailable."
  ; "projection-favorite-membership-limit", "Favorite memberships exceed the bounded read limit."
  ; "projection-favorite-cursor-limit", "Favorite membership cursor exceeds the bounded read limit."
  ; "projection-favorite-dependency-limit", "Favorite dependencies exceed the bounded read limit."
  ; "projection-favorite-pending-limit", "Favorite pending reads exceed the bounded read limit."
  ; "projection-changed-query-missing", "The changed page query is no longer retained."
  ; "projection-block-id-invalid", "Journal entry ID must be a UUID"
  ; "projection-page-id-invalid", "Journal page ID must be a UUID"
  ; "projection-journal-day-invalid", "Journal day must be a valid YYYYMMDD date"
  ; "projection-parent-id-invalid", "Journal parent ID must be a UUID"
  ; "projection-parent-self-reference", "Journal entry cannot be its own parent"
  ; "projection-sibling-order-invalid", "Journal sibling order is invalid"
  ; "projection-child-count-invalid", "Journal child count must not be negative"
  ; "projection-revision-empty", "Journal revision must not be empty"
  ; "projection-mutation-id-invalid", "Journal mutation ID must be a UUID"
  ; "projection-creation-day-invalid", "creation local day is invalid"
  ; "projection-creation-minute-invalid", "creation local minute must be between 0 and 1439"
  ; "projection-source-limit", "source exceeds 65,536 UTF-8 bytes"
  ; "projection-source-utf8", "source is not valid UTF-8"
  ; "projection-source-nul", "source contains NUL"
  ; "projection-mutation-id", "mutation ID: invalid UUID"
  ; "projection-page-uuid", "page UUID: invalid UUID"
  ; "projection-block-uuid", "block UUID: invalid UUID"
  ; "projection-status-uuid", "status UUID: invalid UUID"
  ; "projection-child-uuid", "child UUID: invalid UUID"
  ; "projection-parent-uuid", "parent UUID: invalid UUID"
  ]
;;

let source_classes =
  producer_sources
  @ [ "unknown", "No safe source detail is available"
    ; "sqlite-locked", "SQLite database is locked"
    ; "sqlite-full", "SQLite storage is full"
    ; "sqlite-readonly", "SQLite database is read-only"
    ; "sqlite-corrupt", "SQLite database is malformed"
    ; "sqlite-open", "SQLite database could not be opened"
    ; "sqlite-io", "SQLite I/O failed"
    ; "sqlite-constraint", "SQLite constraint failed"
    ; "sqlite-schema", "SQLite schema object is unavailable"
    ; "sqlite-error", "SQLite operation failed"
    ; "sqlite-no-memory", "SQLite allocation failed"
    ; "sqlite-interrupted", "SQLite operation was interrupted"
    ; "sqlite-aborted", "SQLite operation was aborted"
    ; "sqlite-too-large", "SQLite value exceeds its size limit"
    ; "sqlite-type-mismatch", "SQLite value type does not match"
    ; "io-no-space", "Storage has no free space"
    ; "io-permission", "Storage permission was denied"
    ; "io-missing", "Storage object was not found"
    ; "exception-failure", "An operation raised Failure"
    ; "exception-invalid-argument", "An operation raised Invalid_argument"
    ; "exception-sys-error", "An operating system operation failed"
    ; "exception-not-found", "An expected object was not found"
    ; "exception-eof", "Input ended unexpectedly"
    ; "exception-timeout", "Operation timed out"
    ; "external-exception", "An external operation raised an exception"
    ]
;;

let sqlite_literals =
  [ "database is locked", "sqlite-locked"
  ; "database table is locked", "sqlite-locked"
  ; "database or disk is full", "sqlite-full"
  ; "attempt to write a readonly database", "sqlite-readonly"
  ; "database disk image is malformed", "sqlite-corrupt"
  ; "file is not a database", "sqlite-corrupt"
  ; "unable to open database file", "sqlite-open"
  ; "disk I/O error", "sqlite-io"
  ; "constraint failed", "sqlite-constraint"
  ; "SQLITE_BUSY", "sqlite-locked"
  ; "SQLITE_LOCKED", "sqlite-locked"
  ; "SQLITE_FULL", "sqlite-full"
  ; "SQLITE_READONLY", "sqlite-readonly"
  ; "SQLITE_CORRUPT", "sqlite-corrupt"
  ; "SQLITE_NOTADB", "sqlite-corrupt"
  ; "SQLITE_CANTOPEN", "sqlite-open"
  ; "SQLITE_IOERR", "sqlite-io"
  ; "SQLITE_CONSTRAINT", "sqlite-constraint"
  ; "BUSY", "sqlite-locked"
  ; "LOCKED", "sqlite-locked"
  ; "FULL", "sqlite-full"
  ; "READONLY", "sqlite-readonly"
  ; "CORRUPT", "sqlite-corrupt"
  ; "NOTADB", "sqlite-corrupt"
  ; "CANTOPEN", "sqlite-open"
  ; "IOERR", "sqlite-io"
  ; "CONSTRAINT", "sqlite-constraint"
  ; "ERROR", "sqlite-error"
  ; "NOMEM", "sqlite-no-memory"
  ; "SQLITE_NOMEM", "sqlite-no-memory"
  ; "INTERRUPT", "sqlite-interrupted"
  ; "SQLITE_INTERRUPT", "sqlite-interrupted"
  ; "ABORT", "sqlite-aborted"
  ; "SQLITE_ABORT", "sqlite-aborted"
  ; "TOOBIG", "sqlite-too-large"
  ; "SQLITE_TOOBIG", "sqlite-too-large"
  ; "MISMATCH", "sqlite-type-mismatch"
  ; "SQLITE_MISMATCH", "sqlite-type-mismatch"
  ]
;;

let source_prefixes =
  [ "local time conversion failed: Failure(", "exception-failure"
  ; "local time conversion failed: Invalid_argument(", "exception-invalid-argument"
  ; "local time conversion failed: Sys_error(", "exception-sys-error"
  ; "local time conversion failed:", "external-exception"
  ; "UNIQUE constraint failed:", "sqlite-constraint"
  ; "NOT NULL constraint failed:", "sqlite-constraint"
  ; "CHECK constraint failed:", "sqlite-constraint"
  ; "no such table:", "sqlite-schema"
  ; "no such column:", "sqlite-schema"
  ; "Unix.Unix_error(Unix.ENOSPC,", "io-no-space"
  ; "Unix.Unix_error(Unix.EACCES,", "io-permission"
  ; "Unix.Unix_error(Unix.EPERM,", "io-permission"
  ; "Unix.Unix_error(Unix.ENOENT,", "io-missing"
  ; "Sqlite3.", "sqlite-error"
  ; "Failure(", "exception-failure"
  ; "Invalid_argument(", "exception-invalid-argument"
  ; "Sys_error(", "exception-sys-error"
  ]
;;

let valid_http_status value = value >= 100 && value <= 599

let http_status_of_source source =
  let prefix = "Asset HTTP status " in
  if String.length source = String.length prefix + 3 && String.starts_with ~prefix source
  then
    let text = String.sub source (String.length prefix) 3 in
    match int_of_string_opt text with
    | Some value when valid_http_status value && string_of_int value = text -> Some value
    | _ -> None
  else None
;;

let classify_source source =
  if String.length source > 4096
  then "unknown"
  else if Option.is_some (http_status_of_source source)
  then "asset-http-status"
  else (
    match List.find_opt (fun (_, literal) -> source = literal) producer_sources with
    | Some (name, _) -> name
    | None ->
      let sqlite =
        List.find_opt
          (fun (literal, _) ->
             source = literal
             || List.exists
                  (fun constructor -> source = constructor ^ "(\"" ^ literal ^ "\")")
                  [ "Sqlite3.SqliteError"; "Sqlite3.Error"; "Failure" ])
          sqlite_literals
      in
      (match sqlite with
       | Some (_, name) -> name
       | None ->
         (match
            List.find_opt
              (fun (prefix, _) -> String.starts_with ~prefix source)
              source_prefixes
          with
          | Some (_, name) -> name
          | None ->
            (match source with
             | "Not_found" -> "exception-not-found"
             | "End_of_file" -> "exception-eof"
             | "Eio.Time.Timeout" -> "exception-timeout"
             | _ when String.contains source '(' -> "external-exception"
             | _ -> "unknown"))))
;;

let fixed values fallback value = if List.mem_assoc value values then value else fallback

let create ~operation ~reason ?source ?cursor ?http_status () =
  { operation_name = fixed operations "workerOperation" operation
  ; reason_name = fixed reasons "unknown" reason
  ; source_name = Option.fold ~none:"unknown" ~some:classify_source source
  ; cursor =
      Option.bind cursor (fun value ->
        if value < 0L then None else Some (Int64.to_string value))
  ; http_status =
      (match http_status with
       | Some status when valid_http_status status -> Some status
       | Some _ -> None
       | None -> Option.bind source http_status_of_source)
  }
;;

let operation value = value.operation_name
let phase value = List.assoc value.operation_name operations
let reason value = value.reason_name
let source_class value = value.source_name
let code value = value.operation_name ^ "." ^ value.reason_name

let message value =
  let summary = value.operation_name ^ ": " ^ List.assoc value.reason_name reasons in
  let cause =
    if value.source_name = "unknown"
    then ""
    else ". Cause: " ^ List.assoc value.source_name source_classes
  in
  let http = Option.fold ~none:"" ~some:(fun status -> Printf.sprintf " (http=%d)" status) value.http_status in
  let text = summary ^ cause ^ http ^ "." in
  if String.length text <= 512 then text else summary ^ "."
;;

let prefix = "journal-failure:v1:"

let encode value =
  let fields =
    [ "operation", `String value.operation_name
    ; "reason", `String value.reason_name
    ; "source", `String value.source_name
    ]
    @ Option.fold ~none:[] ~some:(fun cursor -> [ "cursor", `String cursor ]) value.cursor
    @ Option.fold ~none:[] ~some:(fun status -> [ "httpStatus", `Int status ]) value.http_status
  in
  prefix ^ Yojson.Safe.to_string (`Assoc fields)
;;

let decode source =
  if String.length source > 1024 || not (String.starts_with ~prefix source)
  then None
  else (
    try
      let encoded =
        String.sub
          source
          (String.length prefix)
          (String.length source - String.length prefix)
      in
      match Yojson.Safe.from_string encoded with
      | `Assoc fields ->
        let keys = List.map fst fields in
        let valid_keys = List.sort String.compare keys in
        if
          valid_keys <> [ "operation"; "reason"; "source" ]
          && valid_keys <> [ "cursor"; "operation"; "reason"; "source" ]
          && valid_keys <> [ "httpStatus"; "operation"; "reason"; "source" ]
          && valid_keys <> [ "cursor"; "httpStatus"; "operation"; "reason"; "source" ]
        then None
        else (
          match
            ( List.assoc_opt "operation" fields
            , List.assoc_opt "reason" fields
            , List.assoc_opt "source" fields )
          with
          | ( Some (`String operation_name)
            , Some (`String reason_name)
            , Some (`String source_name) )
            when List.mem_assoc operation_name operations
                 && List.mem_assoc reason_name reasons
                 && List.mem_assoc source_name source_classes ->
            let cursor =
              match List.assoc_opt "cursor" fields with
              | None -> Some None
              | Some (`String text) ->
                (match Int64.of_string_opt text with
                 | Some value when value >= 0L && Int64.to_string value = text ->
                   Some (Some text)
                 | _ -> None)
              | _ -> None
            in
            let http_status =
              match List.assoc_opt "httpStatus" fields with
              | None -> Some None
              | Some (`Int value) when valid_http_status value -> Some (Some value)
              | _ -> None in
            (match cursor, http_status with
             | Some cursor, Some http_status ->
               Some { operation_name; reason_name; source_name; cursor; http_status }
             | _ -> None)
          | _ -> None)
      | _ -> None
    with
    | Yojson.Json_error _ -> None)
;;

let detail_name = "failureDiagnostic"
let signal_prefix = "worker.failure:"

let of_source ~operation ~reason source =
  match decode source with
  | Some value ->
    { value with operation_name = fixed operations "workerOperation" operation }
  | None -> create ~operation ~reason ~source ()
;;
