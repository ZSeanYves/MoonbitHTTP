# HTTP/3 package

This package has one public namespace. Its files separate byte codecs, protocol
state, and the QUIC stream adapter; moving a declaration between these files
does not create another API layer.

| Responsibility | Implementation |
| --- | --- |
| Incremental HTTP/3 frame encoding and decoding | `frame.mbt` |
| HTTP field semantics, pseudo-fields, CONNECT, and message metadata | `fields.mbt` |
| SETTINGS and critical unidirectional stream rules | `control.mbt` |
| Connection ownership, request stream dispatch, and QPACK integration | `connection.mbt` |
| Per-message phase, body length, completion, and cancellation | `request_stream.mbt` |
| Fragmented QUIC stream input and outgoing stream actions | `driver.mbt` |
| QPACK public fields and limits | `qpack_fields.mbt`, `qpack_limits.mbt` |
| QPACK integers, strings, and decoder feedback instructions | `qpack_primitives.mbt` |
| QPACK static table and static encoding | `qpack_static.mbt` |
| QPACK dynamic table and field section decoding | `qpack_decoder.mbt` |
| QPACK peer encoder instruction stream | `qpack_decoder_instructions.mbt` |
| QPACK dynamic encoding and reference lifetime | `qpack_encoder.mbt` |
| QPACK peer decoder instruction stream | `qpack_encoder_instructions.mbt` |

`Http3Driver` assembles QUIC stream fragments into frames and calls
`Http3Connection`. The connection owns request states and both QPACK contexts.
The request state alone changes the message phase and tracks received body
length. `validate_http3_field_section` is the shared field semantics boundary.
The package returns actions and bytes; it does not open or write sockets.

Extended CONNECT follows the direction defined by
[RFC 9220 section 3](https://www.rfc-editor.org/rfc/rfc9220.html#section-3):
the receiving server advertises support. Incoming requests use the local
advertised setting; outgoing requests use the peer server setting. A setting
sent by a client cannot enable the extension. Classic CONNECT uses authority
form with an explicit port; extended CONNECT uses an origin-form path.

The public API retains protocol messages, settings, limits, codecs, connection,
and driver types. Request-state representation and dynamic-table bookkeeping
types are private. Tests remain grouped by frame codec, QPACK, connection
behavior, and driver integration, so file moves do not discard regression cases.
