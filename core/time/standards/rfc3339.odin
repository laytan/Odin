package time_standards

import "core:io"
import "core:mem"
import "core:strings"
import "core:time"

iso8601_parse :: rfc3339_parse
rfc3339_parse :: proc(timestamp: string) -> (base: time.Time, offset: Maybe(time.Duration), ok: bool) {
	TIME_LEN :: len("HH:MM:SS")
	DATE_LEN :: len("YYYY-MM-DD")

	parse_digits :: proc(v: string) -> (digits: int, ok: bool) {
		for c in v {
			if c < '0' || c > '9' {
				return
			}
			digits = digits * 10 + (int(c)-'0')
		}
		ok = true
		return
	}

	parse_time_part :: proc(v: string) -> (hours, mins, secs, nanos, length: int, ok: bool) {
		if len(v) < TIME_LEN {
			return
		}

		hours = parse_digits(v[:2])  or_return
		(v[2] == ':') or_return
		mins  = parse_digits(v[3:5]) or_return
		(v[5] == ':') or_return
		secs  = parse_digits(v[6:8]) or_return

		length = TIME_LEN
		if len(v) > 9 && v[8] == '.' {
			fraction_part := v[9:]
			length += 1

			fraction: int
			multiplier := 100_000_000_0
			for c, i in fraction_part {
				if c < '0' || c > '9' {
					break
				}
				
				// Truncate the precision we don't support (more than nanoseconds).
				length += 1
				if i >= 8 {
					continue
				}

				multiplier /= 10
				fraction = fraction * 10 + (int(c)-'0')
			}
			assert(multiplier >= 1 && multiplier <= 100_000_000)

			nanos = fraction * multiplier
		}
		ok = true
		return
	}
	
	parse_date_part :: proc(v: string) -> (year, month, day: int, ok: bool) {
		if len(v) < DATE_LEN {
			return
		}

		year = parse_digits(v[:4])   or_return
		(v[4] == '-')                or_return
		month = parse_digits(v[5:7]) or_return
		(v[7] == '-')                or_return
		day = parse_digits(v[8:10])  or_return

		day += 1
		ok = true
		return
	}

	if len(timestamp) < TIME_LEN {
		return
	}

	if timestamp[2] == ':' {
		hours, mins, secs, nanos, n := parse_time_part(timestamp) or_return
		if n < len(timestamp) { return }
		base = time.datetime_to_time(1970, 1, 1, hours, mins, secs, nanos) or_return
		ok   = true
		return
	}

	year, month, day := parse_date_part(timestamp) or_return
	if len(timestamp) == DATE_LEN {
		base = time.datetime_to_time(year, month, day, 0, 0, 0, 0) or_return
		ok   = true
		return
	}

	time_part := timestamp[DATE_LEN:]
	if time_part[0] != 'T' && time_part[0] != ' ' {
		return
	}

	hours, mins, secs, nanos, n := parse_time_part(time_part[1:]) or_return
	base = time.datetime_to_time(year, month, day, hours, mins, secs, nanos) or_return

	offset_part := time_part[n+1:]
	if len(offset_part) == 0 {
		ok = true
		return
	}

	switch offset_part[0] {
	case 'Z':
		offset = 0	
		ok     = len(offset_part) == 1
		return
	case '-', '+':
		if len(offset_part) != len("+00:00") {
			return
		}

		hours := parse_digits(offset_part[1:3]) or_return
		(offset_part[3] == ':') or_return
		mins := parse_digits(offset_part[4:6]) or_return
		mins += hours * 60
		secs := mins  * 60

		offset = time.Duration(secs * 1_000_000_000) // secs to nanoseconds.

		if offset_part[0] == '-' {
			offset = -offset.?
		}

		ok = true
		return

	case:
		return
	}
}

iso8601_string :: rfc3339_string
rfc3339_string :: proc(base: time.Time, offset: Maybe(time.Duration), allocator := context.allocator) -> (str: string, err: mem.Allocator_Error) #optional_allocator_error {
	b := strings.builder_make(0, len("2001-03-16T00:00:00.000000000+00:00"), allocator) or_return
	if _, ioerr := rfc3339_write(strings.to_stream(&b), base, offset); ioerr != nil {
		strings.builder_destroy(&b)
		return "", .Out_Of_Memory // String builder only gives an error if out of memory.
	}

	return strings.to_string(b), nil
}

iso8601_write :: rfc3339_write
rfc3339_write :: proc(w: io.Writer, base: time.Time, offset: Maybe(time.Duration)) -> (n: int, err: io.Error) {
	n += rfc3339_write_date(w, base) or_return
	io.write_byte(w, 'T', &n)        or_return
	n += rfc3339_write_time(w, base) or_return

	if off, ok := offset.?; ok {
		secs  := time.duration_nanoseconds(off)/1e9
		mins  := secs/60
		hours := mins/60
		switch {
		case hours == 0 && mins == 0:
			io.write_byte(w, 'Z', &n) or_return
			return
		case secs < 0:
			io.write_byte(w, '-', &n)             or_return
			write_padded_number(w, -hours, 2, &n) or_return
			io.write_byte(w, ':', &n)             or_return
			write_padded_number(w, -mins, 2, &n)  or_return
			return
		case:
			io.write_byte(w, '+', &n)            or_return
			write_padded_number(w, hours, 2, &n) or_return
			io.write_byte(w, ':', &n)            or_return
			write_padded_number(w, mins, 2, &n)  or_return
			return
		}
	}
	return
}

iso8601_write_date :: rfc3339_write_date
rfc3339_write_date :: proc(w: io.Writer, base: time.Time) -> (n: int, err: io.Error) {
	y, mon, d := time.date(base)
	write_padded_number(w, i64(y), 4, &n)   or_return
	io.write_byte(w, '-', &n)               or_return
	write_padded_number(w, i64(mon), 2, &n) or_return
	io.write_byte(w, '-', &n)               or_return
	write_padded_number(w, i64(d), 2, &n)   or_return
	return
}

iso8601_write_time :: rfc3339_write_time
rfc3339_write_time :: proc(w: io.Writer, base: time.Time) -> (n: int, err: io.Error) {
	h, min, s := time.clock(base)
	ns := (base._nsec - (base._nsec/1e9 + time.UNIX_TO_ABSOLUTE)*1e9) % 1e9
	write_padded_number(w, i64(h), 2, &n)   or_return
	io.write_byte(w, ':', &n)               or_return
	write_padded_number(w, i64(min), 2, &n) or_return
	io.write_byte(w, ':', &n)               or_return
	write_padded_number(w, i64(s), 2, &n)   or_return
	io.write_byte(w, '.', &n)               or_return
	write_padded_number(w, ns, 9, &n)       or_return
	return
}

@(private)
write_padded_number :: proc(w: io.Writer, i: i64, width: int, n: ^int) -> io.Error {
	n := width-1
	for x := i; x >= 10; x /= 10 {
		n -= 1
	}
	for _ in 0..<n {
		io.write_byte(w, '0', &n) or_return
	}
	io.write_i64(w, i, 10, &n) or_return
	return nil
}
