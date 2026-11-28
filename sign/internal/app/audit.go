package app

import (
	"context"
	"crypto/sha256"
	"encoding/json/v2"

	"github.com/lechup/wmanager/sign/internal/api"
	"github.com/lechup/wmanager/sign/internal/home"
	"github.com/lechup/wmanager/sign/internal/show"
	"github.com/lechup/wmanager/verify"
)

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

// checkAudit links the company's audit log from the newest entry seen here, the entry itself first, as the server
// hands it out (docs/architecture.md, "The server inside"): a history that no longer leads to it was changed, or
// restored from an older backup. It returns how many entries are new; the head seen moves forward only along a
// history that leads from it.
func (a *App) checkAudit(ctx context.Context, s *session, c api.Company, h *home.Company, ch *verify.Chain) (int, error) {
	var seq int64
	var prev [32]byte
	from := int64(0)
	if h.Audit != nil {
		seq, prev, from = h.Audit.Seq-1, h.Audit.Prev, h.Audit.Seq-1
	}
	chain := "company:" + c.ID
	head := h.Audit
	n := 0
	broken := func(why string) (int, error) {
		at := int64(0)
		if h.Audit != nil {
			at = h.Audit.Seq
		}
		a.say("audit.broken", show.Visible(h.Name), at, why)
		return 0, nil
	}
	for {
		entries, err := s.client.AuditAfter(ctx, c.ID, from)
		if err != nil {
			return 0, a.apiErr(s, err)
		}
		for _, raw := range entries {
			var e auditEntry
			if err := json.Unmarshal(raw, &e); err != nil {
				return broken(a.t("audit.notentry", seq+1))
			}
			if e.Seq != seq+1 || e.Chain != chain {
				return broken(a.t("audit.gap", seq+1))
			}
			hash := link(prev, raw)
			if h.Audit != nil && e.Seq == h.Audit.Seq && hash != h.Audit.Hash {
				return broken(a.t("audit.changed", e.Seq))
			}
			head = &home.AuditHead{Seq: e.Seq, Hash: hash, Prev: prev}
			seq, prev = e.Seq, hash
			if h.Audit == nil || e.Seq > h.Audit.Seq {
				n++
			}
		}
		if len(entries) == 0 {
			break
		}
		from = seq
	}
	if h.Audit != nil && seq < h.Audit.Seq {
		return broken(a.t("audit.shorter", seq))
	}
	if head != nil && (h.Audit == nil || head.Seq > h.Audit.Seq) {
		h.Audit = head
		if err := a.Home.SetCompany(h, ch); err != nil {
			return 0, err
		}
	}
	return n, nil
}
