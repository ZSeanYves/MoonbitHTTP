# Connection ID support

The datagram driver accepts and bounds peer-issued connection IDs. Its peer
namespace starts with the source CID authenticated by TLS, including servers
whose Initial source CID differs from the client's original destination.
`NEW_CONNECTION_ID` can replace the sending destination when `retire_prior_to`
retires the selected CID. The driver emits and retransmits the corresponding
`RETIRE_CONNECTION_ID` frames; reordered announcements below the retirement
floor are retired again without restoring their state.

Native HTTP/3 clients and listeners advertise one spare local CID after the
handshake. The initial CID is sequence zero. Replacements keep its length
and use fresh entropy for the CID and 16-byte stateless reset token. The
listener reserves each new UDP route before sending its advertisement.
An old route stays live until its peer sends `RETIRE_CONNECTION_ID` for it.
Closing a peer removes its original Initial mapping and every remaining route.
[RFC 9000 sections 5.1.1 and 5.1.2](https://www.rfc-editor.org/rfc/rfc9000.html#section-5.1.1)

Portable integrations opt in with `enable_connection_id_issuance`. A shared
socket supplies synchronous route reservation and release callbacks. A failed
send releases the reservation. For backpressure the driver keeps one unsent
candidate and retries on transport progress. `rotate_local_connection_id(now_ms)`
returns datagrams to transmit. The HTTP/3 connection scope exposes the same
operation as `Http3ConnectionIo::rotate_local_connection_id()` and handles I/O.
The operation can run during a request. Loss recovery retransmits the
advertisement, and the peer's retirement triggers replenishment.

The default lifetime budget is 256 IDs including sequence zero. It bounds
the history used to prevent reuse of IDs and reset tokens. After the last
spare retires, the remaining route continues to serve the connection.
A further explicit rotation returns a limit error. Zero-length initial IDs
keep their original routing. Raw frame encoding remains available to
integrations with a separate issuer.

The driver recognizes a peer's stateless reset using its authenticated transport
parameter or the token for a selected replacement CID. Only a CID used for
sending to the source address qualifies. Rotation discards the retired token.
The driver remembers up to eight recent destinations and retains the active
path when evicting old probe addresses. A matching reset enters draining
without replying. The shared listener can match an unfamiliar destination CID
against connections from the same UDP endpoint, release the routes and wake
the receiver even when its inbox is full. [RFC 9000 section 10.3.1](https://www.rfc-editor.org/rfc/rfc9000.html#section-10.3.1)

The standalone peer CID manager preserves a bounded set of individually retired
entries to detect reuse. Its history budget equals `max_active`; a new
announcement that would exceed that budget fails without changing state. Moving
the peer's retirement floor frees entries below the floor. It never grants local
issuance rights or accepts incoming local-CID retirement on behalf of a driver.
