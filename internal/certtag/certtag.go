// Package certtag reads and writes the tag of an Authenticode-signed Windows exe: data that the server adds to the
// release's signed wmanager-agent.exe without breaking its signature (docs/architecture.md, "Enrolling a computer").
//
// The tag sits in an extension of an extra ("superfluous") certificate in the signature's set of certificates,
// which the signature doesn't cover. This is the way of Omaha's certificate_tag, which Google uses for Chrome's
// installers; the older way of appending data after the signature fails when Windows checks the signature's
// padding (EnableCertPaddingCheck).
//
// After Omaha's https://github.com/google/omaha/blob/main/common/certificate_tag/certificate_tag.go
// (Copyright 2015 Google Inc., Apache License 2.0), keeping only PE files and the superfluous certificate.
// Changes: an OID of our own; the signature's structure kept byte for byte, its certificates in their own order
// (Omaha re-encodes them, which sorts them); stricter checks of the PE headers; no appended data, which the
// padding check refuses; and a strict reader for the agent.
package certtag

import (
	"bytes"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/binary"
	"errors"
	"fmt"
	"math/big"
	"time"

	"golang.org/x/crypto/cryptobyte"
	cbasn1 "golang.org/x/crypto/cryptobyte/asn1"
)

// OID is the extension that holds the tag.
//
// For the trials it is under 1.3.6.1.4.1.32473, the enterprise number set aside for examples (RFC 5612). Before
// installers are made for real computers (stage 3) it moves to an enterprise number of wmanager's own, registered
// with IANA (free). Go's encoding/asn1 can't hold the 128-bit component of a UUID-based OID (2.25), so that way is
// closed.
var OID = asn1.ObjectIdentifier{1, 3, 6, 1, 4, 1, 32473, 1}

// MaxTag is the largest tag accepted, well above a company's admin chain.
const MaxTag = 1 << 20

// Get returns the tag of a signed PE file. ok is false when the file is signed but has no tag. A file with more
// than one tag certificate, or with data appended after the signature, is refused: the agent reads its tag
// strictly, since anyone can tag a file.
func Get(pe []byte) (tag []byte, ok bool, err error) {
	f, err := parse(pe)
	if err != nil {
		return nil, false, err
	}
	if !allZero(f.appended) {
		return nil, false, errors.New("certtag: data appended after the signature")
	}
	found := false
	for _, der := range f.sd.certs {
		v, has, err := tagExtension(der)
		if err != nil {
			return nil, false, err
		}
		if !has {
			continue
		}
		if found {
			return nil, false, errors.New("certtag: more than one tag certificate")
		}
		found, tag = true, v
	}
	if !found {
		return nil, false, nil
	}
	if len(tag) > MaxTag {
		return nil, false, fmt.Errorf("certtag: tag of %d bytes", len(tag))
	}
	return tag, true, nil
}

// Set returns a copy of the signed PE file with the given tag, replacing a tag it already has. The signature's
// other certificates stay as they are, in their order.
func Set(pe, tag []byte) ([]byte, error) {
	if len(tag) > MaxTag {
		return nil, fmt.Errorf("certtag: tag of %d bytes", len(tag))
	}
	f, err := parse(pe)
	if err != nil {
		return nil, err
	}
	if !allZero(f.appended) {
		return nil, errors.New("certtag: data appended after the signature (an old-style tag)")
	}
	var kept [][]byte
	for _, der := range f.sd.certs {
		_, has, err := tagExtension(der)
		if err != nil {
			return nil, err
		}
		if !has {
			kept = append(kept, der)
		}
	}
	cert, err := tagCertificate(tag)
	if err != nil {
		return nil, err
	}
	sd := f.sd
	sd.certs = append(kept, cert)
	sd.hasCerts = true
	der, err := sd.marshal()
	if err != nil {
		return nil, err
	}
	return f.build(der, nil), nil
}

// AppendAfterSignature returns a copy of the signed PE file with data appended after the SignedData, inside the
// attribute certificate table: the older way of tagging. It is kept only for trial 2, to show that Windows refuses
// such a file when EnableCertPaddingCheck is on; nothing in wmanager tags files this way, and Get refuses them.
func AppendAfterSignature(pe, data []byte) ([]byte, error) {
	f, err := parse(pe)
	if err != nil {
		return nil, err
	}
	der, err := f.sd.marshal()
	if err != nil {
		return nil, err
	}
	return f.build(der, append(append([]byte{}, f.appended...), data...)), nil
}

func allZero(b []byte) bool {
	for _, c := range b {
		if c != 0 {
			return false
		}
	}
	return true
}

// tagExtension returns the value of the tag extension of a certificate, if it has one.
func tagExtension(der []byte) ([]byte, bool, error) {
	c, err := x509.ParseCertificate(der)
	if err != nil {
		return nil, false, fmt.Errorf("certtag: a certificate of the signature: %w", err)
	}
	for _, ext := range c.Extensions {
		if ext.Id.Equal(OID) {
			if ext.Critical {
				return nil, false, errors.New("certtag: the tag extension is marked critical")
			}
			return ext.Value, true, nil
		}
	}
	return nil, false, nil
}

// tagCertificate makes the extra certificate. It is expired and its issuer doesn't exist, so it can't be used for
// anything; Windows doesn't look at it when it checks the signature.
func tagCertificate(tag []byte) ([]byte, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	notBefore := time.Date(2013, 1, 1, 10, 0, 0, 0, time.UTC)
	notAfter := time.Date(2013, 4, 1, 10, 0, 0, 0, time.UTC)
	issuer := x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "Unknown issuer"},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageCertSign,
		BasicConstraintsValid: true,
		IsCA:                  true,
	}
	template := x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "wmanager tag"},
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageDigitalSignature,
		BasicConstraintsValid: true,
		SignatureAlgorithm:    x509.SHA256WithRSA,
		ExtraExtensions:       []pkix.Extension{{Id: OID, Value: tag}},
	}
	return x509.CreateCertificate(rand.Reader, &template, &issuer, &key.PublicKey, key)
}

// signedData is a PKCS#7 ContentInfo with SignedData (RFC 2315), its parts kept as the exact bytes they were,
// so that writing it again changes nothing but the certificates.
type signedData struct {
	contentType []byte   // the OID element
	version     []byte   // INTEGER element
	digests     []byte   // SET element
	content     []byte   // SEQUENCE element (the Authenticode SpcIndirectDataContent)
	hasCerts    bool     // whether the [0] certificates element is there
	certs       [][]byte // each Certificate element, in order
	crls        []byte   // the [1] element, if any
	signers     []byte   // SET element
}

var oidSignedData = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 7, 2}

var (
	tagCerts = cbasn1.Tag(0).ContextSpecific().Constructed()
	tagCRLs  = cbasn1.Tag(1).ContextSpecific().Constructed()
)

func readElement(s *cryptobyte.String, tag cbasn1.Tag) ([]byte, bool) {
	var e cryptobyte.String
	if !s.ReadASN1Element(&e, tag) {
		return nil, false
	}
	return e, true
}

func parseSignedData(der []byte) (signedData, []byte, error) {
	bad := func(what string) (signedData, []byte, error) {
		return signedData{}, nil, fmt.Errorf("certtag: the signature: %s", what)
	}
	input := cryptobyte.String(der)
	var outer cryptobyte.String
	if !input.ReadASN1(&outer, cbasn1.SEQUENCE) {
		return bad("not a SEQUENCE")
	}
	rest := []byte(input)
	var sd signedData
	var ok bool
	if sd.contentType, ok = readElement(&outer, cbasn1.OBJECT_IDENTIFIER); !ok {
		return bad("no content type")
	}
	oid := cryptobyte.String(sd.contentType)
	var got asn1.ObjectIdentifier
	if !oid.ReadASN1ObjectIdentifier(&got) || !got.Equal(oidSignedData) {
		return bad("not SignedData")
	}
	var explicit, inner cryptobyte.String
	if !outer.ReadASN1(&explicit, cbasn1.Tag(0).ContextSpecific().Constructed()) || !outer.Empty() {
		return bad("no [0] content")
	}
	if !explicit.ReadASN1(&inner, cbasn1.SEQUENCE) || !explicit.Empty() {
		return bad("SignedData is not a SEQUENCE")
	}
	if sd.version, ok = readElement(&inner, cbasn1.INTEGER); !ok {
		return bad("no version")
	}
	if sd.digests, ok = readElement(&inner, cbasn1.SET); !ok {
		return bad("no digest algorithms")
	}
	if sd.content, ok = readElement(&inner, cbasn1.SEQUENCE); !ok {
		return bad("no content")
	}
	if inner.PeekASN1Tag(tagCerts) {
		var certs cryptobyte.String
		if !inner.ReadASN1(&certs, tagCerts) {
			return bad("certificates")
		}
		sd.hasCerts = true
		for !certs.Empty() {
			c, ok := readElement(&certs, cbasn1.SEQUENCE)
			if !ok {
				return bad("a certificate")
			}
			sd.certs = append(sd.certs, c)
		}
	}
	if inner.PeekASN1Tag(tagCRLs) {
		if sd.crls, ok = readElement(&inner, tagCRLs); !ok {
			return bad("CRLs")
		}
	}
	if sd.signers, ok = readElement(&inner, cbasn1.SET); !ok || !inner.Empty() {
		return bad("signer infos")
	}
	return sd, rest, nil
}

func (sd signedData) marshal() ([]byte, error) {
	var b cryptobyte.Builder
	b.AddASN1(cbasn1.SEQUENCE, func(b *cryptobyte.Builder) {
		b.AddBytes(sd.contentType)
		b.AddASN1(cbasn1.Tag(0).ContextSpecific().Constructed(), func(b *cryptobyte.Builder) {
			b.AddASN1(cbasn1.SEQUENCE, func(b *cryptobyte.Builder) {
				b.AddBytes(sd.version)
				b.AddBytes(sd.digests)
				b.AddBytes(sd.content)
				if sd.hasCerts {
					b.AddASN1(tagCerts, func(b *cryptobyte.Builder) {
						for _, c := range sd.certs {
							b.AddBytes(c)
						}
					})
				}
				b.AddBytes(sd.crls)
				b.AddBytes(sd.signers)
			})
		})
	})
	out, err := b.Bytes()
	if err != nil {
		return nil, fmt.Errorf("certtag: %w", err)
	}
	return out, nil
}

type peFile struct {
	contents       []byte
	attrCertOffset int // where the attribute certificate table starts
	certSizeOffset int // where its size is written in the data directory
	sd             signedData
	appended       []byte // bytes after the SignedData in the table
}

// Attribute certificate constants (WIN_CERTIFICATE) and PE layout.
const (
	certRevision      = 0x200
	certTypePKCS7     = 2
	certTableIndex    = 4
	pe32Magic         = 0x10b
	pe32PlusMagic     = 0x20b
	charExecutable    = 0x2
	charDLL           = 0x2000
	peHeaderOffsetPos = 0x3c
	fileHeaderSize    = 20
	sectionHeaderSize = 40
)

func parse(contents []byte) (*peFile, error) {
	offset, size, sizeOffset, err := attributeCertificates(contents)
	if err != nil {
		return nil, fmt.Errorf("certtag: %w", err)
	}
	certs := contents[offset : offset+size]
	if len(certs) < 8 {
		return nil, errors.New("certtag: attribute certificate truncated")
	}
	if int(binary.LittleEndian.Uint32(certs[:4])) != len(certs) {
		return nil, errors.New("certtag: more than one attribute certificate")
	}
	if rev := binary.LittleEndian.Uint16(certs[4:6]); rev != certRevision {
		return nil, fmt.Errorf("certtag: attribute certificate revision %#x", rev)
	}
	if typ := binary.LittleEndian.Uint16(certs[6:8]); typ != certTypePKCS7 {
		return nil, fmt.Errorf("certtag: attribute certificate type %d", typ)
	}
	der := certs[8:]
	sd, rest, err := parseSignedData(der)
	if err != nil {
		return nil, err
	}
	// Writing it again must give the same bytes: then Set changes nothing but the certificates.
	again, err := sd.marshal()
	if err != nil || !bytes.Equal(again, der[:len(der)-len(rest)]) {
		return nil, errors.New("certtag: the signature isn't in the DER form expected")
	}
	return &peFile{contents: contents, attrCertOffset: offset, certSizeOffset: sizeOffset, sd: sd, appended: rest}, nil
}

// build writes the file again with new SignedData bytes and the given appended bytes, padded with zeros to 8
// bytes as the format needs.
func (f *peFile) build(der, appended []byte) []byte {
	tail := append([]byte{}, appended...)
	for (len(der)+len(tail))&7 != 0 {
		tail = append(tail, 0)
	}
	n := uint32(8 + len(der) + len(tail))
	out := make([]byte, 0, f.attrCertOffset+int(n))
	out = append(out, f.contents[:f.certSizeOffset]...)
	out = binary.LittleEndian.AppendUint32(out, n)
	out = append(out, f.contents[f.certSizeOffset+4:f.attrCertOffset]...)
	out = binary.LittleEndian.AppendUint32(out, n)
	out = binary.LittleEndian.AppendUint16(out, certRevision)
	out = binary.LittleEndian.AppendUint16(out, certTypePKCS7)
	out = append(out, der...)
	return append(out, tail...)
}

// attributeCertificates finds the attribute certificate table of a PE file. Every offset is checked against the
// file before use: the table must come after the headers and end the file.
func attributeCertificates(bin []byte) (offset, size, sizeOffset int, err error) {
	if len(bin) < peHeaderOffsetPos+4 {
		return 0, 0, 0, errors.New("file truncated")
	}
	peOffset := int(binary.LittleEndian.Uint32(bin[peHeaderOffsetPos:]))
	if peOffset < 0 || peOffset > len(bin)-4-fileHeaderSize {
		return 0, 0, 0, errors.New("PE header out of the file")
	}
	if !bytes.Equal(bin[peOffset:peOffset+4], []byte("PE\x00\x00")) {
		return 0, 0, 0, errors.New("not a PE file")
	}
	fh := bin[peOffset+4 : peOffset+4+fileHeaderSize]
	sections := int(binary.LittleEndian.Uint16(fh[2:]))
	optSize := int(binary.LittleEndian.Uint16(fh[16:]))
	chars := binary.LittleEndian.Uint16(fh[18:])
	if chars&charExecutable == 0 || chars&charDLL != 0 {
		return 0, 0, 0, errors.New("not an exe")
	}
	optStart := peOffset + 4 + fileHeaderSize
	if optStart+optSize > len(bin) {
		return 0, 0, 0, errors.New("optional header out of the file")
	}
	opt := bin[optStart : optStart+optSize]
	// The fixed part of the optional header ends with the number of data directories.
	var countAt int
	switch {
	case len(opt) >= 2 && binary.LittleEndian.Uint16(opt) == pe32PlusMagic:
		countAt = 108
	case len(opt) >= 2 && binary.LittleEndian.Uint16(opt) == pe32Magic:
		countAt = 92
	default:
		return 0, 0, 0, errors.New("unknown optional header")
	}
	if len(opt) < countAt+4 {
		return 0, 0, 0, errors.New("optional header truncated")
	}
	count := int(binary.LittleEndian.Uint32(opt[countAt:]))
	if count <= certTableIndex || count > 16 {
		return 0, 0, 0, fmt.Errorf("%d data directories", count)
	}
	if countAt+4+8*count != len(opt) {
		return 0, 0, 0, errors.New("the optional header's size doesn't match its data directories")
	}
	dir := countAt + 4 + 8*certTableIndex
	tableOffset := int(binary.LittleEndian.Uint32(opt[dir:])) // a file offset for this directory
	tableSize := int(binary.LittleEndian.Uint32(opt[dir+4:]))
	if tableOffset == 0 {
		return 0, 0, 0, errors.New("the file is not signed")
	}
	headersEnd := optStart + optSize + sections*sectionHeaderSize
	if tableOffset < headersEnd || tableOffset > len(bin) || tableSize != len(bin)-tableOffset {
		return 0, 0, 0, fmt.Errorf("the signature table (%d, %d bytes) is not after the headers at the end of the file",
			tableOffset, tableSize)
	}
	return tableOffset, tableSize, optStart + dir + 4, nil
}
