package upload

import (
	"container/list"

	"github.com/zeebo/xxh3"
)

// Cache is a content-addressed LRU upload cache. It maps image data (by hash)
// to kitty image IDs and tracks reference counts for deduplication.
//
// The cache is owned exclusively by the PlacementEngine goroutine — no mutex
// needed. All access is single-threaded through the engine's event loop.
//
// Uses xxh3-128 for content addressing (fast, non-cryptographic).
type Cache struct {
	byHash  map[[2]uint64]*entry
	byID    map[uint32]*entry
	lru     *list.List
	maxSize int
}

type entry struct {
	hash       [2]uint64
	kittyImgID uint32
	refCount   int
	lruElement *list.Element
}

// NewCache creates a new upload cache with the given maximum number of entries.
func NewCache(maxSize int) *Cache {
	return &Cache{
		byHash:  make(map[[2]uint64]*entry),
		byID:    make(map[uint32]*entry),
		lru:     list.New(),
		maxSize: maxSize,
	}
}

// hash128 computes a 128-bit xxh3 hash of the data.
func hash128(data []byte) [2]uint64 {
	h := xxh3.Hash128(data)
	return [2]uint64{h.Lo, h.Hi}
}

// Lookup checks if data with the given content hash exists in the cache.
// Returns the kitty image ID and whether it was found.
func (c *Cache) Lookup(data []byte) (uint32, bool) {
	hash := hash128(data)
	if e, ok := c.byHash[hash]; ok {
		return e.kittyImgID, true
	}
	return 0, false
}

// Store adds a new entry to the cache. Returns evicted kitty image IDs
// that should be deleted from the terminal.
func (c *Cache) Store(data []byte, kittyImgID uint32) (evicted []uint32) {
	hash := hash128(data)

	// Already cached — bump refcount and LRU position
	if e, ok := c.byHash[hash]; ok {
		e.refCount++
		c.lru.MoveToFront(e.lruElement)
		return nil
	}

	// Evict LRU entries at capacity (only evict unreferenced entries)
	for c.lru.Len() >= c.maxSize {
		back := c.lru.Back()
		if back == nil {
			break
		}
		victim := back.Value.(*entry)
		if victim.refCount > 0 {
			// Don't evict entries with active references — cache is over capacity
			// but all entries are in use. Allow the cache to grow temporarily.
			break
		}
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
	if e, ok := c.byID[kittyImgID]; ok {
		e.refCount--
	}
}
