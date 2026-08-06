let () =
  Native_backend.embed
    ~name:(Bonsai_flutter_spec.Id.Application.Entrypoint_name.of_string "logseq_journal")
    Application.app
;;
