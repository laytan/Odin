package http

import "core:io"
import "core:strconv"
import "core:strings"
import "core:time"

Cookie_Same_Site :: enum u8 {
	Unspecified,
	None,
	Strict,
	Lax,
}

Cookie :: struct {
	domain:       string,
	path:         string,
	expires_gmt:  time.Time,
	name:         string,
	value:        string,
	max_age_secs: Maybe(int),
	same_site:    Cookie_Same_Site,
	http_only:    bool,
	partitioned:  bool,
	secure:       bool,
}

// Writes the `Set-Cookie` header string representation of the given cookie.
cookie_write :: proc(w: io.Writer, c: Cookie) -> io.Error {
	io.write_string(w, "set-cookie: ") or_return
	write_escaped_newlines(w, c.name)  or_return
	io.write_byte(w, '=')              or_return
	write_escaped_newlines(w, c.value) or_return

	if c.domain != "" {
		io.write_string(w, "; Domain=")     or_return
		write_escaped_newlines(w, c.domain) or_return
	}

	if c.expires_gmt != {} {
		io.write_string(w, "; Expires=") or_return
		date_write(w, c.expires_gmt)     or_return
	}

	if a, ok := c.max_age_secs.(int); ok {
		io.write_string(w, "; Max-Age=") or_return
		io.write_int(w, a)               or_return
	}

	if c.path != "" {
		io.write_string(w, "; Path=")     or_return
		write_escaped_newlines(w, c.path) or_return
	}

	switch c.same_site {
	case .None:   io.write_string(w, "; SameSite=None")   or_return
	case .Lax:    io.write_string(w, "; SameSite=Lax")    or_return
	case .Strict: io.write_string(w, "; SameSite=Strict") or_return
	case .Unspecified: // no-op.
	}

	if c.secure {
		io.write_string(w, "; Secure") or_return
	}

	if c.partitioned {
		io.write_string(w, "; Partitioned") or_return
	}

	if c.http_only {
		io.write_string(w, "; HttpOnly") or_return
	}

	return nil
}

// Parses a `Set-Cookie` header value.
cookie_parse :: proc(value: string) -> (cookie: Cookie, ok: bool) {
	value := value

	eq := strings.index_byte(value, '=')
	if eq < 1 { return }

	cookie.name = value[:eq]
	value = value[eq + 1:]

	semi := strings.index_byte(value, ';')
	switch semi {
	case -1:
		cookie.value = value
		ok = true
		return
	case 0:
		return
	case:
		cookie.value = value[:semi]
		value = value[semi + 1:]
	}

	parse_part :: proc(cookie: ^Cookie, part: string) -> (ok: bool) {
		eq := strings.index_byte(part, '=')
		switch eq {
		case -1:
			switch {
			case ascii_case_insensitive_eq(part, "httponly"):
				cookie.http_only = true
			case ascii_case_insensitive_eq(part, "partitioned"):
				cookie.partitioned = true
			case ascii_case_insensitive_eq(part, "secure"):
				cookie.secure = true
			case:
				return
			}
		case 0:
			return
		case:
			key   := part[:eq]
			value := part[eq + 1:]

			switch {
			case ascii_case_insensitive_eq(key, "domain"):
				cookie.domain = value
			case ascii_case_insensitive_eq(key, "expires"):
				cookie.expires_gmt = cookie_date_parse(value) or_return
			case ascii_case_insensitive_eq(key, "max-age"):
				cookie.max_age_secs = strconv.parse_int(value, 10) or_return
			case ascii_case_insensitive_eq(key, "path"):
				cookie.path = value
			case ascii_case_insensitive_eq(key, "samesite"):
				switch value {
				case "lax", "Lax", "LAX":
					cookie.same_site = .Lax
				case "none", "None", "NONE":
					cookie.same_site = .None
				case "strict", "Strict", "STRICT":
					cookie.same_site = .Strict
				case:
					return
				}
			case:
				return
			}
		}
		return true
	}

	for semi = strings.index_byte(value, ';'); semi != -1; semi = strings.index_byte(value, ';') {
		part := strings.trim_left_space(value[:semi])
		value = value[semi + 1:]
		parse_part(&cookie, part) or_return
	}

	part := strings.trim_left_space(value)
	if part == "" {
		ok = true
		return
	}

	parse_part(&cookie, part) or_return
	ok = true
	return
}

/*
Implementation of the algorithm described in RFC 6265 section 5.1.1.
*/
cookie_date_parse :: proc(value: string) -> (t: time.Time, ok: bool) {

	iter_delim :: proc(value: ^string) -> (token: string, ok: bool) {
		start := -1
		start_loop: for ch, i in transmute([]byte)value^ {
			switch ch {
			case 0x09, 0x20..=0x2F, 0x3B..=0x40, 0x5B..=0x60, 0x7B..=0x7E:
			case:
				start = i
				break start_loop
			}
		}

		if start == -1 {
			return
		}

		token = value[start:]
		length := len(token)
		end_loop: for ch, i in transmute([]byte)token {
			switch ch {
			case 0x09, 0x20..=0x2F, 0x3B..=0x40, 0x5B..=0x60, 0x7B..=0x7E:
				length = i
				break end_loop
			}
		}

		ok = true

		token  = token[:length]
		value^ = value[start+length:]
		return
	}

	parse_digits :: proc(value: string, min, max: int, trailing_ok: bool) -> (int, bool) {
		count: int
		for ch in transmute([]byte)value {
			if ch <= 0x2f || ch >= 0x3a {
				break
			}
			count += 1
		}

		if count < min || count > max {
			return 0, false
		}

		if !trailing_ok && len(value) != count {
			return 0, false
		}

		return strconv.parse_int(value[:count], 10)
	}

	parse_time :: proc(token: string) -> (t: Time, ok: bool) {
		hours, match1, tail := strings.partition(token, ":")
		if match1 != ":" { return }
		minutes, match2, seconds := strings.partition(tail,  ":")
		if match2 != ":" { return }

		t.hours   = parse_digits(hours,   1, 2, false) or_return
		t.minutes = parse_digits(minutes, 1, 2, false) or_return
		t.seconds = parse_digits(seconds, 1, 2, true)  or_return

		ok = true
		return
	}

	parse_month :: proc(token: string) -> (month: int) {
		if len(token) < 3 {
			return
		}

		lower: [3]byte
		for &ch, i in lower {
			#no_bounds_check orig := token[i]
			switch orig {
			case 'A'..='Z':
				ch = orig + 32
			case:
				ch = orig
			}
		}

		switch string(lower[:]) {
		case "jan":
			return 1
		case "feb":
			return 2
		case "mar":
			return 3
		case "apr":
			return 4
		case "may":
			return 5
		case "jun":
			return 6
		case "jul":
			return 7
		case "aug":
			return 8
		case "sep":
			return 9
		case "oct":
			return 10
		case "nov":
			return 11
		case "dec":
			return 12
		case:
			return
		}
	}

	Time :: struct {
		hours, minutes, seconds: int,
	}

	clock: Maybe(Time)
	day_of_month, month, year: Maybe(int)

	value := value
	for token in iter_delim(&value) {
		if _, has_time := clock.?; !has_time {
			if t, tok := parse_time(token); tok {
				clock = t
				continue
			}
		}

		if _, has_day_of_month := day_of_month.?; !has_day_of_month {
			if dom, dok := parse_digits(token, 1, 2, true); dok {
				day_of_month = dom
				continue
			}
		}

		if _, has_month := month.?; !has_month {
			if mon := parse_month(token); mon > 0 {
				month = mon
				continue
			}
		}

		if _, has_year := year.?; !has_year {
			if yr, yrok := parse_digits(token, 2, 4, true); yrok {

				if yr >= 70 && yr <= 99 {
					yr += 1900
				} else if yr >= 0 && yr <= 69 {
					yr += 2000
				}

				year = yr
				continue
			}
		}
	}

	c := clock.? or_return
	y := year.?  or_return

	if y < 1601 {
		return
	}

	t = time.datetime_to_time(
		y,
		month.?        or_return,
		day_of_month.? or_return,
		c.hours,
		c.minutes,
		c.seconds,
	) or_return

	ok = true
	return
}
