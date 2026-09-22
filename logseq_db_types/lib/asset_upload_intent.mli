(** Durable checkpoints for explicit imports. Staging identifiers never refer to
    temporary picker URLs. Runtime generations are deliberately not persisted. *)
type phase =
  | Prepared
  | Local_committed
  | Uploading
  | Remote_stored
  | Metadata_pending
  | Complete
  | Cancelled

type t = private
  { operation_id : Graph_types.Uuid.t
  ; origin : string
  ; account : string
  ; graph : Graph_types.Uuid.t
  ; asset : Graph_types.Uuid.t
  ; version : Asset_descriptor.version
  ; title : string
  ; size : int64
  ; staged_file : string
  ; replace_reference : Graph_types.Uuid.t option
  ; target : Graph_types.Uuid.t
  ; local_mutation : Graph_types.Uuid.t
  ; metadata_mutation : Graph_types.Uuid.t
  ; phase : phase
  ; revision : int
  }

val prepare
  :  operation_id:Graph_types.Uuid.t
  -> origin:string
  -> account:string
  -> graph:Graph_types.Uuid.t
  -> asset:Graph_types.Uuid.t
  -> version:Asset_descriptor.version
  -> title:string
  -> size:int64
  -> staged_file:string
  -> replace_reference:Graph_types.Uuid.t option
  -> target:Graph_types.Uuid.t
  -> local_mutation:Graph_types.Uuid.t
  -> metadata_mutation:Graph_types.Uuid.t
  -> (t, string) result

val advance : t -> phase -> (t, string) result
val restore : t -> phase:phase -> revision:int -> (t, string) result
