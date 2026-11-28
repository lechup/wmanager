package verify_test

import (
	"errors"
	"testing"
	"time"

	"github.com/lechup/wmanager/verify"
	"github.com/lechup/wmanager/verify/softkey"
)

func TestKeyProof(t *testing.T) {
	now := time.Now()
	k := newKey(t, verify.ES256)
	other := newKey(t, verify.ES256)
	const server = "https://wm.example.com"
	proofFor := func(signer *softkey.Key, srv, account string, at time.Time) verify.Signed {
		s, err := signer.SignStatement(verify.MakeKeyProof(srv, account, at), softkey.Options{})
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	proof := func(signer *softkey.Key, account string, at time.Time) verify.Signed {
		return proofFor(signer, server, account, at)
	}
	if id, err := verify.CheckKeyProof(proof(k, "acc-1", now), k.COSEKey(), server, "acc-1", now); err != nil || id != k.ID() {
		t.Fatalf("a good proof: %q %v", id, err)
	}
	bad := map[string]error{}
	_, bad["another account"] = verify.CheckKeyProof(proof(k, "acc-2", now), k.COSEKey(), server, "acc-1", now)
	_, bad["too old"] = verify.CheckKeyProof(proof(k, "acc-1", now.Add(-11*time.Minute)), k.COSEKey(), server, "acc-1", now)
	_, bad["signed by another key"] = verify.CheckKeyProof(proof(other, "acc-1", now), k.COSEKey(), server, "acc-1", now)
	stolen := proof(other, "acc-1", now)
	stolen.Key = k.ID()
	_, bad["another key's signature, this key's id"] = verify.CheckKeyProof(stolen, k.COSEKey(), server, "acc-1", now)
	_, bad["not a key"] = verify.CheckKeyProof(proof(k, "acc-1", now), []byte("x"), server, "acc-1", now)
	_, bad["another server"] = verify.CheckKeyProof(proofFor(k, "https://other.example.com", "acc-1", now), k.COSEKey(), server, "acc-1", now)
	_, bad["no server of its own"] = verify.CheckKeyProof(proofFor(k, "", "acc-1", now), k.COSEKey(), "", "acc-1", now)
	stmt, _ := k.SignStatement([]byte(`{"format":1,"type":"stop"}`), softkey.Options{})
	_, bad["a statement"] = verify.CheckKeyProof(stmt, k.COSEKey(), server, "acc-1", now)
	for name, err := range bad {
		if !errors.Is(err, verify.ErrKeyProof) {
			t.Errorf("%s: %v", name, err)
		}
	}
	// And a proof is no statement of any type.
	c := newCompany(t)
	ch, _ := verify.VerifyChain(c.fingerprint(), c.lists)
	p := proof(c.anna, "acc-1", now)
	if _, err := ch.VerifyState(p, 0); err == nil {
		t.Error("a key proof passed as a state")
	}
	if _, err := verify.VerifyChain(verify.Fingerprint(p.Hash()), []verify.Signed{p}); err == nil {
		t.Error("a key proof passed as a first admin list")
	}
	if err := ch.Update(append(append([]verify.Signed{}, c.lists...), p)); err == nil {
		t.Error("a key proof passed as a next admin list")
	}
	keys := ch.AdminKeys()
	if _, err := ch.VerifyJob(p, keys); err == nil {
		t.Error("a key proof passed as a job")
	}
	if _, err := ch.VerifyStop(p, keys); err == nil {
		t.Error("a key proof passed as a stop")
	}
	if _, err := ch.VerifySession(p, keys); err == nil {
		t.Error("a key proof passed as a session")
	}
}
