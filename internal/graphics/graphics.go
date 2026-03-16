package graphics

// Graphics is the interface between the engine and the terminal for
// kitty graphics protocol operations.
type Graphics interface {
	// Transmit uploads image data to the terminal.
	Transmit(id uint32, data []byte, format string, width, height int) error

	// Place renders an image placement at the given terminal coordinates.
	Place(imageID, placementID uint32, row, col int, p PlacementInfo) error

	// Delete removes a placement or frees an image from the terminal.
	// If free is true, also frees the stored image data (kitty d=I vs d=i).
	Delete(imageID, placementID uint32, free bool) error

	// BeginBatch starts accumulating Place/Delete operations.
	// Call FlushBatch to send them as a single atomic write.
	BeginBatch()

	// FlushBatch sends all accumulated operations as one write.
	FlushBatch()
}

// PlacementInfo provides placement details needed for rendering.
type PlacementInfo interface {
	GetWidth() int
	GetHeight() int
	GetSrcX() int
	GetSrcY() int
	GetSrcW() int
	GetSrcH() int
	GetZIndex() int32
}
