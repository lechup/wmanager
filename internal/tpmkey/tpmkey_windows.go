// Package tpmkey keeps the computer's key in the TPM, through Windows' Platform Crypto Provider (NCrypt). The key
// is made on the computer and can't leave the TPM; the computer's id is the SHA-256 of its public key
// (docs/architecture.md, "Enrolling a computer").
package tpmkey

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"encoding/asn1"
	"encoding/binary"
	"errors"
	"fmt"
	"math/big"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Provider names of NCrypt.
const (
	PlatformProvider = "Microsoft Platform Crypto Provider" // the TPM
	SoftwareProvider = "Microsoft Software Key Storage Provider"
)

const (
	ncryptMachineKeyFlag   = 0x20
	ncryptOverwriteKeyFlag = 0x80
	ncryptSilentFlag       = 0x40
	bcryptECDSAP256Magic   = 0x31534345 // "ECS1"
	ntePermissionDenied    = 0x80090010
	nteBadKeyset           = 0x80090016
	nteExists              = 0x8009000F
)

var (
	ncrypt                        = windows.NewLazySystemDLL("ncrypt.dll")
	procNCryptOpenStorageProvider = ncrypt.NewProc("NCryptOpenStorageProvider")
	procNCryptCreatePersistedKey  = ncrypt.NewProc("NCryptCreatePersistedKey")
	procNCryptOpenKey             = ncrypt.NewProc("NCryptOpenKey")
	procNCryptFinalizeKey         = ncrypt.NewProc("NCryptFinalizeKey")
	procNCryptExportKey           = ncrypt.NewProc("NCryptExportKey")
	procNCryptSignHash            = ncrypt.NewProc("NCryptSignHash")
	procNCryptDeleteKey           = ncrypt.NewProc("NCryptDeleteKey")
	procNCryptFreeObject          = ncrypt.NewProc("NCryptFreeObject")
	procNCryptGetProperty         = ncrypt.NewProc("NCryptGetProperty")
)

// Errors.
var (
	ErrNotFound = errors.New("tpmkey: no such key")
	ErrExists   = errors.New("tpmkey: a key of that name exists already")
)

// Key is a machine key in an NCrypt provider. Only SYSTEM and administrators can use a machine key.
type Key struct {
	prov, key uintptr
	Provider  string
	pub       *ecdsa.PublicKey
}

func status(op string, r uintptr) error {
	if r == 0 {
		return nil
	}
	switch uint32(r) {
	case nteBadKeyset:
		return fmt.Errorf("tpmkey: %s: %w", op, ErrNotFound)
	case nteExists:
		return fmt.Errorf("tpmkey: %s: %w", op, ErrExists)
	case ntePermissionDenied:
		return fmt.Errorf("tpmkey: %s: permission denied (needs SYSTEM or an administrator)", op)
	}
	return fmt.Errorf("tpmkey: %s: status %#x", op, uint32(r))
}

func openProvider(name string) (uintptr, error) {
	var h uintptr
	n, err := windows.UTF16PtrFromString(name)
	if err != nil {
		return 0, err
	}
	r, _, _ := procNCryptOpenStorageProvider.Call(uintptr(unsafe.Pointer(&h)), uintptr(unsafe.Pointer(n)), 0)
	return h, status("open "+name, r)
}

// Create makes a new ECDSA P-256 machine key of that name in the provider. It refuses when the name is taken:
// the computer's key is its identity, and losing it means enrolling the computer again.
func Create(provider, name string) (*Key, error) { return create(provider, name, 0) }

// Replace makes a new key of that name, replacing one that exists. Only for keys that may be lost, such as the
// trials'.
func Replace(provider, name string) (*Key, error) {
	return create(provider, name, ncryptOverwriteKeyFlag)
}

func create(provider, name string, flags uintptr) (*Key, error) {
	prov, err := openProvider(provider)
	if err != nil {
		return nil, err
	}
	alg, _ := windows.UTF16PtrFromString("ECDSA_P256")
	kn, err := windows.UTF16PtrFromString(name)
	if err != nil {
		free(prov)
		return nil, err
	}
	var key uintptr
	r, _, _ := procNCryptCreatePersistedKey.Call(prov, uintptr(unsafe.Pointer(&key)), uintptr(unsafe.Pointer(alg)),
		uintptr(unsafe.Pointer(kn)), 0, ncryptMachineKeyFlag|flags)
	if err := status("create key", r); err != nil {
		free(prov)
		return nil, err
	}
	// Not exportable is the default; the TPM provider can't export a private key anyway.
	r, _, _ = procNCryptFinalizeKey.Call(key, ncryptSilentFlag)
	if err := status("finalize key", r); err != nil {
		free(key)
		free(prov)
		return nil, err
	}
	return load(prov, key, provider)
}

// Open opens an existing machine key.
func Open(provider, name string) (*Key, error) {
	prov, err := openProvider(provider)
	if err != nil {
		return nil, err
	}
	kn, err := windows.UTF16PtrFromString(name)
	if err != nil {
		free(prov)
		return nil, err
	}
	var key uintptr
	r, _, _ := procNCryptOpenKey.Call(prov, uintptr(unsafe.Pointer(&key)), uintptr(unsafe.Pointer(kn)), 0,
		ncryptMachineKeyFlag|ncryptSilentFlag)
	if err := status("open key", r); err != nil {
		free(prov)
		return nil, err
	}
	return load(prov, key, provider)
}

func load(prov, key uintptr, provider string) (*Key, error) {
	k := &Key{prov: prov, key: key, Provider: provider}
	blob, err := k.export()
	if err != nil {
		k.Close()
		return nil, err
	}
	// BCRYPT_ECCKEY_BLOB: magic, key size in bytes, then X and Y.
	if len(blob) != 8+64 || binary.LittleEndian.Uint32(blob) != bcryptECDSAP256Magic ||
		binary.LittleEndian.Uint32(blob[4:]) != 32 {
		k.Close()
		return nil, fmt.Errorf("tpmkey: unexpected public key blob of %d bytes", len(blob))
	}
	k.pub, err = ecdsa.ParseUncompressedPublicKey(elliptic.P256(), append([]byte{4}, blob[8:]...))
	if err != nil {
		k.Close()
		return nil, fmt.Errorf("tpmkey: %w", err)
	}
	return k, nil
}

func (k *Key) export() ([]byte, error) {
	typ, _ := windows.UTF16PtrFromString("ECCPUBLICBLOB")
	var n uint32
	r, _, _ := procNCryptExportKey.Call(k.key, 0, uintptr(unsafe.Pointer(typ)), 0, 0, 0, uintptr(unsafe.Pointer(&n)), 0)
	if err := status("export public key", r); err != nil {
		return nil, err
	}
	if n == 0 || n > 4096 {
		return nil, fmt.Errorf("tpmkey: public key blob of %d bytes", n)
	}
	buf := make([]byte, n)
	r, _, _ = procNCryptExportKey.Call(k.key, 0, uintptr(unsafe.Pointer(typ)), 0, uintptr(unsafe.Pointer(&buf[0])),
		uintptr(n), uintptr(unsafe.Pointer(&n)), 0)
	if err := status("export public key", r); err != nil {
		return nil, err
	}
	return buf[:n], nil
}

// Public is the key's public key.
func (k *Key) Public() *ecdsa.PublicKey { return k.pub }

// SignDigest signs a SHA-256 digest and returns the signature in ASN.1 form, as crypto/ecdsa verifies it.
func (k *Key) SignDigest(digest []byte) ([]byte, error) {
	if len(digest) != 32 {
		return nil, errors.New("tpmkey: digest must be SHA-256")
	}
	var n uint32
	sig := make([]byte, 64)
	r, _, _ := procNCryptSignHash.Call(k.key, 0, uintptr(unsafe.Pointer(&digest[0])), uintptr(len(digest)),
		uintptr(unsafe.Pointer(&sig[0])), uintptr(len(sig)), uintptr(unsafe.Pointer(&n)), ncryptSilentFlag)
	if err := status("sign", r); err != nil {
		return nil, err
	}
	if n != 64 {
		return nil, fmt.Errorf("tpmkey: signature of %d bytes", n)
	}
	return asn1.Marshal(struct{ R, S *big.Int }{new(big.Int).SetBytes(sig[:32]), new(big.Int).SetBytes(sig[32:])})
}

// PlatformType is what the provider reports about the TPM (e.g. its version and maker), or "" for the software
// provider.
func (k *Key) PlatformType() string {
	name, _ := windows.UTF16PtrFromString("PCP_PLATFORM_TYPE")
	var n uint32
	buf := make([]uint16, 256)
	r, _, _ := procNCryptGetProperty.Call(k.prov, uintptr(unsafe.Pointer(name)), uintptr(unsafe.Pointer(&buf[0])),
		uintptr(len(buf)*2), uintptr(unsafe.Pointer(&n)), 0)
	if r != 0 {
		return ""
	}
	return windows.UTF16ToString(buf[:n/2])
}

// Delete removes the key from the provider. The Key can't be used after it.
func (k *Key) Delete() error {
	r, _, _ := procNCryptDeleteKey.Call(k.key, 0)
	if r == 0 {
		k.key = 0 // NCryptDeleteKey frees the handle when it succeeds
	}
	k.Close()
	return status("delete key", r)
}

// Close frees the handles.
func (k *Key) Close() {
	free(k.key)
	free(k.prov)
	k.key, k.prov = 0, 0
}

func free(h uintptr) {
	if h != 0 {
		procNCryptFreeObject.Call(h)
	}
}
