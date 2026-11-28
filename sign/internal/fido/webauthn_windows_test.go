package fido

import (
	"testing"
	"unsafe"
)

// The structures have the sizes webauthn.h gives them on 64-bit Windows, in the versions used.
func TestWebAuthnLayout(t *testing.T) {
	if unsafe.Sizeof(uintptr(0)) != 8 {
		t.Skip("64-bit only")
	}
	for name, c := range map[string]struct{ got, want uintptr }{
		"WEBAUTHN_RP_ENTITY_INFORMATION":                   {unsafe.Sizeof(rpEntity{}), 32},
		"WEBAUTHN_USER_ENTITY_INFORMATION":                 {unsafe.Sizeof(userEntity{}), 40},
		"WEBAUTHN_CLIENT_DATA":                             {unsafe.Sizeof(clientData{}), 24},
		"WEBAUTHN_COSE_CREDENTIAL_PARAMETER":               {unsafe.Sizeof(coseParam{}), 24},
		"WEBAUTHN_CREDENTIAL":                              {unsafe.Sizeof(credential{}), 24},
		"WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS v4": {unsafe.Sizeof(makeCredentialOptions{}), 96},
		"WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS v4":   {unsafe.Sizeof(getAssertionOptions{}), 88},
		"WEBAUTHN_CREDENTIAL_ATTESTATION: pbCredentialId":   {unsafe.Offsetof(attestation{}.credentialID), 88},
		"WEBAUTHN_ASSERTION: Credential":                    {unsafe.Offsetof(assertion{}.credential), 32},
	} {
		if c.got != c.want {
			t.Errorf("%s: %d, webauthn.h has %d", name, c.got, c.want)
		}
	}
}

// Windows has the API (this needs no person: nothing is made or signed).
func TestWebAuthnThere(t *testing.T) {
	d, err := Open(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer d.Close()
	v, _, _ := procAPIVersion.Call()
	if v < 1 {
		t.Fatalf("API version %d", v)
	}
	t.Logf("webauthn.dll API version %d", v)
}
