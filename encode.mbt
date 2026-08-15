///|
/// Encode window bits into the Brotli stream header.
/// Inverse of decode_window_bits in decode.mbt.
fn encode_window_bits(bw : BitWriter, wbits : Int) -> Unit {
  if wbits == 16 {
    bw.write_bits(1, 0)
  } else if wbits >= 17 && wbits <= 24 {
    bw.write_bits(1, 1)
    bw.write_bits(3, wbits - 17)
  } else if wbits >= 9 && wbits <= 15 {
    bw.write_bits(1, 1)
    bw.write_bits(3, 0)
    bw.write_bits(3, wbits - 8)
  } else {
    // wbits == 17 (fallback for wbits==8+0 => 17)
    bw.write_bits(1, 1)
    bw.write_bits(3, 0)
    bw.write_bits(3, 0)
  }
}

///|
/// Encode meta-block length.
/// Inverse of decode_meta_block_length in decode.mbt.
fn encode_meta_block_length(
  bw : BitWriter,
  length : Int,
  is_last : Bool,
) -> Unit {
  // ISLAST
  bw.write_bits(1, if is_last { 1 } else { 0 })
  if is_last && length == 0 {
    // ISLASTEMPTY
    bw.write_bits(1, 1)
    return
  }
  if is_last {
    // Not empty
    bw.write_bits(1, 0)
  }
  // Encode length - 1 in nibbles
  let len = length - 1
  // Determine number of nibbles needed (4, 5, or 6)
  let mut nibbles = 0
  let mut tmp = len
  while tmp > 0 {
    nibbles += 1
    tmp = tmp >> 4
  }
  if nibbles < 4 {
    nibbles = 4
  }
  if nibbles > 6 {
    nibbles = 6
  }
  // MNIBBLES = nibbles - 4 (2 bits)
  bw.write_bits(2, nibbles - 4)
  // Write nibbles
  for i in 0..<nibbles {
    bw.write_bits(4, (len >> (i * 4)) & 0xf)
  }
}

///|
/// Encode an uncompressed meta-block.
fn encode_uncompressed_meta_block(
  bw : BitWriter,
  data : Bytes,
  offset : Int,
  length : Int,
  is_last : Bool,
) -> Unit {
  encode_meta_block_length(bw, length, is_last)
  if length == 0 {
    return
  }
  // ISUNCOMPRESSED = 1
  bw.write_bits(1, 1)
  // Align to byte boundary
  bw.align_byte()
  // Write raw bytes
  for i in 0..<length {
    bw.write_byte(data[offset + i].to_int())
  }
}

///|
/// Compress data using Brotli format.
/// quality: 0 = store only (uncompressed), 1+ = LZ77 + Huffman
pub fn brotli_compress(data : Bytes) -> Bytes {
  brotli_compress_with_quality(data, 1)
}

///|
/// Compress with specified quality level.
/// quality 0: uncompressed meta-blocks only
/// quality 1: simple LZ77 + simple prefix codes
pub fn brotli_compress_with_quality(data : Bytes, quality : Int) -> Bytes {
  let bw = BitWriter::new(data.length() + 1024)
  let wbits = compute_window_bits(data.length())
  encode_window_bits(bw, wbits)
  if quality == 0 || data.length() == 0 {
    encode_store_only(bw, data)
  } else {
    encode_compressed(bw, data, wbits)
  }
  bw.finish()
}

///|
/// Compute appropriate window bits for data size.
fn compute_window_bits(data_len : Int) -> Int {
  if data_len == 0 {
    return 16
  }
  let mut wbits = 10
  while wbits < 24 && 1 << wbits < data_len {
    wbits += 1
  }
  if wbits < 16 {
    16
  } else {
    wbits
  }
}

///|
/// Store-only encoding: emit data in uncompressed meta-blocks.
/// Note: uncompressed meta-blocks cannot be the last block (ISLAST=1 skips ISUNCOMPRESSED).
/// So we emit uncompressed blocks with ISLAST=0, then an empty last block.
fn encode_store_only(bw : BitWriter, data : Bytes) -> Unit {
  let max_block = (1 << 24) - 1 // max meta-block size
  let mut offset = 0
  let len = data.length()
  if len == 0 {
    // Empty last meta-block
    encode_meta_block_length(bw, 0, true)
    return
  }
  while offset < len {
    let remaining = len - offset
    let block_size = if remaining > max_block { max_block } else { remaining }
    // Always ISLAST=false for uncompressed blocks
    encode_uncompressed_meta_block(bw, data, offset, block_size, false)
    offset += block_size
  }
  // Emit empty last meta-block
  encode_meta_block_length(bw, 0, true)
}

///|
/// Compressed encoding with LZ77 matching and simple prefix codes.
/// Falls back to uncompressed if data requires complex Huffman codes.
fn encode_compressed(bw : BitWriter, data : Bytes, wbits : Int) -> Unit {
  let window_size = 1 << wbits
  let max_backward = window_size - 16
  let commands = find_backward_references(data, max_backward)
  // Check if we have any backward references
  let mut has_backrefs = false
  for i in 0..<commands.length() {
    if commands[i].copy_len > 0 {
      has_backrefs = true
      break
    }
  }
  if !has_backrefs {
    encode_store_only(bw, data)
    return
  }
  emit_compressed_meta_block(bw, data, commands, true)
}

///|
priv struct Command {
  insert_pos : Int
  insert_len : Int
  copy_len : Int
  distance : Int
}

///|
/// Cached encoding results for a command to avoid double computation.
priv struct EncodedCommand {
  cmd_code : Int
  insert_code : Int
  copy_code : Int
  dist_code : Int
  dist_extra : Int
  dist_nbits : Int
}

///|
/// Simple hash-chain LZ77 match finder.
fn find_backward_references(data : Bytes, max_backward : Int) -> Array[Command] {
  let commands : Array[Command] = []
  let len = data.length()
  if len < 4 {
    commands.push({ insert_pos: 0, insert_len: len, copy_len: 0, distance: 0 })
    return commands
  }
  let hash_bits = 15
  let hash_size = 1 << hash_bits
  let hash_table : FixedArray[Int] = FixedArray::make(hash_size, -1)
  let mut pos = 0
  let mut insert_start = 0
  while pos + 3 < len {
    let h = hash4(data, pos) & (hash_size - 1)
    let prev = hash_table[h]
    hash_table[h] = pos
    if prev >= 0 {
      let dist = pos - prev
      if dist > 0 && dist <= max_backward {
        // Try to extend match
        let max_len = if len - pos < 258 { len - pos } else { 258 }
        let mut match_len = 0
        while match_len < max_len &&
              data[prev + match_len] == data[pos + match_len] {
          match_len += 1
        }
        if match_len >= 4 {
          // Emit insert for any literals before this match
          let insert_len = pos - insert_start
          commands.push({
            insert_pos: insert_start,
            insert_len,
            copy_len: match_len,
            distance: dist,
          })
          // Advance past the match, updating hash for skipped positions
          for i = 1; i < match_len && pos + i + 3 < len; i = i + 1 {
            let h2 = hash4(data, pos + i) & (hash_size - 1)
            hash_table[h2] = pos + i
          }
          pos += match_len
          insert_start = pos
          continue
        }
      }
    }
    pos += 1
  }
  // Remaining literals
  if insert_start < len {
    commands.push({
      insert_pos: insert_start,
      insert_len: len - insert_start,
      copy_len: 0,
      distance: 0,
    })
  }
  commands
}

///|
fn hash4(data : Bytes, pos : Int) -> Int {
  let b0 = data[pos].to_int()
  let b1 = data[pos + 1].to_int()
  let b2 = data[pos + 2].to_int()
  let b3 = data[pos + 3].to_int()
  let v = b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
  let h = v * 0x1e35a7bd
  (h ^ (h >> 16)) & 0x7fffffff
}

///|
/// Emit a single compressed meta-block with simple prefix codes.
fn emit_compressed_meta_block(
  bw : BitWriter,
  data : Bytes,
  commands : Array[Command],
  is_last : Bool,
) -> Unit {
  let data_len = data.length()
  encode_meta_block_length(bw, data_len, is_last)
  // ISUNCOMPRESSED = 0 (only if not last block)
  if !is_last {
    bw.write_bits(1, 0)
  }
  // --- Block types: 1 of each (simplest case) ---
  // NBLTYPESL = 1 (VarLenUint8: first bit 0)
  bw.write_bits(1, 0)
  // NBLTYPESI = 1
  bw.write_bits(1, 0)
  // NBLTYPESD = 1
  bw.write_bits(1, 0)
  // --- Distance parameters ---
  // NPOSTFIX = 0
  bw.write_bits(2, 0)
  // NDIRECT = 0 (4 bits after shift)
  bw.write_bits(4, 0)
  // --- Context mode for literal block type 0 ---
  // Use LSB6 context mode (0)
  bw.write_bits(2, 0)
  // --- Context maps ---
  // Literal context map: NTREESL = 1 (VarLenUint8: 0)
  bw.write_bits(1, 0)
  // Distance context map: NTREESD = 1 (VarLenUint8: 0)
  bw.write_bits(1, 0)
  // --- Huffman codes ---
  // Build frequency tables
  let literal_freq : FixedArray[Int] = FixedArray::make(256, 0)
  let cmd_freq : FixedArray[Int] = FixedArray::make(704, 0)
  let dist_freq : FixedArray[Int] = FixedArray::make(16 + 48, 0) // num_distance_short_codes + 48
  // Precompute and cache all command encodings to avoid double computation
  let encoded : FixedArray[EncodedCommand] = FixedArray::make(
    commands.length(),
    {
      cmd_code: 0,
      insert_code: 0,
      copy_code: 0,
      dist_code: 0,
      dist_extra: 0,
      dist_nbits: 0,
    },
  )
  for i in 0..<commands.length() {
    let cmd = commands[i]
    for j in 0..<cmd.insert_len {
      literal_freq[data[cmd.insert_pos + j].to_int()] += 1
    }
    if cmd.copy_len > 0 {
      let (insert_code, copy_code) = get_insert_copy_codes(
        cmd.insert_len,
        cmd.copy_len,
      )
      let cmd_code = combine_insert_copy_code(insert_code, copy_code, true)
      let (dist_code, dist_extra, dist_nbits) = encode_distance(cmd.distance)
      encoded[i] = {
        cmd_code,
        insert_code,
        copy_code,
        dist_code,
        dist_extra,
        dist_nbits,
      }
      if cmd_code < 704 {
        cmd_freq[cmd_code] += 1
      }
      if dist_code < dist_freq.length() {
        dist_freq[dist_code] += 1
      }
    } else {
      let (insert_code, _) = get_insert_copy_codes(cmd.insert_len, 2)
      let cmd_code = combine_insert_copy_code(insert_code, 0, false)
      encoded[i] = {
        cmd_code,
        insert_code,
        copy_code: 0,
        dist_code: 0,
        dist_extra: 0,
        dist_nbits: 0,
      }
      if cmd_code < 704 {
        cmd_freq[cmd_code] += 1
      }
    }
  }
  // Ensure at least one of each symbol type
  ensure_nonzero_freq(literal_freq, 256)
  ensure_nonzero_freq(cmd_freq, 704)
  ensure_nonzero_freq(dist_freq, dist_freq.length())
  // Build and emit Huffman codes
  let literal_depths = build_code_lengths(literal_freq, 256, 15)
  let cmd_depths = build_code_lengths(cmd_freq, 704, 15)
  let dist_depths = build_code_lengths(dist_freq, dist_freq.length(), 15)
  let literal_codes = canonical_codes(literal_depths, 256)
  let cmd_codes = canonical_codes(cmd_depths, 704)
  let dist_codes = canonical_codes(dist_depths, dist_freq.length())
  // Count non-zero symbols for each Huffman code
  let lit_nsym = count_nonzero(literal_depths, 256)
  let cmd_nsym = count_nonzero(cmd_depths, 704)
  let dist_nsym = count_nonzero(dist_depths, dist_freq.length())
  // Emit Huffman code descriptions
  emit_huffman_code(bw, literal_depths, 256)
  emit_huffman_code(bw, cmd_depths, 704)
  emit_huffman_code(bw, dist_depths, dist_freq.length())
  // --- Emit commands using cached encodings ---
  for i in 0..<commands.length() {
    let cmd = commands[i]
    let enc = encoded[i]
    emit_symbol(bw, cmd_codes, cmd_depths, enc.cmd_code, cmd_nsym)
    emit_insert_extra(bw, cmd.insert_len, enc.insert_code)
    if cmd.copy_len > 0 {
      emit_copy_extra(bw, cmd.copy_len, enc.copy_code)
    }
    for j in 0..<cmd.insert_len {
      emit_symbol(
        bw,
        literal_codes,
        literal_depths,
        data[cmd.insert_pos + j].to_int(),
        lit_nsym,
      )
    }
    if cmd.copy_len > 0 {
      emit_symbol(bw, dist_codes, dist_depths, enc.dist_code, dist_nsym)
      emit_distance_extra(bw, enc.dist_code, enc.dist_extra, enc.dist_nbits)
    }
  }
}

///|
fn count_nonzero(depths : FixedArray[Int], n : Int) -> Int {
  let mut count = 0
  for i in 0..<n {
    if depths[i] > 0 {
      count += 1
    }
  }
  count
}

///|
fn ensure_nonzero_freq(freq : FixedArray[Int], n : Int) -> Unit {
  let mut has_nonzero = false
  for i in 0..<n {
    if freq[i] > 0 {
      has_nonzero = true
      break
    }
  }
  if !has_nonzero {
    freq[0] = 1
  }
}

///|
fn emit_symbol(
  bw : BitWriter,
  codes : FixedArray[Int],
  depths : FixedArray[Int],
  symbol : Int,
  num_symbols : Int,
) -> Unit {
  if num_symbols <= 1 {
    return
  }
  bw.write_bits(depths[symbol], codes[symbol])
}

///|
/// Get insert and copy prefix code indices from lengths.
fn get_insert_copy_codes(insert_len : Int, copy_len : Int) -> (Int, Int) {
  let insert_code = find_prefix_code(kInsertLengthPrefixCode, insert_len, 24)
  let copy_code = find_prefix_code(kCopyLengthPrefixCode, copy_len, 24)
  (insert_code, copy_code)
}

///|
fn find_prefix_code(
  table : FixedArray[PrefixCodeRange],
  value : Int,
  max_code : Int,
) -> Int {
  // Binary search: find largest i where table[i].offset <= value
  for lo = 0, hi = max_code - 1; lo < hi; {
    let mid = (lo + hi + 1) >> 1
    if table[mid].offset <= value {
      continue mid, hi
    } else {
      continue lo, mid - 1
    }
  } nobreak {
    lo
  }
}

///|
/// Combine insert and copy codes into a single command code (0-703).
fn combine_insert_copy_code(
  insert_code : Int,
  copy_code : Int,
  has_distance : Bool,
) -> Int {
  let insert_high = insert_code >> 3
  let insert_low = insert_code & 7
  let copy_high = copy_code >> 3
  let copy_low = copy_code & 7
  let base_range = kRangeLookup[insert_high * 3 + copy_high]
  let range = if has_distance { base_range + 2 } else { base_range }
  (range << 6) | (insert_low << 3) | copy_low
}

///|
fn emit_insert_extra(
  bw : BitWriter,
  insert_len : Int,
  insert_code : Int,
) -> Unit {
  let nbits = kInsertLengthPrefixCode[insert_code].nbits
  if nbits > 0 {
    let extra = insert_len - kInsertLengthPrefixCode[insert_code].offset
    bw.write_bits(nbits, extra)
  }
}

///|
fn emit_copy_extra(bw : BitWriter, copy_len : Int, copy_code : Int) -> Unit {
  let nbits = kCopyLengthPrefixCode[copy_code].nbits
  if nbits > 0 {
    let extra = copy_len - kCopyLengthPrefixCode[copy_code].offset
    bw.write_bits(nbits, extra)
  }
}

///|
/// Encode distance as a distance code with NPOSTFIX=0, NDIRECT=0.
/// Returns (code, extra_bits, num_extra_bits).
fn encode_distance(distance : Int) -> (Int, Int, Int) {
  if distance <= 0 {
    return (0, 0, 0)
  }
  let target = distance - 1
  if target < 4 {
    // dcode=0: nbits=1, offset=0, range [0,2)
    // dcode=1: nbits=1, offset=2, range [2,4)
    let dcode = target >> 1
    let extra = target - (dcode << 1)
    return (num_distance_short_codes + dcode, extra, 1)
  }
  // For target >= 4: compute nbits from highest bit position
  // nbits = floor(log2(target + 4)) - 1
  let adjusted = target + 4
  let mut log2 = 0
  let mut v = adjusted >> 1
  while v > 0 {
    log2 += 1
    v = v >> 1
  }
  let nbits = log2 - 1
  // dcode's parity determines which half: even (2<<nbits) or odd (3<<nbits)
  let offset_even = (2 << nbits) - 4
  let dcode = if target >= offset_even + (1 << nbits) {
    // Odd dcode
    (nbits - 1) * 2 + 1
  } else {
    // Even dcode
    (nbits - 1) * 2
  }
  let offset = ((2 + (dcode & 1)) << nbits) - 4
  let extra = target - offset
  (num_distance_short_codes + dcode, extra, nbits)
}

///|
fn emit_distance_extra(
  bw : BitWriter,
  dist_code : Int,
  extra : Int,
  nbits : Int,
) -> Unit {
  if nbits > 0 && dist_code >= num_distance_short_codes {
    bw.write_bits(nbits, extra)
  }
}
