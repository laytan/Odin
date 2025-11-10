#+build windows
package sys_windows

SCHANNEL_SHUTDOWN :: 1

SCH_USE_STRONG_CRYPTO         :: 0x00400000
SCH_CRED_NO_DEFAULT_CREDS     :: 0x00000010
SCH_CRED_AUTO_CRED_VALIDATION :: 0x00000020

SP_PROT_TLS1_2_SERVER :: 0x00000400
SP_PROT_TLS1_2_CLIENT :: 0x00000800
SP_PROT_TLS1_2        :: SP_PROT_TLS1_2_SERVER|SP_PROT_TLS1_2_CLIENT

SCHANNEL_CRED_VERSION :: 0x00000004

UNISP_NAME :: "Microsoft Unified Security Protocol Provider"

SCHANNEL_CRED :: struct {
	dwVersion:  DWORD,
	cCreds:     DWORD,
	paCred:     [^]^CERT_CONTEXT,
	hRootStore: HCERTSTORE,

	cMappers:   DWORD,
	aphMappers: [^]rawptr,

	cSupportedAlgs:    DWORD,
	palgSupportedAlgs: [^]ALG_ID,

	grbitEnabledProtocols:   DWORD,
	dwMinimumCipherStrength: DWORD,
	dwMaximumCipherStrength: DWORD,
	dwSessionLifespan:       DWORD,
	dwFlags:                 DWORD,
	dwCredFormat:            DWORD,
}