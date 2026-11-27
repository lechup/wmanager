package verify

import (
	"bytes"
	"encoding/hex"
	"fmt"
)

// Chain is a company's admin lists, from the first, each checked against the one before. A computer holds its
// company's chain and checks everything against its newest list (docs/architecture.md, "The admin list of a
// company").
type Chain struct {
	Company [32]byte // the SHA-256 of the first list's bytes: the company's id
	Lists   []*Admins
	Signed  []Signed
}

// CompanyID is the company's id in hex, as statements name it.
func (c *Chain) CompanyID() string { return hex.EncodeToString(c.Company[:]) }

// Current is the newest admin list.
func (c *Chain) Current() *Admins { return c.Lists[len(c.Lists)-1] }

// checkSignedBy is checks 3 to 5 with a set of allowed keys: the assertion over the statement's hash, by one of
// them, with the algorithm pinned for it.
func checkSignedBy(s Signed, keys map[string]PublicKey) error {
	pk, ok := keys[s.Key]
	if !ok {
		return fmt.Errorf("%w: key %s is not one that may sign this", ErrSignature, short(s.Key))
	}
	return CheckAssertion(s.Hash(), s.assertion(), pk)
}

// VerifyChain checks a company's whole chain against the fingerprint written down when it was made: the first
// list's hash must match it and be signed by a key of its own; each later list must have the next sequence
// number, name the company and the hash of the list before, and be signed by a key of the list before.
func VerifyChain(fingerprint string, lists []Signed) (*Chain, error) {
	if len(lists) == 0 {
		return nil, bad("an empty chain")
	}
	first, err := ParseAdmins(lists[0].Statement)
	if err != nil {
		return nil, err
	}
	if first.Sequence != 1 {
		return nil, bad("the chain doesn't start with the first admin list")
	}
	c := &Chain{Company: lists[0].Hash()}
	if !MatchesFingerprint(c.Company, fingerprint) {
		return nil, bad("the first admin list doesn't match the fingerprint (it is %s)", Fingerprint(c.Company))
	}
	if err := checkSignedBy(lists[0], first.keys()); err != nil {
		return nil, fmt.Errorf("the first admin list: %w", err)
	}
	c.Lists, c.Signed = []*Admins{first}, []Signed{lists[0]}
	for _, next := range lists[1:] {
		if err := c.Extend(next); err != nil {
			return nil, err
		}
	}
	return c, nil
}

// Extend adds the next admin list, checked against the newest one.
func (c *Chain) Extend(next Signed) error {
	a, err := ParseAdmins(next.Statement)
	if err != nil {
		return err
	}
	cur, prev := c.Current(), c.Signed[len(c.Signed)-1]
	prevHash := prev.Hash()
	switch {
	case a.Sequence != cur.Sequence+1:
		return bad("admin list %d after %d", a.Sequence, cur.Sequence)
	case a.Company != c.CompanyID():
		return bad("admin list %d is of another company", a.Sequence)
	case a.Previous != hex.EncodeToString(prevHash[:]):
		return bad("admin list %d doesn't follow the one before", a.Sequence)
	}
	if err := checkSignedBy(next, cur.keys()); err != nil {
		return fmt.Errorf("admin list %d: %w", a.Sequence, err)
	}
	c.Lists, c.Signed = append(c.Lists, a), append(c.Signed, next)
	return nil
}

// Same tells whether two chains are the same, list for list (for a chain received again).
func (c *Chain) Same(o *Chain) bool {
	if c.Company != o.Company || len(c.Signed) != len(o.Signed) {
		return false
	}
	for i := range c.Signed {
		if !bytes.Equal(c.Signed[i].Statement, o.Signed[i].Statement) {
			return false
		}
	}
	return true
}

func (c *Chain) company(what, company string) error {
	if company != c.CompanyID() {
		return bad("%s: of another company", what)
	}
	return nil
}

// VerifyState checks a state (checks 1 to 6): its form, its company, an administrator's signature, and a serial
// higher than the last one the computer has.
func (c *Chain) VerifyState(s Signed, lastSerial int64) (*State, error) {
	st, err := ParseState(s.Statement)
	if err != nil {
		return nil, err
	}
	if err := c.company("state", st.Company); err != nil {
		return nil, err
	}
	if err := checkSignedBy(s, c.Current().keys()); err != nil {
		return nil, fmt.Errorf("state %d: %w", st.Serial, err)
	}
	if st.Serial <= lastSerial {
		return nil, bad("state %d is not newer than %d", st.Serial, lastSerial)
	}
	return st, nil
}

// AdminKeys is the newest admin list's keys: who may sign a job, a stop or a session, until the people the state
// gives that right join them (stage 4).
func (c *Chain) AdminKeys() map[string]PublicKey { return c.Current().keys() }

// VerifyJob checks a job's form, company and signature (checks 1 to 5); its time and id are checked by the agent
// when it runs (stage 5).
func (c *Chain) VerifyJob(s Signed, keys map[string]PublicKey) (*Job, error) {
	j, err := ParseJob(s.Statement)
	if err != nil {
		return nil, err
	}
	if err := c.company("job", j.Company); err != nil {
		return nil, err
	}
	if err := checkSignedBy(s, keys); err != nil {
		return nil, fmt.Errorf("job %s: %w", j.ID, err)
	}
	return j, nil
}

// VerifyStop checks a stop's form, company and signature.
func (c *Chain) VerifyStop(s Signed, keys map[string]PublicKey) (*Stop, error) {
	st, err := ParseStop(s.Statement)
	if err != nil {
		return nil, err
	}
	if err := c.company("stop", st.Company); err != nil {
		return nil, err
	}
	if err := checkSignedBy(s, keys); err != nil {
		return nil, fmt.Errorf("stop of job %s: %w", st.Job, err)
	}
	return st, nil
}

// VerifySession checks a session's form, company and signature.
func (c *Chain) VerifySession(s Signed, keys map[string]PublicKey) (*Session, error) {
	se, err := ParseSession(s.Statement)
	if err != nil {
		return nil, err
	}
	if err := c.company("session", se.Company); err != nil {
		return nil, err
	}
	if err := checkSignedBy(s, keys); err != nil {
		return nil, fmt.Errorf("session %s: %w", se.ID, err)
	}
	return se, nil
}
