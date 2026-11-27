// Package lokihead writes the newest head of each audit chain to Loki, off the server's database, every few
// minutes (requirement 25, docs/architecture.md "The server inside"). A head seen there is something a hacked
// database can't take back: audit.Verify with that head tells whether the chain still leads to it. It counts
// against a hack of the server's host only when Loki runs elsewhere.
package lokihead

import (
	"bytes"
	"context"
	"encoding/hex"
	"encoding/json/v2"
	"fmt"
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/store"
)

// Pusher sends the heads that changed since its last push.
type Pusher struct {
	Store  *store.Store
	URL    string // Loki's base address, e.g. http://loki:3100
	Tenant string // X-Scope-OrgID
	Every  time.Duration
	Log    *slog.Logger
	Client *http.Client

	sent map[string]head // chain -> the head last pushed
}

type head struct {
	Chain string `json:"chain"`
	Seq   int64  `json:"seq"`
	Hash  string `json:"hash"`
}

// Run pushes every Every until ctx ends; a failed push is retried at the next turn.
func (p *Pusher) Run(ctx context.Context) {
	t := time.NewTicker(p.Every)
	defer t.Stop()
	for {
		if err := p.Push(ctx); err != nil && ctx.Err() == nil {
			p.Log.Warn("audit heads to Loki", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Push sends the heads that changed since the last successful push.
func (p *Pusher) Push(ctx context.Context) error {
	if p.sent == nil {
		p.sent = map[string]head{}
	}
	var heads []head
	err := p.Store.Tx(ctx, store.System, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT chain, seq, hash FROM audit_heads WHERE seq > 0 ORDER BY chain`)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var h head
			var hash []byte
			if err := rows.Scan(&h.Chain, &h.Seq, &hash); err != nil {
				return err
			}
			h.Hash = hex.EncodeToString(hash)
			// A head that changed at the same number (a chain rewritten) is sent again too.
			if p.sent[h.Chain] != h {
				heads = append(heads, h)
			}
		}
		return rows.Err()
	})
	if err != nil || len(heads) == 0 {
		return err
	}
	now := strconv.FormatInt(time.Now().UnixNano(), 10)
	var values [][2]string
	for _, h := range heads {
		line, err := json.Marshal(h)
		if err != nil {
			return err
		}
		values = append(values, [2]string{now, string(line)})
	}
	body, err := json.Marshal(map[string]any{"streams": []any{map[string]any{
		"stream": map[string]string{"service_name": "wmanager-server", "job": "audit-head"},
		"values": values,
	}}})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, p.URL+"/loki/api/v1/push", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	if p.Tenant != "" {
		req.Header.Set("X-Scope-OrgID", p.Tenant)
	}
	client := p.Client
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("Loki answered %s", resp.Status)
	}
	for _, h := range heads {
		p.sent[h.Chain] = h
	}
	return nil
}
