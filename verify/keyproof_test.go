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
	proof := func(signer *softkey.Key, account string, at time.Time) verify.Signed {
		s, err := signer.SignStatement(verify.MakeKeyProof(account, at), softkey.Options{})
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	if id, err := verify.CheckKeyProof(proof(k, "acc-1", now), k.COSEKey(), "acc-1", now); err != nil || id != k.ID() {
		t.Fatalf("a good proof: %q %v", id, err)
	}
	bad := map[string]error{}
	_, bad["another account"] = verify.CheckKeyProof(proof(k, "acc-2", now), k.COSEKey(), "acc-1", now)
	_, bad["too old"] = verify.CheckKeyProof(proof(k, "acc-1", now.Add(-11*time.Minute)), k.COSEKey(), "acc-1", now)
	_, bad["signed by another key"] = verify.CheckKeyProof(proof(other, "acc-1", now), k.COSEKey(), "acc-1", now)
	stolen := proof(other, "acc-1", now)
	stolen.Key = k.ID()
	_, bad["another key's signature, this key's id"] = verify.CheckKeyProof(stolen, k.COSEKey(), "acc-1", now)
	_, bad["not a key"] = verify.CheckKeyProof(proof(k, "acc-1", now), []byte("x"), "acc-1", now)
	stmt, _ := k.SignStatement([]byte(`{"format":1,"type":"stop"}`), softkey.Options{})
	_, bad["a statement"] = verify.CheckKeyProof(stmt, k.COSEKey(), "acc-1", now)
	for name, err := range bad {
		if !errors.Is(err, verify.ErrKeyProof) {
			t.Errorf("%s: %v", name, err)
		}
	}
	// And a proof is no statement.
	c := newCompany(t)
	ch, _ := verify.VerifyChain(c.fingerprint(), c.lists)
	if _, err := ch.VerifyState(proof(c.anna, "acc-1", now), 0); err == nil {
		t.Fatal("a key proof passed as a state")
	}
}
