package toml

import "core:io"
import "core:mem"
import "core:testing"
import "core:unicode/utf8"

Tokenizer_Error :: union #shared_nil {
	mem.Allocator_Error,
	io.Error,
	TOML_Error,
}

Position :: struct {
	offset: int,
	line:   int,
	column: int,
}

Tokenizer :: struct {
	r:       io.Reader,
	pos:     Position,
	buf:     [dynamic]byte,
	buff_i:  int,
	curr:    rune,
	curr_sz: int,
}

Token :: struct {
	using pos: Position,
	value:     string,
	kind:      Token_Kind,
}

TOML_Error :: enum {
	None,
	Unclosed_String,
	Invalid_Number_Base,
	Invalid_Binary_Number,
	Invalid_Decimal_Number,
	Invalid_Hex_Number,
	Invalid_Octal_Number,
	Invalid_Number_Seperator,
	Invalid_Float,
	Invalid_Escape,
	Invalid_Unicode_Escape,
	Invalid_String_Character,
	Invalid_Datetime,

	Invalid_Key,
}

Token_Kind :: enum {
	Invalid,
	Comment,
	Equals,
	Dot,
	Left_Bracket,  // Start of `[table]` or start of an array.
	Right_Bracket, // End of `[table]` or end of an array.
	Comma,
	Left_Brace,  // Start of an inline table `{ hello = "world", "foo" = "bar" }`
	Right_Brace, // End of an inline table.
	Line_Break,  // Line breaks are enforced in certain situations, so making it a token makes sense.

	Infinity, // `inf`, optionally signed.
	NaN,      // `nan`, optionally signed.
	Bool,     // `true` and `false`.

	Datetime_Offset,
	Datetime_Local,
	Time_Local,
	
	Bare,   // Always a key.
	String, // Key if in key position.

	// The following members could be (bare) keys, depending on position in document.
	Date_Local, // `2023-01-00`.
	Float,      // Nested key 1234.1234.
	Integer,    // Digits are valid characters in a key, for example: `1234`, `12_34`, `0xdead`, `0b111` are all valid keys.
}

CURR_EOF :: 0

next_token :: proc(t: ^Tokenizer) -> (token: Token, err: Tokenizer_Error) {
	// Remove previous token.
	remove_range(&t.buf, 0, t.buff_i)
	t.buff_i = 0
	
	// Skip space and newlines, set start of token to the buffer index.
	skip_space(t, skip_newlines=false) or_return
	start := t.buff_i

	token.pos = t.pos

	switch t.curr {
	case CURR_EOF:
		return {}, .EOF

	case '=':
		token.kind = .Equals
		err = advance_rune(t)

	case '.':
		token.kind = .Dot
		err = advance_rune(t)
	
	case '[':
		token.kind = .Left_Bracket
		err = advance_rune(t)

	case ']':
		token.kind = .Right_Bracket
		_, err = eof_ok(advance_rune(t))

	case '{':
		token.kind = .Left_Brace
		err = advance_rune(t)

	case '}':
		token.kind = .Right_Brace
		_, err = eof_ok(advance_rune(t))

	case ',':
		token.kind = .Comma
		err = advance_rune(t)

	case '#':
		token.kind = .Comment
		_, err = eof_ok(read_comment(t))

	case '"':
		token.kind = .String
		err = read_quoted_string(t)

	case '\'':
		token.kind = .String
		err = read_literal_string(t)
	
	case '\r':
		token.kind = .Line_Break
		err = advance_rune(t)
		assert(t.curr == '\n') // We only ever get here when this is the case.
		if err == nil {
			_, err = eof_ok(advance_rune(t))
		}
	
	case '\n':
		token.kind = .Line_Break
		_, err = eof_ok(advance_rune(t))

	case '0'..='9':
		prev_i    := t.buff_i
		prev_curr := t.curr
		prev_size := t.curr_sz
		prev_pos  := t.pos

		token.kind, err = read_datetime(t)

		// Reset to before trying to parse the datetime, then try parsing as number.
		if _, toml_err := err.(TOML_Error); toml_err {
			t.buff_i  = prev_i
			t.curr    = prev_curr
			t.curr_sz = prev_size
			t.pos     = prev_pos

			token.kind, err = read_number(t)
		}

	case '-', '+':
		token.kind, err = read_number(t)

	case:
		prev_i    := t.buff_i
		prev_curr := t.curr
		prev_size := t.curr_sz
		prev_pos  := t.pos

		ok: bool
		if ok, err = read_bare(t); ok || err != nil {
			token.kind = .Bare
			break
		}

		t.buff_i  = prev_i
		t.curr    = prev_curr
		t.curr_sz = prev_size
		t.pos     = prev_pos

		if ok, err = try_read(t, 't', 'r', 'u', 'e'); ok || err != nil {
			token.kind = .Bool
			break
		}

		if ok, err = try_read(t, 'f', 'a', 'l', 's', 'e'); ok || err != nil {
			token.kind = .Bool
			break
		}

		if ok, err = try_read(t, 'i', 'n', 'f'); ok || err != nil {
			token.kind = .Infinity
			break
		}

		if ok, err = try_read(t, 'n', 'a', 'n'); ok || err != nil {
			token.kind = .NaN
			break
		}

		for {
			if is_space(t.curr) {
				break
			}

			is_nl, nlerr := is_newline(t)
			if eof_ok(nlerr) or_return {
				break
			}

			if is_nl {
				break
			}

			if eof_ok(advance_rune(t)) or_return {
				break
			}
		}
	}

	token.value = string(t.buf[start:t.buff_i])
	trim_space(&token)
	if err != nil {
		token.kind = .Invalid
	}
	return
}

// Trim whitespace from token value, adding to the token position.
trim_space :: proc(token: ^Token) {
	full_length := len(token.value)
	token.value = strings.trim_left_proc(token.value, is_space)
	left_offset := full_length - len(token.value)
	token.offset += left_offset
	token.column += left_offset
	token.value = strings.trim_right_proc(token.value, is_space)
}

is_space :: proc(r: rune) -> bool {
	return r == '\t' || r == ' '
}

eof_ok :: #force_inline proc(err: Tokenizer_Error) -> (eof: bool, rerr: Tokenizer_Error) {
	if err == .EOF {
		return true, nil
	}
	return false, err
}

eof_is :: #force_inline proc(err: Tokenizer_Error, replacement: Tokenizer_Error) -> Tokenizer_Error {
	if err == .EOF {
		return replacement
	}
	return err
}

// NOTE: only validates format, not if the time values are valid, an hour value of "25" is let through for example.
read_datetime :: proc(t: ^Tokenizer) -> (kind: Token_Kind, err: Tokenizer_Error) {
	assert(t.curr >= '0' && t.curr <= '9')

	eof_is(advance_rune(t), .Invalid_Datetime) or_return
	if t.curr < '0' || t.curr > '9' {
		err = .Invalid_Datetime
		return
	}

	eof_is(advance_rune(t), .Invalid_Datetime) or_return
	switch t.curr {
	case ':':
		kind = .Time_Local
		err = read_local_time(t)
		return
	case '0'..='9':
		kind = .Date_Local
		err = read_full_date(t)
		if err != nil {
			return
		}

		if eof_ok(advance_rune(t)) or_return {
			return
		}

		switch t.curr {
		case 't', 'T':
			if eof_ok(advance_rune(t)) or_return {
				return
			}
			return read_time(t)

		case ' ':
			if eof_ok(advance_rune(t)) or_return {
				return
			}
			
			if t.curr >= '0' && t.curr <= '9' {
				return read_time(t)
			}

			fallthrough

		case:
			// Whitespace is allowed after a value.

			if is_space(t.curr) { return }

			nl, nlerr := is_newline(t)
			if (eof_ok(nlerr) or_return) || nl {
				return
			}

			err = .Invalid_Datetime
			return
		}

	case:
		err = .Invalid_Datetime
		return
	}

	read_digit :: proc(t: ^Tokenizer) -> Tokenizer_Error {
		eof_is(advance_rune(t), .Invalid_Datetime) or_return
		if t.curr < '0' || t.curr > '9' {
			return .Invalid_Datetime
		}
		return nil
	}

	read_char :: proc(t: ^Tokenizer, ch: rune) -> Tokenizer_Error {
		eof_is(advance_rune(t), .Invalid_Datetime) or_return
		if t.curr != ch {
			return .Invalid_Datetime
		}
		return nil
	}
	
	// Current is `:`, need to read 2 digits, `:`, 2 digits and an optional `.` and a digit.
	read_local_time :: proc(t: ^Tokenizer) -> Tokenizer_Error {
		read_digit(t) or_return
		read_digit(t) or_return
		read_char(t, ':') or_return
		read_digit(t) or_return
		read_digit(t) or_return
		
		if eof_ok(advance_rune(t)) or_return {
			return nil
		}

		if t.curr == '.' {
			read_digit(t) or_return
			for {
				if eof_ok(advance_rune(t)) or_return {
					return nil
				}
				switch t.curr {
				case '0'..='9':
				case:
					return nil
				}
			}
		}
		return nil
	}

	// Current is the third digit of the year, need to read a digit, `-`, 2 digits, `-`, 2 digits.
	read_full_date :: proc(t: ^Tokenizer) -> Tokenizer_Error {
		read_digit(t) or_return
		read_char(t, '-') or_return
		read_digit(t) or_return
		read_digit(t) or_return
		read_char(t, '-') or_return
		read_digit(t) or_return
		read_digit(t) or_return
		return nil
	}
	
	// Current is the character after the time delimiter (t, T, space), need to read either
	// partial time, or full time, and return which of the two it was.
	read_time :: proc(t: ^Tokenizer) -> (kind: Token_Kind, err: Tokenizer_Error) {
		if t.curr < '0' || t.curr > '9' {
			err = .Invalid_Datetime
			return
		}
		read_digit(t) or_return
		read_char(t, ':') or_return
		read_local_time(t) or_return
		kind = .Datetime_Local

		switch t.curr {
		case 'Z':
			kind = .Datetime_Offset
			eof_ok(advance_rune(t)) or_return
			return
		case '-', '+':
			kind = .Datetime_Offset
			read_digit(t) or_return
			read_digit(t) or_return
			read_char(t, ':') or_return
			read_digit(t) or_return
			read_digit(t) or_return
			eof_ok(advance_rune(t)) or_return
			return
		}
		return
	}
}

read_number :: proc(t: ^Tokenizer) -> (kind: Token_Kind, err: Tokenizer_Error) {
	switch t.curr {
	case '0':
		if eof_ok(advance_rune(t)) or_return {
			return .Integer, nil
		}

		switch t.curr {
		case 'x': return .Integer, read_number_hex(t)
		case 'o': return .Integer, read_number_octal(t)
		case 'b': return .Integer, read_number_binary(t)
		case:     return nil, .Invalid_Number_Base
		}

	case '+', '-':
		eof_is(advance_rune(t), .Invalid_Number_Seperator) or_return
		if (try_read(t, 'i', 'n', 'f') or_return) {
			kind = .Infinity
			return
		}
		if (try_read(t, 'n', 'a', 'n') or_return) {
			kind = .NaN
			return
		}
		fallthrough
	case:
		read_number_decimal(t, allow_sign=true) or_return
		kind = .Integer

		if t.curr == '.' {
			kind = .Float

			eof_is(advance_rune(t), .Invalid_Float) or_return
			if t.curr == '_' {
				err = .Invalid_Number_Seperator
				return
			}

			read_number_decimal(t, allow_sign=false) or_return
		}

		if t.curr == 'e' || t.curr == 'E' {
			kind = .Float

			eof_is(advance_rune(t), .Invalid_Float) or_return
			if t.curr == '_' {
				err = .Invalid_Number_Seperator
				return
			}

			err = read_number_decimal(t, allow_sign=true)
			return
		}

		return
	}
}

read_number_hex :: proc(t: ^Tokenizer) -> Tokenizer_Error {
	assert(t.curr == 'x')
	return read_number_proc(t, proc(ch: rune) -> bool {
		switch ch {
		case '0'..='9', 'a'..='f', 'A'..='F': return true
		case:                                 return false
		}
	}, .Invalid_Hex_Number)
}

read_number_octal :: proc(t: ^Tokenizer) -> Tokenizer_Error {
	assert(t.curr == 'x')
	return read_number_proc(t, proc(ch: rune) -> bool {
		return ch >= '0' && ch <= '7'
	}, .Invalid_Octal_Number)
}

read_number_binary :: proc(t: ^Tokenizer) -> Tokenizer_Error {
	assert(t.curr == 'b')
	return read_number_proc(t, proc(ch: rune) -> bool {
		return ch == '0' || ch == '1'
	}, .Invalid_Binary_Number)
}

read_number_proc :: proc(t: ^Tokenizer, f: (proc(ch: rune) -> bool), bad_err: Tokenizer_Error) -> Tokenizer_Error {
	eof_is(advance_rune(t), bad_err) or_return
	if t.curr == '_' {
		return .Invalid_Number_Seperator
	}

	part_loop: for {
		if t.curr != '_' {
			if !f(t.curr) {
				break part_loop
			}
		}
		
		// Break if EOF.
		if eof_ok(advance_rune(t)) or_return {
			break
		}
	}

	if t.curr == '_' {
		return .Invalid_Number_Seperator
	}
	return nil
}

read_number_decimal :: proc(t: ^Tokenizer, allow_sign: bool) -> (err: Tokenizer_Error) {
	if allow_sign && (t.curr == '-' || t.curr == '+') {
		eof_is(advance_rune(t), .Invalid_Decimal_Number) or_return
		if t.curr == '_' {
			return .Invalid_Number_Seperator
		}
	}

	digits_loop: for {
		switch t.curr {
		case '0'..='9', '_':
		case: break digits_loop
		}
		
		// Break if EOF.
		if eof_ok(advance_rune(t)) or_return {
			break
		}
	}

	if t.curr == '_' {
		return .Invalid_Number_Seperator
	}
	return
}

read_comment :: proc(t: ^Tokenizer) -> (err: Tokenizer_Error) {
	for {
		advance_rune(t) or_return

		if (is_newline(t) or_return) {
			return nil
		}
	}
}

read_bare :: proc(t: ^Tokenizer) -> (ok: bool, err: Tokenizer_Error) {
	for i := 0; ; i += 1 {
		switch t.curr {
		case 'a'..='z', 'A'..='Z', '0'..='9', '_', '-':
		case '=', '.', ']':
			if i == 0 {
				return false, nil
			}
			return true, nil
		case:
			if is_space(t.curr) {
				if (eof_ok(skip_space(t, skip_newlines=false)) or_return) {
					return true, nil
				}
				switch t.curr {
				case '=', '.', ']':
					return true, nil
				}
			}
			return false, nil
		}
		if eof_ok(advance_rune(t)) or_return {
			return false, nil
		}
	}
}

read_literal_string :: proc(t: ^Tokenizer) -> (err: Tokenizer_Error) {
	assert(t.curr == '\'')
	
	multiline := try_read(t, '\'', '\'')      or_return
	eof_is(advance_rune(t), .Unclosed_String) or_return

	for {
		switch t.curr {
		case 0x09, 0x20..=0x26, 0x28..=0x7E, 0x80..=0xD7FF, 0xE000..=0x10FFFF:
		case '\'':
			if multiline {
				is_closing := try_read(t, '\'', '\'', '\'') or_return
				if is_closing {
					return nil
				}
			} else {
				eof_ok(advance_rune(t)) or_return
				return nil
			}
		case:
			return .Invalid_String_Character
		}
		eof_is(advance_rune(t), .Unclosed_String) or_return
	}
}

read_quoted_string :: proc(t: ^Tokenizer) -> (err: Tokenizer_Error) {
	assert(t.curr == '"')

	multiline := try_read(t, '"', '"')        or_return
	eof_is(advance_rune(t), .Unclosed_String) or_return

	for {
		switch t.curr {
		case ' ', '\t', 0x21, 0x23..=0x5B, 0x5D..=0x7E, 0x80..=0xD7FF, 0xE000..=0x10FFFF:
		case 0x24:
		case '\\':
			eof_is(advance_rune(t), .Unclosed_String) or_return
			switch t.curr {
			case '"', '\\', 'b', 'f', 'n', 'r', 't':
			case 'u':
				for _ in 0..<4 {
					eof_is(advance_rune(t), .Invalid_Unicode_Escape) or_return
					switch t.curr {
					case '0'..='9', 'A'..='F':
					case:
						return .Invalid_Unicode_Escape
					}
				}
			case 'U':
				for _ in 0..<8 {
					eof_is(advance_rune(t), .Invalid_Unicode_Escape) or_return
					switch t.curr {
					case '0'..='9', 'A'..='F':
					case:
						return .Invalid_Unicode_Escape
					}
				}
			case:
				if !multiline {
					return .Invalid_Escape
				}

				// ABNF: escape ws newline *( wschar / newline )

				if is_space(t.curr) {
					eof_is(skip_space(t, skip_newlines=false), .Invalid_Escape) or_return
				}

				nl, err := is_newline(t)
				eof_is(err, .Unclosed_String) or_return

				if !nl {
					return .Invalid_Escape
				}
			}
		case '"':
			if multiline {
				is_closing := try_read(t, '"', '"', '"') or_return
				if is_closing {
					return nil
				}
			} else {
				eof_ok(advance_rune(t)) or_return
				return nil
			}
		case:
			return .Invalid_String_Character
		}
		eof_is(advance_rune(t), .Unclosed_String) or_return
	}
}

skip_space :: proc(t: ^Tokenizer, skip_newlines: bool) -> Tokenizer_Error {
	for {
		switch {
		case t.curr == 0:
		case is_space(t.curr):
		case (is_newline(t) or_return) && skip_newlines:
		case:
			return nil
		}

		advance_rune(t) or_return
	}
}

is_newline :: proc(t: ^Tokenizer) -> (is_newline: bool, err: Tokenizer_Error) {
	switch t.curr {
	case '\n': is_newline = true
	case '\r':
		peeked := peek_rune(t) or_return
		is_newline = peeked == '\n'
	}
	return
}

advance_rune :: proc(t: ^Tokenizer) -> (err: Tokenizer_Error) {
	t.buff_i     += t.curr_sz
	t.pos.offset += t.curr_sz
	t.pos.column += min(t.curr_sz, 1)

	if t.curr == '\n' {
		t.pos.line  += 1
		t.pos.column = 0
	}

	defer {
		if err == .EOF {
			t.buf[t.buff_i] = CURR_EOF
			t.curr          = CURR_EOF
		}
	}

	if t.buff_i >= len(t.buf) {
		resize(&t.buf, t.buff_i+1)              or_return
		io.read_full(t.r, t.buf[t.buff_i:][:1]) or_return
	}

	s0 := t.buf[t.buff_i]
	t.curr = rune(s0)
	t.curr_sz = 1
	
	// buffered eof.
	if t.curr == CURR_EOF {
		return .EOF
	}

	if t.curr < utf8.RUNE_SELF {
		return nil
	}
	x := utf8.accept_sizes[s0]
	if x >= 0xf0 {
		mask := rune(x) << 31 >> 31
		t.curr = t.curr &~ mask | utf8.RUNE_ERROR&mask
		return nil
	}
	sz := int(x&7)
	new_buff_i := t.buff_i + sz
	if new_buff_i > len(t.buf) {
		resize(&t.buf, new_buff_i)                   or_return
		io.read_full(t.r, t.buf[t.buff_i+1:][:sz-1]) or_return
	}

	t.curr, t.curr_sz = utf8.decode_rune(t.buf[t.buff_i:])
	return nil
}

try_read :: proc(t: ^Tokenizer, runes: ..rune) -> (ok: bool, err: Tokenizer_Error) {
	prev_i    := t.buff_i
	prev_curr := t.curr
	prev_size := t.curr_sz
	prev_pos  := t.pos
	
	defer {
		if !ok {
			t.buff_i  = prev_i
			t.curr    = prev_curr
			t.curr_sz = prev_size
			t.pos     = prev_pos
		}
	}

	for r, i in runes {
		if t.curr != r {
			return
		}

		// Return when EOF, but don't set err to it, because we are peeking.
		if eof_ok(advance_rune(t)) or_return {
			return i == len(runes)-1, nil
		}

	}

	return true, nil
}

peek_rune :: proc(t: ^Tokenizer) -> (ch: rune, err: Tokenizer_Error) {
	prev_i    := t.buff_i
	prev_curr := t.curr
	prev_size := t.curr_sz
	prev_pos  := t.pos

	advance_rune(t) or_return
	ch = t.curr
	
	t.buff_i  = prev_i
	t.curr    = prev_curr
	t.curr_sz = prev_size
	t.pos     = prev_pos
	return
}

import "core:strings"

@(test)
test_next :: proc(t: ^testing.T) {
	r: strings.Reader

	make_tokenizer :: proc() -> Tokenizer {
		return Tokenizer{}
	}

	{
		tok := make_tokenizer()
		tok.r = strings.to_reader(&r, "# Hello World")
		token, err := next_token(&tok)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, token, Token{
			offset = 0,
			line   = 0,
			column = 0,
			value  = "# Hello World",
			kind   = .Comment,
		})

		_, err = next_token(&tok)
		testing.expect_value(t, err, io.Error.EOF)
	}
}

@(test)
test_spec :: proc(t: ^testing.T) {
	expect_tokens :: proc(t: ^testing.T, tok: ^Tokenizer, tokens: ..Token, loc := #caller_location) {
		for token in tokens {
			token := token
			result, err := next_token(tok)
			testing.expect_value(t, err, nil, loc)
			if token.offset == -1 {
				token.offset = 0
				result.pos = {}
			}
			testing.expect_value(t, result, token, loc)
		}
	}

	r: strings.Reader
	{
		tok: Tokenizer
		tok.r = strings.to_reader(&r, `
1979-05-27T07:32:00Z
1979-05-27T00:32:00-07:00
1979-05-27T00:32:00.999999-07:00
1979-05-27 07:32:00Z
1979-05-27T07:32:00
1979-05-27T00:32:00.999999
1979-05-27
07:32:00
00:32:00.999999
`)

		expect_tokens(
			t,
			&tok,
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "1979-05-27T07:32:00Z",
				kind   = .Datetime_Offset,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "1979-05-27T00:32:00-07:00",
				kind   = .Datetime_Offset,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "1979-05-27T00:32:00.999999-07:00",
				kind   = .Datetime_Offset,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "1979-05-27 07:32:00Z",
				kind   = .Datetime_Offset,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "1979-05-27T07:32:00",
				kind   = .Datetime_Local,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "1979-05-27T00:32:00.999999",
				kind   = .Datetime_Local,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "1979-05-27",
				kind   = .Date_Local,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "07:32:00",
				kind   = .Time_Local,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "00:32:00.999999",
				kind   = .Time_Local,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
		)

		_, err := next_token(&tok)
		testing.expect_value(t, err, io.Error.EOF)
	}

	{
		tok: Tokenizer
		tok.r = strings.to_reader(&r, `# This is a full-line comment
key = "value"  # This is a comment at the end of a line
another = "# This is not a comment"`)

		expect_tokens(
			t,
			&tok,
			Token{
				value = "# This is a full-line comment",
				kind  = .Comment,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value = "key",
				kind = .Bare,
				offset = 30,
				line   = 1,
			},
			Token{
				value = "=",
				kind = .Equals,
				offset = 30 + 4,
				line   = 1,
				column = 4,
			},
			Token{
				value = `"value"`,
				kind  = .String,
				offset = 30 + 4 + 2,
				line   = 1,
				column = 4 + 2,
			},
			Token{
				value  = "# This is a comment at the end of a line",
				kind   = .Comment,
				offset = 30 + 4 + 2 + 9,
				line   = 1,
				column = 4 + 2 + 9,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value = "another",
				kind  = .Bare,
				offset = 30 + 4 + 2 + 9 + len("# This is a comment at the end of a line") + 1,
				line   = 2,
				column = 0,
			},
			Token{
				value  = "=",
				kind   = .Equals,
				offset = 94,
				line   = 2,
				column = 8,
			},
			Token{
				value  = `"# This is not a comment"`,
				kind   = .String,
				offset = 96,
				line   = 2,
				column = 10,
			},
		)

		_, err := next_token(&tok)
		testing.expect_value(t, err, io.Error.EOF)
	}

	{
		tok: Tokenizer
		tok.r = strings.to_reader(&r, `
bare_key = "value"
bare-key="value"
1234="value"
"127.0.0.1" = "value"
"character encoding" = "value"
"ʎǝʞ" = "value"
'key2' = "value"
'quoted "value"' = "value"
		`)

		expect_tokens(
			t,
			&tok,
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "bare_key",
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = "=",
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"value"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `bare-key`,
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"value"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `1234`,
				kind   = .Integer,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"value"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `"127.0.0.1"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"value"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `"character encoding"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"value"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `"ʎǝʞ"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"value"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `'key2'`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"value"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `'quoted "value"'`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"value"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
		)

		_, err := next_token(&tok)
		testing.expect_value(t, err, io.Error.EOF)
	}

	{
		tok: Tokenizer
		tok.r = strings.to_reader(&r, `
[name]
first = "Tom"
last = "Preston-Werner"

[point]
x = 1
y = 2

[animal]
type.name = "pug"
		`)

		expect_tokens(
			t,
			&tok,
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `[`,
				kind   = .Left_Bracket,
				offset = -1,
			},
			Token{
				value  = `name`,
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = `]`,
				kind   = .Right_Bracket,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `first`,
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"Tom"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `last`,
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"Preston-Werner"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `[`,
				kind   = .Left_Bracket,
				offset = -1,
			},
			Token{
				value  = `point`,
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = `]`,
				kind   = .Right_Bracket,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `x`,
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `1`,
				kind   = .Integer,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `y`,
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `2`,
				kind   = .Integer,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `[`,
				kind   = .Left_Bracket,
				offset = -1,
			},
			Token{
				value  = `animal`,
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = `]`,
				kind   = .Right_Bracket,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
			Token{
				value  = `type`,
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = `.`,
				kind   = .Dot,
				offset = -1,
			},
			Token{
				value  = `name`,
				kind   = .Bare,
				offset = -1,
			},
			Token{
				value  = `=`,
				kind   = .Equals,
				offset = -1,
			},
			Token{
				value  = `"pug"`,
				kind   = .String,
				offset = -1,
			},
			Token{
				value  = "\n",
				kind   = .Line_Break,
				offset = -1,
			},
		)

		_, err := next_token(&tok)
		testing.expect_value(t, err, io.Error.EOF)
	}
}

@(test)
test_advance_rune :: proc(t: ^testing.T) {
	r: strings.Reader

	make_tokenizer :: proc() -> Tokenizer {
		return Tokenizer{}
	}
	
	{
		tok := make_tokenizer()
		tok.r = strings.to_reader(&r, "")
		err := advance_rune(&tok)
		testing.expect_value(t, err, io.Error.EOF)
		testing.expect_value(t, tok.curr, 0)
		testing.expect_value(t, tok.curr, 0)
		testing.expect_value(t, tok.pos.offset, 0)
	}

	{
		tok := make_tokenizer()
		tok.r = strings.to_reader(&r, "TOML")

		err := advance_rune(&tok)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, tok.curr, 'T')

		err = advance_rune(&tok)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, tok.curr, 'O')

		err = advance_rune(&tok)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, tok.curr, 'M')

		err = advance_rune(&tok)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, tok.curr, 'L')

		testing.expect_value(t, tok.buff_i, 3)
		testing.expect_value(t, tok.pos.offset, 3)

		err = advance_rune(&tok)
		testing.expect_value(t, err, io.Error.EOF)

		testing.expect_value(t, tok.buff_i, 4)
		testing.expect_value(t, tok.pos.offset, 4)

		tok.curr_sz = 0
		tok.buff_i  = 0
		tok.buf     = {}
		tok.r = strings.to_reader(&r, "!₨!")

		err = advance_rune(&tok)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, tok.curr, '!')
		testing.expect_value(t, tok.buff_i, 0)
		testing.expect_value(t, tok.curr_sz, 1)
		testing.expect_value(t, tok.pos.offset, 4)

		err = advance_rune(&tok)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, tok.curr, '₨')
		testing.expect_value(t, tok.buff_i, 1)
		testing.expect_value(t, tok.curr_sz, 3)
		testing.expect_value(t, tok.pos.offset, 5)

		err = advance_rune(&tok)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, tok.curr, '!')
		testing.expect_value(t, tok.buff_i, 4)
		testing.expect_value(t, tok.curr_sz, 1)
		testing.expect_value(t, tok.pos.offset, 8)

		err = advance_rune(&tok)
		testing.expect_value(t, err, io.Error.EOF)
	}
}

