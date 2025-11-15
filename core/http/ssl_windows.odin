#+vet explicit-allocators
package http

import "core:mem"
import "core:net"
import "core:slice"
import win "core:sys/windows"

TLS_MAX_PACKET_SIZE :: 16384+512 // payload + extra over head for header/mac/padding (probably an overestimate)

Schannel_Client :: struct {
	allocator: mem.Allocator,
	handle:    win.CredHandle,
}

Schannel_Connection :: struct {
	handle:    win.CredHandle, // of client

	allocator: mem.Allocator,
	ctx:       win.CtxtHandle,
	sizes:     win.SecPkgContext_StreamSizes,
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
		client_create = proc(allocator: mem.Allocator) -> SSL_Client {
			client := new(Schannel_Client, allocator)
			client.allocator = allocator

			status := win.AcquireCredentialsHandleW(
				"",
				win.UNISP_NAME,
				win.SECPKG_CRED_OUTBOUND,
				nil,
				&win.SCHANNEL_CRED{
					dwVersion             = win.SCHANNEL_CRED_VERSION,
					dwFlags               = win.SCH_USE_STRONG_CRYPTO|win.SCH_CRED_AUTO_CRED_VALIDATION|win.SCH_CRED_NO_DEFAULT_CREDS,
					grbitEnabledProtocols = win.SP_PROT_TLS1_2,
				},
				nil,
				nil,
				&client.handle,
				nil,
			)
			if status != 0 {
				free(client, allocator)
				return nil
			}

			return SSL_Client(client)
		},
		client_destroy = proc(_client: SSL_Client) {
			client := (^Schannel_Client)(_client)
			win.FreeCredentialsHandle(&client.handle)
			free(client, client.allocator)
		},
		connection_create = proc(_client: SSL_Client, socket: net.TCP_Socket, host: string, allocator: mem.Allocator) -> SSL_Connection {
			client := (^Schannel_Client)(_client)

			assert(len(host) > 0)

			n := win.MultiByteToWideChar(win.CP_UTF8, win.MB_ERR_INVALID_CHARS, raw_data(host), i32(len(host)), nil, 0)
			if n == 0 { return nil }
			nbytes := n * size_of(u16)

			data, err := mem.alloc_bytes(int(size_of(Schannel_Connection) + nbytes + size_of(u16)), align_of(Schannel_Connection), allocator)
			if err != nil { return nil }

			connection := (^Schannel_Connection)(raw_data(data))
			host_buf   := slice.reinterpret([]u16, data[size_of(Schannel_Connection):][:nbytes])
			_n := win.MultiByteToWideChar(win.CP_UTF8, win.MB_ERR_INVALID_CHARS, raw_data(host), i32(len(host)), raw_data(host_buf), i32(len(host_buf)))
			assert(n == _n)

			connection.allocator = allocator
			connection.handle    = client.handle
			connection.socket    = socket
			connection.host      = cstring16(raw_data(host_buf))

			return SSL_Connection(connection)
		},
		connection_destroy = proc(client: SSL_Client, _c: SSL_Connection) {
			c := (^Schannel_Connection)(_c)

			type: win.DWORD = win.SCHANNEL_SHUTDOWN
			in_buffers := [1]win.SecBuffer{
				{ size_of(type), win.SECBUFFER_TOKEN, &type },
			}
			in_desc := win.SecBufferDesc{ win.SECBUFFER_VERSION, len(in_buffers), raw_data(&in_buffers) }
			win.ApplyControlToken(&c.ctx, &in_desc)

			out_buffers := [1]win.SecBuffer{
				{ 0, win.SECBUFFER_TOKEN, nil },
			}
			out_desc := win.SecBufferDesc{ win.SECBUFFER_VERSION, len(out_buffers), raw_data(&out_buffers) }

			flags: win.DWORD = win.ISC_REQ_ALLOCATE_MEMORY|win.ISC_REQ_CONFIDENTIALITY|win.ISC_REQ_REPLAY_DETECT|win.ISC_REQ_SEQUENCE_DETECT|win.ISC_REQ_STREAM
			status := win.InitializeSecurityContextW(
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
			if status == 0 {
				// Ignore return values, we are closing down anyway.
				_, _ = net.send_tcp(c.socket, ([^]byte)(out_buffers[0].pvBuffer)[:out_buffers[0].cbBuffer])
				win.FreeContextBuffer(out_buffers[0].pvBuffer)
			}

			win.DeleteSecurityContext(&c.ctx)
			free(c, c.allocator)
		},
		connect = proc(_c: SSL_Connection) -> (res: SSL_Result) {
			c := (^Schannel_Connection)(_c)

			defer if res == nil {
				win.QueryContextAttributesW(&c.ctx, win.SECPKG_ATTR_STREAM_SIZES, &c.sizes)
			}

			has_ctx := c.ctx != {}
			for {
				in_buffers: [2]win.SecBuffer
				in_buffers[0].BufferType = win.SECBUFFER_TOKEN
				in_buffers[0].pvBuffer   = raw_data(&c.incoming)
				in_buffers[0].cbBuffer   = c.received

				out_buffers: [1]win.SecBuffer
				out_buffers[0].BufferType = win.SECBUFFER_TOKEN

				in_desc  := win.SecBufferDesc{ win.SECBUFFER_VERSION, len(in_buffers), raw_data(&in_buffers) }
				out_desc := win.SecBufferDesc{ win.SECBUFFER_VERSION, len(out_buffers), raw_data(&out_buffers) }

				flags: win.DWORD = win.ISC_REQ_USE_SUPPLIED_CREDS|win.ISC_REQ_ALLOCATE_MEMORY|win.ISC_REQ_CONFIDENTIALITY|win.ISC_REQ_REPLAY_DETECT|win.ISC_REQ_SEQUENCE_DETECT|win.ISC_REQ_STREAM

				status := win.InitializeSecurityContextW(
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

				if in_buffers[1].BufferType == win.SECBUFFER_EXTRA {
					copy(c.incoming[:], c.incoming[c.received - in_buffers[1].cbBuffer:][:in_buffers[1].cbBuffer])
					c.received = in_buffers[1].cbBuffer
				} else {
					c.received = 0
				}

				switch u32(status) {
				case 0:
					return
				case win.SEC_I_INCOMPLETE_CREDENTIALS:
					unimplemented("server asked for client ceritficate")
				case win.SEC_I_CONTINUE_NEEDED:
					// need to send data to server
					// TODO: non-blocking
					n, err := net.send(c.socket, ([^]byte)(out_buffers[0].pvBuffer)[:out_buffers[0].cbBuffer])
					defer win.FreeContextBuffer(out_buffers[0].pvBuffer)

					if err != nil {
						res = .Fatal
						return
					}
					assert(n == int(out_buffers[0].cbBuffer))

				case win.SEC_E_INCOMPLETE_MESSAGE:
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

				buffers := [3]win.SecBuffer{
					{ c.sizes.cbHeader, win.SECBUFFER_STREAM_HEADER, raw_data(&wBuffer) },
					{ use, win.SECBUFFER_DATA, raw_data(wBuffer[c.sizes.cbHeader:]) },
					{ c.sizes.cbTrailer, win.SECBUFFER_STREAM_TRAILER, raw_data(wBuffer[c.sizes.cbHeader + use:]) },
				}
				copy(([^]byte)(buffers[1].pvBuffer)[:use], data)

				desc := win.SecBufferDesc{ win.SECBUFFER_VERSION, len(buffers), raw_data(&buffers) }
				status := win.EncryptMessage(&c.ctx, 0, &desc, 0)
				if status != 0 {
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
						buffers := [4]win.SecBuffer{
							{ c.received, win.SECBUFFER_DATA, raw_data(&c.incoming) },
							{},
							{},
							{},
						}
						assert(c.sizes.cBuffers == len(buffers))
						desc := win.SecBufferDesc{ win.SECBUFFER_VERSION, len(buffers), raw_data(&buffers) }

						status := win.DecryptMessage(&c.ctx, &desc, 0, nil)
						switch u32(status) {
						case 0:
							assert(buffers[0].BufferType == win.SECBUFFER_STREAM_HEADER)
							assert(buffers[1].BufferType == win.SECBUFFER_DATA)
							assert(buffers[2].BufferType == win.SECBUFFER_STREAM_TRAILER)

							c.decrypted = ([^]byte)(buffers[1].pvBuffer)
							c.available = buffers[1].cbBuffer
							c.used = c.received - (buffers[3].BufferType == win.SECBUFFER_EXTRA ? buffers[3].cbBuffer : 0)

							// data is now decrypted, go back to beginning of loop to copy memory to output buffer
							continue
						case win.SEC_I_CONTEXT_EXPIRED:
							// server closed TLS connection (but socket is still open)
							c.received = 0
							res = .Shutdown
							return
						case win.SEC_I_RENEGOTIATE:
							unimplemented("server wants to renegotiate")
						case win.SEC_E_INCOMPLETE_MESSAGE:
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