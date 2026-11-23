///|
/// Cryptographic entropy from OpenSSL's operating-system-seeded generator.
pub struct NativeEntropy(Unit)

///|
pub fn NativeEntropy::new() -> NativeEntropy {
  NativeEntropy(())
}

///|
#borrow(buffer)
extern "C" fn random_fill(buffer : FixedArray[Byte]) -> Bool = "moon_http_random_fill"

///|
pub impl @transport.Entropy for NativeEntropy with fn fill(_self, buffer) {
  if random_fill(buffer) {
    Ok(())
  } else {
    Err(Failed("OpenSSL RAND_bytes failed"))
  }
}

///|
pub extend NativeEntropy with @transport.Entropy::{fill}
