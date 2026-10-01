///|
/// Returns whether a frame is legal in a packet-number space.  Keeping this
/// table beside the frame definition prevents the datagram driver from
/// accidentally accepting a STREAM (or other application-only frame) in an
/// Initial or Handshake packet.
fn quic_frame_allowed_in_space(
  space : PacketNumberSpace,
  frame : QuicFrame,
) -> Bool {
  match space {
    Initial | Handshake =>
      match frame {
        Padding | Ping | Ack(_) | Crypto(_, _) => true
        ConnectionClose(transport_error, _, _, _) => transport_error
        _ => false
      }
    Application => true
  }
}

///|
/// Validates every frame before packet accounting or connection state is
/// mutated.  The same gate is used for outgoing and authenticated incoming
/// packets so both sides observe the same packet-space contract.
fn quic_validate_frames_for_space(
  space : PacketNumberSpace,
  frames : Array[QuicFrame],
) -> Result[Unit, QuicError] {
  for frame in frames {
    if !quic_frame_allowed_in_space(space, frame) {
      return Err(InvalidFrame("frame is not valid in this packet number space"))
    }
  }
  Ok(())
}
