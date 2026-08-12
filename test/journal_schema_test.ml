let fail format = Printf.ksprintf failwith format

let require condition format =
  Printf.ksprintf (fun message -> if not condition then failwith message) format
;;

let attribute_names schema = List.map fst schema |> List.sort String.compare

let expected_attributes =
  [ "journal.block/created-instant-unix-ms"
  ; "journal.block/created-local-day"
  ; "journal.block/created-local-minute"
  ; "journal.block/created-time-zone-id"
  ; "journal.block/created-utc-offset-seconds"
  ; "journal.block/id"
  ; "journal.block/last-mutation-id"
  ; "journal.block/order"
  ; "journal.block/page"
  ; "journal.block/parent"
  ; "journal.block/parent-order"
  ; "journal.block/parent-order-block"
  ; "journal.block/revision"
  ; "journal.block/source"
  ; "journal.block/task-state"
  ; "journal.page/day"
  ; "journal.page/id"
  ; "journal.page/title"
  ; "journal.store/id"
  ; "journal.store/schema-version"
  ]
  |> List.sort String.compare
;;

let test_schema_is_the_exact_clean_timeline_schema () =
  require (Journal_schema.version = 1) "schema version must start at 1";
  require
    (String.equal Journal_schema.store_identity "logseq-journal-timeline")
    "store identity did not select the clean timeline store";
  require
    (attribute_names Journal_schema.data_script = expected_attributes)
    "schema contains missing, obsolete, or dormant attributes"
;;

let test_schema_validation_rejects_missing_and_additional_attributes () =
  (match Journal_schema.validate_schema Journal_schema.data_script with
   | Ok () -> ()
   | Error error ->
     fail "canonical schema rejected: %s" (Journal_schema.Error.to_string error));
  let missing = List.tl Journal_schema.data_script in
  let extra_attribute =
    ( "journal.search/index"
    , { Datascript.cardinality = One
      ; unique = None
      ; indexed = false
      ; is_component = false
      ; no_history = false
      ; doc = None
      ; value_type = Some StringType
      ; tuple_attrs = None
      ; tuple_types = None
      } )
  in
  List.iter
    (fun schema ->
       match Journal_schema.validate_schema schema with
       | Error _ -> ()
       | Ok () -> fail "non-canonical schema was accepted")
    [ missing; extra_attribute :: Journal_schema.data_script ]
;;

let test_canonical_database_path_is_new_and_exact () =
  require
    (String.equal Journal_startup.database_relative_path "logseq_journal/store.sqlite3")
    "canonical database relative path is not logseq_journal/store.sqlite3"
;;

let () =
  test_schema_is_the_exact_clean_timeline_schema ();
  test_schema_validation_rejects_missing_and_additional_attributes ();
  test_canonical_database_path_is_new_and_exact ()
;;
