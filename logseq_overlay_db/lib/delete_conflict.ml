let code = function
  | Types.Frontier_fact_changed -> "frontierFactChanged"
  | Descendant_closure_changed -> "descendantClosureChanged"
  | Incoming_reference_changed -> "incomingReferenceChanged"
  | Auxiliary_write_footprint_changed Comment_area -> "auxiliary:commentArea"
  | Auxiliary_write_footprint_changed Default_property_holder ->
    "auxiliary:defaultPropertyHolder"
  | Auxiliary_write_footprint_changed Rewritten_source_title ->
    "auxiliary:rewrittenSourceTitle"
  | Auxiliary_write_footprint_changed Timestamp -> "auxiliary:timestamp"
  | Auxiliary_write_footprint_changed Transaction_metadata ->
    "auxiliary:transactionMetadata"
  | Page_lifecycle_changed -> "pageLifecycleChanged"
;;

let of_code = function
  | "frontierFactChanged" -> Ok Types.Frontier_fact_changed
  | "descendantClosureChanged" -> Ok Types.Descendant_closure_changed
  | "incomingReferenceChanged" -> Ok Types.Incoming_reference_changed
  | "auxiliary:commentArea" -> Ok (Types.Auxiliary_write_footprint_changed Comment_area)
  | "auxiliary:defaultPropertyHolder" ->
    Ok (Types.Auxiliary_write_footprint_changed Default_property_holder)
  | "auxiliary:rewrittenSourceTitle" ->
    Ok (Types.Auxiliary_write_footprint_changed Rewritten_source_title)
  | "auxiliary:timestamp" -> Ok (Types.Auxiliary_write_footprint_changed Timestamp)
  | "auxiliary:transactionMetadata" ->
    Ok (Types.Auxiliary_write_footprint_changed Transaction_metadata)
  | "pageLifecycleChanged" -> Ok Types.Page_lifecycle_changed
  | _ -> Error "invalid delete conflict kind"
;;
