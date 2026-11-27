package lokihead

import (
	"context"
	"encoding/json/v2"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/jackc/pgx/v5"

	"github.com/lechup/wmanager/server/internal/audit"
	"github.com/lechup/wmanager/server/internal/store"
	"github.com/lechup/wmanager/server/internal/store/storetest"
)

func TestPushesChangedHeads(t *testing.T) {
	s := storetest.New(t)
	ctx := context.Background()
	var mu sync.Mutex
	var pushes []string
	status := http.StatusNoContent
	loki := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		defer mu.Unlock()
		if r.URL.Path != "/loki/api/v1/push" || r.Header.Get("X-Scope-OrgID") != "wmanager-server" {
			t.Errorf("push to %s, tenant %q", r.URL.Path, r.Header.Get("X-Scope-OrgID"))
		}
		pushes = append(pushes, string(b))
		w.WriteHeader(status)
	}))
	defer loki.Close()
	add := func(action string) audit.Head {
		var h audit.Head
		if err := s.Tx(ctx, store.System, func(tx pgx.Tx) error {
			var err error
			h, err = audit.Append(ctx, tx, audit.ServerChain, "", "system", action, nil)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		return h
	}
	p := &Pusher{Store: s, URL: loki.URL, Tenant: "wmanager-server", Log: slog.New(slog.DiscardHandler)}
	if err := p.Push(ctx); err != nil || len(pushes) != 0 {
		t.Fatalf("nothing to push: %v, %d pushes", err, len(pushes))
	}
	h := add("one")
	if err := p.Push(ctx); err != nil {
		t.Fatal(err)
	}
	var body struct {
		Streams []struct {
			Stream map[string]string `json:"stream"`
			Values [][2]string       `json:"values"`
		} `json:"streams"`
	}
	if err := json.Unmarshal([]byte(pushes[0]), &body); err != nil {
		t.Fatal(err)
	}
	line := body.Streams[0].Values[0][1]
	if body.Streams[0].Stream["job"] != "audit-head" || !strings.Contains(line, `"chain":"server"`) ||
		!strings.Contains(line, `"seq":1`) || !strings.Contains(line, h.String()[len("server #1 "):]) {
		t.Fatalf("push %s", pushes[0])
	}
	if err := p.Push(ctx); err != nil || len(pushes) != 1 {
		t.Fatalf("an unchanged head pushed again: %d pushes", len(pushes))
	}
	// A failed push is sent again next time.
	add("two")
	status = http.StatusInternalServerError
	if err := p.Push(ctx); err == nil {
		t.Fatal("a refused push reported as sent")
	}
	status = http.StatusNoContent
	if err := p.Push(ctx); err != nil || !strings.Contains(pushes[len(pushes)-1], `\"seq\":2`) {
		t.Fatalf("the retry: %v %s", err, pushes[len(pushes)-1])
	}
}
