package upload

import (
	"container/list"
	"crypto/sha256"
	"sync"
)

// Cache is a content-addressed LRU upload cache. It maps image data (by SHA256)
// to kitty image IDs and tracks per-client handles.
//
// This is one of the few structures protected by a mutex rather than the
// engine's event loop, because client goroutines call Upload directly before
// going through the engine.
type Cache struct {
	mu      sync.RWMutex
	byHash  map[[32]byte]*entry
	byID    map[uint32]*entry
	lru     *list.List
	maxSize int

	nextHandle uint32
}

type entry struct {
	hash       [32]byte
	kittyImgID uint32
	refCount   int
	lruElement *list.Element
}

// NewCache creates a new upload cache with the given maximum number of entries.
func NewCache(maxSize int) *Cache {
	return &Cache{
		byHash:  make(map[[32]byte]*entry),
		byID:    make(map[uint32]*entry),
		lru:     list.New(),
		maxSize: maxSize,
	}
}

// Lookup checks if data with the given content hash exists in the cache.
// Returns the kitty image ID and whether it was found.
func (c *Cache) Lookup(data []byte) (uint32, bool) {
	hash := sha256.Sum256(data)

	c.mu.RLock()
	defer c.mu.RUnlock()

	if e, ok := c.byHash[hash]; ok {
		return e.kittyImgID, true
	}
	return 0, false
}

// Store adds a new entry to the cache. Returns evicted kitty image IDs
// that should be deleted from the terminal.
func (c *Cache) Store(data []byte, kittyImgID uint32) (evicted []uint32) {
	hash := sha256.Sum256(data)

	c.mu.Lock()
	defer c.mu.Unlock()

	// Already cached
	if e, ok := c.byHash[hash]; ok {
		e.refCount++
		c.lru.MoveToFront(e.lruElement)
		return nil
	}

	// Evict if at capacity
	for c.lru.Len() >= c.maxSize {
		back := c.lru.Back()
		if back == nil {
			break
		}
		victim := back.Value.(*entry)
		evicted = append(evicted, victim.kittyImgID)
		c.lru.Remove(back)
		delete(c.byHash, victim.hash)
		delete(c.byID, victim.kittyImgID)
	}

	e := &entry{
		hash:       hash,
		kittyImgID: kittyImgID,
		refCount:   1,
	}
	e.lruElement = c.lru.PushFront(e)
	c.byHash[hash] = e
	c.byID[kittyImgID] = e

	return evicted
}

// Release decrements the reference count for a kitty image ID.
func (c *Cache) Release(kittyImgID uint32) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if e, ok := c.byID[kittyImgID]; ok {
		e.refCount--
	}
}
