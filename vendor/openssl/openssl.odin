#+build !js
package vendor_openssl

import "core:c"

when ODIN_OS == .Windows {
	foreign import lib {
		"libssl.lib",
		"libcrypto.lib",
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
BIO        :: distinct rawptr

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

Option :: enum {
	/* Disable Extended master secret */
	NO_EXTENDED_MASTER_SECRET = 0,
	/* Cleanse plaintext copies of data delivered to the application */
	CLEANSE_PLAINTEXT = 1,
	/* Allow initial connection to servers that don't support RI */
	LEGACY_SERVER_CONNECT = 2,
	/* Enable support for Kernel TLS */
	ENABLE_KTLS = 3,
	TLSEXT_PADDING = 4,
	SAFARI_ECDHE_ECDSA_BUG = 6,
	IGNORE_UNEXPECTED_EOF = 7,
	ALLOW_CLIENT_RENEGOTIATION = 8,
	DISABLE_TLSEXT_CA_NAMES = 9,
	/* In TLSv1.3 allow a non-(ec)dhe based kex_mode */
	ALLOW_NO_DHE_KEY = 10,
	/*
	 * Disable SSL 3.0/TLS 1.0 CBC vulnerability workaround that was added
	 * in OpenSSL 0.9.6d.  Usually (depending on the application protocol)
	 * the workaround is not needed.  Unfortunately some broken SSL/TLS
	 * implementations cannot handle it at all, which is why we include it
	 * in SSL_OP_ALL. Added in 0.9.6e
	 */
	DONT_INSERT_EMPTY_FRAGMENTS = 11,
	/* DTLS options */
	NO_QUERY_MTU = 12,
	/* Turn on Cookie Exchange (on relevant for servers) */
	COOKIE_EXCHANGE = 13,
	/* Don't use RFC4507 ticket extension */
	NO_TICKET = 14,
	/*
	 * Use Cisco's version identifier of DTLS_BAD_VER
	 * (only with deprecated DTLSv1_client_method())
	 */
	CISCO_ANYCONNECT = 15,
	/* As server, disallow session resumption on renegotiation */
	NO_SESSION_RESUMPTION_ON_RENEGOTIATION = 16,
	/* Don't use compression even if supported */
	NO_COMPRESSION = 17,
	/* Permit unsafe legacy renegotiation */
	ALLOW_UNSAFE_LEGACY_RENEGOTIATION = 18,
	/* Disable encrypt-then-mac */
	NO_ENCRYPT_THEN_MAC = 19,
	/*
	 * Enable TLSv1.3 Compatibility mode. This is on by default. A future
	 * version of OpenSSL may have this disabled by default.
	 */
	ENABLE_MIDDLEBOX_COMPAT = 20,
	/*
	 * Prioritize Chacha20Poly1305 when client does.
	 * Modifies SSL_OP_SERVER_PREFERENCE
	 */
	PRIORITIZE_CHACHA = 21,
	/*
	 * Set on servers to choose cipher, curve or group according to server's
	 * preferences.
	 */
	SERVER_PREFERENCE = 22,
	/*
	 * If set, a server will allow a client to issue an SSLv3.0 version
	 * number as latest version supported in the premaster secret, even when
	 * TLSv1.0 (version 3.1) was announced in the client hello. Normally
	 * this is forbidden to prevent version rollback attacks.
	 */
	TLS_ROLLBACK_BUG = 23,
	/*
	 * Switches off automatic TLSv1.3 anti-replay protection for early data.
	 * This is a server-side option only (no effect on the client).
	 */
	NO_ANTI_REPLAY = 24,
	NO_SSLv3 = 25,
	NO_TLSv1 = 26,
	NO_TLSv1_2 = 27,
	NO_TLSv1_1 = 28,
	NO_TLSv1_3 = 29,
	NO_DTLSv1 = 26,
	NO_DTLSv1_2 = 27,
	/* Disallow all renegotiation */
	NO_RENEGOTIATION = 30,
	/*
	 * Make server add server-hello extension from early version of
	 * cryptopro draft, when GOST ciphersuite is negotiated. Required for
	 * interoperability with CryptoPro CSP 3.x
	 */
	CRYPTOPRO_TLSEXT_BUG = 31,
	/*
	 * Disable RFC8879 certificate compression
	 * SSL_OP_NO_TX_CERTIFICATE_COMPRESSION: don't send compressed certificates,
	 *     and ignore the extension when received.
	 * SSL_OP_NO_RX_CERTIFICATE_COMPRESSION: don't send the extension, and
	 *     subsequently indicating that receiving is not supported
	 */
	NO_TX_CERTIFICATE_COMPRESSION = 32,
	NO_RX_CERTIFICATE_COMPRESSION = 33,
	/* Enable KTLS TX zerocopy on Linux */
	ENABLE_KTLS_TX_ZEROCOPY_SENDFILE = 34,
	PREFER_NO_DHE_KEX = 35,
	LEGACY_EC_POINT_FORMATS = 36,
}
Options :: bit_set[Option; u64]

/*
 * Option "collections."
 */
SSL_OP_NO_SSL_MASK  :: Options{.NO_SSLv3, .NO_TLSv1, .NO_TLSv1_1, .NO_TLSv1_2, .NO_TLSv1_3}
SSL_OP_NO_DTLS_MASK :: Options{.NO_DTLSv1, .NO_DTLSv1_2}
/* Various bug workarounds that should be rather harmless. */
SSL_OP_ALL :: Options{.CRYPTOPRO_TLSEXT_BUG, .DONT_INSERT_EMPTY_FRAGMENTS, .TLSEXT_PADDING, .SAFARI_ECDHE_ECDSA_BUG}

BIO_CTRL_GET_KTLS_SEND :: 73
BIO_CTRL_GET_KTLS_RECV :: 76

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
	SSL_CTX_set_options :: proc(ctx: SSL_CTX, options: Options) -> Options ---
	SSL_CTX_get_options :: proc(ctx: SSL_CTX) -> Options ---
	BIO_ctrl :: proc(bp: BIO, cmd: i32, larg: c.long, parg: rawptr) -> c.long ---
	SSL_get_rbio :: proc(ssl: SSL) -> BIO ---
	SSL_get_wbio :: proc(ssl: SSL) -> BIO ---
}

/* Macros */

SSL_set_tlsext_host_name :: proc(ssl: SSL, name: cstring) -> c.int {
	return c.int(SSL_ctrl(ssl, SSL_CTRL_SET_TLSEXT_HOSTNAME, TLSEXT_NAMETYPE_host_name, rawptr(name)))
}

BIO_ctrl_get_ktls_send :: proc(bp: BIO) -> bool {
	return BIO_ctrl(bp, BIO_CTRL_GET_KTLS_SEND, 0, nil) > 0
}

BIO_ctrl_get_ktls_recv :: proc(bp: BIO) -> bool {
	return BIO_ctrl(bp, BIO_CTRL_GET_KTLS_RECV, 0, nil) > 0
}
