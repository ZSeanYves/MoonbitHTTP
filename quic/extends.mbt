///|
pub extend QuicError with Eq::{equal, not_equal}

///|
pub extend QuicError with @debug.Debug::{to_repr}

///|
pub extend QuicLimits with Eq::{equal, not_equal}

///|
pub extend QuicLimits with @debug.Debug::{to_repr}

///|
pub extend QuicVarInt with Eq::{equal, not_equal}

///|
pub extend QuicVarInt with @debug.Debug::{to_repr}

///|
pub extend QuicVarInt with Compare::{compare, op_lt, op_le, op_ge, op_gt}

///|
pub extend ConnectionId with Eq::{equal, not_equal}

///|
pub extend ConnectionId with @debug.Debug::{to_repr}

///|
pub extend PacketNumberSpace with Eq::{equal, not_equal}

///|
pub extend PacketNumberSpace with @debug.Debug::{to_repr}

///|
pub extend QuicRole with Eq::{equal, not_equal}

///|
pub extend QuicRole with @debug.Debug::{to_repr}

///|
pub extend InitialPacket with Eq::{equal, not_equal}

///|
pub extend InitialPacket with @debug.Debug::{to_repr}

///|
pub extend ZeroRttPacket with Eq::{equal, not_equal}

///|
pub extend ZeroRttPacket with @debug.Debug::{to_repr}

///|
pub extend HandshakePacket with Eq::{equal, not_equal}

///|
pub extend HandshakePacket with @debug.Debug::{to_repr}

///|
pub extend RetryPacket with Eq::{equal, not_equal}

///|
pub extend RetryPacket with @debug.Debug::{to_repr}

///|
pub extend ShortPacket with Eq::{equal, not_equal}

///|
pub extend ShortPacket with @debug.Debug::{to_repr}

///|
pub extend QuicPacketHeader with Eq::{equal, not_equal}

///|
pub extend QuicPacketHeader with @debug.Debug::{to_repr}

///|
pub extend AckRange with Eq::{equal, not_equal}

///|
pub extend AckRange with @debug.Debug::{to_repr}

///|
pub extend AckFrame with Eq::{equal, not_equal}

///|
pub extend AckFrame with @debug.Debug::{to_repr}

///|
pub extend StreamFrame with Eq::{equal, not_equal}

///|
pub extend StreamFrame with @debug.Debug::{to_repr}

///|
pub extend QuicFrame with Eq::{equal, not_equal}

///|
pub extend QuicFrame with @debug.Debug::{to_repr}

///|
pub extend QuicTransportParams with Eq::{equal, not_equal}

///|
pub extend QuicTransportParams with @debug.Debug::{to_repr}

///|
pub extend QuicConnectionState with Eq::{equal, not_equal}

///|
pub extend QuicConnectionState with @debug.Debug::{to_repr}

///|
pub extend QuicStreamState with Eq::{equal, not_equal}

///|
pub extend QuicStreamState with @debug.Debug::{to_repr}

///|
pub extend QuicAction with Eq::{equal, not_equal}

///|
pub extend QuicAction with @debug.Debug::{to_repr}

///|
pub extend QuicEndpoint with Eq::{equal, not_equal}

///|
pub extend QuicEndpoint with @debug.Debug::{to_repr}

///|
pub extend QuicInitialPacketOptions with Eq::{equal, not_equal}

///|
pub extend QuicInitialPacketOptions with @debug.Debug::{to_repr}

///|
pub extend QuicRecoveryConfig with Eq::{equal, not_equal}

///|
pub extend QuicRecoveryConfig with @debug.Debug::{to_repr}

///|
pub extend QuicSentPacket with Eq::{equal, not_equal}

///|
pub extend QuicSentPacket with @debug.Debug::{to_repr}

///|
pub extend QuicRecoveryEvent with Eq::{equal, not_equal}

///|
pub extend QuicRecoveryEvent with @debug.Debug::{to_repr}

///|
pub extend QuicRecovery with @debug.Debug::{to_repr}

///|
pub extend QuicPathStatus with Eq::{equal, not_equal}

///|
pub extend QuicPathStatus with @debug.Debug::{to_repr}

///|
pub extend QuicPathManager with @debug.Debug::{to_repr}

///|
pub extend QuicConnectionId with Eq::{equal, not_equal}

///|
pub extend QuicConnectionId with @debug.Debug::{to_repr}

///|
pub extend QuicConnectionIdManager with @debug.Debug::{to_repr}

///|
pub extend QuicDriverAction with Eq::{equal, not_equal}

///|
pub extend QuicDriverAction with @debug.Debug::{to_repr}

///|
pub extend QuicDriverState with Eq::{equal, not_equal}

///|
pub extend QuicDriverState with @debug.Debug::{to_repr}

///|
pub extend QuicCryptoReassembler with Eq::{equal, not_equal}

///|
pub extend QuicCryptoReassembler with @debug.Debug::{to_repr}
