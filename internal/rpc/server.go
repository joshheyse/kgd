package rpc

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"sync"
	"time"

	"github.com/joshheyse/kgd/internal/engine"
)

const (
	sessionIdleTimeout  = 5 * time.Minute
	sessionReapInterval = 30 * time.Second
)

// session tracks state for stateless clients that reconnect with a session ID.
type session struct {
	clientID string // the engine-side client ID
	lastSeen time.Time
}

// Server is the Unix socket RPC server that accepts client connections.
type Server struct {
	socketPath string
	engine     *engine.Engine
	clients    map[string]*Client
	sessions   map[string]*session // sessionID → session
	mu         sync.Mutex
}

// NewServer creates a new RPC server.
func NewServer(socketPath string, eng *engine.Engine) *Server {
	return &Server{
		socketPath: socketPath,
		engine:     eng,
		clients:    make(map[string]*Client),
		sessions:   make(map[string]*session),
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

	// Start session reaper
	go s.reapSessions(ctx)

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

		client := NewClient(conn, s.engine, s)
		s.addClient(client)
		go s.handleClient(ctx, client)
	}
}

func (s *Server) handleClient(ctx context.Context, c *Client) {
	defer func() {
		s.removeClient(c)
		if c.stateless {
			// Update session last-seen time instead of full cleanup
			s.mu.Lock()
			if sess, ok := s.sessions[c.sessionID]; ok {
				sess.lastSeen = time.Now()
			}
			s.mu.Unlock()
			c.conn.Close()
		} else {
			c.Close()
		}
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

// RegisterSession registers a stateless session for a client.
// If a session with the given ID already exists, returns its client ID.
// Otherwise creates a new session with the given client ID.
func (s *Server) RegisterSession(sessionID, clientID string) string {
	s.mu.Lock()
	defer s.mu.Unlock()

	if sess, ok := s.sessions[sessionID]; ok {
		// Existing session — return its client ID so the client can
		// inherit all state (handles, placements)
		sess.lastSeen = time.Now()
		return sess.clientID
	}

	// New session
	s.sessions[sessionID] = &session{
		clientID: clientID,
		lastSeen: time.Now(),
	}
	return clientID
}

// reapSessions periodically removes sessions that have been idle too long.
func (s *Server) reapSessions(ctx context.Context) {
	ticker := time.NewTicker(sessionReapInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Collect expired sessions under lock
			s.mu.Lock()
			var expiredClientIDs []string
			for id, sess := range s.sessions {
				if time.Since(sess.lastSeen) > sessionIdleTimeout {
					slog.Info("reaping idle session", "session", id, "client", sess.clientID)
					expiredClientIDs = append(expiredClientIDs, sess.clientID)
					delete(s.sessions, id)
				}
			}
			s.mu.Unlock()

			// Trigger engine cleanup outside the lock to avoid deadlock
			for _, clientID := range expiredClientIDs {
				s.engine.ClientDisconnected(clientID)
			}
		}
	}
}

// updateClientID re-keys a client in the map when its ID changes (e.g., stateless session takeover).
func (s *Server) updateClientID(c *Client, newID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.clients, c.ID)
	c.ID = newID
	s.clients[newID] = c
}

// NotifyClient sends a notification to a specific client by ID.
func (s *Server) NotifyClient(clientID, method string, params any) error {
	s.mu.Lock()
	var target *Client
	for _, c := range s.clients {
		if c.ID == clientID {
			target = c
			break
		}
	}
	s.mu.Unlock()

	if target == nil {
		return fmt.Errorf("client %s not connected", clientID)
	}
	return target.SendNotification(method, params)
}

// NotifyAll sends a notification to all connected clients.
func (s *Server) NotifyAll(method string, params any) {
	s.mu.Lock()
	clients := make([]*Client, 0, len(s.clients))
	for _, c := range s.clients {
		clients = append(clients, c)
	}
	s.mu.Unlock()

	for _, c := range clients {
		if err := c.SendNotification(method, params); err != nil {
			slog.Debug("notification send failed", "client", c.ID, "method", method, "error", err)
		}
	}
}
