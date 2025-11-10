#+build !js
package openssl

import "core:c"

// Use the shared libraries of OpenSSL.
// Defaults to false on Windows, true otherwise.
// it is usually universally installed as a system library and it's recommended to use that.
SHARED :: #config(OPENSSL_SHARED, ODIN_OS != .Windows)

when ODIN_OS == .Windows {
	when SHARED {
		foreign import lib {
			"./windows/libssl.lib",
			"./windows/libcrypto.lib",
		}
	} else {
		foreign import lib {
			"./windows/libssl_static.lib",
			"./windows/libcrypto_static.lib",
			"system:ws2_32.lib",
			"system:gdi32.lib",
			"system:advapi32.lib",
			"system:crypt32.lib",
			"system:user32.lib",
		}
	}
} else when ODIN_OS == .Darwin {
	foreign import lib {
		"system:ssl.3",
		"system:crypto.3",
	}
} else {
	foreign import lib {
		"system:ssl",
		"system:crypto",
	}
}

SSL_METHOD :: distinct rawptr
SSL_CTX    :: distinct rawptr
SSL        :: distinct rawptr

SSL_CTRL_SET_TLSEXT_HOSTNAME :: 55

TLSEXT_NAMETYPE_host_name :: 0

Error_Callback :: #type proc "c" (str: cstring, len: c.size_t, u: rawptr) -> c.int

Error :: enum c.int {
	None,
	Ssl,
	Want_Read,
	Want_Write,
	Want_X509_Lookup,
	Syscall,
	Zero_Return,
	Want_Connect,
	Want_Accept,
	Want_Async,
	Want_Async_Job,
	Want_Client_Hello_CB,
}

foreign lib {
	TLS_client_method :: proc() -> SSL_METHOD ---
	SSL_CTX_new :: proc(method: SSL_METHOD) -> SSL_CTX ---
	SSL_new :: proc(ctx: SSL_CTX) -> SSL ---
	SSL_set_fd :: proc(ssl: SSL, fd: c.int) -> c.int ---
	SSL_connect :: proc(ssl: SSL) -> c.int ---
	SSL_get_error :: proc(ssl: SSL, ret: c.int) -> Error ---
	ERR_print_errors_fp :: proc(fp: ^c.FILE) ---
	ERR_print_errors_cb :: proc(cb: Error_Callback, u: rawptr) ---
	SSL_read :: proc(ssl: SSL, buf: [^]byte, num: c.int) -> c.int ---
	SSL_write :: proc(ssl: SSL, buf: [^]byte, num: c.int) -> c.int ---
	SSL_free :: proc(ssl: SSL) ---
	SSL_CTX_free :: proc(ctx: SSL_CTX) ---
	SSL_ctrl :: proc(ssl: SSL, cmd: c.int, larg: c.long, parg: rawptr) -> c.long ---
	OpenSSL_version_num :: proc() -> c.ulong ---
}

/* Macros */

SSL_set_tlsext_host_name :: proc(ssl: SSL, name: cstring) -> c.int {
	return c.int(SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(name)))
}
