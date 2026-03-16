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
	MethodList          = "list"
	MethodStatus        = "status"
	MethodStop          = "stop"
)

// Notification method names (daemon → client).
const (
	NotifyEvicted           = "evicted"
	NotifyTopologyChanged   = "topology_changed"
	NotifyVisibilityChanged = "visibility_changed"
	NotifyThemeChanged      = "theme_changed"
)

// Color represents an RGB color with 16-bit per channel precision.
type Color struct {
	R uint16 `msgpack:"r"`
	G uint16 `msgpack:"g"`
	B uint16 `msgpack:"b"`
}

// HelloParams is sent by the client on connect.
type HelloParams struct {
	ClientType string `msgpack:"client_type"`
	PID        int    `msgpack:"pid"`
	Label      string `msgpack:"label"`
	SessionID  string `msgpack:"session_id,omitempty"`
}

// HelloResult is returned after a successful hello handshake.
type HelloResult struct {
	ClientID   string `msgpack:"client_id"`
	Cols       int    `msgpack:"cols"`
	Rows       int    `msgpack:"rows"`
	CellWidth  int    `msgpack:"cell_width"`
	CellHeight int    `msgpack:"cell_height"`
	InTmux     bool   `msgpack:"in_tmux"`
	FG         Color  `msgpack:"fg"`
	BG         Color  `msgpack:"bg"`
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

// EvictedParams notifies a client that an image was evicted from the cache.
type EvictedParams struct {
	Handle uint32 `msgpack:"handle"`
}

// TopologyChangedParams notifies clients of a terminal layout change.
type TopologyChangedParams struct {
	Cols       int `msgpack:"cols"`
	Rows       int `msgpack:"rows"`
	CellWidth  int `msgpack:"cell_width"`
	CellHeight int `msgpack:"cell_height"`
}

// VisibilityChangedParams notifies a client that a placement's visibility changed.
type VisibilityChangedParams struct {
	PlacementID uint32 `msgpack:"placement_id"`
	Visible     bool   `msgpack:"visible"`
}

// ThemeChangedParams notifies clients of a terminal color change.
type ThemeChangedParams struct {
	FG Color `msgpack:"fg"`
	BG Color `msgpack:"bg"`
}

// ListResult is returned by the list command.
type ListResult struct {
	Placements []PlacementInfo `msgpack:"placements"`
}

// PlacementInfo describes a single active placement.
type PlacementInfo struct {
	PlacementID uint32 `msgpack:"placement_id"`
	ClientID    string `msgpack:"client_id"`
	Handle      uint32 `msgpack:"handle"`
	Visible     bool   `msgpack:"visible"`
	Row         int    `msgpack:"row"`
	Col         int    `msgpack:"col"`
}

// StatusResult is returned by the status command.
type StatusResult struct {
	Clients    int `msgpack:"clients"`
	Placements int `msgpack:"placements"`
	Images     int `msgpack:"images"`
	Cols       int `msgpack:"cols"`
	Rows       int `msgpack:"rows"`
}

// RPCError represents an error in an RPC response.
type RPCError struct {
	Message string `msgpack:"message"`
}
