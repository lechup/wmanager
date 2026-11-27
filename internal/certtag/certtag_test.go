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

func mustMarshal(t testing.TB, v any) []byte {
	t.Helper()
	b, err := asn1.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func cert(t testing.TB, cn string, serial int64) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := x509.Certificate{
		SerialNumber: big.NewInt(serial),
		Subject:      pkix.Name{CommonName: cn},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
	}
	der, err := x509.CreateCertificate(rand.Reader, &tmpl, &tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return der
}

// unsorted returns two certificates in the order that DER's SET OF would not put them: a signer chain is written
// leaf first, whatever DER would sort.
func unsorted(t testing.TB) [][]byte {
	t.Helper()
	a, b := cert(t, "leaf", 9), cert(t, "root", 8)
	if bytes.Compare(a, b) < 0 {
		a, b = b, a // the larger first: DER would put it last
	}
	return [][]byte{a, b}
}

// fakeSigned makes a minimal PE32+ exe whose attribute certificate table holds a SignedData shaped like an
// Authenticode signature, with the given certificates. Whether Windows accepts a real signature with a tag is
// trial 2, on a virtual machine; here the file format is tested.
func fakeSigned(t testing.TB, certs [][]byte, appended []byte) []byte {
	t.Helper()
	sd := signedData{
		contentType: mustMarshal(t, oidSignedData),
		version:     mustMarshal(t, 1),
		digests:     []byte{0x31, 0x00},
		content: mustMarshal(t, struct{ Type asn1.ObjectIdentifier }{
			asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 311, 2, 1, 4}}),
		hasCerts: true,
		certs:    certs,
		signers:  []byte{0x31, 0x00},
	}
	der, err := sd.marshal()
	if err != nil {
		t.Fatal(err)
	}
	der = append(der, appended...)
	for len(der)&7 != 0 {
		der = append(der, 0)
	}

	var b bytes.Buffer
	dos := make([]byte, 64)
	copy(dos, "MZ")
	binary.LittleEndian.PutUint32(dos[peHeaderOffsetPos:], 64)
	b.Write(dos)
	b.WriteString("PE\x00\x00")
	fh := make([]byte, fileHeaderSize)
	binary.LittleEndian.PutUint16(fh[0:], 0x8664)
	binary.LittleEndian.PutUint16(fh[16:], 240) // SizeOfOptionalHeader: 112 + 16 data directories
	binary.LittleEndian.PutUint16(fh[18:], 0x22)
	b.Write(fh)
	opt := make([]byte, 240)
	binary.LittleEndian.PutUint16(opt, pe32PlusMagic)
	binary.LittleEndian.PutUint32(opt[108:], 16)
	tableAt := b.Len() + len(opt)
	binary.LittleEndian.PutUint32(opt[112+8*certTableIndex:], uint32(tableAt))
	binary.LittleEndian.PutUint32(opt[112+8*certTableIndex+4:], uint32(8+len(der)))
	b.Write(opt)
	binary.Write(&b, binary.LittleEndian, uint32(8+len(der)))
	binary.Write(&b, binary.LittleEndian, uint16(certRevision))
	binary.Write(&b, binary.LittleEndian, uint16(certTypePKCS7))
	b.Write(der)
	return b.Bytes()
}

func TestUntagged(t *testing.T) {
	tag, ok, err := Get(fakeSigned(t, unsorted(t), nil))
	if err != nil || ok || tag != nil {
		t.Fatalf("Get = %q, %v, %v; want no tag", tag, ok, err)
	}
}

// A signer chain written leaf first is kept as it is, not sorted: re-encoding it would change the signature's
// bytes, and parsing it with encoding/asn1 would refuse half of all two-certificate chains.
func TestSetGetReplaceKeepsOrder(t *testing.T) {
	chain := unsorted(t)
	pe := fakeSigned(t, chain, nil)
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
	if n := len(f.sd.certs); n != 3 || !bytes.Equal(f.sd.certs[0], chain[0]) || !bytes.Equal(f.sd.certs[1], chain[1]) {
		t.Fatalf("%d certificates, or the chain's order changed", n)
	}
	checkLayout(t, again)
	// Everything before the signature table, and the signed parts of the signature, are the same bytes.
	o, _, _, _ := attributeCertificates(pe)
	o2, _, _, _ := attributeCertificates(again)
	if o != o2 || !bytes.Equal(pe[:72], again[:72]) {
		t.Fatal("the headers moved")
	}
}

func TestRetaggingDoesntGrow(t *testing.T) {
	pe := fakeSigned(t, unsorted(t), nil)
	var sizes []int
	cur := pe
	for range 5 {
		var err error
		if cur, err = Set(cur, []byte("same size tag")); err != nil {
			t.Fatal(err)
		}
		_, _, _, _ = attributeCertificates(cur)
		f, _ := parse(cur)
		if len(f.appended) > 7 {
			t.Fatalf("%d bytes of padding after re-tagging", len(f.appended))
		}
		sizes = append(sizes, len(cur))
	}
	for _, n := range sizes[1:] {
		if d := n - sizes[0]; d > 8 || d < -8 {
			t.Fatalf("sizes after re-tagging: %v", sizes)
		}
	}
}

func TestAppendedDataRefused(t *testing.T) {
	pe := fakeSigned(t, unsorted(t), []byte("old appended tag"))
	if _, _, err := Get(pe); err == nil || !strings.Contains(err.Error(), "appended") {
		t.Fatalf("Get of a file with an appended tag: %v", err)
	}
	if _, err := Set(pe, []byte("x")); err == nil {
		t.Fatal("Set kept an appended tag")
	}
	old, err := AppendAfterSignature(fakeSigned(t, unsorted(t), nil), []byte("control"))
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := Get(old); err == nil {
		t.Fatal("Get accepted the trial's control file")
	}
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
	tagged, err := Set(fakeSigned(t, unsorted(t), nil), []byte("a"))
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
	f.sd.certs = append(f.sd.certs, extra)
	der, err := f.sd.marshal()
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := Get(f.build(der, nil)); err == nil || !strings.Contains(err.Error(), "more than one") {
		t.Fatalf("a file with two tags: err = %v", err)
	}
}

func TestBadFiles(t *testing.T) {
	pe := fakeSigned(t, unsorted(t), nil)
	mod := func(f func(b []byte) []byte) []byte { return f(append([]byte{}, pe...)) }
	optStart := 64 + 4 + fileHeaderSize
	dir := optStart + 112 + 8*certTableIndex
	cases := map[string][]byte{
		"empty":                 {},
		"not PE":                bytes.Repeat([]byte{0}, 200),
		"bytes after the table": append(append([]byte{}, pe...), 0),
		"truncated":             pe[:len(pe)-8],
		"not signed": mod(func(b []byte) []byte {
			binary.LittleEndian.PutUint64(b[dir:], 0)
			return b
		}),
		// An optional header said to be larger than the file: Omaha's reader sliced past the end here.
		"optional header past the end": mod(func(b []byte) []byte {
			binary.LittleEndian.PutUint16(b[64+4+16:], 0xffff)
			return b
		}),
		"a table that starts inside the headers": mod(func(b []byte) []byte {
			binary.LittleEndian.PutUint32(b[dir:], 64)
			binary.LittleEndian.PutUint32(b[dir+4:], uint32(len(b)-64))
			return b
		}),
		"section headers over the table": mod(func(b []byte) []byte {
			binary.LittleEndian.PutUint16(b[64+4+2:], 1000)
			return b
		}),
		"a DLL": mod(func(b []byte) []byte {
			binary.LittleEndian.PutUint16(b[64+4+18:], 0x2022)
			return b
		}),
	}
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

// FuzzGetSet: no input makes Get or Set panic, and whatever Set writes, Get reads back.
func FuzzGetSet(f *testing.F) {
	pe := fakeSigned(f, unsorted(f), nil)
	f.Add(pe)
	f.Add(pe[:300])
	tagged, err := Set(pe, []byte("seed"))
	if err != nil {
		f.Fatal(err)
	}
	f.Add(tagged)
	f.Fuzz(func(t *testing.T, b []byte) {
		Get(b)
		out, err := Set(b, []byte("fuzz"))
		if err != nil {
			return
		}
		if tag, ok, err := Get(out); err != nil || !ok || string(tag) != "fuzz" {
			t.Fatalf("Set then Get: %q %v %v", tag, ok, err)
		}
	})
}
