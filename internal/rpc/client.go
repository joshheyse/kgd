package rpc

import (
	"context"
	"net"

	"github.com/google/uuid"
	"github.com/joshheyse/kgd/internal/engine"
)

// Client represents a connected RPC client.
type Client struct {
	ID     string
	conn   net.Conn
	engine *engine.Engine
}

// NewClient creates a new client for the given connection.
func NewClient(conn net.Conn, eng *engine.Engine) *Client {
	return &Client{
		ID:     uuid.NewString(),
		conn:   conn,
		engine: eng,
	}
}

// Serve reads and dispatches messages from the client until the connection
// is closed or ctx is cancelled.
func (c *Client) Serve(ctx context.Context) error {
	// TODO: msgpack framing loop — read messages, dispatch to engine
	<-ctx.Done()
	return ctx.Err()
}

// Close cleans up the client connection and notifies the engine.
func (c *Client) Close() {
	c.engine.ClientDisconnected(c.ID)
	c.conn.Close()
}
