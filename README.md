# mizchi/brotli

Brotli decompression library for [MoonBit](https://docs.moonbitlang.com).

## Install

```bash
moon add mizchi/brotli
```

## Usage

```moonbit
fn main {
  let compressed : Bytes = ... // Brotli-compressed data
  let decompressed = @brotli.brotli_decompress!(compressed)
}
```

## API

### `brotli_decompress(data: Bytes) -> Bytes raise BrotliError`

Decompresses Brotli-encoded bytes. Raises `BrotliError` on invalid input.

## Development

```bash
just           # check + test
just fmt       # format code
just check     # type check
just test      # run tests
```

## License

Apache-2.0
