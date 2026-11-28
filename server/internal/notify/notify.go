// Package notify wakes the agents' long polls when something new for their company is kept: an admin list, a
// state, a job, a stop. It is within one server process; a poll that misses a wake-up still answers when it ends.
package notify

import "sync"

// Hub is the waiting polls, by company.
type Hub struct {
	mu      sync.Mutex
	waiting map[string]map[chan struct{}]bool
}

// Subscribe registers a wait for news of the company, before the poll looks for any: news that comes between the
// look and the wait still wakes it. cancel ends the wait.
func (h *Hub) Subscribe(company string) (news <-chan struct{}, cancel func()) {
	ch := make(chan struct{}, 1)
	h.mu.Lock()
	if h.waiting == nil {
		h.waiting = map[string]map[chan struct{}]bool{}
	}
	if h.waiting[company] == nil {
		h.waiting[company] = map[chan struct{}]bool{}
	}
	h.waiting[company][ch] = true
	h.mu.Unlock()
	return ch, func() {
		h.mu.Lock()
		delete(h.waiting[company], ch)
		if len(h.waiting[company]) == 0 {
			delete(h.waiting, company)
		}
		h.mu.Unlock()
	}
}

// Notify wakes every poll waiting for news of the company.
func (h *Hub) Notify(company string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.waiting[company] {
		select {
		case ch <- struct{}{}:
		default:
		}
	}
}
