#+vet explicit-allocators
package http

import "base:intrinsics"

import "core:strings"
import "core:time"
import "core:strconv"
import "core:io"

Version :: struct {
	major: u8,
	minor: u8,
}

// Parses an HTTP version string according to RFC 7230, section 2.6.
version_parse :: proc(s: string) -> (version: Version, ok: bool) {
	switch len(s) {
	case 8:
		(s[6] == '.') or_return
		version.minor = u8(int(s[7]) - '0')
		fallthrough
	case 6:
		(s[:5] == "HTTP/") or_return
		version.major = u8(int(s[5]) - '0')
	case:
		return
	}
	ok = true
	return
}

Method :: enum u8 {
	Get,
	Post,
	Delete,
	Patch,
	Put,
	Head,
	Connect,
	Options,
	Trace,
}

@(private="file")
_method_strings := [?]string{"GET", "POST", "DELETE", "PATCH", "PUT", "HEAD", "CONNECT", "OPTIONS", "TRACE"}

method_string :: proc(m: Method) -> string #no_bounds_check {
	if m < .Get || m > .Trace { return "" }
	return _method_strings[m]
}

method_parse :: proc(m: string) -> (method: Method, ok: bool) #no_bounds_check {
	for r in Method {
		if _method_strings[r] == m {
			return r, true
		}
	}

	return nil, false
}

Requestline_Error :: enum {
	None,
	Method_Not_Implemented,
	Not_Enough_Fields,
	Invalid_Version_Format,
}

Requestline :: struct {
	method:  Method,
	target:  string,
	version: Version,
}

// A request-line begins with a method token, followed by a single space
// (SP), the request-target, another single space (SP), the protocol
// version, and ends with CRLF.
requestline_parse :: proc(s: string) -> (line: Requestline, err: Requestline_Error) {
	s := s

	next_space := strings.index_byte(s, ' ')
	if next_space == -1 { return line, .Not_Enough_Fields }

	ok: bool
	line.method, ok = method_parse(s[:next_space])
	if !ok { return line, .Method_Not_Implemented }
	s = s[next_space+1:]

	next_space = strings.index_byte(s, ' ')
	if next_space == -1 { return line, .Not_Enough_Fields }

	line.target = s[:next_space]
	s = s[len(line.target)+1:]

	line.version, ok = version_parse(s)
	if !ok { return line, .Invalid_Version_Format }

	return
}

Status :: enum {
	Continue                        = 100,
	Switching_Protocols             = 101,
	Processing                      = 102,
	Early_Hints                     = 103,

	OK                              = 200,
	Created                         = 201,
	Accepted                        = 202,
	Non_Authoritative_Information   = 203,
	No_Content                      = 204,
	Reset_Content                   = 205,
	Partial_Content                 = 206,
	Multi_Status                    = 207,
	Already_Reported                = 208,
	IM_Used                         = 226,

	Multiple_Choices                = 300,
	Moved_Permanently               = 301,
	Found                           = 302,
	See_Other                       = 303,
	Not_Modified                    = 304,
	Use_Proxy                       = 305, // Deprecated.
	Unused                          = 306, // Deprecated.
	Temporary_Redirect              = 307,
	Permanent_Redirect              = 308,

	Bad_Request                     = 400,
	Unauthorized                    = 401,
	Payment_Required                = 402,
	Forbidden                       = 403,
	Not_Found                       = 404,
	Method_Not_Allowed              = 405,
	Not_Acceptable                  = 406,
	Proxy_Authentication_Required   = 407,
	Request_Timeout                 = 408,
	Conflict                        = 409,
	Gone                            = 410,
	Length_Required                 = 411,
	Precondition_Failed             = 412,
	Payload_Too_Large               = 413,
	URI_Too_Long                    = 414,
	Unsupported_Media_Type          = 415,
	Range_Not_Satisfiable           = 416,
	Expectation_Failed              = 417,
	Im_A_Teapot                     = 418,
	Misdirected_Request             = 421,
	Unprocessable_Content           = 422,
	Locked                          = 423,
	Failed_Dependency               = 424,
	Too_Early                       = 425,
	Upgrade_Required                = 426,
	Precondition_Required           = 428,
	Too_Many_Requests               = 429,
	Request_Header_Fields_Too_Large = 431,
	Unavailable_For_Legal_Reasons   = 451,

	Internal_Server_Error           = 500,
	Not_Implemented                 = 501,
	Bad_Gateway                     = 502,
	Service_Unavailable             = 503,
	Gateway_Timeout                 = 504,
	HTTP_Version_Not_Supported      = 505,
	Variant_Also_Negotiates         = 506,
	Insufficient_Storage            = 507,
	Loop_Detected                   = 508,
	Not_Extended                    = 510,
	Network_Authentication_Required = 511,
}

@(private)
_status_strings: #sparse [Status]string = {
    .Continue                        = "100 Continue\r\n",
    .Switching_Protocols             = "101 Switching Protocols\r\n",
    .Processing                      = "102 Processing\r\n",
    .Early_Hints                     = "103 Early Hints\r\n",

    .OK                              = "200 OK\r\n",
    .Created                         = "201 Created\r\n",
    .Accepted                        = "202 Accepted\r\n",
    .Non_Authoritative_Information   = "203 Non-Authoritative Information\r\n",
    .No_Content                      = "204 No Content\r\n",
    .Reset_Content                   = "205 Reset Content\r\n",
    .Partial_Content                 = "206 Partial Content\r\n",
    .Multi_Status                    = "207 Multi-Status\r\n",
    .Already_Reported                = "208 Already Reported\r\n",
    .IM_Used                         = "226 IM Used\r\n",

    .Multiple_Choices                = "300 Multiple Choices\r\n",
    .Moved_Permanently               = "301 Moved Permanently\r\n",
    .Found                           = "302 Found\r\n",
    .See_Other                       = "303 See Other\r\n",
    .Not_Modified                    = "304 Not Modified\r\n",
    .Use_Proxy                       = "305 Use Proxy\r\n",
    .Unused                          = "306 (Unused)\r\n",
    .Temporary_Redirect              = "307 Temporary Redirect\r\n",
    .Permanent_Redirect              = "308 Permanent Redirect\r\n",

    .Bad_Request                     = "400 Bad Request\r\n",
    .Unauthorized                    = "401 Unauthorized\r\n",
    .Payment_Required                = "402 Payment Required\r\n",
    .Forbidden                       = "403 Forbidden\r\n",
    .Not_Found                       = "404 Not Found\r\n",
    .Method_Not_Allowed              = "405 Method Not Allowed\r\n",
    .Not_Acceptable                  = "406 Not Acceptable\r\n",
    .Proxy_Authentication_Required   = "407 Proxy Authentication Required\r\n",
    .Request_Timeout                 = "408 Request Timeout\r\n",
    .Conflict                        = "409 Conflict\r\n",
    .Gone                            = "410 Gone\r\n",
    .Length_Required                 = "411 Length Required\r\n",
    .Precondition_Failed             = "412 Precondition Failed\r\n",
    .Payload_Too_Large               = "413 Payload Too Large\r\n",
    .URI_Too_Long                    = "414 URI Too Long\r\n",
    .Unsupported_Media_Type          = "415 Unsupported Media Type\r\n",
    .Range_Not_Satisfiable           = "416 Range Not Satisfiable\r\n",
    .Expectation_Failed              = "417 Expectation Failed\r\n",
    .Im_A_Teapot                     = "418 I'm a teapot\r\n",
    .Misdirected_Request             = "421 Misdirected Request\r\n",
    .Unprocessable_Content           = "422 Unprocessable Content\r\n",
    .Locked                          = "423 Locked\r\n",
    .Failed_Dependency               = "424 Failed Dependency\r\n",
    .Too_Early                       = "425 Too Early\r\n",
    .Upgrade_Required                = "426 Upgrade Required\r\n",
    .Precondition_Required           = "428 Precondition Required\r\n",
    .Too_Many_Requests               = "429 Too Many Requests\r\n",
    .Request_Header_Fields_Too_Large = "431 Request Header Fields Too Large\r\n",
    .Unavailable_For_Legal_Reasons   = "451 Unavailable For Legal Reasons\r\n",

    .Internal_Server_Error           = "500 Internal Server Error\r\n",
    .Not_Implemented                 = "501 Not Implemented\r\n",
    .Bad_Gateway                     = "502 Bad Gateway\r\n",
    .Service_Unavailable             = "503 Service Unavailable\r\n",
    .Gateway_Timeout                 = "504 Gateway Timeout\r\n",
    .HTTP_Version_Not_Supported      = "505 HTTP Version Not Supported\r\n",
    .Variant_Also_Negotiates         = "506 Variant Also Negotiates\r\n",
    .Insufficient_Storage            = "507 Insufficient Storage\r\n",
    .Loop_Detected                   = "508 Loop Detected\r\n",
    .Not_Extended                    = "510 Not Extended\r\n",
    .Network_Authentication_Required = "511 Network Authentication Required\r\n",
}

status_string :: proc(s: Status) -> string {
	if s >= Status(0) && s <= max(Status) {
		return _status_strings[s]
	}

	return ""
}

status_is_informational :: proc(s: Status) -> bool {
	return s >= Status(100) && s < Status(200)
}

status_is_success :: proc(s: Status) -> bool {
	return s >= Status(200) && s < Status(300)
}

status_is_redirect :: proc(s: Status) -> bool {
	return s >= Status(300) && s < Status(400)
}

status_is_client_error :: proc(s: Status) -> bool {
	return s >= Status(400) && s < Status(500)
}

status_is_server_error :: proc(s: Status) -> bool {
	return s >= Status(500) && s < Status(600)
}

DATE_LENGTH :: len("Fri, 05 Feb 2023 09:01:10 GMT")

@(private, rodata)
MONTHS := [13]string {
	" ", // Jan is 1, so 0 should never be accessed.
	" Jan ",
	" Feb ",
	" Mar ",
	" Apr ",
	" May ",
	" Jun ",
	" Jul ",
	" Aug ",
	" Sep ",
	" Oct ",
	" Nov ",
	" Dec ",
}

// Formats a time in the HTTP header format (no timezone conversion is done, GMT expected):
// `<day-name>, <day> <month> <year> <hour>:<minute>:<second> GMT`
date_write :: proc(buf: []byte, t: time.Time) {
	assert(len(buf) >= DATE_LENGTH)

	write_padded_int :: proc(buf: []byte, i: int) {
		@(static, rodata)
		PADDED_NUMS := [10]string{"00", "01", "02", "03", "04", "05", "06", "07", "08", "09"}

		if i < 10 {
			copy(buf, PADDED_NUMS[i])
			return
		}

		assert(i < 100)
		strconv.write_int(buf, i64(i), 10)
	}

	@(static, rodata)
	DAYS := [7]string{"Sun, ", "Mon, ", "Tue, ", "Wed, ", "Thu, ", "Fri, ", "Sat, "}

	year, month, day := time.date(t)
	hour, minute, second := time.clock_from_time(t)
	wday := time.weekday(t)

	n := 0
	n += copy(buf[n:], DAYS[wday])                    // 'Fri, '
	write_padded_int(buf[n:], day); n += 2            // 'Fri, 05'
	n += copy(buf[n:], MONTHS[month])                 // 'Fri, 05 Feb '
	strconv.write_int(buf[n:], i64(year), 10); n += 4 // 'Fri, 05 Feb 2023' 
	buf[n] = ' '; n += 1                              // 'Fri, 05 Feb 2023 '
	write_padded_int(buf[n:], hour); n += 2           // 'Fri, 05 Feb 2023 09'
	buf[n] = ':'; n += 1                              // 'Fri, 05 Feb 2023 09:'
	write_padded_int(buf[n:], minute); n += 2         // 'Fri, 05 Feb 2023 09:01'
	buf[n] = ':'; n += 1                              // 'Fri, 05 Feb 2023 09:01:'
	write_padded_int(buf[n:], second); n += 2         // 'Fri, 05 Feb 2023 09:01:10'
	n += copy(buf[n:], " GMT")                        // 'Fri, 05 Feb 2023 09:01:10 GMT'
}

date_parse :: proc(value: string) -> (t: time.Time, ok: bool) #no_bounds_check {
	if len(value) != DATE_LENGTH { return }

	// Remove 'Fri, '
	value := value
	value = value[5:]

	// Parse '05'
	day := parse_int(value[:2]) or_return
	value = value[2:]

	// Parse ' Feb ' or '-Feb-' (latter is a deprecated format but should still be parsed).
	month_index := -1
	month_str := value[1:4]
	value = value[5:]
	for month, i in MONTHS[1:] {
		if month_str == month[1:4] {
			month_index = i
			break
		}
	}
	month_index += 1
	if month_index <= 0 { return }

	year := parse_int(value[:4]) or_return
	value = value[4:]

	hour := parse_int(value[1:3]) or_return
	value = value[4:]

	minute := parse_int(value[:2]) or_return
	value = value[3:]

	seconds := parse_int(value[:2]) or_return
	value = value[3:]

	// Should have only 'GMT' left now.
	if value != "GMT" { return }

	t = time.datetime_to_time(int(year), int(month_index), int(day), int(hour), int(minute), int(seconds)) or_return
	ok = true
	return
}

context_of_response :: proc(res: ^Response) -> ^Ctx {
	return container_of(res, Ctx, "res")
}

connection_of_response :: proc(res: ^Response) -> ^Connection {
	return container_of(res, Connection, "res")
}

connection_of_request :: proc(req: ^Request) -> ^Connection {
	return container_of(req, Connection, "req")
}

connection_of_context :: proc(ctx: ^Ctx) -> ^Connection {
	return container_of(ctx, Connection, "ctx")
}

request_of_response :: proc(res: ^Response) -> ^Request {
	return &connection_of_response(res).req
}

/*
Retrieves the cookie with the given `key` out of the request's `Cookie` header.

If the same key is in the header multiple times the last one is returned.
*/
request_cookie_get :: proc(r: ^Request, key: string) -> (value: string, ok: bool) {
	cookies := headers_get(r.headers, "cookie") or_return

	for k, v in request_cookies_iter(&cookies) {
		if key == k { return v, true }
	}

	return
}

/*
Allocates a map with the given allocator and puts all cookie pairs from the request's `Cookie` header into it.

If the same key is in the header multiple times the last one is returned.
*/
request_cookies :: proc(r: ^Request, allocator := context.temp_allocator) -> (res: map[string]string) {
	res.allocator = allocator

	cookies := headers_get(r.headers, "cookie") or_else ""
	for k, v in request_cookies_iter(&cookies) {
		// Don't overwrite, the iterator goes from right to left and we want the last.
		if k in res { continue }

		res[k] = v
	}

	return
}

/*
Iterates the cookies (from the `Cookie` header) from right to left.
*/
request_cookies_iter :: proc(cookies: ^string) -> (key: string, value: string, ok: bool) {
	end := len(cookies)
	eq  := -1
	for i := end-1; i >= 0; i-=1 {
		b := cookies[i]
		start := i == 0
		sep := start || b == ' ' && cookies[i-1] == ';'
		if sep {
			defer end = i - 1

			// Invalid.
			if eq < 0 {
				continue
			}

			off := 0 if start else 1

			key   = cookies[i+off:eq]
			value = cookies[eq+1:end]

			cookies^ = cookies[:i-off]

			return key, value, true
		} else if b == '=' {
			eq = i
		}
	}

	return
}

@(private)
parse_int :: proc(str: string) -> (val: int, ok: bool) {
	overflow: bool
	for b in transmute([]byte)str {
		switch b {
		case '0'..='9':
			val, overflow = intrinsics.overflow_mul(val, 10)
			if overflow { return }
			val, overflow = intrinsics.overflow_add(val, int(b-'0'))
			if overflow { return }
		case:
			return
		}
	}

	ok = true
	return
}

@(private)
buf_writer :: proc(buf: ^[dynamic]byte) -> io.Writer {
	return io.Writer {
		data = buf,
		procedure = proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			buf := (^[dynamic]byte)(stream_data)
			#partial switch mode {
			case .Write:
				n, err := append_elems(buf, ..p)
				return i64(n), .Buffer_Full if err != nil else nil
			case:
				return 0, .Unsupported
			}
		},
	}
}

