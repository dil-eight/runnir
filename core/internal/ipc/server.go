// Package ipc implements Runnir's bounded, newline-delimited JSON-RPC profile.
package ipc

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
)

const MaxFrameBytes = 64 * 1024

type Error struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type Handler func(method string, params json.RawMessage) (any, *Error)

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *Error          `json:"error,omitempty"`
}

func Serve(input io.Reader, output io.Writer, handle Handler) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), MaxFrameBytes+1)
	encoder := json.NewEncoder(output)
	for scanner.Scan() {
		frame := bytes.TrimSpace(scanner.Bytes())
		if len(frame) > MaxFrameBytes {
			return &Error{Code: -32600, Message: "Frame too large"}
		}
		reply := response{JSONRPC: "2.0", ID: json.RawMessage("null")}
		var req request
		switch {
		case !json.Valid(frame):
			reply.Error = &Error{Code: -32700, Message: "Parse error"}
		case json.Unmarshal(frame, &req) != nil || len(frame) == 0 || frame[0] != '{' || req.JSONRPC != "2.0" || req.Method == "" || !validID(req.ID):
			reply.Error = &Error{Code: -32600, Message: "Invalid Request"}
		default:
			if len(req.ID) != 0 {
				reply.ID = req.ID
			}
			if len(req.Params) > 0 && req.Params[0] != '{' && req.Params[0] != '[' {
				reply.Error = &Error{Code: -32602, Message: "Invalid params"}
			} else {
				reply.Result, reply.Error = handle(req.Method, req.Params)
			}
			if len(req.ID) == 0 {
				continue
			}
		}
		if err := encoder.Encode(reply); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func validID(raw json.RawMessage) bool {
	if len(raw) == 0 {
		return true
	}
	var id any
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.UseNumber()
	if decoder.Decode(&id) != nil {
		return false
	}
	switch id.(type) {
	case nil, string, json.Number:
		return true
	default:
		return false
	}
}

func (e *Error) Error() string { return e.Message }
