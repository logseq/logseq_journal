type t =
  { operation : Graph_types.Uuid.t
  ; asset : Graph_types.Uuid.t
  ; replace_reference : Graph_types.Uuid.t option
  ; target : Graph_types.Uuid.t
  ; local_mutation : Graph_types.Uuid.t
  ; metadata_mutation : Graph_types.Uuid.t
  ; source_file : string
  ; title : string
  ; file_type : string
  }
