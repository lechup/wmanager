package fido

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"testing"

	"github.com/fxamacker/cbor/v2"

	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
)

func attested(id, cose, ext []byte, flags byte) []byte {
	rp := sha256.Sum256([]byte(verify.RPID))
	ad := append([]byte{}, rp[:]...)
	ad = append(ad, flags)
	ad = binary.BigEndian.AppendUint32(ad, 1)
	ad = append(ad, make([]byte, 16)...)
	ad = binary.BigEndian.AppendUint16(ad, uint16(len(id)))
	ad = append(ad, id...)
	ad = append(ad, cose...)
	return append(ad, ext...)
}

func TestAttestedKey(t *testing.T) {
	k, err := softkey.New(verify.ES256)
	if err != nil {
		t.Fatal(err)
	}
	cose := k.COSEKey()
	id := []byte("credential-id-16")
	// credProtect's output after the key: {"credProtect": 3}
	ext := []byte{0xa1, 0x6b, 'c', 'r', 'e', 'd', 'P', 'r', 'o', 't', 'e', 'c', 't', 0x03}
	gotID, gotKey, err := AttestedKey(attested(id, cose, ext, FlagUserPresent|FlagUserVerified|FlagAttested|0x80))
	if err != nil || !bytes.Equal(gotID, id) || !bytes.Equal(gotKey, cose) {
		t.Fatalf("AttestedKey: %x %x %v", gotID, gotKey, err)
	}
	if _, err := verify.ParseCOSEKey(gotKey); err != nil {
		t.Fatal(err)
	}
	for name, ad := range map[string][]byte{
		"no attested data": attested(id, cose, nil, FlagUserPresent),
		"cut":              attested(id, cose, nil, FlagAttested)[:60],
		"no key":           attested(id, nil, nil, FlagAttested),
		"not a map":        attested(id, []byte{0x43, 1, 2, 3}, nil, FlagAttested),
		"empty id":         attested(nil, cose, nil, FlagAttested),
	} {
		if _, _, err := AttestedKey(ad); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestUnwrap(t *testing.T) {
	ad := attested([]byte("id"), []byte{0xa0}, nil, FlagAttested)
	enc, _ := cbor.Marshal(ad)
	if got, err := Unwrap(enc); err != nil || !bytes.Equal(got, ad) {
		t.Fatalf("Unwrap: %x %v", got, err)
	}
	for _, bad := range [][]byte{nil, {0xa0}, append(enc, 0), enc[:len(enc)-1]} {
		if _, err := Unwrap(bad); err == nil {
			t.Errorf("Unwrap(%x) accepted", bad)
		}
	}
}
