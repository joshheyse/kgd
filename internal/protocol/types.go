package protocol

// Method names for the kgd RPC protocol.
const (
	MethodHello         = "hello"
	MethodUpload        = "upload"
	MethodPlace         = "place"
	MethodUnplace       = "unplace"
	MethodUnplaceAll    = "unplace_all"
	MethodFree          = "free"
	MethodRegisterWin   = "register_win"
	MethodUpdateScroll  = "update_scroll"
	MethodUnregisterWin = "unregister_win"
)

// HelloParams is sent by the client on connect.
type HelloParams struct {
	ClientType string `msgpack:"client_type"`
	PID        int    `msgpack:"pid"`
	Label      string `msgpack:"label"`
}

// UploadParams transmits image data to the daemon.
type UploadParams struct {
	Data   []byte `msgpack:"data"`
	Format string `msgpack:"format"` // "png" | "rgb" | "rgba"
	Width  int    `msgpack:"width"`
	Height int    `msgpack:"height"`
}

// UploadResult is returned after a successful upload.
type UploadResult struct {
	Handle uint32 `msgpack:"handle"`
}

// Anchor describes a logical position for a placement.
type Anchor struct {
	Type    string `msgpack:"type"` // "pane" | "nvim_win" | "absolute"
	PaneID  string `msgpack:"pane_id,omitempty"`
	WinID   int    `msgpack:"win_id,omitempty"`
	BufLine int    `msgpack:"buf_line,omitempty"`
	Row     int    `msgpack:"row,omitempty"`
	Col     int    `msgpack:"col,omitempty"`
}

// PlaceParams makes an image visible at a logical position.
type PlaceParams struct {
	Handle uint32 `msgpack:"handle"`
	Anchor Anchor `msgpack:"anchor"`
	Width  int    `msgpack:"width"`
	Height int    `msgpack:"height"`
	SrcX   int    `msgpack:"src_x,omitempty"`
	SrcY   int    `msgpack:"src_y,omitempty"`
	SrcW   int    `msgpack:"src_w,omitempty"`
	SrcH   int    `msgpack:"src_h,omitempty"`
	ZIndex int32  `msgpack:"z_index"`
}

// PlaceResult is returned after a successful placement.
type PlaceResult struct {
	PlacementID uint32 `msgpack:"placement_id"`
}

// UnplaceParams removes a placement.
type UnplaceParams struct {
	PlacementID uint32 `msgpack:"placement_id"`
}

// FreeParams releases uploaded image data.
type FreeParams struct {
	Handle uint32 `msgpack:"handle"`
}

// RegisterWinParams registers a neovim window geometry.
type RegisterWinParams struct {
	WinID     int    `msgpack:"win_id"`
	PaneID    string `msgpack:"pane_id,omitempty"`
	Top       int    `msgpack:"top"`
	Left      int    `msgpack:"left"`
	Width     int    `msgpack:"width"`
	Height    int    `msgpack:"height"`
	ScrollTop int    `msgpack:"scroll_top"`
}

// UpdateScrollParams updates scroll position for a neovim window.
type UpdateScrollParams struct {
	WinID     int `msgpack:"win_id"`
	ScrollTop int `msgpack:"scroll_top"`
}

// UnregisterWinParams unregisters a neovim window.
type UnregisterWinParams struct {
	WinID int `msgpack:"win_id"`
}
