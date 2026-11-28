package verify

import (
	"encoding/json/v2"
	"errors"
	"time"
)

// KeyProof is what a new signing key signs when its holder registers it with a server: that the holder of this
// key registers it for this account on this server, now. So nobody can register someone else's public key (which
// an admin list shows to every member) under their own name, and a server can't pass on to another server a proof
// made for it. The server is the address wmanager-sign was set up with, not one the server reports. It is not a
// statement: it has no format or type, so no check of a statement accepts it, and a statement has members a proof
// refuses. wmanager-sign builds the bytes itself (MakeKeyProof) and never signs bytes a server sends.
type KeyProof struct {
	Purpose string    `json:"purpose"`
	Server  string    `json:"server"`
	Account string    `json:"account"`
	At      time.Time `json:"at"`
}

// KeyProofPurpose is a proof's purpose; KeyProofAge how far its time may be from the server's.
const (
	KeyProofPurpose = "wmanager-sign: register this key for this account"
	KeyProofAge     = 10 * time.Minute
)

// ErrKeyProof refuses a proof.
var ErrKeyProof = errors.New("verify: not a proof that the key's holder registers it")

// MakeKeyProof is the bytes a new key signs for the account on the server (https://host[:port]), at the server's
// time.
func MakeKeyProof(server, account string, at time.Time) []byte {
	b, _ := json.Marshal(KeyProof{Purpose: KeyProofPurpose, Server: server, Account: account, At: at.UTC().Truncate(time.Second)})
	return b
}

// CheckKeyProof checks that the key given by its COSE form signed a proof for the account on this server within
// KeyProofAge of now, and returns the key's id.
func CheckKeyProof(s Signed, cose []byte, server, account string, now time.Time) (string, error) {
	if len(s.Statement) > 512 {
		return "", ErrKeyProof
	}
	pk, err := ParseCOSEKey(cose)
	if err != nil {
		return "", ErrKeyProof
	}
	if err := CheckKey(pk); err != nil {
		return "", ErrKeyProof
	}
	id := KeyID(cose)
	if s.Key != id {
		return "", ErrKeyProof
	}
	if err := CheckAssertion(s.Hash(), s.assertion(), pk); err != nil {
		return "", ErrKeyProof
	}
	var p KeyProof
	if err := json.Unmarshal(s.Statement, &p, json.RejectUnknownMembers(true)); err != nil {
		return "", ErrKeyProof
	}
	if p.Purpose != KeyProofPurpose || server == "" || p.Server != server || p.Account != account ||
		p.At.Sub(now).Abs() > KeyProofAge {
		return "", ErrKeyProof
	}
	return id, nil
}
