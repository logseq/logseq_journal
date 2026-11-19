type t

type connect_error =
  | Unauthorized
  | Forbidden
  | Connection_failed of
      { message : string
      ; attention : Transport_domain.error_attention
      }
  | Protocol_failed of string
  | Authentication_failed of string

type liveness =
  | Disabled
  | Ping_pong of
      { interval_seconds : float
      ; timeout_seconds : float
      }

val connect
  :  setup_seconds:float
  -> tls_handshake_seconds:float
  -> http_response_seconds:float
  -> sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:Transport_time.t
  -> liveness:liveness
  -> uri:Uri.t
  -> token:string
  -> maximum_frame_bytes:int
  -> on_message:(string -> unit)
  -> on_close:(Transport_domain.websocket_termination -> unit)
  -> (t, connect_error) result

(** Register and publish open inside [on_open] before enabling message delivery.
    A terminated pending connection fails activation without invoking [on_open]. *)
val activate : t -> on_open:(unit -> unit) -> (unit, connect_error) result

val failure_attention : t -> Transport_domain.error_attention

(** Success means local queue admission, not delivery. *)
val send : t -> string -> (unit, string) result

(** Initiate a bounded close exchange without waiting for the owner. *)
val close : t -> unit

(** Interrupt setup, active use, or graceful close without waiting. *)
val abort : t -> unit

(** Wait until socket ownership, I/O and all callbacks have retired. Never call
    this from one of the connection's callbacks. *)
val await_retired : t -> unit
