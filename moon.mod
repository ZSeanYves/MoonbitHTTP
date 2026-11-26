name = "ZSeanYves/http"

version = "0.9.1"

// Protocol parsers, state machines and transport capabilities return failures
// as values so callers can inspect them before choosing a recovery action.

warnings = "-result_error_return"

import {
  "moonbitlang/x@0.5.9",
  "moonbit-community/normalization@0.5.2",
  "moonbit-community/idna@0.5.2",
  "moonbit-community/punycode@0.8.1",
  "mizchi/experimental_crypto@0.0.2",
  "cc06b/mooncry@0.95.0",
  "moonbit-community/flate@0.10.0",
  "hustcer/fbr@0.8.2",
}

readme = "README.md"

repository = "https://github.com/ZSeanYves/http"

license = "Apache-2.0"

keywords = [ "http", "http1", "http2", "http3", "quic", "tls", "networking" ]

description = "Streaming HTTP protocol suite for MoonBit with HTTP/1.0, HTTP/1.1, HTTP/2, HTTP/3, QUIC, TLS integration, and policy-driven transports."
