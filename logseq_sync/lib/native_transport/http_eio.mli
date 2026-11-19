type progress =
  { received_bytes : int
  ; total_bytes : int option
  ; datom_count : int option
  }

type response =
  { status : int
  ; headers : (string * string) list
  ; body : string
  }

type error =
  | Network of string
  | Protocol of string
  | Authentication of string
  | Storage of string
  | Crypto of string
  | Invalid_input of string

(** DNS/TCP, TLS and HTTP have separate budgets. Redirects share HTTP budgets. *)
val perform_with_deadlines
  :  setup_seconds:float
  -> tls_handshake_seconds:float
  -> http_response_seconds:float
  -> sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:Transport_time.t
  -> Http.request
  -> (response, error) result

val download_with_deadlines
  :  setup_seconds:float
  -> tls_handshake_seconds:float
  -> download_seconds:float
  -> http_response_seconds:float
  -> sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:Transport_time.t
  -> request:Http.request
  -> destination:string
  -> maximum_bytes:int
  -> on_progress:(progress -> unit)
  -> (response, error) result

val perform
  :  sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:Transport_time.t
  -> Http.request
  -> (response, error) result

val download
  :  sw:Eio.Switch.t
  -> authenticator:X509.Authenticator.t
  -> network:_ Eio.Net.t
  -> clock:Transport_time.t
  -> request:Http.request
  -> destination:string
  -> maximum_bytes:int
  -> on_progress:(progress -> unit)
  -> (response, error) result
