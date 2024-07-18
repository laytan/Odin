package openssl_http

import      "core:http"
import      "core:net"

import ossl "vendor:openssl"

client_implementation :: proc() -> http.Client_SSL {
	return {
		implemented = true,
		client_create = proc() -> http.SSL_Client {
			method := ossl.TLS_client_method()
			assert(method != nil)
			ctx := ossl.SSL_CTX_new(method)
			assert(ctx != nil)
			return http.SSL_Client(ctx)
		},
		client_destroy = proc(c: http.SSL_Client) {
			ossl.SSL_CTX_free((^ossl.SSL_CTX)(c))
		},
		connection_create = proc(c: http.SSL_Client, socket: net.TCP_Socket, host: cstring) -> http.SSL_Connection {
			conn := ossl.SSL_new((^ossl.SSL_CTX)(c))
			assert(conn != nil)
			ret: i32
			ret = ossl.SSL_set_tlsext_host_name(conn, host)
			assert(ret == 1)
			ret = ossl.SSL_set_fd(conn, i32(socket))
			assert(ret == 1)
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
			assert(len(buf) > 0)
			assert(len(buf) <= int(max(i32)))
			switch ret := ossl.SSL_write(ssl, raw_data(buf), i32(len(buf))); {
			case ret > 0:
				assert(int(ret) == len(buf))
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
			assert(len(buf) > 0)
			assert(len(buf) <= int(max(i32)))
			switch ret := ossl.SSL_read(ssl, raw_data(buf), i32(len(buf))); {
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
