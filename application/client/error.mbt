///|
#derive(Eq, Debug)
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
}

///|
#derive(Eq, Debug)
pub(all) suberror RedirectError {
  RedirectDisabled
  RedirectLimitExceeded(Int32)
  RedirectLoop
  RedirectDowngradeDenied
  RedirectBodyNotReplayable
  InvalidRedirectLocation
  StatusIsNotRedirect(Int32)
}

///|
#derive(Eq, Debug)
pub(all) suberror RetryError {
  InvalidRetryPolicy
  RetryLimitExceeded
  RetryBodyNotReplayable
}

///|
#derive(Eq, Debug)
pub(all) suberror ClientError {
  ClientInvalidUri(@types.UriError)
  ClientInvalidEndpoint(@types.EndpointError)
  ClientInvalidOptions(String)
  ClientRedirect(RedirectError)
  ClientRetry(RetryError)
  ClientPolicy(@transport.PolicyError)
  ClientTransport(@transport.TransportError)
  ClientTls(@transport.TlsError)
  ClientAuth(@auth.AuthError)
  ClientContentCoding(@content_coding.ContentCodingError)
  ClientBodyLimit(Int32)
  ClientBody(@body.BodyError)
  ClientTimeout(ClientPhase, Int64, Int64)
  ClientCancelled(String)
  ClientConnection(@service.ClientConnectionError)
  ClientHttp1(@http1.Http1Error)
  ClientHttp2(@http2.H2ProtocolError)
  ClientProtocol(String)
}
