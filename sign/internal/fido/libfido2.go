//go:build fido2 && cgo

package fido

/*
#cgo LDFLAGS: -lfido2
#include <fido.h>
#include <stdlib.h>
#include <string.h>

// wipe clears a PIN before it is freed.
static void wipe(char *p) {
	if (p != NULL) {
		explicit_bzero(p, strlen(p));
		free(p);
	}
}
*/
import "C"

import (
	"crypto/sha256"
	"errors"
	"fmt"
	"strings"
	"unsafe"

	"github.com/lechup/wmanager/verify"
)

func init() {
	C.fido_init(0)
	Opener = open
}

type device struct {
	dev  *C.fido_dev_t
	name string
	pin  bool // a PIN is set
	uv   bool // the key's own check (a fingerprint) is set up
	prot bool // it knows credProtect
}

const maxDevices = 16

func open(choose func(names []string) (int, error)) (Device, error) {
	list := C.fido_dev_info_new(maxDevices)
	if list == nil {
		return nil, errors.New("libfido2: out of memory")
	}
	defer C.fido_dev_info_free(&list, maxDevices)
	var n C.size_t
	if r := C.fido_dev_info_manifest(list, maxDevices, &n); r != C.FIDO_OK {
		return nil, failed("listing the security keys", r)
	}
	if n == 0 {
		return nil, ErrNoDevice
	}
	var paths, names []string
	for i := C.size_t(0); i < n; i++ {
		di := C.fido_dev_info_ptr(list, i)
		paths = append(paths, C.GoString(C.fido_dev_info_path(di)))
		names = append(names, strings.TrimSpace(C.GoString(C.fido_dev_info_manufacturer_string(di))+" "+
			C.GoString(C.fido_dev_info_product_string(di))))
	}
	i := 0
	if n > 1 {
		var err error
		if i, err = choose(names); err != nil {
			return nil, err
		}
		if i < 0 || i >= len(paths) {
			return nil, errors.New("no such security key")
		}
	}
	dev := C.fido_dev_new()
	if dev == nil {
		return nil, errors.New("libfido2: out of memory")
	}
	path := C.CString(paths[i])
	defer C.free(unsafe.Pointer(path))
	if r := C.fido_dev_open(dev, path); r != C.FIDO_OK {
		C.fido_dev_free(&dev)
		return nil, failed("opening the security key", r)
	}
	d := &device{dev: dev, name: names[i], pin: bool(C.fido_dev_has_pin(dev)), uv: bool(C.fido_dev_has_uv(dev)),
		prot: bool(C.fido_dev_supports_cred_prot(dev))}
	switch {
	case !bool(C.fido_dev_is_fido2(dev)):
		d.Close()
		return nil, errors.New("the security key knows U2F only, not FIDO2")
	case !d.pin && !d.uv:
		d.Close()
		return nil, ErrNoUV
	}
	return d, nil
}

func (d *device) Name() string { return d.name }

// NeedsPIN: a key with a fingerprint of its own is asked for that instead.
func (d *device) NeedsPIN() bool { return d.pin && !d.uv }

func (d *device) Close() error {
	if d.dev != nil {
		C.fido_dev_close(d.dev)
		C.fido_dev_free(&d.dev)
	}
	return nil
}

func cPIN(pin string) *C.char {
	if pin == "" {
		return nil
	}
	return C.CString(pin)
}

func bytesOf(p *C.uchar, n C.size_t) []byte {
	if p == nil || n == 0 {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(p), C.int(n))
}

func (d *device) MakeCredential(u User, clientData []byte, pin string) (Credential, error) {
	clientDataHash := sha256.Sum256(clientData)
	cred := C.fido_cred_new()
	if cred == nil {
		return Credential{}, errors.New("libfido2: out of memory")
	}
	defer C.fido_cred_free(&cred)
	rp, rpName := C.CString(verify.RPID), C.CString("wmanager-sign")
	defer C.free(unsafe.Pointer(rp))
	defer C.free(unsafe.Pointer(rpName))
	name, display := C.CString(u.Name), C.CString(u.DisplayName)
	defer C.free(unsafe.Pointer(name))
	defer C.free(unsafe.Pointer(display))
	if len(u.ID) == 0 {
		return Credential{}, errors.New("a credential needs a user id")
	}
	steps := []C.int{
		C.fido_cred_set_type(cred, C.COSE_ES256),
		C.fido_cred_set_clientdata_hash(cred, (*C.uchar)(&clientDataHash[0]), 32),
		C.fido_cred_set_rp(cred, rp, rpName),
		C.fido_cred_set_user(cred, (*C.uchar)(&u.ID[0]), C.size_t(len(u.ID)), name, display, nil),
		C.fido_cred_set_rk(cred, C.FIDO_OPT_TRUE),
	}
	// A key that knows credProtect signs with this credential only after verifying its user.
	if d.prot {
		steps = append(steps, C.fido_cred_set_prot(cred, C.FIDO_CRED_PROT_UV_REQUIRED))
	}
	if pin == "" {
		steps = append(steps, C.fido_cred_set_uv(cred, C.FIDO_OPT_TRUE))
	}
	for _, r := range steps {
		if r != C.FIDO_OK {
			return Credential{}, failed("preparing the new key", r)
		}
	}
	p := cPIN(pin)
	defer C.wipe(p)
	if r := C.fido_dev_make_cred(d.dev, cred, p); r != C.FIDO_OK {
		return Credential{}, failed("making the key", r)
	}
	authData, err := Unwrap(bytesOf(C.fido_cred_authdata_ptr(cred), C.fido_cred_authdata_len(cred)))
	if err != nil {
		return Credential{}, err
	}
	id, cose, err := AttestedKey(authData)
	if err != nil {
		return Credential{}, err
	}
	if !equal(id, bytesOf(C.fido_cred_id_ptr(cred), C.fido_cred_id_len(cred))) {
		return Credential{}, errAuthData
	}
	return Credential{ID: id, COSE: cose, Flags: byte(C.fido_cred_flags(cred))}, nil
}

func (d *device) Assert(clientData []byte, allow [][]byte, pin string) ([]Assertion, error) {
	clientDataHash := sha256.Sum256(clientData)
	a := C.fido_assert_new()
	if a == nil {
		return nil, errors.New("libfido2: out of memory")
	}
	defer C.fido_assert_free(&a)
	rp := C.CString(verify.RPID)
	defer C.free(unsafe.Pointer(rp))
	steps := []C.int{
		C.fido_assert_set_rp(a, rp),
		C.fido_assert_set_clientdata_hash(a, (*C.uchar)(&clientDataHash[0]), 32),
		C.fido_assert_set_up(a, C.FIDO_OPT_TRUE),
	}
	for _, id := range allow {
		if len(id) > 0 {
			steps = append(steps, C.fido_assert_allow_cred(a, (*C.uchar)(&id[0]), C.size_t(len(id))))
		}
	}
	if pin == "" {
		steps = append(steps, C.fido_assert_set_uv(a, C.FIDO_OPT_TRUE))
	}
	for _, r := range steps {
		if r != C.FIDO_OK {
			return nil, failed("preparing the signature", r)
		}
	}
	p := cPIN(pin)
	defer C.wipe(p)
	if r := C.fido_dev_get_assert(d.dev, a, p); r != C.FIDO_OK {
		return nil, failed("signing", r)
	}
	var out []Assertion
	for i := C.size_t(0); i < C.fido_assert_count(a); i++ {
		ad, err := Unwrap(bytesOf(C.fido_assert_authdata_ptr(a, i), C.fido_assert_authdata_len(a, i)))
		if err != nil {
			return nil, err
		}
		out = append(out, Assertion{
			CredentialID:      bytesOf(C.fido_assert_id_ptr(a, i), C.fido_assert_id_len(a, i)),
			AuthenticatorData: ad,
			Signature:         bytesOf(C.fido_assert_sig_ptr(a, i), C.fido_assert_sig_len(a, i)),
		})
	}
	if len(out) == 0 {
		return nil, ErrNoCreds
	}
	return out, nil
}

func equal(a, b []byte) bool { return string(a) == string(b) }

func failed(what string, r C.int) error {
	switch r {
	case C.FIDO_ERR_PIN_INVALID:
		return ErrPIN
	case C.FIDO_ERR_NO_CREDENTIALS:
		return ErrNoCreds
	case C.FIDO_ERR_ACTION_TIMEOUT, C.FIDO_ERR_USER_ACTION_TIMEOUT:
		return ErrNotTouched
	case C.FIDO_ERR_PIN_BLOCKED, C.FIDO_ERR_PIN_AUTH_BLOCKED:
		return fmt.Errorf("%s: the security key's PIN is blocked (too many wrong PINs; take the key out and in again, or reset it)", what)
	}
	return fmt.Errorf("%s: %s", what, C.GoString(C.fido_strerr(r)))
}
