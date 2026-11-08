package mcpbridge

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
	"sync"
	"time"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// DefaultWait is how long a call waits for the app.
const DefaultWait = 5 * time.Minute

var (
	ErrNoApp          = errors.New("Runnir is not running. Open Runnir and try again.")
	ErrBusy           = errors.New("Runnir is already asking about other values; answer that first, then try again.")
	ErrTimeout        = errors.New("Nobody answered in Runnir within 5 minutes; nothing was saved.")
	ErrUnknownRequest = errors.New("the request is not waiting")
)

type result struct {
	answer *corev1.AnswerMcpRequestRequest
	err    error
}

type pending struct {
	set  bool
	done chan result
}

// Broker hands the calls of MCP clients to the app, one subscriber at a
// time, and waits for its answers. Safe for concurrent use.
type Broker struct {
	wait time.Duration
	log  io.Writer

	mu         sync.Mutex
	subscriber chan *corev1.McpRequest
	generation uint64
	waiting    map[string]*pending
	closed     bool
}

// NewBroker waits wait (DefaultWait when 0) for each answer and writes one
// line per call to log, which may be nil.
func NewBroker(wait time.Duration, log io.Writer) *Broker {
	if wait <= 0 {
		wait = DefaultWait
	}
	return &Broker{wait: wait, log: log, waiting: map[string]*pending{}}
}

// Subscribe makes the caller the app that answers: requests arrive on the
// channel until stop or ctx ends, or another subscriber replaces it. The
// channel is closed then, and calls still waiting fail with ErrNoApp.
func (b *Broker) Subscribe(ctx context.Context) (<-chan *corev1.McpRequest, func()) {
	b.mu.Lock()
	b.dropSubscriberLocked()
	b.generation++
	generation := b.generation
	channel := make(chan *corev1.McpRequest, 16)
	if b.closed {
		close(channel)
	} else {
		b.subscriber = channel
	}
	b.mu.Unlock()
	var once sync.Once
	stop := func() {
		once.Do(func() {
			b.mu.Lock()
			defer b.mu.Unlock()
			if b.generation == generation && b.subscriber != nil {
				b.dropSubscriberLocked()
			}
		})
	}
	go func() { <-ctx.Done(); stop() }()
	return channel, stop
}

func (b *Broker) dropSubscriberLocked() {
	if b.subscriber == nil {
		return
	}
	close(b.subscriber)
	b.subscriber = nil
	for id, p := range b.waiting {
		delete(b.waiting, id)
		p.done <- result{err: ErrNoApp}
	}
}

// Close ends the subscription, fails the calls still waiting and makes
// every later subscription end at once: the Core is shutting down.
func (b *Broker) Close() {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.closed = true
	b.dropSubscriberLocked()
}

// Answer delivers the app's answer to the call waiting with its id.
func (b *Broker) Answer(a *corev1.AnswerMcpRequestRequest) error {
	b.mu.Lock()
	p, ok := b.waiting[a.GetId()]
	if ok {
		delete(b.waiting, a.GetId())
	}
	b.mu.Unlock()
	if !ok {
		return ErrUnknownRequest
	}
	p.done <- result{answer: a}
	return nil
}

// List asks the app for a workspace's value sets.
func (b *Broker) List(ctx context.Context, client, repository string) (*corev1.McpValueSets, error) {
	request := &corev1.McpRequest{Client: client, Tool: corev1.McpTool_MCP_TOOL_LIST_VALUE_SETS, Repository: repository}
	answer, err := b.ask(ctx, request)
	var sets *corev1.McpValueSets
	if err == nil {
		sets, err = answer.GetSets(), refusalOf(answer)
		if err == nil && sets == nil {
			err = Refusal("Runnir gave no value sets.")
		}
	}
	b.record(request, workspaceOf(sets.GetWorkspace(), repository), err, "listed")
	return sets, err
}

// Set checks a runnir_set_values call, then asks the app to confirm and
// save it.
func (b *Broker) Set(ctx context.Context, r *corev1.McpBridgeSetValuesRequest) (*corev1.McpSavedValues, error) {
	request := &corev1.McpRequest{Client: r.GetClient(), Tool: corev1.McpTool_MCP_TOOL_SET_VALUES,
		Repository: r.GetRepository(), Set: r.GetSet(), Secrets: r.GetSecrets(), Variables: r.GetVariables()}
	if err := CheckSet(r); err != nil {
		b.record(request, r.GetRepository(), err, "")
		return nil, err
	}
	answer, err := b.ask(ctx, request)
	var saved *corev1.McpSavedValues
	if err == nil {
		saved, err = answer.GetSaved(), refusalOf(answer)
		if err == nil && saved == nil {
			err = Refusal("Runnir gave no answer about the values.")
		}
	}
	b.record(request, workspaceOf(saved.GetWorkspace(), r.GetRepository()), err, "saved")
	return saved, err
}

func refusalOf(a *corev1.AnswerMcpRequestRequest) error {
	if refusal, ok := a.GetAnswer().(*corev1.AnswerMcpRequestRequest_Refusal); ok {
		return Refusal(refusal.Refusal)
	}
	return nil
}

func workspaceOf(answered, asked string) string {
	if answered != "" {
		return answered
	}
	return asked
}

func (b *Broker) ask(ctx context.Context, request *corev1.McpRequest) (*corev1.AnswerMcpRequestRequest, error) {
	set := request.Tool == corev1.McpTool_MCP_TOOL_SET_VALUES
	b.mu.Lock()
	if b.subscriber == nil {
		b.mu.Unlock()
		return nil, ErrNoApp
	}
	if set {
		for _, p := range b.waiting {
			if p.set {
				b.mu.Unlock()
				return nil, ErrBusy
			}
		}
	}
	request.Id = newID()
	p := &pending{set: set, done: make(chan result, 1)}
	select {
	case b.subscriber <- request:
	default:
		b.mu.Unlock()
		return nil, ErrNoApp
	}
	b.waiting[request.Id] = p
	b.mu.Unlock()

	timer := time.NewTimer(b.wait)
	defer timer.Stop()
	select {
	case r := <-p.done:
		return r.answer, r.err
	case <-ctx.Done():
		b.forget(request.Id)
		return nil, ctx.Err()
	case <-timer.C:
		b.forget(request.Id)
		return nil, ErrTimeout
	}
}

func (b *Broker) forget(id string) {
	b.mu.Lock()
	delete(b.waiting, id)
	b.mu.Unlock()
}

// record writes one line: the tool, the workspace, the set, the names and
// the outcome. Never a value.
func (b *Broker) record(r *corev1.McpRequest, workspace string, err error, success string) {
	if b.log == nil {
		return
	}
	outcome := success
	if err != nil {
		outcome = "refused: " + err.Error()
	}
	line := "mcp: list_value_sets " + fmt.Sprintf("%q", workspace)
	if r.Tool == corev1.McpTool_MCP_TOOL_SET_VALUES {
		line = fmt.Sprintf("mcp: set_values %q set %q secrets=[%s] variables=[%s]", workspace, r.GetSet(),
			names(r.GetSecrets()), names(r.GetVariables()))
	}
	if r.GetClient() != "" {
		line += fmt.Sprintf(" client %q", r.GetClient())
	}
	fmt.Fprintf(b.log, "%s: %s\n", line, outcome)
}

func names(values []*corev1.McpValue) string {
	out := make([]string, 0, len(values))
	for _, v := range values {
		out = append(out, v.GetName())
	}
	sort.Strings(out)
	return strings.Join(out, " ")
}

func newID() string {
	var raw [12]byte
	_, _ = rand.Read(raw[:])
	return "mcp_" + hex.EncodeToString(raw[:])
}
