package allocator

import "sync/atomic"

// IDAllocator generates unique kitty image IDs. kgd is the sole allocator —
// no client ever sees or picks a kitty image ID directly.
type IDAllocator struct {
	next atomic.Uint32
}

// New creates a new IDAllocator starting from 1.
func New() *IDAllocator {
	a := &IDAllocator{}
	a.next.Store(1)
	return a
}

// Next returns the next available kitty image ID.
// Monotonically incrementing, wraps at math.MaxUint32.
func (a *IDAllocator) Next() uint32 {
	return a.next.Add(1) - 1
}
