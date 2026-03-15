package upload

import (
	"container/list"
	"hash/maphash"
)

// Cache is a content-addressed LRU upload cache. It maps image data (by hash)
// to kitty image IDs and tracks reference counts for deduplication.
//
// The cache is owned exclusively by the PlacementEngine goroutine — no mutex
// needed. All access is single-threaded through the engine's event loop.
//
// Uses maphash for content addressing (fast, non-cryptographic). Will be
// replaced with xxh3-128 (github.com/zeebo/xxh3) when the dependency is added.
type Cache struct {
	byHash  map[[2]uint64]*entry
	byID    map[uint32]*entry
	lru     *list.List
	maxSize int
	seed    maphash.Seed
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
		seed:    maphash.MakeSeed(),
	}
}

// hash128 computes a 128-bit hash of data using two seeded maphash passes.
// This is a placeholder until xxh3-128 is added as a dependency.
func (c *Cache) hash128(data []byte) [2]uint64 {
	var h maphash.Hash
	h.SetSeed(c.seed)
	h.Write(data)
	lo := h.Sum64()
	h.Reset()
	h.WriteByte(0xff) // differentiate second pass
	h.Write(data)
	hi := h.Sum64()
	return [2]uint64{lo, hi}
}

// Lookup checks if data with the given content hash exists in the cache.
// Returns the kitty image ID and whether it was found.
func (c *Cache) Lookup(data []byte) (uint32, bool) {
	hash := c.hash128(data)
	if e, ok := c.byHash[hash]; ok {
		return e.kittyImgID, true
	}
	return 0, false
}

// Store adds a new entry to the cache. Returns evicted kitty image IDs
// that should be deleted from the terminal.
func (c *Cache) Store(data []byte, kittyImgID uint32) (evicted []uint32) {
	hash := c.hash128(data)

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
