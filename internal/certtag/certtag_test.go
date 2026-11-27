package certtag

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/binary"
	"math/big"
	"strings"
	"testing"
	"time"
)

// fakeSigned makes a minimal PE32+ exe whose attribute certificate table holds a SignedData with one certificate,
// shaped like an Authenticode signature. Whether Windows accepts a real signature with a tag is trial 2, on a
// virtual machine; here the file format is tested.
func fakeSigned(t *testing.T, appended []byte) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(7),
		Subject:      pkix.Name{CommonName: "test signer"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	signer, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	var sd signedData
	sd.Type = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 2}
	sd.PKCS7.Version = 1
	sd.PKCS7.Digests = asn1.RawValue{FullBytes: []byte{0x31, 0x00}}
	sd.PKCS7.ContentInfo = asn1.RawValue{FullBytes: mustMarshal(t, struct{ Type asn1.ObjectIdentifier }{
		asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 311, 2, 1, 4}})}
	sd.PKCS7.Certs = []asn1.RawValue{{FullBytes: signer}}
	sd.PKCS7.SignerInfos = asn1.RawValue{FullBytes: []byte{0x31, 0x00}}
	der := append(mustMarshal(t, sd), appended...)
	for len(der)&7 != 0 {
		der = append(der, 0)
	}

	var b bytes.Buffer
	dos := make([]byte, 64)
	copy(dos, "MZ")
	binary.LittleEndian.PutUint32(dos[peHeaderOffsetPos:], 64)
	b.Write(dos)
	b.WriteString("PE\x00\x00")
	put := func(v any) { binary.Write(&b, binary.LittleEndian, v) }
	put(fileHeader{Machine: 0x8664, SizeOfOptionalHeader: 240, Characteristics: 0x22})
	put(optionalHeaderStart{Magic: pe32PlusMagic})
	b.Write(make([]byte, 84)) // the Windows-specific fields of PE32+
	put(uint32(16))
	dirs := make([]dataDirectory, 16)
	tableAt := b.Len() + 16*8
	dirs[certTableIndex] = dataDirectory{VirtualAddress: uint32(tableAt), Size: uint32(8 + len(der))}
	put(dirs)
	put(uint32(8 + len(der)))
	put(uint16(certRevision))
	put(uint16(certTypePKCS7))
	b.Write(der)
	return b.Bytes()
}

func mustMarshal(t *testing.T, v any) []byte {
	t.Helper()
	b, err := asn1.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestUntagged(t *testing.T) {
	tag, ok, err := Get(fakeSigned(t, nil))
	if err != nil || ok || tag != nil {
		t.Fatalf("Get = %q, %v, %v; want no tag", tag, ok, err)
	}
}

func TestSetGetAndReplace(t *testing.T) {
	pe := fakeSigned(t, nil)
	first := []byte(`{"server":"https://wm.example.com","token":"one"}`)
	tagged, err := Set(pe, first)
	if err != nil {
		t.Fatal(err)
	}
	if got, ok, err := Get(tagged); err != nil || !ok || !bytes.Equal(got, first) {
		t.Fatalf("Get after Set = %q, %v, %v", got, ok, err)
	}
	second := bytes.Repeat([]byte("chain "), 5000) // an admin chain of 30 kB
	again, err := Set(tagged, second)
	if err != nil {
		t.Fatal(err)
	}
	if got, ok, err := Get(again); err != nil || !ok || !bytes.Equal(got, second) {
		t.Fatalf("Get after a second Set = %d bytes, %v, %v", len(got), ok, err)
	}
	f, err := parse(again)
	if err != nil {
		t.Fatal(err)
	}
	if n := len(f.signed.PKCS7.Certs); n != 2 {
		t.Fatalf("%d certificates after two tags, want the signer and one tag", n)
	}
	checkLayout(t, again)
}

func TestAppendedBytesKept(t *testing.T) {
	pe := fakeSigned(t, []byte("old appended tag"))
	tagged, err := Set(pe, []byte("x"))
	if err != nil {
		t.Fatal(err)
	}
	f, err := parse(tagged)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(f.appended, []byte("old appended tag")) {
		t.Fatalf("appended bytes lost: %q", f.appended)
	}
	checkLayout(t, tagged)
}

// checkLayout checks that the data directory, the WIN_CERTIFICATE header and the file's length agree.
func checkLayout(t *testing.T, pe []byte) {
	t.Helper()
	offset, size, _, err := attributeCertificates(pe)
	if err != nil {
		t.Fatal(err)
	}
	if offset+size != len(pe) || size&7 != 0 {
		t.Fatalf("table at %d, %d bytes, file %d bytes", offset, size, len(pe))
	}
	if n := binary.LittleEndian.Uint32(pe[offset:]); int(n) != size {
		t.Fatalf("WIN_CERTIFICATE says %d bytes, the directory %d", n, size)
	}
}

func TestTwoTagsRefused(t *testing.T) {
	tagged, err := Set(fakeSigned(t, nil), []byte("a"))
	if err != nil {
		t.Fatal(err)
	}
	f, err := parse(tagged)
	if err != nil {
		t.Fatal(err)
	}
	extra, err := tagCertificate([]byte("b"))
	if err != nil {
		t.Fatal(err)
	}
	f.signed.PKCS7.Certs = append(f.signed.PKCS7.Certs, asn1.RawValue{FullBytes: extra})
	both := f.build(mustMarshal(t, f.signed))
	if _, _, err := Get(both); err == nil || !strings.Contains(err.Error(), "more than one") {
		t.Fatalf("a file with two tags: err = %v", err)
	}
}

func TestNotSignedOrNotPE(t *testing.T) {
	pe := fakeSigned(t, nil)
	cases := map[string][]byte{
		"empty":                 {},
		"not PE":                bytes.Repeat([]byte{0}, 200),
		"bytes after the table": append(append([]byte{}, pe...), 0),
		"truncated":             pe[:len(pe)-8],
	}
	unsigned := append([]byte{}, pe...)
	_, _, sizeOffset, err := attributeCertificates(pe)
	if err != nil {
		t.Fatal(err)
	}
	binary.LittleEndian.PutUint64(unsigned[sizeOffset-4:], 0) // the certificate directory empty
	cases["not signed"] = unsigned
	for name, b := range cases {
		t.Run(name, func(t *testing.T) {
			if _, _, err := Get(b); err == nil {
				t.Fatal("accepted")
			}
			if _, err := Set(b, []byte("x")); err == nil {
				t.Fatal("Set accepted it")
			}
		})
	}
}
