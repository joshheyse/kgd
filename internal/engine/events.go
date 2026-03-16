package engine

import "github.com/joshheyse/kgd/internal/protocol"

// Event is the interface for all events processed by the PlacementEngine.
type Event interface {
	eventTag()
}

// HelloRequest asks the engine for a hello handshake response.
type HelloRequest struct {
	ClientID string
	Params   protocol.HelloParams
	Reply    chan<- HelloReply
}

func (HelloRequest) eventTag() {}

// HelloReply is the response to a HelloRequest.
type HelloReply struct {
	Result protocol.HelloResult
	Err    error
}

// PlaceRequest asks the engine to create a new placement.
type PlaceRequest struct {
	ClientID string
	Params   protocol.PlaceParams
	Reply    chan<- PlaceReply
}

func (PlaceRequest) eventTag() {}

// PlaceReply is the response to a PlaceRequest.
type PlaceReply struct {
	PlacementID uint32
	Err         error
}

// UnplaceRequest asks the engine to remove a placement.
type UnplaceRequest struct {
	ClientID string
	Params   protocol.UnplaceParams
}

func (UnplaceRequest) eventTag() {}

// UnplaceAllRequest removes all placements for a client.
type UnplaceAllRequest struct {
	ClientID string
}

func (UnplaceAllRequest) eventTag() {}

// UploadRequest asks the engine to register uploaded image data.
type UploadRequest struct {
	ClientID string
	Params   protocol.UploadParams
	Reply    chan<- UploadReply
}

func (UploadRequest) eventTag() {}

// UploadReply is the response to an UploadRequest.
type UploadReply struct {
	Handle uint32
	Err    error
}

// FreeRequest releases uploaded image data.
type FreeRequest struct {
	ClientID string
	Handle   uint32
}

func (FreeRequest) eventTag() {}

// ScrollUpdate notifies the engine of a scroll position change.
type ScrollUpdate struct {
	ClientID string
	Params   protocol.UpdateScrollParams
}

func (ScrollUpdate) eventTag() {}

// RegisterWin registers a neovim window geometry.
type RegisterWin struct {
	ClientID string
	Params   protocol.RegisterWinParams
}

func (RegisterWin) eventTag() {}

// UnregisterWin unregisters a neovim window.
type UnregisterWin struct {
	ClientID string
	WinID    int
}

func (UnregisterWin) eventTag() {}

// TopologyEvent signals a change in tmux/terminal layout.
type TopologyEvent struct{}

func (TopologyEvent) eventTag() {}

// ClientDisconnect signals that a client has disconnected.
type ClientDisconnect struct {
	ClientID string
}

func (ClientDisconnect) eventTag() {}

// ListRequest asks the engine for active placements.
type ListRequest struct {
	ClientID string
	Reply    chan<- ListReply
}

func (ListRequest) eventTag() {}

// ListReply is the response to a ListRequest.
type ListReply struct {
	Result protocol.ListResult
}

// StatusRequest asks the engine for daemon status.
type StatusRequest struct {
	Reply chan<- StatusReply
}

func (StatusRequest) eventTag() {}

// StatusReply is the response to a StatusRequest.
type StatusReply struct {
	Result protocol.StatusResult
}

// StopRequest asks the daemon to shut down gracefully.
type StopRequest struct{}

func (StopRequest) eventTag() {}
