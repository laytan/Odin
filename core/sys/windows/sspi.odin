#+build windows
package sys_windows

foreign import secur32 "system:secur32.lib"

PSECURITY_STRING :: wstring

SECURITY_STATUS :: LONG

SECPKG_CRED_OUTBOUND :: 0x00000002

SECPKG_ATTR_STREAM_SIZES :: 4

SECBUFFER_VERSION        :: 0

SECBUFFER_EMPTY          :: 0
SECBUFFER_DATA           :: 1
SECBUFFER_TOKEN          :: 2
SECBUFFER_EXTRA          :: 5
SECBUFFER_STREAM_TRAILER :: 6
SECBUFFER_STREAM_HEADER  :: 7

ISC_REQ_USE_SUPPLIED_CREDS :: 0x00000080
ISC_REQ_ALLOCATE_MEMORY    :: 0x00000100
ISC_REQ_CONFIDENTIALITY    :: 0x00000010
ISC_REQ_REPLAY_DETECT      :: 0x00000004
ISC_REQ_SEQUENCE_DETECT    :: 0x00000008
ISC_REQ_STREAM             :: 0x00008000

SecHandle :: struct {
	dwLower: ULONG_PTR,
	dwUpper: ULONG_PTR,
}
PSecHandle :: ^SecHandle

CredHandle  :: distinct SecHandle
PCredHandle :: ^CredHandle

CtxtHandle  :: distinct SecHandle
PCtxtHandle :: ^CtxtHandle

TimeStamp  :: distinct LARGE_INTEGER
PTimeStamp :: ^TimeStamp

SEC_GET_KEY_FN :: #type proc "system" (Arg: rawptr, Principal: rawptr, KeyVar: c_ulong, Key: ^rawptr, Status: ^SECURITY_STATUS)

SecPkgContext_StreamSizes :: struct {
	cbHeader:         c_ulong,
	cbTrailer:        c_ulong,
	cbMaximumMessage: c_ulong,
	cBuffers:         c_ulong,
	cbBlockSize:      c_ulong,
}

SecBuffer :: struct {
	cbBuffer:   c_ulong,
	BufferType: c_ulong,
	pvBuffer:   rawptr,
}
PSecBuffer :: ^SecBuffer

SecBufferDesc :: struct {
	ulVersion: c_ulong,
	cBuffers:  c_ulong,
	pBuffers:  [^]SecBuffer,
}
PSecBufferDesc :: ^SecBufferDesc

@(default_calling_convention="system")
foreign secur32 {
	AcquireCredentialsHandleW :: proc(
		pPrincipal:       PSECURITY_STRING,
		pPackage:         PSECURITY_STRING,
		fCredentialUse:   c_ulong,
		pvLogonId:        rawptr,
		pAuthData:        rawptr,
		pGetKeyFn:        SEC_GET_KEY_FN,
		pvGetKeyArgument: rawptr,
		phCredentials:    PCredHandle,
		ptsExpiry:        PTimeStamp,
	) -> SECURITY_STATUS ---
	FreeCredentialsHandle :: proc(phCredential: PCredHandle) -> SECURITY_STATUS ---

	InitializeSecurityContextW :: proc(
		phCredential:  PCredHandle,
		phContext:     PCtxtHandle,
		pTargetName:   PSECURITY_STRING,
		fContextReq:   c_ulong,
		Reserved1:     c_ulong,
		TargetDataRep: c_ulong,
		pInput:        PSecBufferDesc,
		Reserved2:     c_ulong,
		phNewContext:  PCtxtHandle,
		POutput:       PSecBufferDesc,
		pfContextAttr: ^c_ulong,
		ptsExpiry:     PTimeStamp,
	) -> SECURITY_STATUS ---
	DeleteSecurityContext :: proc(phContext: PCtxtHandle) -> SECURITY_STATUS ---

	QueryContextAttributesW :: proc(
		phContext:   PCtxtHandle,
		ulAttribute: c_ulong,
		pBuffer:     rawptr,
	) -> SECURITY_STATUS ---

	EncryptMessage :: proc(
		phContext:    PCtxtHandle,
		fQOP:         c_ulong,
		pMessage:     PSecBufferDesc,
		MessageSeqNo: c_ulong,
	) -> SECURITY_STATUS ---

	DecryptMessage :: proc(
		phContext:    PCtxtHandle,
		pMessage:     PSecBufferDesc,
		MessageSeqNo: c_ulong,
		pfQOP:        ^c_ulong,
	) -> SECURITY_STATUS ---

	ApplyControlToken :: proc(
		phContext: PCtxtHandle,
		pInput:    PSecBufferDesc,
	) -> SECURITY_STATUS ---

	FreeContextBuffer :: proc(pvContextBuffer: PVOID) ---
}