package app

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json/v2"
	"errors"
	"fmt"

	"github.com/lechup/wmanager/sign/internal/api"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/sign/internal/show"
	"github.com/lechup/wmanager/verify"
)

// ErrAuditBroken is a company's audit log whose history no longer leads to the entry seen here.
var ErrAuditBroken = errors.New("the audit log's history doesn't lead to the entry seen")

// auditEntry is what wmanager-sign reads of an audit entry: its place.
type auditEntry struct {
	Seq   int64  `json:"seq"`
	Chain string `json:"chain"`
}

func link(prev [32]byte, raw []byte) [32]byte {
	d := sha256.New()
	d.Write(prev[:])
	d.Write(raw)
	var h [32]byte
	d.Sum(h[:0])
	return h
}

func headString(h home.AuditHead) string {
	return fmt.Sprintf("%d:%s", h.Seq, hex.EncodeToString(h.Hash[:]))
}

// auditHistory links the company's whole audit log as the server hands it out, from its first entry, each to the
// one before (the SHA-256 of the hash before and the entry's bytes). It returns the newest entry and the hash at
// entry at, or why the history doesn't link.
func (a *App) auditHistory(ctx context.Context, s *session, c api.Company, at int64) (head home.AuditHead, hashAt [32]byte, broken string, err error) {
	chain := "company:" + c.ID
	var prev [32]byte
	var seq int64
	for {
		entries, err := s.client.AuditAfter(ctx, c.ID, seq)
		if err != nil {
			return head, hashAt, "", a.apiErr(s, err)
		}
		if len(entries) == 0 {
			break
		}
		for _, raw := range entries {
			var e auditEntry
			if json.Unmarshal(raw, &e) != nil {
				return head, hashAt, a.t("audit.notentry", seq+1), nil
			}
			if e.Seq != seq+1 || e.Chain != chain {
				return head, hashAt, a.t("audit.gap", seq+1), nil
			}
			prev, seq = link(prev, raw), e.Seq
			if seq == at {
				hashAt = prev
			}
		}
	}
	return home.AuditHead{Seq: seq, Hash: prev}, hashAt, "", nil
}

// checkAudit links the company's whole audit log, as the server hands it out, and checks that it leads to the
// newest entry seen here from this server (docs/architecture.md, "The server inside"): a history that doesn't was
// changed, or restored from an older backup. The entry seen moves forward only along a history that leads from it.
// It returns the newest entry and how many are new; a history that doesn't lead to the entry seen is said, and is
// ErrAuditBroken.
func (a *App) checkAudit(ctx context.Context, s *session, c api.Company, h *home.Company, ch *verify.Chain) (home.AuditHead, int64, error) {
	seen, kept := h.Audits[s.client.Server]
	head, hashAt, broken, err := a.auditHistory(ctx, s, c, seen.Seq)
	if err != nil {
		return head, 0, err
	}
	switch {
	case broken != "" && !kept:
		a.say("audit.brokenfirst", show.Visible(h.Name), broken)
		return head, 0, ErrAuditBroken
	case broken != "":
	case kept && head.Seq < seen.Seq:
		broken = a.t("audit.shorter", head.Seq)
	case kept && hashAt != seen.Hash:
		broken = a.t("audit.changed", seen.Seq)
	}
	if broken != "" {
		a.say("audit.broken", show.Visible(h.Name), headString(seen), broken, show.Visible(h.Name))
		return seen, 0, ErrAuditBroken
	}
	if head.Seq > seen.Seq {
		if h.Audits == nil {
			h.Audits = map[string]home.AuditHead{}
		}
		h.Audits[s.client.Server] = head
		if err := a.Home.SetCompany(h, ch); err != nil {
			return head, 0, err
		}
	}
	return head, head.Seq - seen.Seq, nil
}

// acceptAudit takes the server's audit log as it is now, after showing the entry seen and the server's newest:
// for a server moved or restored, whose history no longer leads to the entry seen.
func (a *App) acceptAudit(ctx context.Context, which string) error {
	s, err := a.connected()
	if err != nil {
		return err
	}
	c, h, ch, err := a.held(ctx, s, which)
	if err != nil {
		return err
	}
	seen, kept := h.Audits[s.client.Server]
	head, _, broken, err := a.auditHistory(ctx, s, c, 0)
	if err != nil {
		return err
	}
	if broken != "" {
		return a.fail("audit.cantaccept", show.Visible(h.Name), broken)
	}
	if kept {
		a.say("audit.seen", headString(seen))
	}
	a.say("audit.now", headString(head))
	if ok, err := a.confirm("audit.confirm"); err != nil || !ok {
		if err == nil {
			a.say("sign.cancelled")
		}
		return err
	}
	h.AcceptAudit(s.client.Server, head)
	if err := a.Home.SetCompany(h, ch); err != nil {
		return err
	}
	a.say("audit.accepted", show.Visible(h.Name), headString(head))
	return nil
}
