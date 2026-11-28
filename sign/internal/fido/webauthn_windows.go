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

// makeCredentialOptions is WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS version 4.
type makeCredentialOptions struct {
	version               uint32
	timeout               uint32
	credentialList        credentials
	extensions            extensions
	attachment            uint32
	requireResidentKey    int32
	userVerification      uint32
	attestation           uint32
	flags                 uint32
	cancellationID        *windows.GUID
	excludeList           uintptr
	enterpriseAttestation uint32
	largeBlobSupport      uint32
	preferResidentKey     int32
}

// getAssertionOptions is WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS version 4.
type getAssertionOptions struct {
	version          uint32
	timeout          uint32
	credentialList   credentials
	extensions       extensions
	attachment       uint32
	userVerification uint32
	flags            uint32
	u2fAppID         *uint16
	usedU2fAppID     *int32
	cancellationID   *windows.GUID
	allowList        uintptr
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
	ntePermission       = 0x80090010 // NTE_PERM: the dialog was closed
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
	case errCancelled, ntePermission:
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
	rp := rpEntity{version: 1, id: utf16(verify.RPID), name: utf16("wmanager-sign")}
	user := userEntity{version: 1, cbID: uint32(len(u.ID)), id: &u.ID[0], name: utf16(u.Name), displayName: utf16(u.DisplayName)}
	param := coseParam{version: 1, credType: utf16(credTypePublicKey), alg: coseES256}
	params := coseParams{count: 1, list: &param}
	data := clientData{version: 1, cb: uint32(len(cd)), json: &cd[0], hashAlg: utf16(hashSHA256)}
	opts := makeCredentialOptions{version: 4, timeout: timeoutMilliseconds, attachment: attachmentAny,
		requireResidentKey: 1, userVerification: uvRequired, attestation: attestationNone, preferResidentKey: 1}
	var out *attestation
	r, _, _ := procMakeCredential.Call(window(), uintptr(unsafe.Pointer(&rp)), uintptr(unsafe.Pointer(&user)),
		uintptr(unsafe.Pointer(&params)), uintptr(unsafe.Pointer(&data)), uintptr(unsafe.Pointer(&opts)),
		uintptr(unsafe.Pointer(&out)))
	runtime.KeepAlive(u.ID)
	runtime.KeepAlive(cd)
	if err := hresult("making the key", r); err != nil {
		return Credential{}, err
	}
	defer procFreeAttestation.Call(uintptr(unsafe.Pointer(out)))
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

func (webauthnDevice) Assert(cd []byte, allow [][]byte, _ string) ([]Assertion, error) {
	if len(cd) == 0 {
		return nil, errors.New("a signature needs client data")
	}
	data := clientData{version: 1, cb: uint32(len(cd)), json: &cd[0], hashAlg: utf16(hashSHA256)}
	opts := getAssertionOptions{version: 4, timeout: timeoutMilliseconds, attachment: attachmentAny, userVerification: uvRequired}
	list := make([]credential, 0, len(allow))
	for _, id := range allow {
		if len(id) > 0 {
			list = append(list, credential{version: 1, cbID: uint32(len(id)), id: &id[0], credType: utf16(credTypePublicKey)})
		}
	}
	if len(list) > 0 {
		opts.credentialList = credentials{count: uint32(len(list)), list: &list[0]}
	}
	var out *assertion
	r, _, _ := procGetAssertion.Call(window(), uintptr(unsafe.Pointer(utf16(verify.RPID))), uintptr(unsafe.Pointer(&data)),
		uintptr(unsafe.Pointer(&opts)), uintptr(unsafe.Pointer(&out)))
	runtime.KeepAlive(cd)
	runtime.KeepAlive(list)
	runtime.KeepAlive(allow)
	if uint32(r) == 0x80090011 { // NTE_NOT_FOUND: no credential of this relying party
		return nil, ErrNoCreds
	}
	if err := hresult("signing", r); err != nil {
		return nil, err
	}
	defer procFreeAssertion.Call(uintptr(unsafe.Pointer(out)))
	return []Assertion{{
		CredentialID:      bytesAt(out.credential.id, out.credential.cbID),
		AuthenticatorData: bytesAt(out.authData, out.cbAuthData),
		Signature:         bytesAt(out.sig, out.cbSig),
	}}, nil
}
