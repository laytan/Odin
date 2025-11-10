#+vet explicit-allocators
#+build !js
package openssl_http

import "core:strings"
import "core:mem"
import "core:http"
import "core:net"
import "core:sys/posix"
import "core:c/libc"

import ossl "vendor:openssl"

client_implementation :: proc() -> http.SSL_Client {
	Version :: bit_field u32 {
		pre_release: uint | 4,
		patch:       uint | 16,
		minor:       uint | 8,
		major:       uint | 4,
	}

	VERSION := Version(ossl.OpenSSL_version_num())
	assert(VERSION.major == 3, "invalid OpenSSL library version, expected 3.x")

	// ossl.ERR_print_errors_fp(libc.stderr)

	method := ossl.TLS_client_method()
	if method == nil { return {} }

	ctx := ossl.SSL_CTX_new(method)
	if ctx == nil { return {} }

	ossl.SSL_CTX_set_options(ctx, {.ENABLE_KTLS, .ENABLE_KTLS_TX_ZEROCOPY_SENDFILE})

	return {
		user_data = ctx,
		client_destroy = proc(c: http.SSL_Client) {
			ossl.SSL_CTX_free((ossl.SSL_CTX)(c.user_data))
		},
		connection_create = proc(c: http.SSL_Client, socket: net.TCP_Socket, host: string, allocator: mem.Allocator) -> http.SSL_Connection {
			conn := ossl.SSL_new((ossl.SSL_CTX)(c.user_data))
			if conn == nil { return nil }

			chost, err := strings.clone_to_cstring(host, allocator)
			if err != nil { return nil }
			defer delete(chost, allocator)

			ret: i32
			ret = ossl.SSL_set_tlsext_host_name(conn, chost)
			if ret != 1 { return nil }

			ret = ossl.SSL_set_fd(conn, i32(socket))
			if ret != 1 { return nil }

			return http.SSL_Connection(conn)
		},
		connection_destroy = proc(c: http.SSL_Client, conn: http.SSL_Connection) {
			ossl.SSL_free((ossl.SSL)(conn))
		},
		connect = proc(c: http.SSL_Connection) -> (http.SSL_Result, http.SSL_Capabilities) {
			ssl := (ossl.SSL)(c)

			// NOTE: OpenSSL does not provide a NOSIGNAL flag.
			when ODIN_OS != .Windows {
				prev := posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
				defer posix.signal(.SIGPIPE, prev)
			}

			for {
				switch ret := ossl.SSL_connect(ssl); ret {
				case 1:
					capabilities: http.SSL_Capabilities
					if ossl.BIO_ctrl_get_ktls_send(ossl.SSL_get_wbio(ssl)) {
						capabilities += {.KTLS}
					}

					return nil, capabilities
				case 0:
					return .Shutdown, nil
				case:
					assert(ret < 0)
					err := ossl.SSL_get_error(ssl, ret)
					#partial switch err {
					case .Want_Read:  return .Want_Read, nil
					case .Want_Write: return .Want_Write, nil
					case:             return .Fatal, nil
					}
				}
			}
		},
		send = proc(c: http.SSL_Connection, bufs: [][]byte) -> (int, http.SSL_Result) {
			ssl := (ossl.SSL)(c)
			assert(len(bufs) > 0)

			// NOTE: OpenSSL does not provide a NOSIGNAL flag.
			when ODIN_OS != .Windows {
				prev := posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
				defer posix.signal(.SIGPIPE, prev)
			}

			sent: int
			bufs := bufs
			for len(bufs) > 0 {
				buf := bufs[0]
				n := max(i32) if len(buf) > int(max(i32)) else i32(len(buf))
				switch ret := ossl.SSL_write(ssl, raw_data(buf), n); {
				case ret > 0:
					sent += int(ret)
					buf = buf[ret:]
					if len(buf) == 0 {
						bufs = bufs[1:]
					}
				case:
					err := ossl.SSL_get_error(ssl, ret)
					#partial switch err {
					case .Want_Read:   return sent, .Want_Read
					case .Want_Write:  return sent, .Want_Write
					case .Zero_Return: return sent, .Shutdown
					case:              return sent, .Fatal
					}
				}
			}

			return sent, nil
		},
		recv = proc(c: http.SSL_Connection, buf: []byte) -> (int, http.SSL_Result) {
			ssl := (ossl.SSL)(c)
			assert(len(buf) > 0)

			// NOTE: OpenSSL does not provide a NOSIGNAL flag.
			when ODIN_OS != .Windows {
				prev := posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
				defer posix.signal(.SIGPIPE, prev)
			}

			n := max(i32) if len(buf) > int(max(i32)) else i32(len(buf))
			switch ret := ossl.SSL_read(ssl, raw_data(buf), n); {
			case ret > 0:
				return int(ret), nil
			case:
				err := ossl.SSL_get_error(ssl, ret)
				#partial switch err {
				case .Want_Read:   return 0, .Want_Read
				case .Want_Write:  return 0, .Want_Write
				case .Zero_Return: return 0, .Shutdown
				case:              return 0, .Fatal
				}
			}
		},
	}
}
