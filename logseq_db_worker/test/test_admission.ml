module T = Logseq_db_worker_test_support.Test_support
module Admission = Logseq_db_worker__Admission

let uuid =
  match
    Logseq_db_worker.Graph_types.Uuid.of_string "11111111-1111-4111-8111-111111111111"
  with
  | Ok uuid -> uuid
  | Error message -> failwith message
;;

let observed
      ?(major = 65)
      ?(minor = 33)
      ?(remote_flag = Admission.Absent)
      ?rtc_graph_uuid
      ?client_ops_graph_uuid
      ?(codec_lossless = true)
      ?(required_schema_present = true)
      ()
  =
  Admission.
    { schema = Logseq_db_worker.Graph_types.{ major; minor }
    ; local_graph_uuid = Some uuid
    ; remote_flag
    ; rtc_graph_uuid
    ; client_ops_graph_uuid
    ; codec_lossless
    ; required_schema_present
    }
;;

let expect_ok observed () =
  match Admission.admit ~target:Local_target observed with
  | Ok _ -> ()
  | Error _ -> T.fail "expected graph admission"
;;

let expect_error expected observed () =
  match Admission.admit ~target:Local_target observed with
  | Error actual when actual = expected -> ()
  | _ -> T.fail "unexpected admission result"
;;

let () =
  T.run
    "admission"
    [ T.case "schema 65.33 is admitted" (expect_ok (observed ()))
    ; T.case
        "newer minor schema is admitted when lossless"
        (expect_ok (observed ~minor:34 ()))
    ; T.case
        "newer major schema is admitted when lossless"
        (expect_ok (observed ~major:66 ~minor:0 ()))
    ; T.case
        "schema 65.32 is rejected"
        (expect_error Admission.Unsupported_schema (observed ~minor:32 ()))
    ; T.case
        "graph-remote true is rejected"
        (expect_error Admission.Remote_graph (observed ~remote_flag:(Boolean true) ()))
    ; T.case
        "non-boolean remote flag is ambiguous"
        (expect_error
           Admission.Ambiguous_sync_state
           (observed ~remote_flag:(Malformed "yes") ()))
    ; T.case
        "remote flag false with local history is admitted"
        (expect_ok (observed ~remote_flag:(Boolean false) ()))
    ; T.case
        "RTC graph UUID without remote flag is ambiguous"
        (expect_error Admission.Ambiguous_sync_state (observed ~rtc_graph_uuid:uuid ()))
    ; T.case
        "client-ops graph UUID is ambiguous"
        (expect_error
           Admission.Ambiguous_sync_state
           (observed ~client_ops_graph_uuid:uuid ()))
    ; T.case
        "unsupported reachable value is rejected"
        (expect_error Admission.Unsupported_value (observed ~codec_lossless:false ()))
    ; T.case
        "missing required schema is rejected"
        (expect_error
           Admission.Corrupt_storage
           (observed ~required_schema_present:false ()))
    ]
;;
