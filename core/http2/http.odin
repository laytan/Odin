#+vet explicit-allocators
package http

import "base:intrinsics"
import "base:runtime"

import "core:encoding/hex"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

Version :: struct {
	major: u8,
	minor: u8,
}

// Parses an HTTP version string according to RFC 7230, section 2.6.
version_parse :: proc(s: string) -> (version: Version, ok: bool) {
	switch len(s) {
	case 8:
		(s[6] == '.') or_return
		(s[7] >= '0' && s[7] <= '9') or_return
		version.minor = u8(int(s[7]) - '0')
		fallthrough
	case 6:
		(s[:5] == "HTTP/") or_return
		(s[5] >= '0' && s[5] <= '9') or_return
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
	Invalid_Target,
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
	if len(line.target) == 0 { return line, .Invalid_Target }
	for b in transmute([]byte)line.target {
		if b <= 0x20 || b >= 0x7f || b == '#' { return line, .Invalid_Target }
	}
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
    .Continue                        = "100 Continue",
    .Switching_Protocols             = "101 Switching Protocols",
    .Processing                      = "102 Processing",
    .Early_Hints                     = "103 Early Hints",

    .OK                              = "200 OK",
    .Created                         = "201 Created",
    .Accepted                        = "202 Accepted",
    .Non_Authoritative_Information   = "203 Non-Authoritative Information",
    .No_Content                      = "204 No Content",
    .Reset_Content                   = "205 Reset Content",
    .Partial_Content                 = "206 Partial Content",
    .Multi_Status                    = "207 Multi-Status",
    .Already_Reported                = "208 Already Reported",
    .IM_Used                         = "226 IM Used",

    .Multiple_Choices                = "300 Multiple Choices",
    .Moved_Permanently               = "301 Moved Permanently",
    .Found                           = "302 Found",
    .See_Other                       = "303 See Other",
    .Not_Modified                    = "304 Not Modified",
    .Use_Proxy                       = "305 Use Proxy",
    .Unused                          = "306 (Unused)",
    .Temporary_Redirect              = "307 Temporary Redirect",
    .Permanent_Redirect              = "308 Permanent Redirect",

    .Bad_Request                     = "400 Bad Request",
    .Unauthorized                    = "401 Unauthorized",
    .Payment_Required                = "402 Payment Required",
    .Forbidden                       = "403 Forbidden",
    .Not_Found                       = "404 Not Found",
    .Method_Not_Allowed              = "405 Method Not Allowed",
    .Not_Acceptable                  = "406 Not Acceptable",
    .Proxy_Authentication_Required   = "407 Proxy Authentication Required",
    .Request_Timeout                 = "408 Request Timeout",
    .Conflict                        = "409 Conflict",
    .Gone                            = "410 Gone",
    .Length_Required                 = "411 Length Required",
    .Precondition_Failed             = "412 Precondition Failed",
    .Payload_Too_Large               = "413 Payload Too Large",
    .URI_Too_Long                    = "414 URI Too Long",
    .Unsupported_Media_Type          = "415 Unsupported Media Type",
    .Range_Not_Satisfiable           = "416 Range Not Satisfiable",
    .Expectation_Failed              = "417 Expectation Failed",
    .Im_A_Teapot                     = "418 I'm a teapot",
    .Misdirected_Request             = "421 Misdirected Request",
    .Unprocessable_Content           = "422 Unprocessable Content",
    .Locked                          = "423 Locked",
    .Failed_Dependency               = "424 Failed Dependency",
    .Too_Early                       = "425 Too Early",
    .Upgrade_Required                = "426 Upgrade Required",
    .Precondition_Required           = "428 Precondition Required",
    .Too_Many_Requests               = "429 Too Many Requests",
    .Request_Header_Fields_Too_Large = "431 Request Header Fields Too Large",
    .Unavailable_For_Legal_Reasons   = "451 Unavailable For Legal Reasons",

    .Internal_Server_Error           = "500 Internal Server Error",
    .Not_Implemented                 = "501 Not Implemented",
    .Bad_Gateway                     = "502 Bad Gateway",
    .Service_Unavailable             = "503 Service Unavailable",
    .Gateway_Timeout                 = "504 Gateway Timeout",
    .HTTP_Version_Not_Supported      = "505 HTTP Version Not Supported",
    .Variant_Also_Negotiates         = "506 Variant Also Negotiates",
    .Insufficient_Storage            = "507 Insufficient Storage",
    .Loop_Detected                   = "508 Loop Detected",
    .Not_Extended                    = "510 Not Extended",
    .Network_Authentication_Required = "511 Network Authentication Required",
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

context_of_request :: proc(req: ^Request) -> ^Ctx {
	return container_of(req, Ctx, "req")
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

Query_Entry :: struct {
	key, value: string,
}

query_iter :: proc(query: ^string) -> (entry: Query_Entry, ok: bool) {
	for len(query) > 0 {
		pair: string
		if amp := strings.index_byte(query^, '&'); amp < 0 {
			pair   = query^
			query^ = ""
		} else {
			pair   = query[:amp]
			query^ = query[amp+1:]
		}
		if len(pair) == 0 { continue }

		if eq := strings.index_byte(pair, '='); eq < 0 {
			entry.key   = pair
			entry.value = ""
		} else {
			entry.key   = pair[:eq]
			entry.value = pair[eq+1:]
		}
		return entry, true
	}
	return
}

query_of_url :: proc(url: string) -> string {
	idx := strings.index_byte(url, '?')
	if idx < 0 {
		return ""
	}

	return url[idx+1:]
}

query_get :: proc(url: string, key: string) -> (val: string, ok: bool) #optional_ok {
	q := query_of_url(url)
	for entry in #force_inline query_iter(&q) {
		if entry.key == key {
			return entry.value, true
		}
	}
	return
}

query_get_percent_decoded :: proc(url: string, key: string, allocator := context.temp_allocator) -> (val: string, ok: bool) {
	str := query_get(url, key) or_return
	return net.percent_decode(str, allocator)
}

query_get_bool :: proc(url: string, key: string) -> (result, set: bool) #optional_ok {
	str := query_get(url, key) or_return
	set = true
	switch str {
	case "", "false", "0", "no":
	case:
		result = true
	}
	return
}

query_get_int :: proc(url: string, key: string, base := 0) -> (result: int, ok: bool, set: bool) {
	str := query_get(url, key) or_return
	set = true
	result, ok = strconv.parse_int(str, base)
	return
}

query_get_uint :: proc(url: string, key: string, base := 0) -> (result: uint, ok: bool, set: bool) {
	str := query_get(url, key) or_return
	set = true
	result, ok = strconv.parse_uint(str, base)
	return
}

/*
Decodes an `application/x-www-form-urlencoded` key or value (`+` -> `' '`, `%XX` -> byte).

Returns `s` directly without allocating when no decoding is needed.
*/
url_encoded_decode :: proc(s: string, allocator := context.temp_allocator) -> (decoded: string, ok: bool) {
	if strings.index_any(s, "%+") < 0 {
		utf8.valid_string(s) or_return
		return s, true
	}

	buf, err := make([]byte, len(s), allocator)
	if err != nil { return }
	defer if !ok { delete(buf, allocator) }

	n := 0
	for i := 0; i < len(s); {
		switch s[i] {
		case '+':
			buf[n] = ' '
			n += 1
			i += 1
		case '%':
			if i+2 >= len(s) { return }
			val := hex.decode_sequence(s[i+1:i+3]) or_return
			buf[n] = val
			n += 1
			i += 3
		case:
			buf[n] = s[i]
			n += 1
			i += 1
		}
	}

	decoded = string(buf[:n])
	utf8.valid_string(decoded) or_return
	return decoded, true
}

/*
Parses an `application/x-www-form-urlencoded` body into a map of decoded key/value pairs
(last value wins on duplicate keys; use `query_iter` + `url_encoded_decode` to preserve duplicates).

Intended for arena/temp allocators (such as `transaction_allocator` or `context.temp_allocator`),
since undecoded keys and values alias `plain` while decoded ones are allocated with `allocator`.
*/
body_url_encoded :: proc(plain: string, allocator := context.temp_allocator) -> (res: map[string]string, ok: bool) {
	if len(plain) == 0 {
		res.allocator = allocator
		return res, true
	}

	plain_start := uintptr(raw_data(plain))
	plain_end   := plain_start + uintptr(len(plain))
	free_if_alloc :: #force_inline proc(s: string, plain_start, plain_end: uintptr, allocator: runtime.Allocator) {
		if len(s) == 0 { return }
		if p := uintptr(raw_data(s)); p < plain_start || p >= plain_end {
			delete(s, allocator)
		}
	}

	count := 1 + strings.count(plain, "&")
	alloc_err: runtime.Allocator_Error
	res, alloc_err = make(map[string]string, count, allocator)
	if alloc_err != nil { return }
	defer if !ok {
		for k, v in res {
			free_if_alloc(k, plain_start, plain_end, allocator)
			free_if_alloc(v, plain_start, plain_end, allocator)
		}
		delete(res)
	}

	s := plain
	for entry in query_iter(&s) {
		k := url_encoded_decode(entry.key, allocator) or_return
		v, vok := url_encoded_decode(entry.value, allocator)
		if !vok {
			free_if_alloc(k, plain_start, plain_end, allocator)
			return
		}
		res[k] = v
	}

	return res, true
}

@(private)
parse_int :: proc(str: string) -> (val: int, ok: bool) {
	if len(str) == 0 { return }

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
parse_int16 :: proc(str: string) -> (val: int, ok: bool) {
	if len(str) == 0 { return }

	overflow: bool
	for b in transmute([]byte)str {
		digit: int
		switch b {
		case '0'..='9':
			digit = int(b-'0')
		case 'a'..='z':
			digit = int(b-'a'+10)
		case 'A'..='Z':
			digit = int(b-'A'+10)
		case:
			return
		}

		val, overflow = intrinsics.overflow_mul(val, 16)
		if overflow { return }
		val, overflow = intrinsics.overflow_add(val, digit)
		if overflow { return }
	}

	ok = true
	return
}

Mime_Type :: enum {
	Plain,

	Css,
	Csv,
	Gif,
	Html,
	Ico,
	Jpeg,
	Js,
	Json,
	Png,
	Svg,
	Url_Encoded,
	Xml,
	Zip,
	Wasm,
	Md,
}

mime_from_extension :: proc(s: string) -> (Mime_Type, bool) #optional_ok {
	_, ext := os.split_filename(s)
	if ext == "" {
		ext = strings.trim_prefix(s, ".")
	}
	switch ext {
	case "txt":         return .Plain, true
	case "html", "htm": return .Html,  true
	case "js", "mjs":   return .Js,    true
	case "css":         return .Css,   true
	case "csv":         return .Csv,   true
	case "xml":         return .Xml,   true
	case "zip":         return .Zip,   true
	case "json":        return .Json,  true
	case "ico":         return .Ico,   true
	case "gif":         return .Gif,   true
	case "jpeg", "jpg": return .Jpeg,  true
	case "png":         return .Png,   true
	case "svg":         return .Svg,   true
	case "wasm":        return .Wasm,  true
	case "md":          return .Md,    true
	case:               return nil,    false
	}
}

@(private="file", rodata)
_mime_to_content_type := [Mime_Type]string{
	.Plain       = "text/plain",

	.Css         = "text/css",
	.Csv         = "text/csv",
	.Gif         = "image/gif",
	.Html        = "text/html",
	.Ico         = "application/vnd.microsoft.ico",
	.Jpeg        = "image/jpeg",
	.Js          = "application/javascript",
	.Json        = "application/json",
	.Png         = "image/png",
	.Svg         = "image/svg+xml",
	.Url_Encoded = "application/x-www-form-urlencoded",
	.Xml         = "text/xml",
	.Zip         = "application/zip",
	.Wasm        = "application/wasm",
	.Md          = "text/markdown",
}

mime_to_content_type :: proc(m: Mime_Type) -> string #no_bounds_check {
	assert(m >= min(Mime_Type) && m <= max(Mime_Type))
	return _mime_to_content_type[m]
}

