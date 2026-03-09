///|
test "bench brotli" (b : @bench.T) {
  // Text data: ~4500 bytes of repeated text
  let fox = "The quick brown fox jumps over the lazy dog. "
  let text : Array[Byte] = []
  for _rep in 0..<100 {
    for i in 0..<fox.length() {
      text.push(fox[i].to_int().to_byte())
    }
  }
  let data = Bytes::from_array(text)
  let compressed = brotli_compress(data)
  println(
    "text: \{data.length()}B -> \{compressed.length()}B (\{compressed.length() * 100 / data.length()}%)",
  )
  // Binary data: 1000 bytes, 256 unique symbols
  let bin : Array[Byte] = []
  for i in 0..<1000 {
    bin.push(((i * 17 + 31) & 0xFF).to_byte())
  }
  let bin_data = Bytes::from_array(bin)
  let bin_compressed = brotli_compress(bin_data)
  println(
    "binary: \{bin_data.length()}B -> \{bin_compressed.length()}B (\{bin_compressed.length() * 100 / bin_data.length()}%)",
  )
  // Compress benchmarks
  b.bench(name="compress_q0_4500B_text", fn() {
    b.keep(brotli_compress_with_quality(data, 0))
  })
  b.bench(name="compress_q1_4500B_text", fn() { b.keep(brotli_compress(data)) })
  b.bench(name="compress_q1_1000B_bin", fn() {
    b.keep(brotli_compress(bin_data))
  })
  // Decompress benchmarks
  b.bench(name="decompress_4500B_text", fn() {
    b.keep(brotli_decompress(compressed)) catch {
      _ => ()
    }
  })
  b.bench(name="decompress_1000B_bin", fn() {
    b.keep(brotli_decompress(bin_compressed)) catch {
      _ => ()
    }
  })
}
