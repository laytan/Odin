package encoding_cbor

import "base:intrinsics"
import "base:runtime"

import "core:bytes"
import "core:encoding/endian"
import "core:io"
import "core:slice"
import "core:strings"

Encoder_Flag :: enum {
	// CBOR defines a tag header that also acts as a file/binary header,
	// this way decoders can check the first header of the binary and see if it is CBOR.
	Self_Described_CBOR,

	// Integers are stored in the smallest integer type it fits.
	// This involves checking each int against the max of all its smaller types.
	Deterministic_Int_Size,

	// Floats are stored in the smallest size float type without losing precision.
	// This involves casting each float down to its smaller types and checking if it changed.
	Deterministic_Float_Size,

	// Sort maps by their keys in bytewise lexicographic order of their deterministic encoding.
	// NOTE: In order to do this, all keys of a map have to be pre-computed, sorted, and
	// then written, this involves temporary allocations for the keys and a copy of the map itself.
	Deterministic_Map_Sorting, 
}

Encoder_Flags :: bit_set[Encoder_Flag]

// Flags for fully deterministic output (if you are not using streaming/indeterminate length).
ENCODE_FULLY_DETERMINISTIC :: Encoder_Flags{.Deterministic_Int_Size, .Deterministic_Float_Size, .Deterministic_Map_Sorting}

// Flags for the smallest encoding output.
ENCODE_SMALL :: Encoder_Flags{.Deterministic_Int_Size, .Deterministic_Float_Size}

Encoder :: struct {
	flags:          Encoder_Flags,
	writer:         Buffered_Writer,
	temp_allocator: runtime.Allocator,
}

Decoder_Flag :: enum {
	// Rejects (with an error `.Disallowed_Streaming`) when a streaming CBOR header is encountered.
	Disallow_Streaming,

	// Pre-allocates buffers and containers with the size that was set in the CBOR header.
	// This should only be enabled when you control both ends of the encoding, if you don't,
	// attackers can craft input that causes massive (`max(u64)`) byte allocations for a few bytes of
	// CBOR.
	Trusted_Input,
	
	// Makes the decoder shrink of excess capacity from allocated buffers/containers before returning.
	Shrink_Excess,
}

Decoder_Flags :: bit_set[Decoder_Flag]

Decoder :: struct {
	// The max amount of bytes allowed to pre-allocate when `.Trusted_Input` is not set on the
	// flags.
	max_pre_alloc: int,

	flags:  Decoder_Flags,
	reader: Buffered_Reader,
}

/*
Decodes both deterministic and non-deterministic CBOR into a `Value` variant.

`Text` and `Bytes` can safely be cast to cstrings because of an added 0 byte.

Allocations are done using the given allocator,
*no* allocations are done on the `context.temp_allocator`.

A value can be (fully and recursively) deallocated using the `destroy` proc in this package.

Disable streaming/indeterminate lengths with the `.Disallow_Streaming` flag.

Shrink excess bytes in buffers and containers with the `.Shrink_Excess` flag.

Mark the input as trusted input with the `.Trusted_Input` flag, this turns off the safety feature
of not pre-allocating more than `max_pre_alloc` bytes before reading into the bytes. You should only
do this when you own both sides of the encoding and are sure there can't be malicious bytes used as
an input.
*/
decode_from :: proc {
	decode_from_string,
	decode_from_reader,
	decode_from_decoder,
}
decode :: decode_from

// Decodes the given string as CBOR.
// See docs on the proc group `decode` for more information.
decode_from_string :: proc(s: string, flags: Decoder_Flags = {}, allocator := context.allocator, loc := #caller_location) -> (v: Value, err: Decode_Error) {
	r: strings.Reader
	strings.reader_init(&r, s)
	return decode_from_reader(strings.reader_to_stream(&r), flags, allocator, loc)
}

// Reads a CBOR value from the given reader.
// See docs on the proc group `decode` for more information.
decode_from_reader :: proc(r: io.Reader, flags: Decoder_Flags = {}, allocator := context.allocator, loc := #caller_location) -> (v: Value, err: Decode_Error) {
	return decode_from_decoder(
		Decoder{ DEFAULT_MAX_PRE_ALLOC, flags, Buffered_Reader{r=r} },
		allocator=allocator,
		loc = loc,
	)
}

// Reads a CBOR value from the given decoder.
// See docs on the proc group `decode` for more information.
decode_from_decoder :: proc(d: Decoder, allocator := context.allocator, loc := #caller_location) -> (v: Value, err: Decode_Error) {
	context.allocator = allocator
	
	d := d

	if d.max_pre_alloc <= 0 {
		d.max_pre_alloc = DEFAULT_MAX_PRE_ALLOC
	}

	v, err = _decode_from_decoder(&d, {}, allocator, loc)
	// Normal EOF does not exist here, we try to read the exact amount that is said to be provided.
	if err == .EOF { err = .Unexpected_EOF }
	return
}

_decode_from_decoder :: proc(d: ^Decoder, hdr: Header = Header(0), allocator := context.allocator, loc := #caller_location) -> (v: Value, err: Decode_Error) {
	hdr := hdr
	r := &d.reader
	if hdr == Header(0) { hdr = _decode_header(r) or_return }
	switch hdr {
	case .U8:  return _decode_u8 (r)
	case .U16: return _decode_u16(r)
	case .U32: return _decode_u32(r)
	case .U64: return _decode_u64(r)

	case .Neg_U8:  return Negative_U8 (_decode_u8 (r) or_return), nil
	case .Neg_U16: return Negative_U16(_decode_u16(r) or_return), nil
	case .Neg_U32: return Negative_U32(_decode_u32(r) or_return), nil
	case .Neg_U64: return Negative_U64(_decode_u64(r) or_return), nil

	case .Simple: return _decode_simple(r)

	case .F16: return _decode_f16(r)
	case .F32: return _decode_f32(r)
	case .F64: return _decode_f64(r)

	case .True:  return true, nil
	case .False: return false, nil
	
	case .Nil:       return Nil{}, nil
	case .Undefined: return Undefined{}, nil

	case .Break: return nil, .Break
	}

	maj, add := _header_split(hdr)
	switch maj {
	case .Unsigned: return _decode_tiny_u8(add)
	case .Negative: return Negative_U8(_decode_tiny_u8(add) or_return), nil
	case .Bytes:    return _decode_bytes_ptr(d, add, .Bytes, allocator, loc)
	case .Text:     return _decode_text_ptr(d, add, allocator, loc)
	case .Array:    return _decode_array_ptr(d, add, allocator, loc)
	case .Map:      return _decode_map_ptr(d, add, allocator, loc)
	case .Tag:      return _decode_tag_ptr(d, add, allocator, loc)
	case .Other:    return _decode_tiny_simple(add)
	case:           return nil, .Bad_Major
	}
}

/*
Encodes the CBOR value into a binary CBOR.

Flags can be used to control the output (mainly determinism, which coincidently affects size).

The default flags `ENCODE_SMALL` (`.Deterministic_Int_Size`, `.Deterministic_Float_Size`) will try
to put ints and floats into their smallest possible byte size without losing equality.

Adding the `.Self_Described_CBOR` flag will wrap the value in a tag that lets generic decoders know
the contents are CBOR from just reading the first byte.

Adding the `.Deterministic_Map_Sorting` flag will sort the encoded maps by the byte content of the
encoded key. This flag has a cost on performance and memory efficiency because all keys in a map
have to be precomputed, sorted and only then written to the output.

Empty flags will do nothing extra to the value.

The allocations for the `.Deterministic_Map_Sorting` flag are done using the given temp_allocator.
but are followed by the necessary `delete` and `free` calls if the allocator supports them.
This is helpful when the CBOR size is so big that you don't want to collect all the temporary
allocations until the end.
*/
encode_into :: proc {
	encode_into_bytes,
	encode_into_builder,
	encode_into_writer,
	encode_into_encoder,
}
encode :: encode_into

// Encodes the CBOR value into binary CBOR allocated on the given allocator.
// See the docs on the proc group `encode_into` for more info.
encode_into_bytes :: proc(v: Value, flags := ENCODE_SMALL, allocator := context.allocator, temp_allocator := context.temp_allocator, loc := #caller_location) -> (data: []byte, err: Encode_Error) {
	b := strings.builder_make(allocator, loc) or_return
	encode_into_builder(&b, v, flags, temp_allocator) or_return
	return b.buf[:], nil
}

// Encodes the CBOR value into binary CBOR written to the given builder.
// See the docs on the proc group `encode_into` for more info.
encode_into_builder :: proc(b: ^strings.Builder, v: Value, flags := ENCODE_SMALL, temp_allocator := context.temp_allocator) -> Encode_Error {
	return encode_into_writer(strings.to_stream(b), v, flags, temp_allocator)
}

// Encodes the CBOR value into binary CBOR written to the given writer.
// See the docs on the proc group `encode_into` for more info.
encode_into_writer :: proc(w: io.Writer, v: Value, flags := ENCODE_SMALL, temp_allocator := context.temp_allocator) -> Encode_Error {
	return encode_into_encoder(Encoder{flags, Buffered_Writer{w=w}, temp_allocator}, v)
}

// Encodes the CBOR value into binary CBOR written to the given encoder.
// See the docs on the proc group `encode_into` for more info.
encode_into_encoder :: proc(e: Encoder, v: Value) -> Encode_Error {
	e := e

	defer flush(&e.writer)

	if e.temp_allocator.procedure == nil {
		e.temp_allocator = context.temp_allocator
	}

	if .Self_Described_CBOR in e.flags {
		_encode_u64(&e, TAG_SELF_DESCRIBED_CBOR, .Tag) or_return
		e.flags -= { .Self_Described_CBOR }
	}

	return encode_value(&e, v)
}

encode_value :: proc(e: ^Encoder, v: Value) -> Encode_Error {
	switch v_spec in v {
	case u8:           return _encode_u8(&e.writer, v_spec, .Unsigned)
	case u16:          return _encode_u16(e, v_spec, .Unsigned)
	case u32:          return _encode_u32(e, v_spec, .Unsigned)
	case u64:          return _encode_u64(e, v_spec, .Unsigned)
	case Negative_U8:  return _encode_u8(&e.writer, u8(v_spec), .Negative)
	case Negative_U16: return _encode_u16(e, u16(v_spec), .Negative)
	case Negative_U32: return _encode_u32(e, u32(v_spec), .Negative)
	case Negative_U64: return _encode_u64(e, u64(v_spec), .Negative)
	case ^Bytes:       return _encode_bytes(e, v_spec^)
	case ^Text:        return _encode_text(e, v_spec^)
	case ^Array:       return _encode_array(e, v_spec^)
	case ^Map:         return _encode_map(e, v_spec^)
	case ^Tag:         return _encode_tag(e, v_spec^)
	case Simple:       return _encode_simple(&e.writer, v_spec)
	case f16:          return _encode_f16(&e.writer, v_spec)
	case f32:          return _encode_f32(e, v_spec)
	case f64:          return _encode_f64(e, v_spec)
	case bool:         return _encode_bool(&e.writer, v_spec)
	case Nil:          return _encode_nil(&e.writer)
	case Undefined:    return _encode_undefined(&e.writer)
	case:              return nil
	}
}

_decode_header :: proc(r: ^Buffered_Reader) -> (hdr: Header, err: io.Error) {
	hdr = Header(_decode_u8(r) or_return)
	return
}

_header_split :: proc(hdr: Header) -> (Major, Add) {
	return Major(u8(hdr) >> 5), Add(u8(hdr) & 0x1f)
}

_decode_u8 :: proc(r: ^Buffered_Reader) -> (v: u8, err: io.Error) #no_bounds_check {
	return (read_n(r, 1) or_return)[0], nil
}

_encode_uint :: proc {
	_encode_u8,
	_encode_u16,
	_encode_u32,
	_encode_u64,
}

_encode_u8 :: proc(w: ^Buffered_Writer, v: u8, major: Major = .Unsigned) -> (err: io.Error) {
	header := u8(major) << 5
	if v < u8(Add.One_Byte) {
		header |= v
		return write_full(w, {header})
	}

	header |= u8(Add.One_Byte)
	return write_full(w, {header, v})
}

_decode_tiny_u8 :: proc(additional: Add) -> (u8, Decode_Data_Error) {
	if additional < .One_Byte {
		return u8(additional), nil
	}

	return 0, .Bad_Argument
}

_decode_u16 :: proc(r: ^Buffered_Reader) -> (v: u16, err: io.Error) {
	bytes := read_n(r, size_of(u16)) or_return
	return endian.unchecked_get_u16be(bytes[:]), nil
}

_encode_u16 :: proc(e: ^Encoder, v: u16, major: Major = .Unsigned) -> Encode_Error {
	if .Deterministic_Int_Size in e.flags {
		return _encode_deterministic_uint(&e.writer, v, major)
	}
	return _encode_u16_exact(&e.writer, v, major)
}

_encode_u16_exact :: proc(w: ^Buffered_Writer, v: u16, major: Major = .Unsigned) -> (err: io.Error) #no_bounds_check {
	bytes := write_n(w, 1+size_of(u16)) or_return
	bytes[0] = (u8(major) << 5) | u8(Add.Two_Bytes)
	endian.unchecked_put_u16be(bytes[1:], v)
	return
}

_decode_u32 :: proc(r: ^Buffered_Reader) -> (v: u32, err: io.Error) {
	bytes := read_n(r, size_of(u32)) or_return
	return endian.unchecked_get_u32be(bytes[:]), nil
}

_encode_u32 :: proc(e: ^Encoder, v: u32, major: Major = .Unsigned) -> Encode_Error {
	if .Deterministic_Int_Size in e.flags {
		return _encode_deterministic_uint(&e.writer, v, major)
	}
	return _encode_u32_exact(&e.writer, v, major)
}

_encode_u32_exact :: proc(w: ^Buffered_Writer, v: u32, major: Major = .Unsigned) -> (err: io.Error) #no_bounds_check {
	bytes := write_n(w, 1+size_of(u32)) or_return
	bytes[0] = (u8(major) << 5) | u8(Add.Four_Bytes)
	endian.unchecked_put_u32be(bytes[1:], v)
	return
}

_decode_u64 :: proc(r: ^Buffered_Reader) -> (v: u64, err: io.Error) {
	bytes := read_n(r, size_of(u64)) or_return
	return endian.unchecked_get_u64be(bytes[:]), nil
}

_encode_u64 :: proc(e: ^Encoder, v: u64, major: Major = .Unsigned) -> Encode_Error {
	if .Deterministic_Int_Size in e.flags {
		return _encode_deterministic_uint(&e.writer, v, major)
	}
	return _encode_u64_exact(&e.writer, v, major)
}

_encode_u64_exact :: proc(w: ^Buffered_Writer, v: u64, major: Major = .Unsigned) -> (err: io.Error) #no_bounds_check {
	bytes := write_n(w, 1+size_of(u64)) or_return
	bytes[0] = (u8(major) << 5) | u8(Add.Eight_Bytes)
	endian.unchecked_put_u64be(bytes[1:], v)
	return
}

_decode_bytes_ptr :: proc(d: ^Decoder, add: Add, type: Major = .Bytes, allocator := context.allocator, loc := #caller_location) -> (v: ^Bytes, err: Decode_Error) {
	v = new(Bytes, allocator, loc) or_return
	defer if err != nil { free(v, allocator, loc) }

	v^ = _decode_bytes(d, add, type, allocator, loc) or_return
	return
}

_decode_bytes :: proc(d: ^Decoder, add: Add, type: Major = .Bytes, allocator := context.allocator, loc := #caller_location) -> (v: Bytes, err: Decode_Error) {
	context.allocator = allocator

	add := add
	n, scap := _decode_len_str(d, add) or_return
	
	buf := strings.builder_make(0, scap, allocator, loc) or_return
	defer if err != nil { strings.builder_destroy(&buf) }

	if n == -1 {
		indefinite_loop: for {
			header := _decode_header(&d.reader) or_return
			maj: Major
			maj, add = _header_split(header)
			#partial switch maj {
			case type:
				iter_n, iter_cap := _decode_len_str(d, add) or_return
				if iter_n == -1 {
					return nil, .Nested_Indefinite_Length
				}
				reserve(&buf.buf, len(buf.buf) + iter_cap) or_return
				copy_n(&buf, &d.reader, iter_n) or_return

			case .Other:
				if add != .Break { return nil, .Bad_Argument }
				break indefinite_loop

			case:
				return nil, .Bad_Major
			}
		}
	} else {
		copy_n(&buf, &d.reader, n) or_return
	}

	v = buf.buf[:]

	// Write zero byte so this can be converted to cstring.
	strings.write_byte(&buf, 0)

	if .Shrink_Excess in d.flags { shrink(&buf.buf) }
	return
}

_encode_bytes :: proc(e: ^Encoder, val: Bytes, major: Major = .Bytes) -> (err: Encode_Error) {
	assert(len(val) >= 0)
	_encode_u64(e, u64(len(val)), major) or_return
	return write_full(&e.writer, val[:])
}

_decode_text_ptr :: proc(d: ^Decoder, add: Add, allocator := context.allocator, loc := #caller_location) -> (v: ^Text, err: Decode_Error) {
	v = new(Text, allocator, loc) or_return
	defer if err != nil { free(v) }

	v^ = _decode_text(d, add, allocator, loc) or_return
	return
}

_decode_text :: proc(d: ^Decoder, add: Add, allocator := context.allocator, loc := #caller_location) -> (v: Text, err: Decode_Error) {
	return (Text)(_decode_bytes(d, add, .Text, allocator, loc) or_return), nil
}

_encode_text :: proc(e: ^Encoder, val: Text) -> Encode_Error {
	return _encode_bytes(e, transmute([]byte)val, .Text)
}

_decode_array_ptr :: proc(d: ^Decoder, add: Add, allocator := context.allocator, loc := #caller_location) -> (v: ^Array, err: Decode_Error) {
	v = new(Array, allocator, loc) or_return
	defer if err != nil { free(v) }

	v^ = _decode_array(d, add, allocator, loc) or_return
	return
}

_decode_array :: proc(d: ^Decoder, add: Add, allocator := context.allocator, loc := #caller_location) -> (v: Array, err: Decode_Error) {
	n, scap := _decode_len_container(d, add) or_return
	array := make([dynamic]Value, 0, scap, allocator, loc) or_return
	defer if err != nil {
		for entry in array { destroy(entry, allocator) }
		delete(array, loc)
	}
	
	for i := 0; n == -1 || i < n; i += 1 {
		val, verr := _decode_from_decoder(d, {}, allocator, loc)
		if n == -1 && verr == .Break {
			break
		} else if verr != nil {
			err = verr
			return
		}

		append(&array, val) or_return
	}

	if .Shrink_Excess in d.flags { shrink(&array) }
	
	v = array[:]
	return
}

_encode_array :: proc(e: ^Encoder, arr: Array) -> Encode_Error {
	assert(len(arr) >= 0)
	_encode_u64(e, u64(len(arr)), .Array)
	for val in arr {
		encode_value(e, val) or_return
	}
	return nil
}

_decode_map_ptr :: proc(d: ^Decoder, add: Add, allocator := context.allocator, loc := #caller_location) -> (v: ^Map, err: Decode_Error) {
	v = new(Map, allocator, loc) or_return
	defer if err != nil { free(v) }

	v^ = _decode_map(d, add, allocator, loc) or_return
	return
}

_decode_map :: proc(d: ^Decoder, add: Add, allocator := context.allocator, loc := #caller_location) -> (v: Map, err: Decode_Error) {
	n, scap := _decode_len_container(d, add) or_return
	items := make([dynamic]Map_Entry, 0, scap, allocator, loc) or_return
	defer if err != nil { 
		for entry in items {
			destroy(entry.key)
			destroy(entry.value)
		}
		delete(items, loc)
	}

	for i := 0; n == -1 || i < n; i += 1 {
		key, kerr := _decode_from_decoder(d, {}, allocator, loc)
		if n == -1 && kerr == .Break {
			break
		} else if kerr != nil {
			return nil, kerr
		} 

		value := _decode_from_decoder(d, {}, allocator, loc) or_return

		append(&items, Map_Entry{
			key   = key,
			value = value,
		}, loc) or_return
	}

	if .Shrink_Excess in d.flags { shrink(&items) }
	
	v = items[:]
	return
}

_encode_map :: proc(e: ^Encoder, m: Map) -> (err: Encode_Error) {
	assert(len(m) >= 0)
	_encode_u64(e, u64(len(m)), .Map) or_return
	
	if .Deterministic_Map_Sorting not_in e.flags {
		for entry in m {
			encode_value(e, entry.key)   or_return
			encode_value(e, entry.value) or_return
		}
		return
	}

	// Deterministic_Map_Sorting needs us to sort the entries by the byte contents of the
	// encoded key.
	//
	// This means we have to store and sort them before writing incurring extra (temporary) allocations.

	Map_Entry_With_Key :: struct {
		encoded_key: []byte,
		entry:       Map_Entry,
	}

	entries := make([]Map_Entry_With_Key, len(m), e.temp_allocator) or_return
	defer delete(entries, e.temp_allocator)

	for &entry, i in entries {
		entry.entry = m[i]

		buf := strings.builder_make(e.temp_allocator) or_return
		
		ke := e^
		ke.writer = Buffered_Writer{w=strings.to_stream(&buf)}

		encode_value(&ke, entry.entry.key) or_return
		flush(&ke.writer)
		entry.encoded_key = buf.buf[:]
	}
	
	// Sort lexicographic on the bytes of the key.
	slice.sort_by_cmp(entries, proc(a, b: Map_Entry_With_Key) -> slice.Ordering {
		return slice.Ordering(bytes.compare(a.encoded_key, b.encoded_key))
	})

	for entry in entries {
		write_full(&e.writer, entry.encoded_key) or_return
		delete(entry.encoded_key, e.temp_allocator)

		encode_value(e, entry.entry.value) or_return
	}

	return nil
}

_decode_tag_ptr :: proc(d: ^Decoder, add: Add, allocator := context.allocator, loc := #caller_location) -> (v: Value, err: Decode_Error) {
	tag := _decode_tag(d, add, allocator, loc) or_return
	if t, ok := tag.?; ok {
		defer if err != nil { destroy(t.value) }
		tp := new(Tag, allocator, loc) or_return
		tp^ = t
		return tp, nil
	}

	// no error, no tag, this was the self described CBOR tag, skip it.
	return _decode_from_decoder(d, {}, allocator, loc)
}

_decode_tag :: proc(d: ^Decoder, add: Add, allocator := context.allocator, loc := #caller_location) -> (v: Maybe(Tag), err: Decode_Error) {
	num := _decode_uint_as_u64(&d.reader, add) or_return

	// CBOR can be wrapped in a tag that decoders can use to see/check if the binary data is CBOR.
	// We can ignore it here.
	if num == TAG_SELF_DESCRIBED_CBOR {
		return
	}

	t := Tag{
		number = num,
		value = _decode_from_decoder(d, {}, allocator, loc) or_return,
	}

	if nested, ok := t.value.(^Tag); ok {
		destroy(nested)
		return nil, .Nested_Tag
	}

	return t, nil
}

_decode_uint_as_u64 :: proc(r: ^Buffered_Reader, add: Add) -> (nr: u64, err: Decode_Error) {
	#partial switch add {
	case .One_Byte:    return u64(_decode_u8(r) or_return), nil
	case .Two_Bytes:   return u64(_decode_u16(r) or_return), nil
	case .Four_Bytes:  return u64(_decode_u32(r) or_return), nil
	case .Eight_Bytes: return u64(_decode_u64(r) or_return), nil
	case:              return u64(_decode_tiny_u8(add) or_return), nil
	}
}

_encode_tag :: proc(e: ^Encoder, val: Tag) -> Encode_Error {
	_encode_u64(e, val.number, .Tag) or_return
	return encode_value(e, val.value)
}

_decode_simple :: proc(r: ^Buffered_Reader) -> (v: Simple, err: io.Error) {
	return Simple(_decode_u8(r) or_return), nil
}

_encode_simple :: proc(w: ^Buffered_Writer, v: Simple) -> (err: Encode_Error) {
	header := u8(Major.Other) << 5

	if v < Simple(Add.False) {
		header |= u8(v)
		err = write_full(w, {header})
		return
	} else if v <= Simple(Add.Break) {
		return .Invalid_Simple
	}
	
	header |= u8(Add.One_Byte)
	err = write_full(w, {header, u8(v)})
	return
}

_decode_tiny_simple :: proc(add: Add) -> (Simple, Decode_Data_Error) {
	if add < Add.False {
		return Simple(add), nil
	}
	
	return 0, .Bad_Argument
}

_decode_f16 :: proc(r: ^Buffered_Reader) -> (v: f16, err: io.Error) {
	bytes := read_n(r, size_of(f16)) or_return
	n := endian.unchecked_get_u16be(bytes[:])
	return transmute(f16)n, nil
}

_encode_f16 :: proc(w: ^Buffered_Writer, v: f16) -> (err: io.Error) {
	bytes := write_n(w, 1+size_of(f16)) or_return
	bytes[0] = u8(Header.F16)
	endian.unchecked_put_u16be(bytes[1:], transmute(u16)v)
	return
}

_decode_f32 :: proc(r: ^Buffered_Reader) -> (v: f32, err: io.Error) {
	bytes := read_n(r, size_of(f32)) or_return
	n := endian.unchecked_get_u32be(bytes[:])
	return transmute(f32)n, nil
}

_encode_f32 :: proc(e: ^Encoder, v: f32) -> io.Error {
	if .Deterministic_Float_Size in e.flags {
		return _encode_deterministic_float(&e.writer, v)
	}
	return _encode_f32_exact(&e.writer, v)
}

_encode_f32_exact :: proc(w: ^Buffered_Writer, v: f32) -> (err: io.Error) #no_bounds_check {
	bytes := write_n(w, 1+size_of(f32)) or_return
	bytes[0] = u8(Header.F32)
	endian.unchecked_put_u32be(bytes[1:], transmute(u32)v)
	return
}

_decode_f64 :: proc(r: ^Buffered_Reader) -> (v: f64, err: io.Error) {
	bytes := read_n(r, size_of(f64)) or_return
	n := endian.unchecked_get_u64be(bytes[:])
	return transmute(f64)n, nil
}

_encode_f64 :: proc(e: ^Encoder, v: f64) -> io.Error {
	if .Deterministic_Float_Size in e.flags {
		return _encode_deterministic_float(&e.writer, v)
	}
	return _encode_f64_exact(&e.writer, v)
}

_encode_f64_exact :: proc(w: ^Buffered_Writer, v: f64) -> (err: io.Error) {
	bytes := write_n(w, 1+size_of(f64)) or_return
	bytes[0] = u8(Header.F64)
	endian.unchecked_put_u64be(bytes[1:], transmute(u64)v)
	return
}

_encode_bool :: proc(w: ^Buffered_Writer, v: bool) -> (err: io.Error) {
	switch v {
	case true:  err = write_full(w, {u8(Header.True )}); return
	case false: err = write_full(w, {u8(Header.False)}); return
	case:       unreachable()
	}
}

_encode_undefined :: proc(w: ^Buffered_Writer) -> io.Error {
	return write_full(w, {u8(Header.Undefined)})
}

_encode_nil :: proc(w: ^Buffered_Writer) -> io.Error {
	return write_full(w, {u8(Header.Nil)})
}

// Streaming

encode_stream_begin :: proc(w: ^Buffered_Writer, major: Major) -> (err: io.Error) {
	assert(major >= Major(.Bytes) && major <= Major(.Map), "illegal stream type")

	header := (u8(major) << 5) | u8(Add.Length_Unknown)
	return write_full(w, {header})
}

encode_stream_end :: proc(w: ^Buffered_Writer) -> io.Error {
	header := (u8(Major.Other) << 5) | u8(Add.Break)
	write_full(w, {header}) or_return
	flush(w) or_return
	return nil
}

encode_stream_bytes      :: _encode_bytes
encode_stream_text       :: _encode_text
encode_stream_array_item :: encode_value

encode_stream_map_entry :: proc(e: ^Encoder, key: Value, val: Value) -> Encode_Error {
	encode_value(e, key) or_return
	return encode_value(e, val)
}

// For `Bytes` and `Text` strings: Decodes the number of items the header says follows.
// If the number is not specified -1 is returned and streaming should be initiated.
// A suitable starting capacity is also returned for a buffer that is allocated up the stack.
_decode_len_str :: proc(d: ^Decoder, add: Add) -> (n: int, scap: int, err: Decode_Error) {
	if add == .Length_Unknown {
		if .Disallow_Streaming in d.flags {
			return -1, -1, .Disallowed_Streaming
		}
		return -1, INITIAL_STREAMED_BYTES_CAPACITY, nil
	}

	_n := _decode_uint_as_u64(&d.reader, add) or_return
	if _n > u64(max(int)) { return -1, -1, .Length_Too_Big }
	n = int(_n)

	scap = n + 1 // Space for zero byte.
	if .Trusted_Input not_in d.flags {
		scap = min(d.max_pre_alloc, scap)
	}

	return
}

// For `Array` and `Map` types: Decodes the number of items the header says follows.
// If the number is not specified -1 is returned and streaming should be initiated.
// A suitable starting capacity is also returned for a buffer that is allocated up the stack.
_decode_len_container :: proc(d: ^Decoder, add: Add) -> (n: int, scap: int, err: Decode_Error) {
	if add == .Length_Unknown {
		if .Disallow_Streaming in d.flags {
			return -1, -1, .Disallowed_Streaming
		}
		return -1, INITIAL_STREAMED_CONTAINER_CAPACITY, nil
	}

	_n := _decode_uint_as_u64(&d.reader, add) or_return
	if _n > u64(max(int)) { return -1, -1, .Length_Too_Big }
	n = int(_n)

	scap = n
	if .Trusted_Input not_in d.flags {
		// NOTE: if this is a map it will be twice this.
		scap = min(d.max_pre_alloc / size_of(Value), scap)
	}

	return
}

// Deterministic encoding is (among other things) encoding all values into their smallest
// possible representation.
// See section 4 of RFC 8949.

_encode_deterministic_uint :: proc {
	_encode_u8,
	_encode_deterministic_u16,
	_encode_deterministic_u32,
	_encode_deterministic_u64,
	_encode_deterministic_u128,
}

_encode_deterministic_u16 :: proc(w: ^Buffered_Writer, v: u16, major: Major = .Unsigned) -> Encode_Error {
	switch {
	case v <= u16(max(u8)): return _encode_u8(w, u8(v), major)
	case:                   return _encode_u16_exact(w, v, major)
	}
}

_encode_deterministic_u32 :: proc(w: ^Buffered_Writer, v: u32, major: Major = .Unsigned) -> Encode_Error {
	switch {
	case v <= u32(max(u8)):  return _encode_u8(w, u8(v), major)
	case v <= u32(max(u16)): return _encode_u16_exact(w, u16(v), major)
	case:                    return _encode_u32_exact(w, u32(v), major)
	}
}

_encode_deterministic_u64 :: proc(w: ^Buffered_Writer, v: u64, major: Major = .Unsigned) -> Encode_Error {
	switch {
	case v <= u64(max(u8)):  return _encode_u8(w, u8(v), major)
	case v <= u64(max(u16)): return _encode_u16_exact(w, u16(v), major)
	case v <= u64(max(u32)): return _encode_u32_exact(w, u32(v), major)
	case:                    return _encode_u64_exact(w, u64(v), major)
	}
}

_encode_deterministic_u128 :: proc(w: ^Buffered_Writer, v: u128, major: Major = .Unsigned) -> Encode_Error {
	switch {
	case v <= u128(max(u8)):  return _encode_u8(w, u8(v), major)
	case v <= u128(max(u16)): return _encode_u16_exact(w, u16(v), major)
	case v <= u128(max(u32)): return _encode_u32_exact(w, u32(v), major)
	case v <= u128(max(u64)): return _encode_u64_exact(w, u64(v), major)
	case:                     return .Int_Too_Big
	}
}

_encode_deterministic_negative :: #force_inline proc(w: ^Buffered_Writer, v: $T) -> Encode_Error
	where T == Negative_U8 || T == Negative_U16 || T == Negative_U32 || T == Negative_U64 {
	return _encode_deterministic_uint(w, v, .Negative)
}

// A Deterministic float is a float in the smallest type that stays the same after down casting.
_encode_deterministic_float :: proc {
	_encode_f16,
	_encode_deterministic_f32,
	_encode_deterministic_f64,
}

_encode_deterministic_f32 :: proc(w: ^Buffered_Writer, v: f32) -> io.Error {
	if (f32(f16(v)) == v) {
		return _encode_f16(w, f16(v))
	}

	return _encode_f32_exact(w, v)
}

_encode_deterministic_f64 :: proc(w: ^Buffered_Writer, v: f64) -> io.Error {
	if (f64(f16(v)) == v) {
		return _encode_f16(w, f16(v))
	}

	if (f64(f32(v)) == v) {
		return _encode_f32_exact(w, f32(v))
	}

	return _encode_f64_exact(w, v)
}

// Buffered IO

Buffered_Writer :: struct {
	buf: [1024]byte,
	n:   int,
	w:   io.Writer,
}

write_full :: proc(w: ^Buffered_Writer, bs: []byte) -> (err: io.Error) #no_bounds_check {
	if len(bs) > len(w.buf)-w.n {
		io.write_full(w.w, w.buf[:w.n]) or_return
		w.n = 0
	}

	if len(bs) >= len(w.buf) {
		io.write_full(w.w, bs) or_return
	} else {
		w.n += copy(w.buf[w.n:], bs)
	}
	return
}

write_n :: proc(w: ^Buffered_Writer, n: int) -> (bs: []byte, err: io.Error) #no_bounds_check {
	if n > len(w.buf)-w.n {
		w.n -= io.write_full(w.w, w.buf[:w.n]) or_return
	}

	defer w.n += n
	return w.buf[w.n:][:n], nil
}

flush :: proc(w: ^Buffered_Writer) -> (err: io.Error) #no_bounds_check {
	if w.n == 0 {
		return
	}

	io.write_full(w.w, w.buf[:w.n]) or_return
	w.n = 0
	return
}

Buffered_Reader :: struct {
	buf: [1024]byte,
	off: int,
	n:   int,
	r:   io.Reader,
}

need_at_least :: proc(r: ^Buffered_Reader, n: int) -> (err: io.Error) #no_bounds_check {
	available := r.n - r.off
	if available >= n {
		return
	}

	if r.off > 0 {
		copy(r.buf[:available], r.buf[r.off:r.n])
		r.n = available
		r.off = 0
	}

	to_read := n - available
	n_: int
	n_, err = io.read_at_least(r.r, r.buf[r.n:], to_read)
	assert(err == nil)
	r.n += n_
	return
}

read_n :: proc(r: ^Buffered_Reader, n: int) -> (bytes: []byte, err: io.Error) #no_bounds_check {
	need_at_least(r, n) or_return

	start := r.off
	r.off += n

	if r.off == r.n {
		r.off = 0
		r.n = 0
	}

	return r.buf[start:start+n], nil
}

copy_n :: proc(dst: ^strings.Builder, src: ^Buffered_Reader, n: int) -> (err: io.Error) #no_bounds_check {
	n := n

	available := src.n - src.off
	if available > 0 {
		to_write := min(n, available)
		written  := strings.write_bytes(dst, src.buf[src.off:][:to_write])

		src.off += written
		n -= written

		if src.off == src.n {
			src.off = 0
			src.n   = 0
		}
	}

	for n > 0 {
		bytes := read_n(src, min(n, len(src.buf))) or_return
		n -= strings.write_bytes(dst, bytes)
	}
	return
}
