package notify

import (
	"testing"
	"time"
)

func TestHub(t *testing.T) {
	var h Hub
	a, cancelA := h.Subscribe("acme")
	b, cancelB := h.Subscribe("other")
	defer cancelB()
	h.Notify("acme")
	select {
	case <-a:
	case <-time.After(time.Second):
		t.Fatal("not woken")
	}
	select {
	case <-b:
		t.Fatal("another company's poll woken")
	default:
	}
	cancelA()
	h.Notify("acme") // nobody waits: nothing blocks
	if len(h.waiting["acme"]) != 0 {
		t.Fatal("a cancelled wait is kept")
	}
}
