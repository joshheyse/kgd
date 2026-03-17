package rpc

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"sync"

	"github.com/google/uuid"
	"github.com/joshheyse/kgd/internal/engine"
	"github.com/joshheyse/kgd/internal/protocol"
	"github.com/vmihailenco/msgpack/v5"
)

// fatalError wraps decode errors that corrupt the message stream.
// These cause the connection to be closed rather than returning an RPC error.
type fatalError struct{ error }

func (e *fatalError) Unwrap() error { return e.error }

// Aliases for protocol-level message type constants.
const (
	msgRequest      = protocol.MsgRequest
	msgResponse     = protocol.MsgResponse
	msgNotification = protocol.MsgNotification
)

// Client represents a connected RPC client.
type Client struct {
	ID        string
	conn      net.Conn
	engine    *engine.Engine
	server    *Server
	enc       *msgpack.Encoder
	mu        sync.Mutex // protects enc for concurrent notification sends
	stateless bool       // true if this client uses stateless session mode
	sessionID string     // non-empty for stateless clients
}

// NewClient creates a new client for the given connection.
func NewClient(conn net.Conn, eng *engine.Engine, srv *Server) *Client {
	return &Client{
		ID:     uuid.NewString(),
		conn:   conn,
		engine: eng,
		server: srv,
		enc:    msgpack.NewEncoder(conn),
	}
}

// SetStateless marks this client as using stateless session mode.
// The client ID is replaced with the session's client ID so it inherits state.
func (c *Client) SetStateless(sessionID, clientID string) {
	c.stateless = true
	c.sessionID = sessionID
	if c.server != nil {
		c.server.updateClientID(c, clientID)
	} else {
		c.ID = clientID
	}
}

// Serve reads and dispatches messages from the client until the connection
// is closed or ctx is cancelled.
func (c *Client) Serve(ctx context.Context) error {
	// Close connection when context is cancelled to unblock the decoder
	go func() {
		<-ctx.Done()
		c.conn.Close()
	}()

	dec := msgpack.NewDecoder(c.conn)

	for {
		// Each message is a msgpack array: [type, ...]
		arrLen, err := dec.DecodeArrayLen()
		if err != nil {
			if err == io.EOF || isClosedErr(err) {
				return nil
			}
			return fmt.Errorf("decoding message array: %w", err)
		}

		if arrLen < 3 {
			return fmt.Errorf("invalid message: array length %d < 3", arrLen)
		}

		msgType, err := dec.DecodeInt()
		if err != nil {
			return fmt.Errorf("decoding message type: %w", err)
		}

		switch msgType {
		case msgRequest:
			// [0, msgid, method, params]
			if err := c.handleRequest(dec); err != nil {
				return fmt.Errorf("handling request: %w", err)
			}
		case msgNotification:
			// [2, method, params]
			if err := c.handleNotification(dec); err != nil {
				return fmt.Errorf("handling notification: %w", err)
			}
		default:
			return fmt.Errorf("unknown message type: %d", msgType)
		}
	}
}

func (c *Client) handleRequest(dec *msgpack.Decoder) error {
	msgID, err := dec.DecodeUint32()
	if err != nil {
		return fmt.Errorf("decoding msgid: %w", err)
	}

	method, err := dec.DecodeString()
	if err != nil {
		return fmt.Errorf("decoding method: %w", err)
	}

	// Decode the params array wrapper — dispatch expects to decode the inner value
	paramsLen, err := dec.DecodeArrayLen()
	if err != nil {
		return fmt.Errorf("decoding params array: %w", err)
	}

	var result any
	var dispatchErr error

	if paramsLen > 0 {
		result, dispatchErr = c.dispatch(method, dec)
		// Decode errors corrupt the stream — disconnect immediately
		var fe *fatalError
		if errors.As(dispatchErr, &fe) {
			return fe
		}
		// Skip any extra params
		for i := 1; i < paramsLen; i++ {
			if err := skipValue(dec); err != nil {
				return fmt.Errorf("skipping extra param: %w", err)
			}
		}
	} else {
		// No params — still dispatch (for methods like list, status)
		result, dispatchErr = c.dispatchNoParams(method)
	}

	return c.sendResponse(msgID, dispatchErr, result)
}

func (c *Client) handleNotification(dec *msgpack.Decoder) error {
	method, err := dec.DecodeString()
	if err != nil {
		return fmt.Errorf("decoding method: %w", err)
	}

	paramsLen, err := dec.DecodeArrayLen()
	if err != nil {
		return fmt.Errorf("decoding params array: %w", err)
	}

	if paramsLen > 0 {
		_, dispatchErr := c.dispatch(method, dec)
		// Fatal decode errors corrupt the stream — must disconnect
		var fe *fatalError
		if errors.As(dispatchErr, &fe) {
			return fe
		}
		for i := 1; i < paramsLen; i++ {
			if err := skipValue(dec); err != nil {
				return fmt.Errorf("skipping extra param: %w", err)
			}
		}
	} else {
		// Dispatch no-param methods (unplace_all, stop)
		_, _ = c.dispatchNoParams(method)
	}

	return nil
}

func (c *Client) dispatchNoParams(method string) (any, error) {
	switch method {
	case protocol.MethodList:
		reply := make(chan engine.ListReply, 1)
		r, err := sendAndWait(c, engine.ListRequest{
			ClientID: c.ID,
			Reply:    reply,
		}, reply)
		if err != nil {
			return nil, err
		}
		return r.Result, nil
	case protocol.MethodStatus:
		reply := make(chan engine.StatusReply, 1)
		r, err := sendAndWait(c, engine.StatusRequest{
			Reply: reply,
		}, reply)
		if err != nil {
			return nil, err
		}
		return r.Result, nil
	case protocol.MethodStop:
		return nil, c.sendEvent(engine.StopRequest{})
	case protocol.MethodUnplaceAll:
		return nil, c.sendEvent(engine.UnplaceAllRequest{
			ClientID: c.ID,
		})
	default:
		return nil, fmt.Errorf("unknown method: %s", method)
	}
}

// sendResponse encodes a msgpack-rpc response: [1, msgid, error, result]
func (c *Client) sendResponse(msgID uint32, respErr error, result any) error {
	c.mu.Lock()
	defer c.mu.Unlock()

	if err := c.enc.EncodeArrayLen(4); err != nil {
		return err
	}
	if err := c.enc.EncodeInt(msgResponse); err != nil {
		return err
	}
	if err := c.enc.EncodeUint32(msgID); err != nil {
		return err
	}
	if respErr != nil {
		if err := c.enc.Encode(protocol.RPCError{Message: respErr.Error()}); err != nil {
			return err
		}
		if err := c.enc.EncodeNil(); err != nil {
			return err
		}
	} else {
		if err := c.enc.EncodeNil(); err != nil {
			return err
		}
		if err := c.enc.Encode(result); err != nil {
			return err
		}
	}
	return nil
}

// SendNotification encodes a msgpack-rpc notification: [2, method, [params]]
// Safe to call from any goroutine.
func (c *Client) SendNotification(method string, params any) error {
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
	if err := c.enc.EncodeArrayLen(1); err != nil {
		return err
	}
	return c.enc.Encode(params)
}

// Close cleans up the client connection and notifies the engine.
func (c *Client) Close() {
	c.engine.ClientDisconnected(c.ID)
	c.conn.Close()
}

func isClosedErr(err error) bool {
	if err == nil {
		return false
	}
	// net.ErrClosed or "use of closed network connection"
	if err == net.ErrClosed {
		return true
	}
	slog.Debug("connection error", "error", err.Error())
	return false
}
