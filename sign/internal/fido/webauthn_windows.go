package fido

// Windows' own WebAuthn API (webauthn.dll, Microsoft's webauthn.h): Windows Hello, or a security key through
// Windows' own dialog, which takes the PIN or the fingerprint itself. A desktop program may give it any relying
// party id and the client data it builds (docs/architecture.md, "wmanager-sign").

import (
	"errors"
	"fmt"
	"runtime"
	"unsafe"

	"golang.org/x/sys/windows"

	"github.com/lechup/wmanager/verify"
)

var (
	webauthnDLL             = windows.NewLazySystemDLL("webauthn.dll")
	procAPIVersion          = webauthnDLL.NewProc("WebAuthNGetApiVersionNumber")
	procMakeCredential      = webauthnDLL.NewProc("WebAuthNAuthenticatorMakeCredential")
	procGetAssertion        = webauthnDLL.NewProc("WebAuthNAuthenticatorGetAssertion")
	procFreeAttestation     = webauthnDLL.NewProc("WebAuthNFreeCredentialAttestation")
	procFreeAssertion       = webauthnDLL.NewProc("WebAuthNFreeAssertion")
	procErrorName           = webauthnDLL.NewProc("WebAuthNGetErrorName")
	user32                  = windows.NewLazySystemDLL("user32.dll")
	procGetForegroundWindow = user32.NewProc("GetForegroundWindow")
	kernel32                = windows.NewLazySystemDLL("kernel32.dll")
	procGetConsoleWindow    = kernel32.NewProc("GetConsoleWindow")
)

// The structures, as webauthn.h has them, in the versions used here (the API takes older versions).
type rpEntity struct {
	version uint32
	id      *uint16
	name    *uint16
	icon    *uint16
}

type userEntity struct {
	version     uint32
	cbID        uint32
	id          *byte
	name        *uint16
	icon        *uint16
	displayName *uint16
}

type clientData struct {
	version uint32
	cb      uint32
	json    *byte
	hashAlg *uint16
}

type coseParam struct {
	version  uint32
	credType *uint16
	alg      int32
}

type coseParams struct {
	count uint32
	list  *coseParam
}

type credential struct {
	version  uint32
	cbID     uint32
	id       *byte
	credType *uint16
}

type credentials struct {
	count uint32
	list  *credential
}

type extensions struct {
	count uint32
	list  uintptr
}

// makeCredentialOptions is WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS version 3, which every webauthn.dll knows
// (Windows 10 1903 on). Version 4's bPreferResidentKey would make a discoverable key only preferred.
type makeCredentialOptions struct {
	version            uint32
	timeout            uint32
	credentialList     credentials
	extensions         extensions
	attachment         uint32
	requireResidentKey int32
	userVerification   uint32
	attestation        uint32
	flags              uint32
	cancellationID     *windows.GUID
	excludeList        uintptr
}

// getAssertionOptions is WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS version 1.
type getAssertionOptions struct {
	version          uint32
	timeout          uint32
	credentialList   credentials
	extensions       extensions
	attachment       uint32
	userVerification uint32
	flags            uint32
}

// attestation is the start of WEBAUTHN_CREDENTIAL_ATTESTATION, as far as it is read.
type attestation struct {
	version           uint32
	formatType        *uint16
	cbAuthData        uint32
	authData          *byte
	cbAttestation     uint32
	attestation       *byte
	decodeType        uint32
	decode            uintptr
	cbAttestationObj  uint32
	attestationObject *byte
	cbCredentialID    uint32
	credentialID      *byte
	// version 2 on
	extensions extensions
	// version 3 on
	usedTransport uint32
	// version 4 on
	epAtt              int32
	largeBlobSupported int32
	residentKey        int32
}

// assertion is the start of WEBAUTHN_ASSERTION, as far as it is read.
type assertion struct {
	version    uint32
	cbAuthData uint32
	authData   *byte
	cbSig      uint32
	sig        *byte
	credential credential
}

const (
	attachmentAny       = 0
	uvRequired          = 1
	attestationNone     = 1
	timeoutMilliseconds = 120000
	credTypePublicKey   = "public-key"
	hashSHA256          = "SHA-256"
	coseES256           = -7
	errCancelled        = 0x800704C7 // HRESULT_FROM_WIN32(ERROR_CANCELLED)
	errTimeout          = 0x800705B4 // HRESULT_FROM_WIN32(ERROR_TIMEOUT)
	ntePermission       = 0x80090010 // NTE_PERM: the dialog was closed
	nteUserCancelled    = 0x80090036 // NTE_USER_CANCELLED
	nteNotFound         = 0x80090011 // NTE_NOT_FOUND: no credential of this relying party
)

type webauthnDevice struct{}

func init() { Opener = openWebAuthn }

func openWebAuthn(func([]string) (int, error)) (Device, error) {
	if err := procAPIVersion.Find(); err != nil {
		return nil, errors.New("this Windows has no WebAuthn API (webauthn.dll): Windows 10 1903 or newer is needed")
	}
	return webauthnDevice{}, nil
}

func (webauthnDevice) Name() string   { return "Windows Hello, or a security key (Windows)" }
func (webauthnDevice) NeedsPIN() bool { return false } // Windows' own dialog asks
func (webauthnDevice) Close() error   { return nil }

func window() uintptr {
	if h, _, _ := procGetForegroundWindow.Call(); h != 0 {
		return h
	}
	h, _, _ := procGetConsoleWindow.Call()
	return h
}

func utf16(s string) *uint16 {
	p, err := windows.UTF16PtrFromString(s)
	if err != nil {
		panic(err) // fixed strings without NUL
	}
	return p
}

var errNUL = errors.New("a name with a NUL character")

func bytesAt(p *byte, n uint32) []byte {
	if p == nil || n == 0 {
		return nil
	}
	return append([]byte(nil), unsafe.Slice(p, n)...)
}

func hresult(what string, r uintptr) error {
	switch uint32(r) {
	case 0:
		return nil
	case errCancelled, ntePermission, nteUserCancelled, errTimeout:
		return ErrNotTouched
	}
	name := ""
	if p, _, _ := procErrorName.Call(r); p != 0 {
		// A static string of webauthn.dll: read through the uintptr's address, as Go keeps no pointer to it.
		name = windows.UTF16PtrToString(*(**uint16)(unsafe.Pointer(&p)))
	}
	return fmt.Errorf("%s: Windows answered 0x%08X %s", what, uint32(r), name)
}

func (webauthnDevice) MakeCredential(u User, cd []byte, _ string) (Credential, error) {
	if len(u.ID) == 0 || len(cd) == 0 {
		return Credential{}, errors.New("a credential needs a user id and client data")
	}
	name, err1 := windows.UTF16PtrFromString(u.Name)
	display, err2 := windows.UTF16PtrFromString(u.DisplayName)
	if err1 != nil || err2 != nil {
		return Credential{}, errNUL
	}
	rp := rpEntity{version: 1, id: utf16(verify.RPID), name: utf16("wmanager-sign")}
	user := userEntity{version: 1, cbID: uint32(len(u.ID)), id: &u.ID[0], name: name, displayName: display}
	param := coseParam{version: 1, credType: utf16(credTypePublicKey), alg: coseES256}
	params := coseParams{count: 1, list: &param}
	data := clientData{version: 1, cb: uint32(len(cd)), json: &cd[0], hashAlg: utf16(hashSHA256)}
	opts := makeCredentialOptions{version: 3, timeout: timeoutMilliseconds, attachment: attachmentAny,
		requireResidentKey: 1, userVerification: uvRequired, attestation: attestationNone}
	var out *attestation
	r, _, _ := procMakeCredential.Call(window(), uintptr(unsafe.Pointer(&rp)), uintptr(unsafe.Pointer(&user)),
		uintptr(unsafe.Pointer(&params)), uintptr(unsafe.Pointer(&data)), uintptr(unsafe.Pointer(&opts)),
		uintptr(unsafe.Pointer(&out)))
	runtime.KeepAlive(u.ID)
	runtime.KeepAlive(cd)
	if err := hresult("making the key", r); err != nil {
		return Credential{}, err
	}
	if out == nil {
		return Credential{}, errors.New("making the key: Windows gave nothing back")
	}
	defer procFreeAttestation.Call(uintptr(unsafe.Pointer(out)))
	// A key made but not discoverable would sign only where its id is kept: refused, where Windows says so.
	if out.version >= 4 && out.residentKey == 0 {
		return Credential{}, errors.New("the key made isn't discoverable (the security key may have no room left for one)")
	}
	authData := bytesAt(out.authData, out.cbAuthData)
	id, cose, err := AttestedKey(authData)
	if err != nil {
		return Credential{}, err
	}
	if string(id) != string(bytesAt(out.credentialID, out.cbCredentialID)) {
		return Credential{}, errAuthData
	}
	return Credential{ID: id, COSE: cose, Flags: authData[32]}, nil
}

// Assert ignores the credentials allowed: Windows' dialog waits for a key that has one of them, and a key made on
// another computer would never do. Every key of wmanager-sign is discoverable; the person picks one, and the caller
// finds which by its signature.
func (webauthnDevice) Assert(cd []byte, _ [][]byte, _ string) ([]Assertion, error) {
	if len(cd) == 0 {
		return nil, errors.New("a signature needs client data")
	}
	data := clientData{version: 1, cb: uint32(len(cd)), json: &cd[0], hashAlg: utf16(hashSHA256)}
	opts := getAssertionOptions{version: 1, timeout: timeoutMilliseconds, attachment: attachmentAny, userVerification: uvRequired}
	var out *assertion
	r, _, _ := procGetAssertion.Call(window(), uintptr(unsafe.Pointer(utf16(verify.RPID))), uintptr(unsafe.Pointer(&data)),
		uintptr(unsafe.Pointer(&opts)), uintptr(unsafe.Pointer(&out)))
	runtime.KeepAlive(cd)
	if uint32(r) == nteNotFound {
		return nil, ErrNoCreds
	}
	if err := hresult("signing", r); err != nil {
		return nil, err
	}
	if out == nil {
		return nil, errors.New("signing: Windows gave nothing back")
	}
	defer procFreeAssertion.Call(uintptr(unsafe.Pointer(out)))
	return []Assertion{{
		CredentialID:      bytesAt(out.credential.id, out.credential.cbID),
		AuthenticatorData: bytesAt(out.authData, out.cbAuthData),
		Signature:         bytesAt(out.sig, out.cbSig),
	}}, nil
}
