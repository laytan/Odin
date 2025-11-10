#+build !js
package openssl_http

import      "core:http"
import      "core:net"

import ossl "vendor:openssl"

client_implementation :: proc() -> http.Client_SSL {
	return {
		client_create = proc() -> http.SSL_Client {
			Version :: bit_field u32 {
				pre_release: uint | 4,
				patch:       uint | 16,
				minor:       uint | 8,
				major:       uint | 4,
			}

			VERSION := Version(OpenSSL_version_num())
			assert(VERSION.major == 3, "invalid OpenSSL library version, expected 3.x")

			method := ossl.TLS_client_method()
			if method == nil { return nil }

			ctx := ossl.SSL_CTX_new(method)
			if ctx == nil { return nil }

			return http.SSL_Client(ctx)
		},
		client_destroy = proc(c: http.SSL_Client) {
			ossl.SSL_CTX_free((^ossl.SSL_CTX)(c))
		},
		connection_create = proc(c: http.SSL_Client, socket: net.TCP_Socket, host: cstring) -> http.SSL_Connection {
			conn := ossl.SSL_new((^ossl.SSL_CTX)(c))
			if conn == nil { return nil }

			ret: i32

			ret = ossl.SSL_set_tlsext_host_name(conn, host)
			if ret != 1 { return nil }

			ret = ossl.SSL_set_fd(conn, i32(socket))
			if ret != 1 { return nil }

			return http.SSL_Connection(conn)
		},
		connection_destroy = proc(c: http.SSL_Client, conn: http.SSL_Connection) {
			ossl.SSL_free((^ossl.SSL)(conn))
		},
		connect = proc(c: http.SSL_Connection) -> http.SSL_Result {
			ssl := (^ossl.SSL)(c)
			switch ret := ossl.SSL_connect(ssl); ret {
			case 1:
				return nil
			case 0:
				return .Shutdown
			case:
				assert(ret < 0)
				#partial switch ossl.SSL_get_error(ssl, ret) {
				case .Want_Read:  return .Want_Read
				case .Want_Write: return .Want_Write
				case:             return .Fatal
				}
			}
		},
		send = proc(c: http.SSL_Connection, buf: []byte) -> (int, http.SSL_Result) {
			ssl := (^ossl.SSL)(c)

			if len(buf) <= 0 {
				return 0, nil
			}

			n := max(i32) if len(buf) > int(max(i32)) else i32(len(buf))
			switch ret := ossl.SSL_write(ssl, raw_data(buf), n); {
			case ret > 0:
				return int(ret), nil
			case:
				#partial switch ossl.SSL_get_error(ssl, ret) {
				case .Want_Read:   return 0, .Want_Read
				case .Want_Write:  return 0, .Want_Write
				case .Zero_Return: return 0, .Shutdown
				case:              return 0, .Fatal
				}
			}
		},
		recv = proc(c: http.SSL_Connection, buf: []byte) -> (int, http.SSL_Result) {
			ssl := (^ossl.SSL)(c)

			if len(buf) <= 0 {
				return 0, nil
			}

			n := max(i32) if len(buf) > int(max(i32)) else i32(len(buf))
			switch ret := ossl.SSL_read(ssl, raw_data(buf), n); {
			case ret > 0:
				return int(ret), nil
			case:
				#partial switch ossl.SSL_get_error(ssl, ret) {
				case .Want_Read:   return 0, .Want_Read
				case .Want_Write:  return 0, .Want_Write
				case .Zero_Return: return 0, .Shutdown
				case:              return 0, .Fatal
				}
			}
		},
	}
}
