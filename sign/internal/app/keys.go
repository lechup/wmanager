package app

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"net/http"
	"net/url"

	"github.com/lechup/wmanager/sign/internal/api"
	"github.com/lechup/wmanager/sign/internal/fido"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/verify"
)

// keyFingerprint is a key's fingerprint: the first 128 bits of the SHA-256 of its public key.
func keyFingerprint(cose []byte) string { return verify.Fingerprint(sha256.Sum256(cose)) }

// newKey makes a signing key on the security key, tied to it, and registers it with the server with the key's
// proof that its holder registers it for this account on this server. It then shows the key's whole fingerprint,
// which an administrator types to add the key to an admin list.
func (a *App) newKey(ctx context.Context) error {
	s, err := a.connected()
	if err != nil {
		return err
	}
	d, pin, err := a.device()
	if err != nil {
		return err
	}
	defer d.Close()
	host := s.client.Server
	if u, err := url.Parse(host); err == nil {
		host = u.Host
	}
	user := fido.User{ID: make([]byte, 16), Name: "wmanager-sign " + host, DisplayName: "wmanager-sign"}
	rand.Read(user.ID)
	// The client data of a registration: nothing checks it (no attestation is asked for), but a key signs its hash.
	var challenge [32]byte
	rand.Read(challenge[:])
	clientData := []byte(`{"type":"webauthn.create","challenge":"` + base64.RawURLEncoding.EncodeToString(challenge[:]) +
		`","origin":"` + verify.Origin + `"}`)
	a.say("key.touchnew")
	cred, err := d.MakeCredential(user, clientData, pin)
	if err != nil {
		return err
	}
	switch {
	case cred.Flags&fido.FlagBackupEligible != 0:
		return a.fail("err.synced")
	case cred.Flags&fido.FlagUserVerified == 0 || cred.Flags&fido.FlagUserPresent == 0:
		return a.fail("err.nouv")
	}
	if _, err := verify.ParseCOSEKey(cred.COSE); err != nil {
		return a.fail("err.badkey", err.Error())
	}
	id := verify.KeyID(cred.COSE)
	pk, _ := verify.ParseCOSEKey(cred.COSE)

	// The proof is at the server's time, which it checks against its own clock.
	now, err := s.client.Time(ctx)
	if err != nil {
		return a.apiErr(s, err)
	}
	proof := verify.MakeKeyProof(s.client.Server, s.account, now)
	local := []home.Key{{ID: id, COSE: cred.COSE, CredentialID: cred.ID}}
	signed, err := a.signWith(d, pin, proof, map[string]verify.PublicKey{id: pk}, local)
	if err != nil {
		return err
	}
	if _, err := s.client.RegisterKey(ctx, cred.COSE, signed); err != nil {
		switch api.Status(err) {
		case http.StatusConflict:
			return a.fail("err.keyconflict", err.Error())
		case http.StatusServiceUnavailable:
			return a.fail("err.nopublicurl")
		}
		return a.apiErr(s, err)
	}
	if err := s.srv.AddKey(home.Key{ID: id, COSE: cred.COSE, CredentialID: cred.ID, Account: s.account, Made: a.Now().UTC()}); err != nil {
		return err
	}
	a.say("key.made", keyFingerprint(cred.COSE))
	return nil
}

// listKeys lists the signing keys made here for the server.
func (a *App) listKeys() error {
	s, err := a.connected()
	if err != nil {
		return err
	}
	ks, err := s.srv.Keys()
	if err != nil {
		return err
	}
	if len(ks) == 0 {
		a.say("key.none")
		return nil
	}
	for _, k := range ks {
		a.say("key.line", keyFingerprint(k.COSE), k.Made.Local().Format("2006-01-02 15:04"))
	}
	return nil
}

func sha256Sum(b []byte) [32]byte { return sha256.Sum256(b) }
