let () =
  let code = Cmdliner.Cmd.eval' ~term_err:2 Cli_command.command in
  exit (if List.mem code [ 0; 2; 3; 4; 5 ] then code else 5)
;;
