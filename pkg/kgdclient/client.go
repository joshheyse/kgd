// Package kgdclient provides a Go client for the kgd daemon.
package kgdclient

import (
	"context"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"sync"
	"sync/atomic"

	"github.com/joshheyse/kgd/internal/protocol"
	"github.com/joshheyse/kgd/pkg/kgdsocket"
	"github.com/vmihailenco/msgpack/v5"
)

// Aliases for protocol-level message type constants.
const (
	msgRequest      = protocol.MsgRequest
	msgResponse     = protocol.MsgResponse
	msgNotification = protocol.MsgNotification
)

// Options configures the client connection.
type Options struct {
	// SocketPath overrides the socket path. If empty, uses $KGD_SOCKET or computes default.
	SocketPath string

	// SessionID enables stateless mode. The daemon preserves state across reconnects
	// for clients with the same session ID.
	SessionID string

	// ClientType identifies the type of client (e.g., "mupager", "molten").
	ClientType string

	// Label is a human-readable label for this client.
	Label string

	// AutoLaunch starts the daemon if not running. Default true.
	AutoLaunch bool
}

// Client is a connection to the kgd daemon.
type Client struct {
	conn    net.Conn
	enc     *msgpack.Encoder
	dec     *msgpack.Decoder
	mu      sync.Mutex // protects enc (writes)
	nextID  atomic.Uint32
	pending sync.Map // msgid → chan *response

	// Hello result
	ClientID   string
	Cols       int
	Rows       int
	CellWidth  int
	CellHeight int
	InTmux     bool
	FG         protocol.Color
	BG         protocol.Color

	// Notification callbacks
	OnEvicted           func(handle uint32)
	OnTopologyChanged   func(cols, rows, cellW, cellH int)
	OnVisibilityChanged func(placementID uint32, visible bool)
	OnThemeChanged      func(fg, bg protocol.Color)

	done chan struct{}
}

type response struct {
	err    any
	result any
}

// Connect establishes a connection to the kgd daemon.
func Connect(ctx context.Context, opts Options) (*Client, error) {
	if opts.SocketPath == "" {
		opts.SocketPath = os.Getenv("KGD_SOCKET")
	}
	if opts.SocketPath == "" {
		opts.SocketPath = kgdsocket.DefaultPath()
	}

	if opts.AutoLaunch {
		if err := kgdsocket.EnsureDaemon(opts.SocketPath); err != nil {
			return nil, fmt.Errorf("ensuring daemon: %w", err)
		}
	}

	conn, err := net.Dial("unix", opts.SocketPath)
	if err != nil {
		return nil, fmt.Errorf("connecting to %s: %w", opts.SocketPath, err)
	}

	c := &Client{
		conn: conn,
		enc:  msgpack.NewEncoder(conn),
		dec:  msgpack.NewDecoder(conn),
		done: make(chan struct{}),
	}

	// Start reader goroutine
	go c.readLoop()

	// Send hello
	result, err := c.call(ctx, protocol.MethodHello, protocol.HelloParams{
		ClientType: opts.ClientType,
		PID:        os.Getpid(),
		Label:      opts.Label,
		SessionID:  opts.SessionID,
	})
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("hello: %w", err)
	}

	if m, ok := result.(map[string]any); ok {
		c.ClientID = stringVal(m, "client_id")
		c.Cols = intVal(m, "cols")
		c.Rows = intVal(m, "rows")
		c.CellWidth = intVal(m, "cell_width")
		c.CellHeight = intVal(m, "cell_height")
		c.InTmux, _ = m["in_tmux"].(bool)
		if fg, ok := m["fg"].(map[string]any); ok {
			c.FG = colorFromMap(fg)
		}
		if bg, ok := m["bg"].(map[string]any); ok {
			c.BG = colorFromMap(bg)
		}
	}

	return c, nil
}

// Upload transmits image data to the daemon and returns a handle.
func (c *Client) Upload(ctx context.Context, data []byte, format string, width, height int) (uint32, error) {
	result, err := c.call(ctx, protocol.MethodUpload, protocol.UploadParams{
		Data:   data,
		Format: format,
		Width:  width,
		Height: height,
	})
	if err != nil {
		return 0, err
	}
	if m, ok := result.(map[string]any); ok {
		return uint32Val(m, "handle"), nil
	}
	return 0, fmt.Errorf("unexpected upload result: %T", result)
}

// PlaceOpts holds optional parameters for Place.
type PlaceOpts struct {
	SrcX   int   // source region X offset (pixels)
	SrcY   int   // source region Y offset (pixels)
	SrcW   int   // source region width (pixels, 0 = full)
	SrcH   int   // source region height (pixels, 0 = full)
	ZIndex int32 // stacking order (negative = behind text)
}

// Place makes an image visible at the given position. Returns a placement ID.
// opts may be nil for defaults.
func (c *Client) Place(ctx context.Context, handle uint32, anchor protocol.Anchor, width, height int, opts *PlaceOpts) (uint32, error) {
	params := protocol.PlaceParams{
		Handle: handle,
		Anchor: anchor,
		Width:  width,
		Height: height,
	}
	if opts != nil {
		params.SrcX = opts.SrcX
		params.SrcY = opts.SrcY
		params.SrcW = opts.SrcW
		params.SrcH = opts.SrcH
		params.ZIndex = opts.ZIndex
	}
	result, err := c.call(ctx, protocol.MethodPlace, params)
	if err != nil {
		return 0, err
	}
	if m, ok := result.(map[string]any); ok {
		return uint32Val(m, "placement_id"), nil
	}
	return 0, fmt.Errorf("unexpected place result: %T", result)
}

// Unplace removes a placement.
func (c *Client) Unplace(placementID uint32) error {
	_, err := c.call(context.Background(), protocol.MethodUnplace, protocol.UnplaceParams{
		PlacementID: placementID,
	})
	return err
}

// UnplaceAll removes all placements for this client.
func (c *Client) UnplaceAll() error {
	return c.notify(protocol.MethodUnplaceAll, nil)
}

// Free releases an uploaded image handle.
func (c *Client) Free(handle uint32) error {
	_, err := c.call(context.Background(), protocol.MethodFree, protocol.FreeParams{Handle: handle})
	return err
}

// RegisterWin registers a neovim window's geometry with the daemon.
func (c *Client) RegisterWin(winID int, paneID string, top, left, width, height, scrollTop int) error {
	return c.notify(protocol.MethodRegisterWin, protocol.RegisterWinParams{
		WinID:     winID,
		PaneID:    paneID,
		Top:       top,
		Left:      left,
		Width:     width,
		Height:    height,
		ScrollTop: scrollTop,
	})
}

// UpdateScroll updates the scroll position for a registered neovim window.
func (c *Client) UpdateScroll(winID int, scrollTop int) error {
	return c.notify(protocol.MethodUpdateScroll, protocol.UpdateScrollParams{
		WinID:     winID,
		ScrollTop: scrollTop,
	})
}

// UnregisterWin unregisters a neovim window.
func (c *Client) UnregisterWin(winID int) error {
	return c.notify(protocol.MethodUnregisterWin, protocol.UnregisterWinParams{
		WinID: winID,
	})
}

// List returns all active placements.
func (c *Client) List(ctx context.Context) (protocol.ListResult, error) {
	result, err := c.call(ctx, protocol.MethodList, nil)
	if err != nil {
		return protocol.ListResult{}, err
	}
	// Decode from generic map
	if m, ok := result.(map[string]any); ok {
		var lr protocol.ListResult
		if placements, ok := m["placements"].([]any); ok {
			for _, p := range placements {
				if pm, ok := p.(map[string]any); ok {
					lr.Placements = append(lr.Placements, protocol.PlacementInfo{
						PlacementID: uint32Val(pm, "placement_id"),
						ClientID:    stringVal(pm, "client_id"),
						Handle:      uint32Val(pm, "handle"),
						Visible:     boolVal(pm, "visible"),
						Row:         intVal(pm, "row"),
						Col:         intVal(pm, "col"),
					})
				}
			}
		}
		return lr, nil
	}
	return protocol.ListResult{}, nil
}

// Status returns daemon status information.
func (c *Client) Status(ctx context.Context) (protocol.StatusResult, error) {
	result, err := c.call(ctx, protocol.MethodStatus, nil)
	if err != nil {
		return protocol.StatusResult{}, err
	}
	if m, ok := result.(map[string]any); ok {
		return protocol.StatusResult{
			Clients:    intVal(m, "clients"),
			Placements: intVal(m, "placements"),
			Images:     intVal(m, "images"),
			Cols:       intVal(m, "cols"),
			Rows:       intVal(m, "rows"),
		}, nil
	}
	return protocol.StatusResult{}, nil
}

// Stop requests the daemon to shut down gracefully.
func (c *Client) Stop() error {
	return c.notify(protocol.MethodStop, nil)
}

// Close closes the connection to the daemon.
func (c *Client) Close() error {
	return c.conn.Close()
}

// call sends a request and waits for the response.
func (c *Client) call(ctx context.Context, method string, params any) (any, error) {
	msgID := c.nextID.Add(1)
	ch := make(chan *response, 1)
	c.pending.Store(msgID, ch)
	defer c.pending.Delete(msgID)

	c.mu.Lock()
	err := c.writeRequest(msgID, method, params)
	c.mu.Unlock()
	if err != nil {
		return nil, fmt.Errorf("writing request: %w", err)
	}

	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-c.done:
		return nil, fmt.Errorf("connection closed")
	case resp := <-ch:
		if resp.err != nil {
			if m, ok := resp.err.(map[string]any); ok {
				if msg, ok := m["message"].(string); ok {
					return nil, fmt.Errorf("%s", msg)
				}
			}
			return nil, fmt.Errorf("rpc error: %v", resp.err)
		}
		return resp.result, nil
	}
}

func (c *Client) writeRequest(msgID uint32, method string, params any) error {
	if err := c.enc.EncodeArrayLen(4); err != nil {
		return err
	}
	if err := c.enc.EncodeInt(msgRequest); err != nil {
		return err
	}
	if err := c.enc.EncodeUint32(msgID); err != nil {
		return err
	}
	if err := c.enc.EncodeString(method); err != nil {
		return err
	}
	if params != nil {
		if err := c.enc.EncodeArrayLen(1); err != nil {
			return err
		}
		return c.enc.Encode(params)
	}
	return c.enc.EncodeArrayLen(0)
}

// notify sends a one-way notification (no response expected).
func (c *Client) notify(method string, params any) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := c.enc.EncodeArrayLen(3); err != nil {
		return err
	}
	if err := c.enc.EncodeInt(msgNotification); err != nil {
		return err
	}
	if err := c.enc.EncodeString(method); err != nil {
		return err
	}
	if params != nil {
		if err := c.enc.EncodeArrayLen(1); err != nil {
			return err
		}
		return c.enc.Encode(params)
	}
	return c.enc.EncodeArrayLen(0)
}

// readLoop reads responses and notifications from the daemon.
func (c *Client) readLoop() {
	defer close(c.done)

	for {
		arrLen, err := c.dec.DecodeArrayLen()
		if err != nil {
			if err != io.EOF {
				slog.Debug("kgdclient read error", "error", err)
			}
			return
		}
		if arrLen < 3 {
			return
		}

		msgType, err := c.dec.DecodeInt()
		if err != nil {
			return
		}

		switch msgType {
		case msgResponse:
			c.handleResponse()
		case msgNotification:
			c.handleNotification()
		default:
			return
		}
	}
}

func (c *Client) handleResponse() {
	msgID, err := c.dec.DecodeUint32()
	if err != nil {
		return
	}
	var rpcErr any
	if err := c.dec.Decode(&rpcErr); err != nil {
		return
	}
	var result any
	if err := c.dec.Decode(&result); err != nil {
		return
	}

	if ch, ok := c.pending.Load(msgID); ok {
		ch.(chan *response) <- &response{err: rpcErr, result: result}
	}
}

func (c *Client) handleNotification() {
	method, err := c.dec.DecodeString()
	if err != nil {
		return
	}
	paramsLen, err := c.dec.DecodeArrayLen()
	if err != nil {
		return
	}

	if paramsLen == 0 {
		return
	}

	var params any
	if err := c.dec.Decode(&params); err != nil {
		return
	}
	// Skip extra params
	for i := 1; i < paramsLen; i++ {
		var ignored any
		c.dec.Decode(&ignored)
	}

	m, ok := params.(map[string]any)
	if !ok {
		return
	}

	switch method {
	case protocol.NotifyEvicted:
		if c.OnEvicted != nil {
			c.OnEvicted(uint32Val(m, "handle"))
		}
	case protocol.NotifyTopologyChanged:
		if c.OnTopologyChanged != nil {
			c.OnTopologyChanged(intVal(m, "cols"), intVal(m, "rows"), intVal(m, "cell_width"), intVal(m, "cell_height"))
		}
	case protocol.NotifyVisibilityChanged:
		if c.OnVisibilityChanged != nil {
			c.OnVisibilityChanged(uint32Val(m, "placement_id"), boolVal(m, "visible"))
		}
	case protocol.NotifyThemeChanged:
		if c.OnThemeChanged != nil {
			var fg, bg protocol.Color
			if fgm, ok := m["fg"].(map[string]any); ok {
				fg = colorFromMap(fgm)
			}
			if bgm, ok := m["bg"].(map[string]any); ok {
				bg = colorFromMap(bgm)
			}
			c.OnThemeChanged(fg, bg)
		}
	}
}

// Helpers for decoding generic map values from msgpack.

func stringVal(m map[string]any, key string) string {
	if v, ok := m[key]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

func intVal(m map[string]any, key string) int {
	if v, ok := m[key]; ok {
		switch n := v.(type) {
		case int64:
			return int(n)
		case uint64:
			return int(n)
		case int8:
			return int(n)
		case uint8:
			return int(n)
		case int32:
			return int(n)
		case uint32:
			return int(n)
		}
	}
	return 0
}

func uint32Val(m map[string]any, key string) uint32 {
	if v, ok := m[key]; ok {
		switch n := v.(type) {
		case uint64:
			return uint32(n)
		case uint32:
			return n
		case int64:
			return uint32(n)
		case int8:
			return uint32(n)
		case uint8:
			return uint32(n)
		}
	}
	return 0
}

func boolVal(m map[string]any, key string) bool {
	if v, ok := m[key]; ok {
		if b, ok := v.(bool); ok {
			return b
		}
	}
	return false
}

func colorFromMap(m map[string]any) protocol.Color {
	return protocol.Color{
		R: uint16(intVal(m, "r")),
		G: uint16(intVal(m, "g")),
		B: uint16(intVal(m, "b")),
	}
}
