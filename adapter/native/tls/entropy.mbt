///|
/// Cryptographic entropy from OpenSSL's operating-system-seeded generator.
pub struct NativeEntropy(Unit)

///|
pub fn NativeEntropy::new() -> NativeEntropy {
  NativeEntropy(())
}

///|
pub impl @transport.Entropy for NativeEntropy with fn fill(_self, buffer) {
  if @packet_crypto.random_fill(buffer) {
    Ok(())
  } else {
    Err(Failed("OpenSSL RAND_bytes failed"))
  }
}

///|
pub extend NativeEntropy with @transport.Entropy::{fill}
