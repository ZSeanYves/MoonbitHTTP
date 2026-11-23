///|
/// Discarding an encryption level also removes its recovery and retained
/// CRYPTO state. Retired keys can never drive a PTO retransmission.
fn QuicDatagramDriver::discard_packet_space(
  self : QuicDatagramDriver,
  space : PacketNumberSpace,
) -> Unit {
  match space {
    Initial => {
      if self.initial_send_keys is None && self.initial_receive_keys is None {
        return
      }
      self.initial_send_keys = None
      self.initial_receive_keys = None
    }
    Handshake => {
      if self.handshake_send_keys is None && self.handshake_receive_keys is None {
        return
      }
      self.handshake_send_keys = None
      self.handshake_receive_keys = None
    }
    Application => return
  }
  self.received(space).pending = None
  self.recovery.timer(space).loss_at_ms = None
  let mut index = self.retransmissions.length() - 1
  while index >= 0 {
    if self.retransmissions[index].space == space {
      self.retransmissions.remove(index) |> ignore
    }
    index -= 1
  }
  index = self.recovery.sent.length() - 1
  while index >= 0 {
    let packet = self.recovery.sent[index]
    if packet.space == space {
      ignore(self.recovery.remove_sent(index))
    }
    index -= 1
  }
  self.recovery.pto_count = 0
  self.recovery.last_probe_ms = None
}
