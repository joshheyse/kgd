package rpc

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"sync"

	"github.com/joshheyse/kgd/internal/engine"
)

// Server is the Unix socket RPC server that accepts client connections.
type Server struct {
	socketPath string
	engine     *engine.Engine
	clients    map[string]*Client
	mu         sync.Mutex
}

// NewServer creates a new RPC server.
func NewServer(socketPath string, eng *engine.Engine) *Server {
	return &Server{
		socketPath: socketPath,
		engine:     eng,
		clients:    make(map[string]*Client),
	}
}

// Run starts the server and blocks until ctx is cancelled.
func (s *Server) Run(ctx context.Context) error {
	// Remove stale socket
	_ = os.Remove(s.socketPath)

	ln, err := net.Listen("unix", s.socketPath)
	if err != nil {
		return fmt.Errorf("listen %s: %w", s.socketPath, err)
	}
	defer ln.Close()
	defer os.Remove(s.socketPath)

	slog.Info("rpc server listening", "socket", s.socketPath)

	// Close listener when context is done
	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return nil
			default:
				slog.Error("accept error", "error", err)
				continue
			}
		}

		client := NewClient(conn, s.engine)
		s.addClient(client)
		go s.handleClient(ctx, client)
	}
}

func (s *Server) handleClient(ctx context.Context, c *Client) {
	defer func() {
		s.removeClient(c)
		c.Close()
	}()

	slog.Info("client connected", "id", c.ID)

	if err := c.Serve(ctx); err != nil {
		slog.Debug("client disconnected", "id", c.ID, "error", err)
	} else {
		slog.Info("client disconnected", "id", c.ID)
	}
}

func (s *Server) addClient(c *Client) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.clients[c.ID] = c
}

func (s *Server) removeClient(c *Client) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.clients, c.ID)
}
