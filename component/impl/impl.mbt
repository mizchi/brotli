///|
/// Export: decompress
pub fn decompress(data : Array[Byte]) -> Result[Array[Byte], String] {
  let bytes = Bytes::from_array(data)
  try {
    let result = @brotli.brotli_decompress(bytes)
    let arr : Array[Byte] = Array::new(capacity=result.length())
    for i = 0; i < result.length(); i = i + 1 {
      arr.push(result[i])
    }
    Ok(arr)
  } catch {
    @brotli.InvalidData(msg) => Err(msg)
  }
}

///|
/// Export: compress
pub fn compress(data : Array[Byte]) -> Array[Byte] {
  let bytes = Bytes::from_array(data)
  let result = @brotli.brotli_compress(bytes)
  let arr : Array[Byte] = Array::new(capacity=result.length())
  for i = 0; i < result.length(); i = i + 1 {
    arr.push(result[i])
  }
  arr
}

///|
/// Export: compress-with-quality
pub fn compress_with_quality(data : Array[Byte], quality : UInt) -> Array[Byte] {
  let bytes = Bytes::from_array(data)
  let result = @brotli.brotli_compress_with_quality(bytes, quality.reinterpret_as_int())
  let arr : Array[Byte] = Array::new(capacity=result.length())
  for i = 0; i < result.length(); i = i + 1 {
    arr.push(result[i])
  }
  arr
}
