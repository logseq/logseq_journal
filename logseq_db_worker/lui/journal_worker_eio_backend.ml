(*
 * Copyright (C) 2023 Thomas Leonard
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

type environment =
  < stdin : Eio_unix.source_ty Eio.Resource.t
  ; stdout : Eio_unix.sink_ty Eio.Resource.t
  ; stderr : Eio_unix.sink_ty Eio.Resource.t
  ; net : [ `Unix | `Generic ] Eio.Net.ty Eio.Resource.t
  ; domain_mgr : Eio.Domain_manager.ty Eio.Resource.t
  ; clock : float Eio.Time.clock_ty Eio.Resource.t
  ; mono_clock : Eio.Time.Mono.ty Eio.Resource.t
  ; fs : Eio.Fs.dir_ty Eio.Path.t
  ; cwd : Eio.Fs.dir_ty Eio.Path.t
  ; secure_random : Eio.Flow.source_ty Eio.Resource.t
  ; debug : Eio.Debug.t
  ; backend_id : string >

(* Eio 1.2's command-line entrypoint installs a process-wide SIGCHLD handler.
   Embedded hosts own their signals and do not give their UI threads OCaml TLS.
   Assemble the pinned backend directly, without a process manager or handler. *)
module Posix = Eio_posix__

let run main =
  (* This thread belongs to the Worker for its entire lifetime. Its Eio helper
     threads inherit the mask. Keep broken-pipe errors local without replacing
     the host application's process-wide SIGPIPE disposition. *)
  ignore (Unix.sigprocmask Unix.SIG_BLOCK [ Sys.sigpipe ] : int list);
  let stdin = (Posix.Flow.of_fd Eio_unix.Fd.stdin :> Eio_unix.source_ty Eio.Resource.t) in
  let stdout = (Posix.Flow.of_fd Eio_unix.Fd.stdout :> Eio_unix.sink_ty Eio.Resource.t) in
  let stderr = (Posix.Flow.of_fd Eio_unix.Fd.stderr :> Eio_unix.sink_ty Eio.Resource.t) in
  Posix.Domain_mgr.run_event_loop
    main
    object (_ : environment)
      method stdin = stdin
      method stdout = stdout
      method stderr = stderr
      method debug = Eio.Private.Debug.v
      method clock = Posix.Time.clock
      method mono_clock = Posix.Time.mono_clock
      method net = Posix.Net.v
      method domain_mgr = Posix.Domain_mgr.v
      method cwd = ((Posix.Fs.cwd, "") :> Eio.Fs.dir_ty Eio.Path.t)
      method fs = ((Posix.Fs.fs, "") :> Eio.Fs.dir_ty Eio.Path.t)
      method secure_random = Posix.Flow.secure_random
      method backend_id = "posix"
    end
;;

let stdenv environment = environment
let mono_clock environment = environment#mono_clock
let net environment = (environment#net :> [ `Generic ] Eio.Net.ty Eio.Resource.t)
let fs environment = environment#fs
