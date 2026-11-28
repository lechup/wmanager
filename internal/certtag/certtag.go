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
// Changes: an OID of our own (2.25, from a UUID; the tag certificate written by hand for it); the signature's structure kept byte for byte, its certificates in their own order
// (Omaha re-encodes them, which sorts them); stricter checks of the PE headers; no appended data, which the
// padding check refuses; and a strict reader for the agent.
package certtag

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/asn1"
	"encoding/binary"
	"errors"
	"fmt"
	"time"

	"golang.org/x/crypto/cryptobyte"
	cbasn1 "golang.org/x/crypto/cryptobyte/asn1"
)

// OID is the extension that holds the tag: 2.25.158821274951320701755001128286401276726, the UUID
// 777bdd6b-9f8e-49e7-bef7-ffca86332b36 as an OID (ITU-T X.667), which needs no registration. Go's crypto/x509
// can't hold its 128-bit arc, so the tag certificate is written and read here with cryptobyte, and the OID is kept
// as its DER content.
const OID = "2.25.158821274951320701755001128286401276726"

// oidDER is OID's DER content (without its tag and length).
var oidDER = []byte{0x69, 0x81, 0xee, 0xfb, 0xee, 0xda, 0xf3, 0xf8, 0xf2, 0xa7, 0xcf, 0xbe, 0xfb, 0xff, 0xf9, 0xa8, 0xb1,
	0xcc, 0xd6, 0x36}

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

var errCert = errors.New("certtag: a certificate of the signature is malformed")

// tagExtension returns the value of the tag extension of a certificate, if it has one. The certificate is read with
// cryptobyte, as far as its extensions: crypto/x509 refuses the tag's OID.
func tagExtension(der []byte) ([]byte, bool, error) {
	in := cryptobyte.String(der)
	var cert, tbs cryptobyte.String
	if !in.ReadASN1(&cert, cbasn1.SEQUENCE) || !in.Empty() || !cert.ReadASN1(&tbs, cbasn1.SEQUENCE) {
		return nil, false, errCert
	}
	if !tbs.SkipOptionalASN1(cbasn1.Tag(0).Constructed().ContextSpecific()) || // version
		!tbs.SkipASN1(cbasn1.INTEGER) || // serial number
		!tbs.SkipASN1(cbasn1.SEQUENCE) || // signature algorithm
		!tbs.SkipASN1(cbasn1.SEQUENCE) || // issuer
		!tbs.SkipASN1(cbasn1.SEQUENCE) || // validity
		!tbs.SkipASN1(cbasn1.SEQUENCE) || // subject
		!tbs.SkipASN1(cbasn1.SEQUENCE) || // subject public key info
		!tbs.SkipOptionalASN1(cbasn1.Tag(1).ContextSpecific()) || // issuer unique id
		!tbs.SkipOptionalASN1(cbasn1.Tag(2).ContextSpecific()) { // subject unique id
		return nil, false, errCert
	}
	var exts cryptobyte.String
	var has bool
	if !tbs.ReadOptionalASN1(&exts, &has, cbasn1.Tag(3).Constructed().ContextSpecific()) {
		return nil, false, errCert
	}
	if !has {
		return nil, false, nil
	}
	var list cryptobyte.String
	if !exts.ReadASN1(&list, cbasn1.SEQUENCE) || !exts.Empty() {
		return nil, false, errCert
	}
	var value []byte
	found := false
	for !list.Empty() {
		var ext, oid, val cryptobyte.String
		critical := false // DEFAULT FALSE: a plain BOOLEAN, when there is one
		if !list.ReadASN1(&ext, cbasn1.SEQUENCE) || !ext.ReadASN1(&oid, cbasn1.OBJECT_IDENTIFIER) ||
			(ext.PeekASN1Tag(cbasn1.BOOLEAN) && !ext.ReadASN1Boolean(&critical)) ||
			!ext.ReadASN1(&val, cbasn1.OCTET_STRING) || !ext.Empty() {
			return nil, false, errCert
		}
		if !bytes.Equal(oid, oidDER) {
			continue
		}
		if critical {
			return nil, false, errors.New("certtag: the tag extension is marked critical")
		}
		if found {
			return nil, false, errors.New("certtag: the tag extension twice")
		}
		found, value = true, append([]byte(nil), val...)
	}
	return value, found, nil
}

var (
	oidCommonName = asn1.ObjectIdentifier{2, 5, 4, 3}
	oidSHA256RSA  = asn1.ObjectIdentifier{1, 2, 840, 113549, 1, 1, 11}
)

func addName(b *cryptobyte.Builder, cn string) {
	b.AddASN1(cbasn1.SEQUENCE, func(b *cryptobyte.Builder) {
		b.AddASN1(cbasn1.SET, func(b *cryptobyte.Builder) {
			b.AddASN1(cbasn1.SEQUENCE, func(b *cryptobyte.Builder) {
				b.AddASN1ObjectIdentifier(oidCommonName)
				b.AddASN1(cbasn1.UTF8String, func(b *cryptobyte.Builder) { b.AddBytes([]byte(cn)) })
			})
		})
	})
}

func addSHA256RSA(b *cryptobyte.Builder) {
	b.AddASN1(cbasn1.SEQUENCE, func(b *cryptobyte.Builder) {
		b.AddASN1ObjectIdentifier(oidSHA256RSA)
		b.AddASN1NULL()
	})
}

// tagCertificate makes the extra certificate, written by hand for its OID. It is expired and its issuer doesn't
// exist, so it can't be used for anything; Windows doesn't look at it when it checks the signature.
func tagCertificate(tag []byte) ([]byte, error) { return buildTagCertificate(tag, false) }

// buildTagCertificate is tagCertificate, with the extension marked critical for a test of its refusal.
func buildTagCertificate(tag []byte, critical bool) ([]byte, error) {
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, err
	}
	spki, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		return nil, err
	}
	var tb cryptobyte.Builder
	tb.AddASN1(cbasn1.SEQUENCE, func(b *cryptobyte.Builder) {
		b.AddASN1(cbasn1.Tag(0).Constructed().ContextSpecific(), func(b *cryptobyte.Builder) { b.AddASN1Int64(2) }) // v3
		b.AddASN1Int64(1)
		addSHA256RSA(b)
		addName(b, "Unknown issuer")
		b.AddASN1(cbasn1.SEQUENCE, func(b *cryptobyte.Builder) {
			b.AddASN1UTCTime(time.Date(2013, 1, 1, 10, 0, 0, 0, time.UTC))
			b.AddASN1UTCTime(time.Date(2013, 4, 1, 10, 0, 0, 0, time.UTC))
		})
		addName(b, "wmanager tag")
		b.AddBytes(spki)
		b.AddASN1(cbasn1.Tag(3).Constructed().ContextSpecific(), func(b *cryptobyte.Builder) {
			b.AddASN1(cbasn1.SEQUENCE, func(b *cryptobyte.Builder) {
				b.AddASN1(cbasn1.SEQUENCE, func(b *cryptobyte.Builder) {
					b.AddASN1(cbasn1.OBJECT_IDENTIFIER, func(b *cryptobyte.Builder) { b.AddBytes(oidDER) })
					if critical {
						b.AddASN1Boolean(true)
					}
					b.AddASN1OctetString(tag)
				})
			})
		})
	})
	tbs, err := tb.Bytes()
	if err != nil {
		return nil, err
	}
	h := sha256.Sum256(tbs)
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, h[:])
	if err != nil {
		return nil, err
	}
	var cb cryptobyte.Builder
	cb.AddASN1(cbasn1.SEQUENCE, func(b *cryptobyte.Builder) {
		b.AddBytes(tbs)
		addSHA256RSA(b)
		b.AddASN1BitString(sig)
	})
	return cb.Bytes()
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
