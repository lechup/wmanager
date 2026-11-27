// Package certtag reads and writes the tag of an Authenticode-signed Windows exe: data that the server adds to the
// release's signed wmanager-agent.exe without breaking its signature (docs/architecture.md, "Enrolling a computer").
//
// The tag sits in an extension of an extra ("superfluous") certificate in the signature's set of certificates,
// which the signature doesn't cover. This is the way of Omaha's certificate_tag, which Google uses for Chrome's
// installers; the older way of appending data after the signature fails when Windows checks the signature's
// padding (EnableCertPaddingCheck).
//
// Ported from https://github.com/google/omaha/blob/main/common/certificate_tag/certificate_tag.go
// (Copyright 2015 Google Inc., Apache License 2.0), keeping only PE files and the superfluous certificate.
// Changes: an OID of our own, a SHA-256 signature on the extra certificate, and a strict reader for the agent.
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
	"io"
	"math/big"
	"time"
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
// than one tag certificate is refused: the agent reads its tag strictly, since anyone can tag a file.
func Get(pe []byte) (tag []byte, ok bool, err error) {
	f, err := parse(pe)
	if err != nil {
		return nil, false, err
	}
	found := -1
	for i, raw := range f.signed.PKCS7.Certs {
		v, has, err := tagExtension(raw.FullBytes)
		if err != nil {
			return nil, false, err
		}
		if !has {
			continue
		}
		if found >= 0 {
			return nil, false, errors.New("certtag: more than one tag certificate")
		}
		found, tag = i, v
	}
	if found < 0 {
		return nil, false, nil
	}
	if len(tag) > MaxTag {
		return nil, false, fmt.Errorf("certtag: tag of %d bytes", len(tag))
	}
	return tag, true, nil
}

// Set returns a copy of the signed PE file with the given tag, replacing a tag it already has.
func Set(pe, tag []byte) ([]byte, error) {
	if len(tag) > MaxTag {
		return nil, fmt.Errorf("certtag: tag of %d bytes", len(tag))
	}
	f, err := parse(pe)
	if err != nil {
		return nil, err
	}
	var kept []asn1.RawValue
	for _, raw := range f.signed.PKCS7.Certs {
		_, has, err := tagExtension(raw.FullBytes)
		if err != nil {
			return nil, err
		}
		if !has {
			kept = append(kept, raw)
		}
	}
	cert, err := tagCertificate(tag)
	if err != nil {
		return nil, err
	}
	f.signed.PKCS7.Certs = append(kept, asn1.RawValue{FullBytes: cert})
	der, err := asn1.Marshal(f.signed)
	if err != nil {
		return nil, fmt.Errorf("certtag: %w", err)
	}
	return f.build(der), nil
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

// signedData is a PKCS#7 SignedData, enough of it to change its set of certificates.
type signedData struct {
	Type  asn1.ObjectIdentifier
	PKCS7 struct {
		Version     int
		Digests     asn1.RawValue
		ContentInfo asn1.RawValue
		Certs       []asn1.RawValue `asn1:"tag:0,optional,set"`
		SignerInfos asn1.RawValue
	} `asn1:"explicit,tag:0"`
}

type peFile struct {
	contents       []byte
	attrCertOffset int // where the attribute certificate table starts
	certSizeOffset int // where its size is written in the data directory
	signed         signedData
	appended       []byte // bytes after the SignedData, kept as they are
}

// Attribute certificate constants (WIN_CERTIFICATE).
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
	var sd signedData
	rest, err := asn1.Unmarshal(der, &sd)
	if err != nil {
		return nil, fmt.Errorf("certtag: the signature: %w", err)
	}
	inner := der[:len(der)-len(rest)]
	again, err := asn1.Marshal(sd)
	if err != nil || !bytes.Equal(again, inner) {
		return nil, errors.New("certtag: the signature doesn't survive reading and writing again")
	}
	return &peFile{
		contents:       contents,
		attrCertOffset: offset,
		certSizeOffset: sizeOffset,
		signed:         sd,
		appended:       rest,
	}, nil
}

// build writes the file again with new SignedData bytes, padded to 8 bytes as the format needs.
func (f *peFile) build(der []byte) []byte {
	tail := append([]byte{}, f.appended...)
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

type fileHeader struct {
	Machine              uint16
	NumberOfSections     uint16
	TimeDateStamp        uint32
	PointerToSymbolTable uint32
	NumberOfSymbols      uint32
	SizeOfOptionalHeader uint16
	Characteristics      uint16
}

type optionalHeaderStart struct {
	Magic                   uint16
	MajorLinkerVersion      uint8
	MinorLinkerVersion      uint8
	SizeOfCode              uint32
	SizeOfInitializedData   uint32
	SizeOfUninitializedData uint32
	AddressOfEntryPoint     uint32
	BaseOfCode              uint32
}

type dataDirectory struct {
	VirtualAddress uint32 // for the certificate table: a file offset
	Size           uint32
}

// attributeCertificates finds the attribute certificate table of a PE file. It must be the end of the file.
func attributeCertificates(bin []byte) (offset, size, sizeOffset int, err error) {
	if len(bin) < peHeaderOffsetPos+4 {
		return 0, 0, 0, errors.New("file truncated")
	}
	peOffset := int(binary.LittleEndian.Uint32(bin[peHeaderOffsetPos:]))
	if peOffset < 0 || peOffset > len(bin)-4 {
		return 0, 0, 0, errors.New("PE header out of the file")
	}
	if !bytes.Equal(bin[peOffset:peOffset+4], []byte("PE\x00\x00")) {
		return 0, 0, 0, errors.New("not a PE file")
	}
	r := bytes.NewReader(bin[peOffset+4:])
	var fh fileHeader
	if err := binary.Read(r, binary.LittleEndian, &fh); err != nil {
		return 0, 0, 0, err
	}
	if fh.Characteristics&charExecutable == 0 || fh.Characteristics&charDLL != 0 {
		return 0, 0, 0, errors.New("not an exe")
	}
	opt := io.LimitReader(r, int64(fh.SizeOfOptionalHeader))
	var oh optionalHeaderStart
	if err := binary.Read(opt, binary.LittleEndian, &oh); err != nil {
		return 0, 0, 0, err
	}
	var addr int
	switch oh.Magic {
	case pe32PlusMagic:
		addr = 8
	case pe32Magic:
		addr = 4
		var baseOfData uint32
		if err := binary.Read(opt, binary.LittleEndian, &baseOfData); err != nil {
			return 0, 0, 0, err
		}
	default:
		return 0, 0, 0, fmt.Errorf("optional header magic %#x", oh.Magic)
	}
	// The Windows-specific fields up to the number of data directories.
	if _, err := io.CopyN(io.Discard, opt, int64(addr+40+addr*4+4)); err != nil {
		return 0, 0, 0, err
	}
	var count uint32
	if err := binary.Read(opt, binary.LittleEndian, &count); err != nil {
		return 0, 0, 0, err
	}
	if count <= certTableIndex || count > 4096 {
		return 0, 0, 0, fmt.Errorf("%d data directories", count)
	}
	dirs := make([]dataDirectory, count)
	if err := binary.Read(opt, binary.LittleEndian, dirs); err != nil {
		return 0, 0, 0, err
	}
	if n, _ := io.Copy(io.Discard, opt); n != 0 {
		return 0, 0, 0, errors.New("extra data after the data directories")
	}
	cert := dirs[certTableIndex]
	if cert.VirtualAddress == 0 {
		return 0, 0, 0, errors.New("the file is not signed")
	}
	end := uint64(cert.VirtualAddress) + uint64(cert.Size)
	if end != uint64(len(bin)) {
		return 0, 0, 0, fmt.Errorf("the signature is not at the end of the file (%d of %d)", end, len(bin))
	}
	sizeOffset = peOffset + 4 + fileHeaderSize + int(fh.SizeOfOptionalHeader) - 8*(int(count)-certTableIndex) + 4
	if binary.LittleEndian.Uint32(bin[sizeOffset:]) != cert.Size {
		return 0, 0, 0, errors.New("internal error: the size of the certificate table not where expected")
	}
	return int(cert.VirtualAddress), int(cert.Size), sizeOffset, nil
}

// AppendAfterSignature returns a copy of the signed PE file with data appended after the SignedData, inside the
// attribute certificate table: the older way of tagging. It is kept only for trial 2, to show that Windows refuses
// such a file when EnableCertPaddingCheck is on; nothing in wmanager tags files this way.
func AppendAfterSignature(pe, data []byte) ([]byte, error) {
	f, err := parse(pe)
	if err != nil {
		return nil, err
	}
	f.appended = append(append([]byte{}, f.appended...), data...)
	der, err := asn1.Marshal(f.signed)
	if err != nil {
		return nil, fmt.Errorf("certtag: %w", err)
	}
	return f.build(der), nil
}
