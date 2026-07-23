///|
test "bench HPACK Huffman codec fixture" (it : @bench.T) {
  let input = @utf8.encode("www.example.com").to_array()
  it.bench(fn() {
    let encoded = hpack_huffman_encode(input).unwrap()
    it.keep(encoded.length())
  })
}
