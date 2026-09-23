(** Eio backend selected for the native Worker Domain. *)

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

(** Run on the dedicated Worker Domain thread. The thread keeps SIGPIPE blocked
    for its lifetime; the host's signal dispositions are not replaced. *)
val run : (environment -> 'a) -> 'a

val stdenv : environment -> environment
val mono_clock : environment -> Eio.Time.Mono.ty Eio.Resource.t
val net : environment -> [ `Generic ] Eio.Net.ty Eio.Resource.t
val fs : environment -> Eio.Fs.dir_ty Eio.Path.t
