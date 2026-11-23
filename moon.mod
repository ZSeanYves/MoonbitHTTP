name = "ZSeanYves/MoonbitHTTP"

version = "0.7.0"

// Protocol parsers, state machines and transport capabilities return failures
// as values so callers can inspect them before choosing a recovery action.

warnings = "-result_error_return"

import {
  "moonbitlang/x@0.5.5",
  "mizchi/crater-browser-http@0.19.0",
  "moonbit-community/normalization@0.5.2",
  "moonbit-community/idna@0.5.2",
  "mizchi/experimental_crypto@0.0.2",
  "cc06b/mooncry@0.95.0",
  "moonbit-community/flate@0.8.4",
  "hustcer/fbr@0.8.2",
}

readme = "README.md"

repository = "https://github.com/ZSeanYves/MoonbitHTTP"

license = "Apache-2.0"

keywords = [ "http", "http1", "http2", "http3", "quic", "tls", "networking" ]

description = "Streaming HTTP protocol suite for MoonBit with HTTP/1.1, HTTP/2, HTTP/3, QUIC, TLS integration, and policy-driven transports."
