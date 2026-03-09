///|
priv struct BitWriter {
  mut buf : FixedArray[Byte]
  mut size : Int
  mut pos : Int
  mut bits : Int
  mut nbits : Int
}

///|
fn BitWriter::new(capacity : Int) -> BitWriter {
  {
    buf: FixedArray::make(capacity, b'\x00'),
    size: capacity,
    pos: 0,
    bits: 0,
    nbits: 0,
  }
}

///|
fn BitWriter::ensure_capacity(self : BitWriter, needed : Int) -> Unit {
  if self.pos + needed >= self.size {
    let new_size = (self.pos + needed) * 2
    let new_buf : FixedArray[Byte] = FixedArray::make(new_size, b'\x00')
    for i in 0..<self.pos {
      new_buf[i] = self.buf[i]
    }
    self.buf = new_buf
    self.size = new_size
  }
}

///|
fn BitWriter::write_bits(self : BitWriter, nbits : Int, value : Int) -> Unit {
  self.bits = self.bits | (value << self.nbits)
  self.nbits += nbits
  while self.nbits >= 8 {
    self.ensure_capacity(1)
    self.buf[self.pos] = (self.bits & 0xff).to_byte()
    self.pos += 1
    self.bits = self.bits >> 8
    self.nbits -= 8
  }
}

///|
fn BitWriter::write_byte(self : BitWriter, b : Int) -> Unit {
  self.write_bits(8, b & 0xff)
}

///|
fn BitWriter::align_byte(self : BitWriter) -> Unit {
  if self.nbits > 0 {
    self.ensure_capacity(1)
    self.buf[self.pos] = (self.bits & 0xff).to_byte()
    self.pos += 1
    self.bits = 0
    self.nbits = 0
  }
}

///|
fn BitWriter::finish(self : BitWriter) -> Bytes {
  self.align_byte()
  Bytes::makei(self.pos, fn(i) { self.buf[i] })
}
