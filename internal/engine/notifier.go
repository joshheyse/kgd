package engine

// Notifier is the interface for sending notifications from the engine to clients.
// This avoids an import cycle between engine and rpc packages.
type Notifier interface {
	// NotifyClient sends a notification to a specific client.
	NotifyClient(clientID, method string, params any) error

	// NotifyAll sends a notification to all connected clients.
	NotifyAll(method string, params any)
}
