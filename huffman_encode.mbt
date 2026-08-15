///|
/// Build code lengths from frequency data.
/// Returns an array of code lengths (0 means symbol not used).
fn build_code_lengths(
  freq : FixedArray[Int],
  n : Int,
  max_depth : Int,
) -> FixedArray[Int] {
  let depths : FixedArray[Int] = FixedArray::make(n, 0)
  // Count non-zero symbols
  let mut num_symbols = 0
  let mut first_symbol = 0
  let mut second_symbol = 0
  for i in 0..<n {
    if freq[i] > 0 {
      if num_symbols == 0 {
        first_symbol = i
      } else if num_symbols == 1 {
        second_symbol = i
      }
      num_symbols += 1
    }
  }
  if num_symbols == 0 {
    depths[0] = 1
    return depths
  }
  if num_symbols == 1 {
    depths[first_symbol] = 1
    return depths
  }
  if num_symbols == 2 {
    depths[first_symbol] = 1
    depths[second_symbol] = 1
    return depths
  }
  // For 3-4 symbols with simple prefix code,
  // use the Brotli simple code convention
  if num_symbols == 3 {
    let syms = collect_nonzero_symbols(freq, n)
    depths[syms[0]] = 1
    depths[syms[1]] = 2
    depths[syms[2]] = 2
    return depths
  }
  if num_symbols == 4 {
    let syms = collect_nonzero_symbols(freq, n)
    for i in 0..<4 {
      depths[syms[i]] = 2
    }
    return depths
  }
  // For 5+ symbols, use proper Huffman tree construction
  build_huffman_tree_depths(freq, depths, n, max_depth)
  depths
}

///|
fn collect_nonzero_symbols(freq : FixedArray[Int], n : Int) -> Array[Int] {
  let syms : Array[Int] = []
  for i in 0..<n {
    if freq[i] > 0 {
      syms.push(i)
    }
  }
  syms
}

///|
/// Build Huffman code lengths using parent-pointer tree construction.
fn build_huffman_tree_depths(
  freq : FixedArray[Int],
  depths : FixedArray[Int],
  n : Int,
  max_depth : Int,
) -> Unit {
  let sym_indices : Array[Int] = []
  let sym_freqs : Array[Int] = []
  for i in 0..<n {
    if freq[i] > 0 {
      sym_indices.push(i)
      sym_freqs.push(freq[i])
    }
  }
  let num = sym_indices.length()
  if num <= 1 {
    if num == 1 {
      depths[sym_indices[0]] = 1
    }
    return
  }
  // Sort by frequency ascending, then by symbol index
  let sorted : FixedArray[Int] = FixedArray::make(num, 0)
  for i in 0..<num {
    sorted[i] = i
  }
  // Simple insertion sort (good enough for small n, avoids allocation)
  for i in 1..<num {
    let key = sorted[i]
    let mut j = i - 1
    while j >= 0 &&
          (
            sym_freqs[sorted[j]] > sym_freqs[key] ||
            (
              sym_freqs[sorted[j]] == sym_freqs[key] &&
              sym_indices[sorted[j]] > sym_indices[key]
            )
          ) {
      sorted[j + 1] = sorted[j]
      j -= 1
    }
    sorted[j + 1] = key
  }
  // Nodes 0..num-1 are leaves (sorted order), num..2*num-2 are internal
  let weights : FixedArray[Int] = FixedArray::make(2 * num - 1, 0)
  let parent : FixedArray[Int] = FixedArray::make(2 * num - 1, -1)
  for i in 0..<num {
    weights[i] = sym_freqs[sorted[i]]
  }
  // Two-queue merge: q1 = leaves [0..num), q2 = internal nodes [num..)
  let mut q1_idx = 0
  let mut q2_idx = num // read pointer into internal nodes
  let mut next_internal = num // write pointer for new internal nodes
  fn pop_min() -> Int {
    let use_q1 = q1_idx < num &&
      (q2_idx >= next_internal || weights[q1_idx] <= weights[q2_idx])
    if use_q1 {
      let r = q1_idx
      q1_idx += 1
      r
    } else {
      let r = q2_idx
      q2_idx += 1
      r
    }
  }

  while num - q1_idx + (next_internal - q2_idx) > 1 {
    let a = pop_min()
    let b = pop_min()
    weights[next_internal] = weights[a] + weights[b]
    parent[a] = next_internal
    parent[b] = next_internal
    next_internal += 1
  }
  // Compute depth of each leaf by walking to root
  for i in 0..<num {
    let mut depth = 0
    let mut node = i
    while parent[node] >= 0 {
      depth += 1
      node = parent[node]
    }
    let sym = sym_indices[sorted[i]]
    depths[sym] = if depth > max_depth { max_depth } else { depth }
  }
  // If any depths were clamped, adjust to satisfy Kraft inequality
  fix_kraft_inequality(depths, n, max_depth)
}

///|
/// Ensure code lengths satisfy Kraft inequality: sum(2^-depth) == 1.
/// Uses depth histogram to find candidates in O(max_depth) instead of O(n).
fn fix_kraft_inequality(
  depths : FixedArray[Int],
  n : Int,
  max_depth : Int,
) -> Unit {
  let mut kraft_sum = 0
  let target = 1 << max_depth
  // Build histogram of depths and track one symbol per depth level
  let depth_count : FixedArray[Int] = FixedArray::make(max_depth + 1, 0)
  for i in 0..<n {
    if depths[i] > 0 {
      kraft_sum += 1 << (max_depth - depths[i])
      depth_count[depths[i]] += 1
    }
  }
  // Increase depths (lengthen codes) to reduce kraft_sum
  while kraft_sum > target {
    // Find shallowest depth with a symbol
    let mut d = 1
    while d < max_depth && depth_count[d] == 0 {
      d += 1
    }
    if d >= max_depth {
      break
    }
    // Find a symbol at this depth and increase it
    for i in 0..<n {
      if depths[i] == d {
        kraft_sum -= 1 << (max_depth - d)
        depths[i] += 1
        kraft_sum += 1 << (max_depth - depths[i])
        depth_count[d] -= 1
        depth_count[d + 1] += 1
        break
      }
    }
  }
  // Decrease depths (shorten codes) to use remaining kraft budget
  while kraft_sum < target {
    // Find deepest depth with a symbol
    let mut d = max_depth
    while d > 1 && depth_count[d] == 0 {
      d -= 1
    }
    if d <= 1 {
      break
    }
    let new_kraft = kraft_sum -
      (1 << (max_depth - d)) +
      (1 << (max_depth - d + 1))
    if new_kraft > target {
      break
    }
    for i in 0..<n {
      if depths[i] == d {
        kraft_sum -= 1 << (max_depth - d)
        depths[i] -= 1
        kraft_sum += 1 << (max_depth - depths[i])
        depth_count[d] -= 1
        depth_count[d - 1] += 1
        break
      }
    }
  }
}

///|
/// Generate canonical Huffman codes from code lengths.
fn canonical_codes(depths : FixedArray[Int], n : Int) -> FixedArray[Int] {
  let codes : FixedArray[Int] = FixedArray::make(n, 0)
  let max_depth = 15
  // Count codes of each length (bl_count[0] = 0 always)
  let bl_count : FixedArray[Int] = FixedArray::make(max_depth + 1, 0)
  for i in 0..<n {
    if depths[i] > 0 {
      bl_count[depths[i]] += 1
    }
  }
  // Compute starting code for each length
  let next_code : FixedArray[Int] = FixedArray::make(max_depth + 1, 0)
  let mut code = 0
  bl_count[0] = 0
  for bits in 1..<=max_depth {
    code = (code + bl_count[bits - 1]) << 1
    next_code[bits] = code
  }
  // Assign codes with bit reversal for LSB-first encoding
  for i in 0..<n {
    let len = depths[i]
    if len > 0 {
      codes[i] = reverse_bits(next_code[len], len)
      next_code[len] += 1
    }
  }
  codes
}

///|
/// Byte-level bit reversal lookup table.
let kReverseByte : FixedArray[Int] = [
  0x00, 0x80, 0x40, 0xC0, 0x20, 0xA0, 0x60, 0xE0, 0x10, 0x90, 0x50, 0xD0, 0x30, 0xB0,
  0x70, 0xF0, 0x08, 0x88, 0x48, 0xC8, 0x28, 0xA8, 0x68, 0xE8, 0x18, 0x98, 0x58, 0xD8,
  0x38, 0xB8, 0x78, 0xF8, 0x04, 0x84, 0x44, 0xC4, 0x24, 0xA4, 0x64, 0xE4, 0x14, 0x94,
  0x54, 0xD4, 0x34, 0xB4, 0x74, 0xF4, 0x0C, 0x8C, 0x4C, 0xCC, 0x2C, 0xAC, 0x6C, 0xEC,
  0x1C, 0x9C, 0x5C, 0xDC, 0x3C, 0xBC, 0x7C, 0xFC, 0x02, 0x82, 0x42, 0xC2, 0x22, 0xA2,
  0x62, 0xE2, 0x12, 0x92, 0x52, 0xD2, 0x32, 0xB2, 0x72, 0xF2, 0x0A, 0x8A, 0x4A, 0xCA,
  0x2A, 0xAA, 0x6A, 0xEA, 0x1A, 0x9A, 0x5A, 0xDA, 0x3A, 0xBA, 0x7A, 0xFA, 0x06, 0x86,
  0x46, 0xC6, 0x26, 0xA6, 0x66, 0xE6, 0x16, 0x96, 0x56, 0xD6, 0x36, 0xB6, 0x76, 0xF6,
  0x0E, 0x8E, 0x4E, 0xCE, 0x2E, 0xAE, 0x6E, 0xEE, 0x1E, 0x9E, 0x5E, 0xDE, 0x3E, 0xBE,
  0x7E, 0xFE, 0x01, 0x81, 0x41, 0xC1, 0x21, 0xA1, 0x61, 0xE1, 0x11, 0x91, 0x51, 0xD1,
  0x31, 0xB1, 0x71, 0xF1, 0x09, 0x89, 0x49, 0xC9, 0x29, 0xA9, 0x69, 0xE9, 0x19, 0x99,
  0x59, 0xD9, 0x39, 0xB9, 0x79, 0xF9, 0x05, 0x85, 0x45, 0xC5, 0x25, 0xA5, 0x65, 0xE5,
  0x15, 0x95, 0x55, 0xD5, 0x35, 0xB5, 0x75, 0xF5, 0x0D, 0x8D, 0x4D, 0xCD, 0x2D, 0xAD,
  0x6D, 0xED, 0x1D, 0x9D, 0x5D, 0xDD, 0x3D, 0xBD, 0x7D, 0xFD, 0x03, 0x83, 0x43, 0xC3,
  0x23, 0xA3, 0x63, 0xE3, 0x13, 0x93, 0x53, 0xD3, 0x33, 0xB3, 0x73, 0xF3, 0x0B, 0x8B,
  0x4B, 0xCB, 0x2B, 0xAB, 0x6B, 0xEB, 0x1B, 0x9B, 0x5B, 0xDB, 0x3B, 0xBB, 0x7B, 0xFB,
  0x07, 0x87, 0x47, 0xC7, 0x27, 0xA7, 0x67, 0xE7, 0x17, 0x97, 0x57, 0xD7, 0x37, 0xB7,
  0x77, 0xF7, 0x0F, 0x8F, 0x4F, 0xCF, 0x2F, 0xAF, 0x6F, 0xEF, 0x1F, 0x9F, 0x5F, 0xDF,
  0x3F, 0xBF, 0x7F, 0xFF,
]

///|
fn reverse_bits(value : Int, nbits : Int) -> Int {
  // Use byte lookup table: reverse full 16 bits, then shift right
  let lo = kReverseByte[value & 0xFF]
  let hi = kReverseByte[(value >> 8) & 0xFF]
  ((lo << 8) | hi) >> (16 - nbits)
}

///|
/// Emit a Huffman code description in Brotli format.
fn emit_huffman_code(bw : BitWriter, depths : FixedArray[Int], n : Int) -> Unit {
  // Count distinct non-zero symbols
  let symbols : Array[Int] = []
  for i in 0..<n {
    if depths[i] > 0 {
      symbols.push(i)
    }
  }
  if symbols.length() <= 4 {
    emit_simple_huffman_code(bw, symbols, n)
  } else {
    emit_complex_huffman_code(bw, depths, n)
  }
}

///|
/// Emit a simple Huffman code with 1-4 symbols.
fn emit_simple_huffman_code(
  bw : BitWriter,
  symbols : Array[Int],
  alphabet_size : Int,
) -> Unit {
  // HSKIP = 1 (simple code)
  bw.write_bits(2, 1)
  let nsym = symbols.length()
  // NSYM - 1
  bw.write_bits(2, nsym - 1)
  // Compute max_bits for symbol encoding
  let mut max_bits = 0
  let mut tmp = alphabet_size - 1
  while tmp > 0 {
    max_bits += 1
    tmp = tmp >> 1
  }
  if max_bits < 1 {
    max_bits = 1
  }
  // Sort symbols for canonical ordering
  let sorted : Array[Int] = []
  for i in 0..<symbols.length() {
    sorted.push(symbols[i])
  }
  sorted.sort_by(fn(a, b) { a.compare(b) })
  // Write symbols
  for i in 0..<nsym {
    bw.write_bits(max_bits, sorted[i])
  }
  // For 4 symbols, write tree shape bit
  if nsym == 4 {
    bw.write_bits(1, 0)
  }
}

///|
/// RLE entry for code-length sequence.
priv struct RleEntry {
  sym : Int
  extra : Int
  nbits : Int
}

///|
/// Build RLE-encoded code-length sequence using repeat codes 16 and 17.
/// Uses pre-allocated FixedArray instead of 3 dynamic Arrays.
fn build_rle_code_lengths(
  depths : FixedArray[Int],
  n : Int,
) -> (FixedArray[RleEntry], Int) {
  // Max output: each symbol produces at most 2 entries (chain-break + RLE)
  let max_entries = n * 2
  let entries : FixedArray[RleEntry] = FixedArray::make(max_entries, {
    sym: 0,
    extra: 0,
    nbits: 0,
  })
  let mut len = 0
  let mut i = 0
  while i < n {
    let d = depths[i]
    if d == 0 {
      let mut run = 1
      while i + run < n && depths[i + run] == 0 {
        run += 1
      }
      let mut first_rle = true
      while run >= 3 {
        if !first_rle {
          entries[len] = { sym: 0, extra: 0, nbits: 0 }
          len += 1
          run -= 1
          i += 1
          if run < 3 {
            break
          }
        }
        let repeat = if run > 10 { 10 } else { run }
        entries[len] = { sym: 17, extra: repeat - 3, nbits: 3 }
        len += 1
        run -= repeat
        i += repeat
        first_rle = false
      }
      while run > 0 {
        entries[len] = { sym: 0, extra: 0, nbits: 0 }
        len += 1
        run -= 1
        i += 1
      }
    } else {
      entries[len] = { sym: d, extra: 0, nbits: 0 }
      len += 1
      i += 1
      let mut run = 0
      while i + run < n && depths[i + run] == d {
        run += 1
      }
      let mut first_rle = true
      while run >= 3 {
        if !first_rle {
          entries[len] = { sym: d, extra: 0, nbits: 0 }
          len += 1
          run -= 1
          i += 1
          if run < 3 {
            break
          }
        }
        let repeat = if run > 6 { 6 } else { run }
        entries[len] = { sym: 16, extra: repeat - 3, nbits: 2 }
        len += 1
        run -= repeat
        i += repeat
        first_rle = false
      }
      while run > 0 {
        entries[len] = { sym: d, extra: 0, nbits: 0 }
        len += 1
        run -= 1
        i += 1
      }
    }
  }
  (entries, len)
}

///|
/// Emit a complex Huffman code with code-length codes.
fn emit_complex_huffman_code(
  bw : BitWriter,
  depths : FixedArray[Int],
  n : Int,
) -> Unit {
  // Build RLE-encoded code-length sequence
  let (rle_entries, rle_len) = build_rle_code_lengths(depths, n)
  // Build code-length frequencies from the RLE sequence
  let cl_freq : FixedArray[Int] = FixedArray::make(code_length_codes, 0)
  for i in 0..<rle_len {
    let s = rle_entries[i].sym
    if s < code_length_codes {
      cl_freq[s] += 1
    }
  }
  // Build code-length code lengths
  let cl_depths : FixedArray[Int] = FixedArray::make(code_length_codes, 0)
  let num_cl = count_nonzero(cl_freq, code_length_codes)
  if num_cl <= 1 {
    for i in 0..<code_length_codes {
      if cl_freq[i] > 0 {
        cl_depths[i] = 1
      }
    }
  } else {
    let cl_depths_tmp = build_code_lengths(cl_freq, code_length_codes, 5)
    for i in 0..<code_length_codes {
      cl_depths[i] = cl_depths_tmp[i]
    }
  }
  let cl_codes = canonical_codes(cl_depths, code_length_codes)
  // HSKIP: find how many leading code-length-code-order entries have zero depth
  let mut hskip = 0
  for i in 0..<code_length_codes {
    let idx = kCodeLengthCodeOrder[i]
    if cl_depths[idx] == 0 {
      hskip = i + 1
    } else {
      break
    }
  }
  // HSKIP value 1 means "simple code" to the decoder, so it's not valid
  // for complex codes. Valid HSKIP values for complex codes: 0, 2, 3.
  if hskip == 1 || hskip > 3 {
    hskip = 0
  }
  bw.write_bits(2, hskip)
  // Emit code-length code lengths using the fixed prefix code.
  // Must emit until space reaches 0 or all code_length_codes entries are written.
  let mut space = 32
  for i = hskip; i < code_length_codes; i = i + 1 {
    if space <= 0 {
      break
    }
    let idx = kCodeLengthCodeOrder[i]
    let v = cl_depths[idx]
    emit_code_length_code_length(bw, v)
    if v != 0 {
      space -= 32 >> v
    }
  }
  // Emit RLE-encoded code lengths using the code-length Huffman code.
  // When num_cl <= 1, the decoder's brotli_build_huffman_table sets bits=0
  // for single-symbol codes, meaning it reads 0 bits per symbol.
  if num_cl > 1 {
    let mut cl_space = 32768
    let mut prev_code_len = 0
    for i in 0..<rle_len {
      if cl_space <= 0 {
        break
      }
      let e = rle_entries[i]
      bw.write_bits(cl_depths[e.sym], cl_codes[e.sym])
      if e.nbits > 0 {
        bw.write_bits(e.nbits, e.extra)
      }
      if e.sym < 16 {
        if e.sym > 0 {
          prev_code_len = e.sym
          cl_space -= 32768 >> e.sym
        }
      } else if e.sym == 16 {
        let repeat_count = e.extra + 3
        cl_space -= repeat_count << (15 - prev_code_len)
      }
    }
  }
}

///|
/// Emit a code-length code length value using the fixed prefix code.
/// The fixed code is (from the decoder's lookup table):
///   0 → 00  (2 bits)
///   4 → 01  (2 bits)
///   3 → 10  (2 bits)
///   2 → 011 (3 bits)
///   1 → 0111 (4 bits)
///   5 → 1111 (4 bits)
fn emit_code_length_code_length(bw : BitWriter, value : Int) -> Unit {
  match value {
    0 => bw.write_bits(2, 0) // 00
    4 => bw.write_bits(2, 1) // 01
    3 => bw.write_bits(2, 2) // 10
    2 => bw.write_bits(3, 3) // 011
    1 => bw.write_bits(4, 7) // 0111
    5 => bw.write_bits(4, 15) // 1111
    _ => bw.write_bits(2, 0) // default: 0
  }
}
