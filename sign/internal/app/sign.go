package app

import (
	"crypto/sha256"
	"errors"

	"github.com/lechup/wmanager/sign/internal/fido"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/sign/internal/show"
	"github.com/lechup/wmanager/verify"
)

// device opens the security key and reads its PIN, when it has one, typed and kept nowhere.
func (a *App) device() (fido.Device, string, error) {
	d, err := a.OpenDevice()
	if err != nil {
		return nil, "", err
	}
	a.say("key.using", show.Visible(d.Name()))
	if !d.NeedsPIN() {
		return d, "", nil
	}
	pin, err := a.ReadSecret(a.t("key.pin"))
	if err == nil && pin == "" {
		err = a.fail("err.nopin")
	}
	if err != nil {
		d.Close()
		return nil, "", err
	}
	return d, pin, nil
}

// signWith signs a statement's bytes with whichever of the allowed keys the security key holds: the keys made
// here are asked for by their credential ids; with none of them, every wmanager-sign key on it signs and the one
// that verifies against an allowed key is taken. Each signature is checked before it is used.
func (a *App) signWith(d fido.Device, pin string, raw []byte, allowed map[string]verify.PublicKey, local []home.Key) (verify.Signed, error) {
	h := sha256.Sum256(raw)
	clientData := verify.ClientDataJSON(h)
	cdh := sha256.Sum256(clientData)
	var creds [][]byte
	for _, k := range local {
		if _, ok := allowed[k.ID]; ok && len(k.CredentialID) > 0 {
			creds = append(creds, k.CredentialID)
		}
	}
	a.say("key.touch")
	as, err := d.Assert(cdh, creds, pin)
	if errors.Is(err, fido.ErrNoCreds) && creds != nil {
		// The keys made here may be on another security key: try every one on this one.
		a.say("key.touch")
		as, err = d.Assert(cdh, nil, pin)
	}
	if errors.Is(err, fido.ErrNoCreds) {
		return verify.Signed{}, a.fail("err.nokeyhere")
	}
	if err != nil {
		return verify.Signed{}, err
	}
	byCred := map[string]string{}
	for _, k := range local {
		byCred[string(k.CredentialID)] = k.ID
	}
	for _, x := range as {
		sig := verify.Assertion{AuthenticatorData: x.AuthenticatorData, ClientDataJSON: clientData, Signature: x.Signature}
		signed := func(id string) verify.Signed {
			return verify.Signed{Statement: raw, Key: id, AuthenticatorData: x.AuthenticatorData,
				ClientDataJSON: clientData, Signature: x.Signature}
		}
		// A key made here is known by its credential id: its signature must check, and why it doesn't is said.
		if id, ok := byCred[string(x.CredentialID)]; ok {
			if pk, ok := allowed[id]; ok {
				if err := verify.CheckAssertion(h, sig, pk); err != nil {
					return verify.Signed{}, err
				}
				return signed(id), nil
			}
			continue
		}
		for id, pk := range allowed {
			if verify.CheckAssertion(h, sig, pk) == nil {
				return signed(id), nil
			}
		}
	}
	return verify.Signed{}, a.fail("err.nokeyhere")
}
