///|
/// Helper: convert hex string to Bytes
fn hex_to_bytes(hex : String) -> Bytes {
  let view = hex.view()
  let arr : Array[Byte] = []
  let chars : Array[Char] = []
  for c in view {
    chars.push(c)
  }
  for i = 0; i < chars.length(); i = i + 2 {
    let hi = hex_char(chars[i])
    let lo = hex_char(chars[i + 1])
    arr.push(((hi << 4) | lo).to_byte())
  }
  Bytes::from_array(arr)
}

///|
fn hex_char(c : Char) -> Int {
  if c >= '0' && c <= '9' {
    c.to_int() - '0'.to_int()
  } else if c >= 'a' && c <= 'f' {
    c.to_int() - 'a'.to_int() + 10
  } else if c >= 'A' && c <= 'F' {
    c.to_int() - 'A'.to_int() + 10
  } else {
    0
  }
}

///|
/// Helper: decompress and verify output matches expected bytes
fn assert_decompresses_to(
  compressed_hex : String,
  expected : Bytes,
  label : String,
) -> Unit raise Error {
  let compressed = hex_to_bytes(compressed_hex)
  let result = brotli_decompress(compressed)
  assert_eq(
    result.length(),
    expected.length(),
    msg="\{label}: length mismatch: got \{result.length()}, expected \{expected.length()}",
  )
  for i in 0..<result.length() {
    assert_eq(
      result[i],
      expected[i],
      msg="\{label}: byte \{i} mismatch",
    )
  }
}

// ============================================================
// google/brotli official test vectors - decoder conformance
// ============================================================

///|
test "conformance: empty (0 bytes)" {
  assert_decompresses_to("06", Bytes::from_array([]), "empty")
}

///|
test "conformance: x (1 byte 'X')" {
  let expected = Bytes::from_array([b'\x58'])
  assert_decompresses_to("0b00805803", expected, "x")
}

///|
test "conformance: xyzzy (5 bytes)" {
  let expected = hex_to_bytes("58797a7a79")
  assert_decompresses_to("0b028058797a7a7903", expected, "xyzzy")
}

///|
test "conformance: 10x10y (20 bytes, back-references)" {
  // 10 'X' + 10 'Y'
  let arr : Array[Byte] = []
  for _i in 0..<10 {
    arr.push(b'\x58')
  }
  for _i in 0..<10 {
    arr.push(b'\x59')
  }
  let expected = Bytes::from_array(arr)
  assert_decompresses_to("1b130000a4b0b2ea8147028a", expected, "10x10y")
}

///|
test "conformance: 64x (64 'X' chars, repeat coding)" {
  let arr : Array[Byte] = []
  for _i in 0..<64 {
    arr.push(b'\x58')
  }
  let expected = Bytes::from_array(arr)
  assert_decompresses_to("1b3f000024b0e2998012", expected, "64x")
}

///|
test "conformance: quickfox (43 bytes, uncompressed metablock)" {
  let expected = hex_to_bytes(
    "54686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f67",
  )
  assert_decompresses_to(
    "0b158054686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f6703",
    expected,
    "quickfox",
  )
}

///|
test "conformance: ukkonooa (119 bytes, Finnish text)" {
  let expected = hex_to_bytes(
    "756b6b6f206e6f6f612c20756b6b6f206e6f6f61206f6c69206b756e6e6f6e206d6965732c206b756e2068616e206d656e69207361756e61616e2c207069737469206c61756b756e206e61756c61616e2c20756b6b6f206e6f6f612c20756b6b6f206e6f6f61206f6c69206b756e6e6f6e206d6965732e",
  )
  assert_decompresses_to(
    "1b760000144aac9b7abde1979d7f8ec282360e9ce09003f78b9e38e6b600abc3caa0c2da6636dccd808d2e21d76ee3ea4cb8f0d2b8c7c2704d3af0697ea1b84573abc4571e",
    expected,
    "ukkonooa",
  )
}

///|
test "conformance: zeros (262144 bytes -> 13 bytes)" {
  let expected_len = 262144
  let compressed = hex_to_bytes("5bffff036002201e0b28f77e00")
  let result = brotli_decompress(compressed)
  assert_eq(result.length(), expected_len, msg="zeros: length mismatch")
  for i in 0..<expected_len {
    assert_eq(result[i], b'\x00', msg="zeros: byte \{i} not zero")
  }
}

// ============================================================
// Alternate valid encodings (decoder must accept all)
// ============================================================

///|
test "conformance: empty alternate encodings" {
  let alternates = [
    "06", "8101", "a101", "b101", "c101", "d101", "e101", "f101", "33", "35",
    "37", "39", "3b", "3d", "3f", "1a", "81160058",
  ]
  for i, hex in alternates {
    assert_decompresses_to(hex, Bytes::from_array([]), "empty.\{i}")
  }
}

///|
test "conformance: x alternate encodings" {
  let expected = Bytes::from_array([b'\x58'])
  let alternates = [
    "0000105803", "2c00580000085803", "000010580d", "a1000000008115080400",
  ]
  for i, hex in alternates {
    assert_decompresses_to(hex, expected, "x.\{i}")
  }
}

///|
test "conformance: monkey (843 bytes)" {
  let compressed = hex_to_bytes(
    "1b4a03008c946edeb4d796b17886f22de11abc0b1cbaa9c7f7cc6eb2423451448b4e1308a0cd6ee82ca553a19c5d2c1d231ad256bedbeb26ba03657c966aa276ecef874733d6270e6395e21d8d2cc5d1289f60946f028bddaa64942c1e3b657c07455ab2e2fc49812c9f40aeef6881ac167a0ff53b6d1cb91e2d5fd5c8af5e85aa05be5375c2b0228a15c6a3b1e64214f4845453195fbec3f21dd1b7e5ddb6d923c6f69f9ef64d6530fbc0714504ad03b5bec9cbfde2505a4674040dff200477b26d27bf47a99d1b962c6290238be0f81dcfaf1d3dee8ac8752366ddded66de32a828a788adbe6204cb75c63ba30e33fb6ee8c22a22ab0220a99ff3d6251ee08f63d4ae4ccef228711e28328e4f58f3519635be15a9273dda1509d385cebb5036a649094c88dfb2f8a8622cc1d87e0480a96779039c6232348fb114756ca20e34281f77732c1a55c40216517402917176c5632983806dc994d3329bb02df4c26936c17828620d703797d9a00d78700e70b66e34c6671670832f9083e8133cd177231f0b894524b90318e68c1ef90c9e5f261097225adecc562c00b1205f791750dee612e2e1909c203",
  )
  let result = brotli_decompress(compressed)
  assert_eq(result.length(), 843, msg="monkey: length mismatch")
  // Verify first few bytes: "znxcvnmz,xvnm.,zxcnv."
  let first_bytes = hex_to_bytes("7a6e7863766e6d7a2c78766e6d2e2c7a78636e76")
  for i in 0..<first_bytes.length() {
    assert_eq(result[i], first_bytes[i], msg="monkey: byte \{i} mismatch")
  }
}

// ============================================================
// Encoder roundtrip tests with official test data
// ============================================================

///|
test "roundtrip: quickfox" {
  let original = hex_to_bytes(
    "54686520717569636b2062726f776e20666f78206a756d7073206f76657220746865206c617a7920646f67",
  )
  let compressed = brotli_compress(original)
  let decompressed = brotli_decompress(compressed)
  assert_eq(decompressed.length(), original.length(), msg="roundtrip quickfox length")
  for i in 0..<original.length() {
    assert_eq(decompressed[i], original[i], msg="roundtrip quickfox byte \{i}")
  }
}

///|
test "roundtrip: 10x10y" {
  let arr : Array[Byte] = []
  for _i in 0..<10 {
    arr.push(b'\x58')
  }
  for _i in 0..<10 {
    arr.push(b'\x59')
  }
  let original = Bytes::from_array(arr)
  let compressed = brotli_compress(original)
  let decompressed = brotli_decompress(compressed)
  assert_eq(decompressed.length(), original.length(), msg="roundtrip 10x10y length")
  for i in 0..<original.length() {
    assert_eq(decompressed[i], original[i], msg="roundtrip 10x10y byte \{i}")
  }
}

///|
test "roundtrip: 64x" {
  let arr : Array[Byte] = []
  for _i in 0..<64 {
    arr.push(b'\x58')
  }
  let original = Bytes::from_array(arr)
  let compressed = brotli_compress(original)
  let decompressed = brotli_decompress(compressed)
  assert_eq(decompressed.length(), original.length(), msg="roundtrip 64x length")
  for i in 0..<original.length() {
    assert_eq(decompressed[i], original[i], msg="roundtrip 64x byte \{i}")
  }
}

///|
test "roundtrip: ukkonooa" {
  let original = hex_to_bytes(
    "756b6b6f206e6f6f612c20756b6b6f206e6f6f61206f6c69206b756e6e6f6e206d6965732c206b756e2068616e206d656e69207361756e61616e2c207069737469206c61756b756e206e61756c61616e2c20756b6b6f206e6f6f612c20756b6b6f206e6f6f61206f6c69206b756e6e6f6e206d6965732e",
  )
  let compressed = brotli_compress(original)
  let decompressed = brotli_decompress(compressed)
  assert_eq(
    decompressed.length(),
    original.length(),
    msg="roundtrip ukkonooa length",
  )
  for i in 0..<original.length() {
    assert_eq(decompressed[i], original[i], msg="roundtrip ukkonooa byte \{i}")
  }
}

///|
test "roundtrip: zeros 1024" {
  let arr : Array[Byte] = []
  for _i in 0..<1024 {
    arr.push(b'\x00')
  }
  let original = Bytes::from_array(arr)
  let compressed = brotli_compress(original)
  let decompressed = brotli_decompress(compressed)
  assert_eq(decompressed.length(), original.length(), msg="roundtrip zeros length")
  for i in 0..<original.length() {
    assert_eq(decompressed[i], original[i], msg="roundtrip zeros byte \{i}")
  }
}

///|
test "roundtrip: binary pattern" {
  let arr : Array[Byte] = []
  for i in 0..<256 {
    arr.push(i.to_byte())
  }
  let original = Bytes::from_array(arr)
  let compressed = brotli_compress(original)
  let decompressed = brotli_decompress(compressed)
  assert_eq(
    decompressed.length(),
    original.length(),
    msg="roundtrip binary length",
  )
  for i in 0..<original.length() {
    assert_eq(decompressed[i], original[i], msg="roundtrip binary byte \{i}")
  }
}
