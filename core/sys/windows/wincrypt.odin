#+build windows
package sys_windows

HCERTSTORE :: distinct rawptr

CRYPTOAPI_BLOB :: struct {
	cbData: DWORD,
	pbData: [^]BYTE,
}

CRYPT_INTEGER_BLOB :: distinct CRYPTOAPI_BLOB
CRYPT_OBJID_BLOB   :: distinct CRYPTOAPI_BLOB
CERT_NAME_BLOB     :: distinct CRYPTOAPI_BLOB

CRYPT_BIT_BLOB :: struct {
	cbData:      DWORD,
	pbData:      [^]BYTE,
	cUnusedBits: DWORD,
}

CRYPT_ALGORITHM_IDENTIFIER :: struct {
	pszObjId:   LPSTR,
	Parameters: CRYPT_OBJID_BLOB,
}

CERT_PUBLIC_KEY_INFO :: struct {
	Algorithm: CRYPT_ALGORITHM_IDENTIFIER,
	PublicKey: CRYPT_BIT_BLOB,
}

CERT_EXTENSION :: struct {
	pszObjId:  LPSTR,
	fCritical: BOOL,
	Value:     CRYPT_OBJID_BLOB,
}
PCERT_EXTENSION :: ^CERT_EXTENSION

CERT_INFO :: struct {
	dwVersion:            DWORD,
	SerialNumber:         CRYPT_INTEGER_BLOB,
	SignatureAlgorithm:   CRYPT_ALGORITHM_IDENTIFIER,
	Issuer:               CERT_NAME_BLOB,
	NotBefore:            FILETIME,
	NotAfter:             FILETIME,
	Subject:              CERT_NAME_BLOB,
	SubjectPublicKeyInfo: CERT_PUBLIC_KEY_INFO,
	IssuerUniqueId:       CRYPT_BIT_BLOB,
	SubjectUniqueId:      CRYPT_BIT_BLOB,
	cExtension:           DWORD,
	rgExtension:          PCERT_EXTENSION,
}
PCERT_INFO :: ^CERT_INFO

CERT_CONTEXT :: struct {
	dwCertEncodingType: DWORD,
	pbCertEncoded:      [^]BYTE,
	cbCertEncoded:      DWORD,
	pCertInfo:          PCERT_INFO,
	hCertStore:         HCERTSTORE,
}


