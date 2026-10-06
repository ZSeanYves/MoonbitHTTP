# Connection ID support

The datagram driver accepts and bounds peer-issued connection IDs. Its peer
namespace starts with the source CID authenticated by TLS, including servers
whose Initial source CID differs from the client's original destination.
`NEW_CONNECTION_ID` can replace the sending destination when `retire_prior_to`
retires the selected CID. The driver emits and retransmits the corresponding
`RETIRE_CONNECTION_ID` frames; reordered announcements below the retirement
floor are retired again without restoring their state.

The driver currently issues only its initial local CID, sequence zero. It does
not mint replacement local CIDs or route packets to additional local CIDs.
Sending `NEW_CONNECTION_ID` through the driver returns `Unsupported`. Incoming
retirement of an unissued local sequence, or of the CID used as the packet's
destination, is rejected before any CID state is changed. The standalone packet
codec remains available for integrations that implement their own CID routing.

The standalone peer CID manager preserves a bounded set of individually retired
entries to detect reuse. Its history budget equals `max_active`; a new
announcement that would exceed that budget fails without changing state. Moving
the peer's retirement floor frees entries below the floor. It never grants local
issuance rights or accepts incoming local-CID retirement on behalf of a driver.
