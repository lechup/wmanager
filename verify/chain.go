package verify

import (
	"bytes"
	"encoding/hex"
	"errors"
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

// Signer is a key that may sign, with the name the admin list (or the state) gives its owner.
type Signer struct {
	Key  PublicKey
	Name string
}

// checkSignedBy is checks 3 to 5 with a set of allowed keys: the assertion over the statement's hash, by one of
// them, with the algorithm pinned for it. It runs before the statement is parsed: nothing unsigned is read.
func checkSignedBy(s Signed, keys map[string]Signer, typ string) (Signer, error) {
	if len(s.Statement) > MaxSize[typ] {
		return Signer{}, bad("%s of %d bytes, more than %d", typ, len(s.Statement), MaxSize[typ])
	}
	if !hex64.MatchString(s.Key) {
		return Signer{}, fmt.Errorf("%w: a key id that isn't one", ErrSignature)
	}
	k, ok := keys[s.Key]
	if !ok {
		return Signer{}, fmt.Errorf("%w: key %s is not one that may sign this", ErrSignature, short(s.Key))
	}
	return k, CheckAssertion(s.Hash(), s.assertion(), k.Key)
}

// VerifyChain checks a company's whole chain against the fingerprint written down when it was made: the first
// list's hash must match it and be signed by a key of its own; each later list must have the next sequence
// number, name the company and the hash of the list before, and be signed by a key of the list before.
//
// It is for a chain seen the first time (at enrollment, or by wmanager-sign for a new company). Once a chain is
// held, a chain received later goes through Update, which refuses one that doesn't start with the held one: an
// older prefix or a fork could bring back a removed key.
func VerifyChain(fingerprint string, lists []Signed) (*Chain, error) {
	if len(lists) == 0 {
		return nil, bad("an empty chain")
	}
	c := &Chain{Company: lists[0].Hash()}
	if !MatchesFingerprint(c.Company, fingerprint) { // before anything is read
		return nil, bad("the first admin list doesn't match the fingerprint (it is %s)", Fingerprint(c.Company))
	}
	first, err := ParseAdmins(lists[0].Statement)
	if err != nil {
		return nil, err
	}
	if first.Sequence != 1 {
		return nil, bad("the chain doesn't start with the first admin list")
	}
	if _, err := checkSignedBy(lists[0], first.keys(), TypeAdmins); err != nil {
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

// Extend adds the next admin list, checked against the newest one: signed by one of its keys (checked before the
// list is read), with the next sequence number, the company and the hash of the newest one.
func (c *Chain) Extend(next Signed) error {
	cur, prev := c.Current(), c.Signed[len(c.Signed)-1]
	if _, err := checkSignedBy(next, cur.keys(), TypeAdmins); err != nil {
		return fmt.Errorf("admin list %d: %w", cur.Sequence+1, err)
	}
	a, err := ParseAdmins(next.Statement)
	if err != nil {
		return err
	}
	prevHash := prev.Hash()
	switch {
	case a.Sequence != cur.Sequence+1:
		return bad("admin list %d after %d", a.Sequence, cur.Sequence)
	case a.Company != c.CompanyID():
		return bad("admin list %d is of another company", a.Sequence)
	case a.Previous != hex.EncodeToString(prevHash[:]):
		return bad("admin list %d doesn't follow the one before", a.Sequence)
	}
	c.Lists, c.Signed = append(c.Lists, a), append(c.Signed, next)
	return nil
}

// Errors of Update. ErrOlderChain means the server is behind (a backup restored, a list not passed on yet): keep the
// chain held, no alarm. ErrForkedChain means a chain that leaves the held one, signed by keys of an earlier list:
// a key that was removed and a server that hands out its lists. That is an alarm.
var (
	ErrOlderChain  = errors.New("verify: an older chain than the one held")
	ErrForkedChain = errors.New("verify: a chain that leaves the one held")
)

// Update takes a chain received later (check 6 for admin lists): it must start with every list held, byte for
// byte, and the lists after them are added with Extend, all or none. A shorter chain is refused as older, one that
// leaves the held one at any point as forked: either could bring back a key removed since.
func (c *Chain) Update(lists []Signed) error {
	for i := 0; i < len(lists) && i < len(c.Signed); i++ {
		if !bytes.Equal(c.Signed[i].Statement, lists[i].Statement) {
			return fmt.Errorf("%w: admin list %d differs", ErrForkedChain, i+1)
		}
	}
	if len(lists) < len(c.Signed) {
		return fmt.Errorf("%w: %d admin lists, %d held", ErrOlderChain, len(lists), len(c.Signed))
	}
	next := &Chain{Company: c.Company, Lists: append([]*Admins{}, c.Lists...), Signed: append([]Signed{}, c.Signed...)}
	for _, s := range lists[len(c.Signed):] {
		if err := next.Extend(s); err != nil {
			return err
		}
	}
	c.Lists, c.Signed = next.Lists, next.Signed
	return nil
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
	if _, err := checkSignedBy(s, c.Current().keys(), TypeState); err != nil {
		return nil, fmt.Errorf("state: %w", err)
	}
	st, err := ParseState(s.Statement)
	if err != nil {
		return nil, err
	}
	if err := c.company("state", st.Company); err != nil {
		return nil, err
	}
	if st.Serial <= lastSerial {
		return nil, bad("state %d is not newer than %d", st.Serial, lastSerial)
	}
	return st, nil
}

// AdminKeys is the newest admin list's keys: who may sign a job, a stop or a session, until the people the state
// gives that right join them (stage 4).
func (c *Chain) AdminKeys() map[string]Signer { return c.Current().keys() }

// VerifyJob checks a job's form, company and signature (checks 1 to 5); its time and id are checked by the agent
// when it runs (stage 5).
func (c *Chain) VerifyJob(s Signed, keys map[string]Signer) (*Job, error) {
	if _, err := checkSignedBy(s, keys, TypeJob); err != nil {
		return nil, fmt.Errorf("job: %w", err)
	}
	j, err := ParseJob(s.Statement)
	if err != nil {
		return nil, err
	}
	if err := c.company("job", j.Company); err != nil {
		return nil, err
	}
	return j, nil
}

// VerifyStop checks a stop's form, company and signature.
func (c *Chain) VerifyStop(s Signed, keys map[string]Signer) (*Stop, error) {
	if _, err := checkSignedBy(s, keys, TypeStop); err != nil {
		return nil, fmt.Errorf("stop: %w", err)
	}
	st, err := ParseStop(s.Statement)
	if err != nil {
		return nil, err
	}
	if err := c.company("stop", st.Company); err != nil {
		return nil, err
	}
	return st, nil
}

// VerifySession checks a session's form, company and signature, and that the person it names is the signer, as
// the black screen of privacy mode shows it.
func (c *Chain) VerifySession(s Signed, keys map[string]Signer) (*Session, error) {
	signer, err := checkSignedBy(s, keys, TypeSession)
	if err != nil {
		return nil, fmt.Errorf("session: %w", err)
	}
	se, err := ParseSession(s.Statement)
	if err != nil {
		return nil, err
	}
	if err := c.company("session", se.Company); err != nil {
		return nil, err
	}
	if se.Person != signer.Name {
		return nil, bad("session: it names %q, but %q signed it", se.Person, signer.Name)
	}
	return se, nil
}
