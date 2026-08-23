type t

val connect
  :  sw:Eio.Switch.t
  -> environment:Eio_unix.Stdenv.base
  -> uri:Uri.t
  -> token:string
  -> maximum_frame_bytes:int
  -> on_message:(string -> unit)
  -> on_close:(string option -> unit)
  -> (t, string) result

val send : t -> string -> (unit, string) result
val close : t -> unit
