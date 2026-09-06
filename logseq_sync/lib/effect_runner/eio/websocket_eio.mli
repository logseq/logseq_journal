type t

type connect_error =
  | Unauthorized
  | Forbidden
  | Connection_failed of string

type liveness =
  | Disabled
  | Ping_pong of
      { interval_seconds : float
      ; timeout_seconds : float
      }

val connect
  :  sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:_ Eio.Time.clock
  -> liveness:liveness
  -> uri:Uri.t
  -> token:string
  -> maximum_frame_bytes:int
  -> on_message:(string -> unit)
  -> on_close:(string option -> unit)
  -> (t, connect_error) result

(** Register and publish open inside [on_open] before enabling message delivery.
    A terminated pending connection fails activation without invoking [on_open]. *)
val activate : t -> on_open:(unit -> unit) -> (unit, connect_error) result

(** Success means local queue admission. Driver failures use the terminal callback. *)
val send : t -> string -> (unit, string) result

(** Initiate a bounded close exchange without waiting for the owner. *)
val close : t -> unit

(** Interrupt setup, active use, or graceful close without waiting. *)
val abort : t -> unit
