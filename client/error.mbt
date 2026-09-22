///|
pub(all) enum ClientPhase {
  ClientResolve
  ClientConnect
  ClientTlsHandshake
  ClientRequestHeaders
  ClientRequestBody
  ClientResponseHeaders
  ClientResponseBody
  ClientIdle
  ClientTotal
} derive(Eq, Debug)

///|
pub(all) suberror RedirectError {
  RedirectDisabled
  RedirectLimitExceeded(Int)
  RedirectLoop
  RedirectDowngradeDenied
  RedirectBodyNotReplayable
  InvalidRedirectLocation
  StatusIsNotRedirect(Int)
} derive(Eq, Debug)

///|
pub(all) suberror RetryError {
  InvalidRetryPolicy
  RetryLimitExceeded
  RetryBodyNotReplayable
} derive(Eq, Debug)

///|
pub(all) suberror ClientError {
  ClientInvalidUri(@types.UriError)
  ClientInvalidEndpoint(@transport.EndpointError)
  ClientInvalidOptions(String)
  ClientRedirect(RedirectError)
  ClientRetry(RetryError)
  ClientPolicy(@transport.PolicyError)
  ClientTransport(@transport.TransportError)
  ClientTls(@tls.TlsError)
  ClientAuth(@auth.AuthError)
  ClientContentCoding(@content_coding.ContentCodingError)
  ClientBodyLimit(Int)
  ClientBody(@body.BodyError)
  ClientTimeout(ClientPhase, Int64, Int64)
  ClientCancelled(String)
  ClientProtocol(String)
} derive(Eq, Debug)
