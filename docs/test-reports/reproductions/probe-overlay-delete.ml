#use "@@BOOTSTRAP@@";;
#mod_use "@@OVERLAY_HELPERS@@";;
let () = Test_support.with_database ~behavior:"M02 actual overlay defer/accept control" Overlay_sync_helpers.submitted_delete_defers_authoritative_batch_until_transport_outcome; print_endline "M02 actual overlay: submitted own delete defers; Accept_group followed by replay commits successfully.";;
