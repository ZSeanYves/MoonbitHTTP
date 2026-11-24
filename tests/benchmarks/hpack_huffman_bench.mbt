///|
test "bench HPACK Huffman codec fixture" (it : @bench.T) {
  let input = @utf8.encode("www.example.com")
  it.bench(fn() {
    let encoded = @codec.huffman_encode(input)
    it.keep(encoded.length())
  })
}
