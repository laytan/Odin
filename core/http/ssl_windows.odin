package http

import "core:net"
import win "core:sys/windows"

foreign import lib {
	"system:secur32.lib",
	"system:ws2_32.lib",
	"system:shlwapi.lib",
}

PSECURITY_STRING :: win.wstring

SEC_GET_KEY_FN :: #type proc "system" (Arg: rawptr, Principal: rawptr, KeyVar: win.c_ulong, Key: ^rawptr, Status: ^SECURITY_STATUS)

SECURITY_STATUS :: win.c_long

SEC_E_OK                  :: 0x00000000
SEC_E_INSUFFICIENT_MEMORY :: 0x80090300
SEC_E_INTERNAL_ERROR      :: 0x80090304
SEC_E_NO_CREDENTIALS      :: 0x8009030E
SEC_E_NOT_OWNER           :: 0x80090306
SEC_E_SECPKG_NOT_FOUND    :: 0x80090305
SEC_E_UNKNOWN_CREDENTIALS :: 0x8009030D
SEC_E_INCOMPLETE_MESSAGE  :: 0x80090318

SEC_I_INCOMPLETE_CREDENTIALS :: 0x00090320
SEC_I_CONTINUE_NEEDED        :: 0x00090312
SEC_I_CONTEXT_EXPIRED        :: 0x00090317
SEC_I_RENEGOTIATE            :: 0x00090321

SCHANNEL_SHUTDOWN :: 1

SecHandle :: struct {
	dwLower: win.ULONG_PTR,
	dwUpper: win.ULONG_PTR,
}

TimeStamp :: struct {
	LowPart:  win.DWORD,
	HighPart: win.LONG,
}
PTimeStamp :: ^TimeStamp

CredHandle  :: distinct SecHandle
PCredHandle :: ^CredHandle

CtxtHandle  :: distinct SecHandle
PCtxtHandle :: ^CtxtHandle

SECPKG_CRED_OUTBOUND :: 0x00000002

CRYPTOAPI_BLOB :: struct {
	cbData: win.DWORD,
	pbData: [^]win.BYTE,
}

CRYPT_INTEGER_BLOB :: distinct CRYPTOAPI_BLOB
CRYPT_OBJID_BLOB :: distinct CRYPTOAPI_BLOB
CERT_NAME_BLOB :: distinct CRYPTOAPI_BLOB

CRYPT_BIT_BLOB :: struct {
	cbData: win.DWORD,
	pbData: [^]win.BYTE,
	cUnusedBits: win.DWORD,
}

CRYPT_ALGORITHM_IDENTIFIER :: struct {
	pszObjId: win.LPSTR,
	Parameters: CRYPT_OBJID_BLOB,
}

CERT_PUBLIC_KEY_INFO :: struct {
	Algorithm: CRYPT_ALGORITHM_IDENTIFIER,
	PublicKey: CRYPT_BIT_BLOB,
}

CERT_EXTENSION :: struct {
	pszObjId: win.LPSTR,
	fCritical: win.BOOL,
	Value: CRYPT_OBJID_BLOB,
}
PCERT_EXTENSION :: ^CERT_EXTENSION

CERT_INFO :: struct {
	dwVersion: win.DWORD,
	SerialNumber: CRYPT_INTEGER_BLOB,
	SignatureAlgorithm: CRYPT_ALGORITHM_IDENTIFIER,
	Issuer: CERT_NAME_BLOB,
	NotBefore: win.FILETIME,
	NotAfter: win.FILETIME,
	Subject: CERT_NAME_BLOB,
	SubjectPublicKeyInfo: CERT_PUBLIC_KEY_INFO,
	IssuerUniqueId: CRYPT_BIT_BLOB,
	SubjectUniqueId: CRYPT_BIT_BLOB,
	cExtension: win.DWORD,
	rgExtension: PCERT_EXTENSION,

}
PCERT_INFO :: ^CERT_INFO

HCERTSTORE :: distinct rawptr

ALG_ID :: distinct win.c_uint

CERT_CONTEXT :: struct {
	dwCertEncodingType: win.DWORD,
	pbCertEncoded: ^win.BYTE,
	cbCertEncoded: win.DWORD,
	pCertInfo: PCERT_INFO,
	hCertStore: HCERTSTORE,
}

SCHANNEL_CRED :: struct {
	dwVersion: win.DWORD,
	cCreds: win.DWORD,
	paCred: [^]^CERT_CONTEXT,
	hRootStore: HCERTSTORE,

	cMappers: win.DWORD,
	aphMappers: [^]^struct{},

	cSupportedAlgs: win.DWORD,
	palgSupportedAlgs: [^]ALG_ID,

	grbitEnabledProtocols: win.DWORD,
	dwMinimumCipherStrength: win.DWORD,
	dwMaximumCipherStrength: win.DWORD,
	dwSessionLifespan: win.DWORD,
	dwFlags: win.DWORD,
	dwCredFormat: win.DWORD,
}

SecBuffer :: struct {
	cbBuffer: win.c_ulong,
	BufferType: win.c_ulong,
	pvBuffer: rawptr,
}
PSecBuffer :: ^SecBuffer

SecBufferDesc :: struct {
	ulVersion: win.c_ulong,
	cBuffers: win.c_ulong,
	pBuffers: [^]SecBuffer,
}
PSecBufferDesc :: ^SecBufferDesc

SCHANNEL_CRED_VERSION   :: 0x00000004
SCH_CREDENTIALS_VERSION :: 0x00000005

UNISP_NAME :: "Microsoft Unified Security Protocol Provider"

SCH_USE_STRONG_CRYPTO :: 0x00400000
SCH_CRED_NO_DEFAULT_CREDS :: 0x00000010
SCH_CRED_AUTO_CRED_VALIDATION :: 0x00000020

ISC_REQ_USE_SUPPLIED_CREDS :: 0x00000080
ISC_REQ_ALLOCATE_MEMORY    :: 0x00000100
ISC_REQ_CONFIDENTIALITY    :: 0x00000010
ISC_REQ_REPLAY_DETECT      :: 0x00000004
ISC_REQ_SEQUENCE_DETECT    :: 0x00000008
ISC_REQ_STREAM             :: 0x00008000

SP_PROT_TLS1_2_CLIENT :: 0x00000800

SECBUFFER_VERSION        :: 0

SECBUFFER_EMPTY          :: 0
SECBUFFER_DATA           :: 1
SECBUFFER_TOKEN          :: 2
SECBUFFER_EXTRA          :: 5
SECBUFFER_STREAM_TRAILER :: 6
SECBUFFER_STREAM_HEADER  :: 7

foreign lib {
	AcquireCredentialsHandleW :: proc(
		pPrincipal: PSECURITY_STRING,
		pPackage: PSECURITY_STRING,
		fCredentialUse: win.c_ulong,
		pvLogonId: rawptr,
		pAuthData: rawptr,
		pGetKeyFn: SEC_GET_KEY_FN,
		pvGetKeyArgument: rawptr,
		phCredentials: PCredHandle,
		ptsExpiry: PTimeStamp,
	) -> SECURITY_STATUS ---

	FreeCredentialsHandle :: proc(phCredential: PCredHandle) -> SECURITY_STATUS ---
	FreeContextBuffer :: proc(pvContextBuffer: win.PVOID) ---

	InitializeSecurityContextW :: proc(
		phCredential: PCredHandle,
		phContext: PCtxtHandle,
		pTargetName: PSECURITY_STRING,
		fContextReq: win.c_ulong,
		Reserved1: win.c_ulong,
		TargetDataRep: win.c_ulong,
		pInput: PSecBufferDesc,
		Reserved2: win.c_ulong,
		phNewContext: PCtxtHandle,
		POutput: PSecBufferDesc,
		pfContextAttr: ^win.c_ulong,
		ptsExpiry: PTimeStamp,
	) -> SECURITY_STATUS ---

	QueryContextAttributesW :: proc(
		phContext: PCtxtHandle,
		ulAttribute: win.c_ulong,
		pBuffer: rawptr,
	) -> SECURITY_STATUS ---

	EncryptMessage :: proc(
		phContext: PCtxtHandle,
		fQOP: win.c_ulong,
		pMessage: PSecBufferDesc,
		MessageSeqNo: win.c_ulong,
	) -> SECURITY_STATUS ---

	DecryptMessage :: proc(
		phContext: PCtxtHandle,
		pMessage: PSecBufferDesc,
		MessageSeqNo: win.c_ulong,
		pfQOP: ^win.c_ulong,
	) -> SECURITY_STATUS ---

	ApplyControlToken :: proc(
		phContext: PCtxtHandle,
		pInput: PSecBufferDesc,
	) -> SECURITY_STATUS ---

	DeleteSecurityContext :: proc(phContext: PCtxtHandle) -> SECURITY_STATUS ---
}

// NOTE: NOT FROM WIN HEADER
TLS_MAX_PACKET_SIZE :: 16384+512 // payload + extra over head for header/mac/padding (probably an overestimate)

Schannel_Client :: struct {
	handle: CredHandle,
}

SecPkgContext_StreamSizes :: struct {
	cbHeader:         win.c_ulong,
	cbTrailer:        win.c_ulong,
	cbMaximumMessage: win.c_ulong,
	cBuffers:         win.c_ulong,
	cbBlockSize:      win.c_ulong,
}
SECPKG_ATTR_STREAM_SIZES :: 4

Schannel_Connection :: struct {
	handle:    CredHandle, // of client

	ctx:       CtxtHandle,
	sizes:     SecPkgContext_StreamSizes,
	socket:    net.TCP_Socket,
	host:      cstring16,
	received:  u32, // byte count in incoming buffer (ciphertext)
	used:      u32, // byte count used from incoming bufer to decrypt current packet
	available: u32, // byte count available for decrypted bytes
	decrypted: [^]byte, // points to incoming buffer where data is decrypted inplace
	incoming:  [TLS_MAX_PACKET_SIZE]byte,
}

native_ssl_implementation :: proc() -> Client_SSL {
	return {
		client_create = proc() -> SSL_Client {
			client := new(Schannel_Client) // TODO: allocator?
			status := AcquireCredentialsHandleW(
				"",
				UNISP_NAME,
				SECPKG_CRED_OUTBOUND,
				nil,
				&SCHANNEL_CRED{
					dwVersion             = SCHANNEL_CRED_VERSION,
					dwFlags               = SCH_USE_STRONG_CRYPTO|SCH_CRED_AUTO_CRED_VALIDATION|SCH_CRED_NO_DEFAULT_CREDS,
					grbitEnabledProtocols = SP_PROT_TLS1_2_CLIENT,
				},
				nil,
				nil,
				&client.handle,
				nil,
			)
			if status != SEC_E_OK {
				free(client)
				return nil
			}

			return SSL_Client(client)
		},
		client_destroy = proc(_client: SSL_Client) {
			client := (^Schannel_Client)(_client)
			FreeCredentialsHandle(&client.handle)
			free(client)
		},
		connection_create = proc(_client: SSL_Client, socket: net.TCP_Socket, host: cstring) -> SSL_Connection {
			client := (^Schannel_Client)(_client)

			connection := new(Schannel_Connection) // TODO:
			connection.handle = client.handle
			connection.socket = socket
			connection.host   = win.utf8_to_wstring_alloc(string(host)) // TODO: allocator

			return SSL_Connection(connection)
		},
		connection_destroy = proc(client: SSL_Client, _c: SSL_Connection) {
			c := (^Schannel_Connection)(_c)

			type: win.DWORD = SCHANNEL_SHUTDOWN
			in_buffers := [1]SecBuffer{
				{ size_of(type), SECBUFFER_TOKEN, &type },
			}
			in_desc := SecBufferDesc{ SECBUFFER_VERSION, len(in_buffers), raw_data(&in_buffers) }
			ApplyControlToken(&c.ctx, &in_desc)

			out_buffers := [1]SecBuffer{
				{ 0, SECBUFFER_TOKEN, nil },
			}
			out_desc := SecBufferDesc{ SECBUFFER_VERSION, len(out_buffers), raw_data(&out_buffers) }

			flags: win.DWORD = ISC_REQ_ALLOCATE_MEMORY|ISC_REQ_CONFIDENTIALITY|ISC_REQ_REPLAY_DETECT|ISC_REQ_SEQUENCE_DETECT|ISC_REQ_STREAM
			status := InitializeSecurityContextW(
				&c.handle,
				&c.ctx,
				nil,
				flags,
				0,
				0,
				&out_desc,
				0,
				nil,
				&out_desc,
				&flags,
				nil,
			)
			if status == SEC_E_OK {
				// Ignore return values, we are closing down anyway.
				_, _ = net.send_tcp(c.socket, ([^]byte)(out_buffers[0].pvBuffer)[:out_buffers[0].cbBuffer])
				FreeContextBuffer(out_buffers[0].pvBuffer)
			}

			DeleteSecurityContext(&c.ctx)
			delete(c.host)
			free(c)
		},
		connect = proc(_c: SSL_Connection) -> (res: SSL_Result) {
			c := (^Schannel_Connection)(_c)

			defer if res == nil {
				QueryContextAttributesW(&c.ctx, SECPKG_ATTR_STREAM_SIZES, &c.sizes)
			}

			has_ctx := c.ctx != {}
			for {
				in_buffers: [2]SecBuffer
				in_buffers[0].BufferType = SECBUFFER_TOKEN
				in_buffers[0].pvBuffer   = raw_data(&c.incoming)
				in_buffers[0].cbBuffer   = c.received

				out_buffers: [1]SecBuffer
				out_buffers[0].BufferType = SECBUFFER_TOKEN

				in_desc  := SecBufferDesc{ SECBUFFER_VERSION, len(in_buffers), raw_data(&in_buffers) }
				out_desc := SecBufferDesc{ SECBUFFER_VERSION, len(out_buffers), raw_data(&out_buffers) }

				flags: win.DWORD = ISC_REQ_USE_SUPPLIED_CREDS|ISC_REQ_ALLOCATE_MEMORY|ISC_REQ_CONFIDENTIALITY|ISC_REQ_REPLAY_DETECT|ISC_REQ_SEQUENCE_DETECT|ISC_REQ_STREAM

				status := InitializeSecurityContextW(
					&c.handle,
					has_ctx ? &c.ctx : nil,
					has_ctx ? nil : c.host,
					flags,
					0,
					0,
					has_ctx ? &in_desc : nil,
					0,
					has_ctx ? nil : &c.ctx,
					&out_desc,
					&flags,
					nil,
				)

				if in_buffers[1].BufferType == SECBUFFER_EXTRA {
					copy(c.incoming[:], c.incoming[c.received - in_buffers[1].cbBuffer:][:in_buffers[1].cbBuffer])
					c.received = in_buffers[1].cbBuffer
				} else {
					c.received = 0
				}

				switch u32(status) {
				case SEC_E_OK:
					return
				case SEC_I_INCOMPLETE_CREDENTIALS:
					unimplemented("server asked for client ceritficate")
				case SEC_I_CONTINUE_NEEDED:
					// need to send data to server
					// TODO: non-blocking
					n, err := net.send(c.socket, ([^]byte)(out_buffers[0].pvBuffer)[:out_buffers[0].cbBuffer])
					defer FreeContextBuffer(out_buffers[0].pvBuffer)

					if err != nil {
						res = .Fatal
						return
					}
					assert(n == int(out_buffers[0].cbBuffer))

				case SEC_E_INCOMPLETE_MESSAGE:
					// no-op
				case:
					// SEC_E_CERT_EXPIRED - certificate expired or revoked
					// SEC_E_WRONG_PRINCIPAL - bad hostname
					// SEC_E_UNTRUSTED_ROOT - cannot vertify CA chain
					// SEC_E_ILLEGAL_MESSAGE / SEC_E_ALGORITHM_MISMATCH - cannot negotiate crypto algorithms
					res = .Fatal
					return
				}

				if c.received == size_of(c.incoming) {
					// server is sending too much data instead of proper handshake?
					res = .Fatal
					return
				}

				n, err := net.recv(c.socket, c.incoming[c.received:])
				if err == .Would_Block {
					res = .Want_Read
					return
				} else if err != nil {
					res = .Fatal
					return
				} else if n == 0 {
					// disconnect
					res = .Shutdown
					return
				}
				c.received += u32(n)
			}
		},
		send = proc(_c: SSL_Connection, data: []byte) -> (sent: int, res: SSL_Result) {
			c    := (^Schannel_Connection)(_c)
			data := data
			for len(data) > 0 {
				use := min(u32(len(data)), c.sizes.cbMaximumMessage)

				wBuffer: [TLS_MAX_PACKET_SIZE]byte = ---
				assert(c.sizes.cbHeader + c.sizes.cbMaximumMessage + c.sizes.cbTrailer <= size_of(wBuffer))

				buffers := [3]SecBuffer{
					{ c.sizes.cbHeader, SECBUFFER_STREAM_HEADER, raw_data(&wBuffer) },
					{ use, SECBUFFER_DATA, raw_data(wBuffer[c.sizes.cbHeader:]) },
					{ c.sizes.cbTrailer, SECBUFFER_STREAM_TRAILER, raw_data(wBuffer[c.sizes.cbHeader + use:]) },
				}
				copy(([^]byte)(buffers[1].pvBuffer)[:use], data)

				desc := SecBufferDesc{ SECBUFFER_VERSION, len(buffers), raw_data(&buffers) }
				status := EncryptMessage(&c.ctx, 0, &desc, 0)
				if status != SEC_E_OK {
					res = .Fatal
					return
				}

				// TODO: non-blocking
				total := buffers[0].cbBuffer + buffers[1].cbBuffer + buffers[2].cbBuffer
				_sent, err := net.send_tcp(c.socket, wBuffer[:total])
				if err != nil {
					// TODO: are all these errors fatal?
					res = .Fatal
					return
				} else if _sent == 0 {
					res = .Shutdown
					return
				}

				sent += _sent
				data = data[use:]
			}

			return
		},
		recv = proc(_c: SSL_Connection, buf: []byte) -> (received: int, res: SSL_Result) {
			c   := (^Schannel_Connection)(_c)
			buf := buf

			for len(buf) > 0 {
				if c.decrypted != nil {
					// if there is decrypted data available, then use it as much as possible
					use := min(u32(len(buf)), c.available)
					copy(buf, c.decrypted[:use])
					buf = buf[use:]
					received += int(use)

					if use == c.available {
						// all decrypted data is used, remove ciphertext from incoming buffer so next time it starts from the beginning
						copy(c.incoming[:c.received - c.used], c.incoming[c.used:])
						c.received -= c.used
						c.used = 0
						c.available = 0
						c.decrypted = nil
					} else {
						c.available -= use
						c.decrypted = c.decrypted[use:]
					}
				} else {
					if c.received != 0 {
						// if any ciphertext data available then try to decrypt it
						buffers := [4]SecBuffer{
							{ c.received, SECBUFFER_DATA, raw_data(&c.incoming) },
							{},
							{},
							{},
						}
						assert(c.sizes.cBuffers == len(buffers))
						desc := SecBufferDesc{ SECBUFFER_VERSION, len(buffers), raw_data(&buffers) }

						status := DecryptMessage(&c.ctx, &desc, 0, nil)
						switch u32(status) {
						case SEC_E_OK:
							assert(buffers[0].BufferType == SECBUFFER_STREAM_HEADER)
							assert(buffers[1].BufferType == SECBUFFER_DATA)
							assert(buffers[2].BufferType == SECBUFFER_STREAM_TRAILER)

							c.decrypted = ([^]byte)(buffers[1].pvBuffer)
							c.available = buffers[1].cbBuffer
							c.used = c.received - (buffers[3].BufferType == SECBUFFER_EXTRA ? buffers[3].cbBuffer : 0)

							// data is now decrypted, go back to beginning of loop to copy memory to output buffer
							continue
						case SEC_I_CONTEXT_EXPIRED:
							// server closed TLS connection (but socket is still open)
							c.received = 0
							res = .Shutdown
							return
						case SEC_I_RENEGOTIATE:
							unimplemented("server wants to renegotiate")
						case SEC_E_INCOMPLETE_MESSAGE:
							// no-op, read more data
						case:
							// some other schannel or TLS protocol error
							res = .Fatal
							return
						}
					}
					// otherwise not enough data received to decrypt

					if received > 0 {
						// some data is already copied to output buffer, so return that before blocking with recv
						break
					}

					if c.received >= size_of(c.incoming) {
						// server is sending too much garbage data instead of proper TLS packet
						res = .Fatal
						return
					}

					// TODO: non-blocking
					// wait for more ciphertext data from server
					_received, err := net.recv_tcp(c.socket, c.incoming[c.received:])
					if err == .Would_Block {
						res = .Want_Read
						return
					} else if err != nil {
						// error receiving data from socket
						res = .Fatal
						break
					} else if _received == 0 {
						// server disconnected socket
						res = .Shutdown
						return
					}
					c.received += u32(_received)
				}
			}

			return
		},
	}
}