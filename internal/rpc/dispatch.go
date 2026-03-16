package rpc

import (
	"fmt"

	"github.com/joshheyse/kgd/internal/engine"
	"github.com/joshheyse/kgd/internal/protocol"
	"github.com/vmihailenco/msgpack/v5"
)

// dispatch decodes params for a method and sends the appropriate event to the engine.
// Returns the result to encode in the response, or an error.
// Decode errors are wrapped as *fatalError to signal stream corruption.
func (c *Client) dispatch(method string, dec *msgpack.Decoder) (any, error) {
	switch method {
	case protocol.MethodHello:
		var params protocol.HelloParams
		if err := dec.Decode(&params); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding hello params: %w", err)}
		}

		// Handle stateless session mode
		if params.SessionID != "" && c.server != nil {
			clientID := c.server.RegisterSession(params.SessionID, c.ID)
			c.SetStateless(params.SessionID, clientID)
		}

		reply := make(chan engine.HelloReply, 1)
		c.engine.Events <- engine.HelloRequest{
			ClientID: c.ID,
			Params:   params,
			Reply:    reply,
		}
		r := <-reply
		if r.Err != nil {
			return nil, r.Err
		}
		return r.Result, nil

	case protocol.MethodUpload:
		var params protocol.UploadParams
		if err := dec.Decode(&params); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding upload params: %w", err)}
		}
		reply := make(chan engine.UploadReply, 1)
		c.engine.Events <- engine.UploadRequest{
			ClientID: c.ID,
			Params:   params,
			Reply:    reply,
		}
		r := <-reply
		if r.Err != nil {
			return nil, r.Err
		}
		return protocol.UploadResult{Handle: r.Handle}, nil

	case protocol.MethodPlace:
		var params protocol.PlaceParams
		if err := dec.Decode(&params); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding place params: %w", err)}
		}
		reply := make(chan engine.PlaceReply, 1)
		c.engine.Events <- engine.PlaceRequest{
			ClientID: c.ID,
			Params:   params,
			Reply:    reply,
		}
		r := <-reply
		if r.Err != nil {
			return nil, r.Err
		}
		return protocol.PlaceResult{PlacementID: r.PlacementID}, nil

	case protocol.MethodUnplace:
		var params protocol.UnplaceParams
		if err := dec.Decode(&params); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding unplace params: %w", err)}
		}
		c.engine.Events <- engine.UnplaceRequest{
			ClientID: c.ID,
			Params:   params,
		}
		return nil, nil

	case protocol.MethodUnplaceAll:
		// params is nil/empty array — skip it
		if err := skipValue(dec); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding unplace_all params: %w", err)}
		}
		c.engine.Events <- engine.UnplaceAllRequest{
			ClientID: c.ID,
		}
		return nil, nil

	case protocol.MethodFree:
		var params protocol.FreeParams
		if err := dec.Decode(&params); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding free params: %w", err)}
		}
		c.engine.Events <- engine.FreeRequest{
			ClientID: c.ID,
			Handle:   params.Handle,
		}
		return nil, nil

	case protocol.MethodRegisterWin:
		var params protocol.RegisterWinParams
		if err := dec.Decode(&params); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding register_win params: %w", err)}
		}
		c.engine.Events <- engine.RegisterWin{
			ClientID: c.ID,
			Params:   params,
		}
		return nil, nil

	case protocol.MethodUpdateScroll:
		var params protocol.UpdateScrollParams
		if err := dec.Decode(&params); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding update_scroll params: %w", err)}
		}
		c.engine.Events <- engine.ScrollUpdate{
			ClientID: c.ID,
			Params:   params,
		}
		return nil, nil

	case protocol.MethodUnregisterWin:
		var params protocol.UnregisterWinParams
		if err := dec.Decode(&params); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding unregister_win params: %w", err)}
		}
		c.engine.Events <- engine.UnregisterWin{
			ClientID: c.ID,
			WinID:    params.WinID,
		}
		return nil, nil

	case protocol.MethodList:
		if err := skipValue(dec); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding list params: %w", err)}
		}
		reply := make(chan engine.ListReply, 1)
		c.engine.Events <- engine.ListRequest{
			ClientID: c.ID,
			Reply:    reply,
		}
		r := <-reply
		return r.Result, nil

	case protocol.MethodStatus:
		if err := skipValue(dec); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding status params: %w", err)}
		}
		reply := make(chan engine.StatusReply, 1)
		c.engine.Events <- engine.StatusRequest{
			Reply: reply,
		}
		r := <-reply
		return r.Result, nil

	case protocol.MethodStop:
		if err := skipValue(dec); err != nil {
			return nil, &fatalError{fmt.Errorf("decoding stop params: %w", err)}
		}
		c.engine.Events <- engine.StopRequest{}
		return nil, nil

	default:
		// Skip the params we can't decode
		if err := skipValue(dec); err != nil {
			return nil, &fatalError{fmt.Errorf("skipping unknown method params: %w", err)}
		}
		return nil, fmt.Errorf("unknown method: %s", method)
	}
}

// skipValue decodes and discards one msgpack value.
func skipValue(dec *msgpack.Decoder) error {
	var ignored any
	return dec.Decode(&ignored)
}
