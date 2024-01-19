package toml

import "core:time"
import "core:fmt"
import "core:strings"
import "core:math"
import "core:strconv"
import "core:testing"
import "core:time/standards"

@(test)
test_parse :: proc(t: ^testing.T) {
	r: strings.Reader
	p: Parser
	p.tokenizer.r = strings.to_reader(&r, `foo=1`)

	res, err := parse(&p)
	fmt.println(res, err)
}

Parser :: struct {
	tokenizer: Tokenizer,
	root:      Value,
}

Datetime_Offset :: struct {
	base:   time.Time,     // UTC.
	offset: time.Duration, // Timezone offset.
}

Datetime_Local :: distinct time.Time // Date+Time without timezone.
Date_Local     :: distinct time.Time // Date without timezone.
Time_Local     :: distinct time.Time // Time without timezone.

Value :: union {
	string,
	i64,
	f64,
	bool,
	Datetime_Offset,
	Datetime_Local,
	Date_Local,
	Time_Local,
	[]Value,
	^Object, // Pointer to not bloat the union.
}

Object :: distinct map[string]Value

parse :: proc(p: ^Parser) -> (toml: Object, err: Tokenizer_Error) {
	#partial switch root in p.root {
	case ^Object:
	case nil:
		p.root = new(Object) or_return
	case:
		fmt.panicf("Can't parse into type %T", p.root)
	}

	defer toml = p.root.(^Object)^

	for {
		token: Token
		token, err = next_token(&p.tokenizer)
		if err != nil {
			if err == .EOF {
				err = nil
			}
			return
		}

		#partial switch token.kind {
		case .Line_Break, .Comment: continue
		case .Left_Bracket:
			if err = parse_table(p, token, p.root.(^Object)); err != nil {
				if err == .EOF {
					err = .Unexpected_EOF
				}
				return 
			}
		case:
			if err = parse_global_keyval(p, token); err != nil {
				if err == .EOF {
					err = .Unexpected_EOF
				}
				return
			}
		}
	}
}

parse_table :: proc(p: ^Parser, token: Token, out: ^Object) -> Tokenizer_Error {
	token := token
	assert(token.kind == .Left_Bracket)

	token = next_token(&p.tokenizer) or_return
	if token.kind == .Left_Bracket {
		// TODO: this can also be a double bracket for the weird array stuff.
		panic("unimplemented: parse array of tables")
	}

	target := parse_key(p, token) or_return

	obj := new(Object) or_return
	target^ = obj

	root := p.root
	p.root = target^
	defer p.root = root

	parse(p) or_return

	return nil
}

parse_inline_table :: proc(p: ^Parser, token: Token, out: ^Object) -> Tokenizer_Error {
	token := token
	assert(token.kind == .Left_Brace)

	root := p.root
	p.root = out
	defer p.root = root

	token = next_token(&p.tokenizer) or_return
	entries_loop: for {
		parse_keyval(p, token) or_return

		token = next_token(&p.tokenizer) or_return
		#partial switch token.kind {
		case .Comma:       continue
		case .Right_Brace: break entries_loop
		}
	}
	return nil
}

parse_array :: proc(p: ^Parser, token: Token) -> (result: []Value, err: Tokenizer_Error) {
	token := token
	assert(token.kind == .Left_Bracket)
	
	vals: [dynamic]Value

	values_loop: for {
		for {
			token = next_token(&p.tokenizer) or_return
			#partial switch token.kind {
			case .Line_Break, .Comment, .Comma: continue
			case .Right_Bracket:                break values_loop
			}
			break
		}

		val := parse_value(p, token) or_return
		append(&vals, val)           or_return
	}

	return vals[:], nil
}

parse_key :: proc(p: ^Parser, token: Token) -> (target: ^Value, err: Tokenizer_Error) {
	target = &p.root

	token := token
	key_loop: for {
		#partial switch token.kind {
		case .String:
			token.value = parse_string(p, token) or_return
			fallthrough
		case .Bare, .Date_Local, .Integer:
			#partial switch tval in target {
			case nil:
				obj     := new(Object)
				target^ = obj
				obj[strings.clone(token.value)] = {}
			case ^Object:
				key := token.value
				if token.value not_in tval {
					key = strings.clone(key)
					tval[key] = {}
				}
				target = &tval[key]
			case:
				fmt.panicf("invalid type %T for target", target)
			}

		case .Float:
			// NOTE: + is the only character legal in floats that isn't legal in a key.
			if strings.contains_rune(token.value, '+') {
				return nil, .Invalid_Key
			}

			v := token.value
			for key in strings.split_iterator(&v, ".") {
				key := key
				#partial switch tval in target {
				case nil:
					obj     := new(Object)
					target^  = obj
					obj[strings.clone(key)] = {}
				case ^Object:
					if key not_in tval {
						key = strings.clone(key)
						tval[key] = {}
					}
					target = &tval[key]
				case:
					fmt.panicf("invalid type %T for target", target)
				}
			}
		case:
			fmt.panicf("invalid token %v, expected bare, string, date local, integer or float", token)
		}

		next := next_token(&p.tokenizer) or_return
		#partial switch next.kind {
		case .Dot:    continue key_loop
		case .Equals: break key_loop
		case:         fmt.panicf("invalid token %v, expected dot or equals", next)
		}
	}
}

parse_keyval :: proc(p: ^Parser, token: Token) -> Tokenizer_Error {
	token := token

	target  := parse_key(p, token) or_return
	token    = next_token(&p.tokenizer) or_return
	val     := parse_value(p, token) or_return
	target^  = val

	return nil
}

parse_global_keyval :: proc(p: ^Parser, token: Token) -> Tokenizer_Error {
	parse_keyval(p, token) or_return
	expect_token_or_eof(p, .Line_Break) or_return
	return nil
}

parse_value :: proc(p: ^Parser, token: Token) -> (val: Value, err: Tokenizer_Error) {
	#partial switch token.kind {
	case .Left_Brace:
		obj := new(Object)
		parse_inline_table(p, token, obj) or_return
		return obj, nil
	case .String:
		str := parse_string(p, token) or_return
		val  = strings.clone(str)     or_return
		return
	case .Left_Bracket:    return parse_array(p, token)
	case .Bool:            val = parse_bool(p, token); return
	case .Date_Local:      return parse_date_local(p, token)
	case .Datetime_Local:  return parse_datetime_local(p, token)
	case .Datetime_Offset: return parse_datetime_offset(p, token)
	case .Time_Local:      return parse_time_local(p, token)
	case .Float:           val = parse_float(p, token); return
	case .Infinity:        val = parse_infinity(p, token); return
	case .NaN:             val = parse_nan(p, token); return
	case .Integer:         val = parse_int(p, token); return
	case:                  fmt.panicf("invalid token %v, expected string, bool, left bracket, left brace, date local, datetime local, datetime offset, time local, float, infinity, nan or integer", token)
	}
}

// TODO: not fully compliant.
parse_string :: proc(p: ^Parser, token: Token) -> (str: string, err: Tokenizer_Error) {
	assert(token.kind == .String)
	str = token.value
	switch str[0] {
	case '\'':
		if strings.has_prefix(str, `'''`) {
			str = strings.trim_prefix(str, `'''`)
			str = strings.trim_suffix(str, `'''`)
		} else {
			str = strings.trim_prefix(str, `'`)
			str = strings.trim_suffix(str, `'`)
		}
	case '"':
		if strings.has_prefix(str, `"""`) {
			str = strings.trim_prefix(str, `"""`)
			str = strings.trim_suffix(str, `"""`)
		} else {
			str = strings.trim_prefix(str, `"`)
			str = strings.trim_suffix(str, `"`)
		}
	}
	return
}

parse_datetime_local :: proc(p: ^Parser, token: Token) -> (Datetime_Local, Tokenizer_Error) {
	assert(token.kind == .Datetime_Local)

	dt, off, ok := standards.rfc3339_parse(token.value)
	if !ok { return {}, .Invalid_Datetime }
	assert(off == nil)

	return Datetime_Local(dt), nil
}

parse_datetime_offset :: proc(p: ^Parser, token: Token) -> (dt: Datetime_Offset, err: Tokenizer_Error) {
	assert(token.kind == .Datetime_Offset)

	base, off, ok := standards.rfc3339_parse(token.value)
	if !ok { return {}, .Invalid_Datetime }

	dt.base   = base
	dt.offset = off.?
	return
}

parse_date_local :: proc(p: ^Parser, token: Token) -> (Date_Local, Tokenizer_Error) {
	assert(token.kind == .Date_Local)

	base, off, ok := standards.rfc3339_parse(token.value)
	if !ok { return {}, .Invalid_Datetime }
	assert(off == nil)

	return Date_Local(base), nil
}

parse_time_local :: proc(p: ^Parser, token: Token) -> (Time_Local, Tokenizer_Error) {
	assert(token.kind == .Time_Local)

	base, off, ok := standards.rfc3339_parse(token.value)
	if !ok { return {}, .Invalid_Datetime }
	assert(off == nil)

	return Time_Local(base), nil
}

parse_bool :: proc(p: ^Parser, token: Token) -> bool {
	assert(token.kind == .Bool)
	assert(token.value == "true" || token.value == "false") // Guaranteed by tokenizer.

	return token.value == "true"
}

parse_infinity :: proc(p: ^Parser, token: Token) -> f64 {
	assert(token.kind == .Infinity)
	assert(token.value == "inf" || token.value == "-inf" || token.value == "+inf") // Guaranteed by tokenizer.

	sign := -1 if token.value[0] == '-' else 1
	return math.inf_f64(sign)
}

parse_nan :: proc(p: ^Parser, token: Token) -> f64 {
	assert(token.kind == .NaN)
	assert(token.value == "nan" || token.value == "-nan" || token.value == "+nan") // Guaranteed by tokenizer.

	// NOTE: TOML seems to suggest NaN can be signed?
	return math.nan_f64()
}

parse_int :: proc(p: ^Parser, token: Token) -> i64 {
	assert(token.kind == .Integer)
	// strconv.parse_int seems to parse it exactly according to the TOML spec.
	val, ok := strconv.parse_i64(token.value)
	assert(ok) // Guaranteed by the tokenizer.
	return val
}

parse_float :: proc(p: ^Parser, token: Token) -> f64 {
	assert(token.kind == .Float)
	// strconv.parse_f64 seems to parse it exactly according to the TOML spec.
	// It just has support for more, but the tokenizer has already validated the format.
	val, ok := strconv.parse_f64(token.value)
	assert(ok) // Guaranteed by the tokenizer.
	return val
}

// TODO: nicer error, showing expected and gotten kind.
expect_token_or_eof :: proc(p: ^Parser, kind: Token_Kind) -> (err: Tokenizer_Error) {
	token: Token
	token, err = next_token(&p.tokenizer)
	if err != nil {
		if err == .EOF {
			err = nil
		}
		return
	}
	if token.kind != kind {
		fmt.panicf("invalid token %v, expected %v", token, kind)
	}
	return nil
}
