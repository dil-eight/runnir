package mcpbridge

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sync"
	"time"

	"google.golang.org/protobuf/types/known/timestamppb"

	corev1 "runnir/core/internal/gen/runnir/core/v1"
)

// DefaultWait is how long a call waits for the app.
const DefaultWait = 5 * time.Minute

// ClaimedWait is how long a call waits once the app claimed it: the user
// answered, and the app saves the values or starts the run.
const ClaimedWait = 2 * time.Minute

var (
	ErrNoApp          = errors.New("Runnir is not running. Open Runnir and try again.")
	ErrBusy           = errors.New("Runnir is already asking about other values; answer that first, then try again.")
	ErrTimeout        = errors.New("Runnir did not answer within 5 minutes.")
	ErrSetTimeout     = errors.New("Nobody answered in Runnir within 5 minutes; nothing was saved.")
	ErrUnknownRequest = errors.New("the request is not waiting")
	ErrUnfinished     = errors.New("The user answered in Runnir, but Runnir did not finish within 2 minutes. Check Runnir.")
)

type result struct {
	answer *corev1.AnswerMcpRequestRequest
	err    error
}

type pending struct {
	set  bool
	done chan result
	// claim is closed when the app claims the request: it no longer expires.
	claim   chan struct{}
	claimed bool
}

// Broker hands the questions of MCP tools to the app, one subscriber at a
// time, and waits for its answers. Safe for concurrent use.
type Broker struct {
	wait, claimedWait time.Duration

	mu         sync.Mutex
	subscriber chan *corev1.McpRequest
	generation uint64
	waiting    map[string]*pending
	closed     bool
}

// NewBroker waits wait (DefaultWait when 0) for each answer.
func NewBroker(wait time.Duration) *Broker {
	if wait <= 0 {
		wait = DefaultWait
	}
	return &Broker{wait: wait, claimedWait: ClaimedWait, waiting: map[string]*pending{}}
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

// Claim marks a request the app is about to act on: it no longer expires,
// and its call waits up to ClaimedWait for the answer. ErrUnknownRequest
// when the request no longer waits: its client was told nothing happened,
// so the app must not act.
func (b *Broker) Claim(id string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	p, ok := b.waiting[id]
	if !ok {
		return ErrUnknownRequest
	}
	if !p.claimed {
		p.claimed = true
		close(p.claim)
	}
	return nil
}

// Workspaces asks the app for its registered workspaces.
func (b *Broker) Workspaces(ctx context.Context, client string) (*corev1.McpWorkspaces, error) {
	answer, err := b.ask(ctx, &corev1.McpRequest{Client: client, Tool: corev1.McpTool_MCP_TOOL_LIST_WORKSPACES})
	if err != nil {
		return nil, err
	}
	return answered(answer.GetWorkspaces(), answer, "Runnir gave no workspaces.")
}

// Open asks the app for a workspace ready to use: resolved by its folder or
// name, its window opened when none shows it. With action, the app refuses
// while the user turned actions off.
func (b *Broker) Open(ctx context.Context, client, repository string, action bool) (*corev1.McpOpenedWorkspace, error) {
	answer, err := b.ask(ctx, &corev1.McpRequest{Client: client, Tool: corev1.McpTool_MCP_TOOL_OPEN_WORKSPACE, Repository: repository, Action: action})
	if err != nil {
		return nil, err
	}
	return answered(answer.GetWorkspace(), answer, "Runnir gave no workspace.")
}

// Start asks the app to start a local run as Run Locally does.
func (b *Broker) Start(ctx context.Context, client, repository string, start *corev1.McpLocalRunStart) (*corev1.McpLocalRunStarted, error) {
	answer, err := b.ask(ctx, &corev1.McpRequest{Client: client, Tool: corev1.McpTool_MCP_TOOL_START_LOCAL_RUN,
		Repository: repository, Action: true, Start: start})
	if err != nil {
		return nil, err
	}
	return answered(answer.GetStarted(), answer, "Runnir gave no answer about the run.")
}

// List asks the app for a workspace's value sets.
func (b *Broker) List(ctx context.Context, client, repository string) (*corev1.McpValueSets, error) {
	answer, err := b.ask(ctx, &corev1.McpRequest{Client: client, Tool: corev1.McpTool_MCP_TOOL_LIST_VALUE_SETS, Repository: repository})
	if err != nil {
		return nil, err
	}
	return answered(answer.GetSets(), answer, "Runnir gave no value sets.")
}

// Set checks a runnir_set_values call, then asks the app to confirm and
// save it.
func (b *Broker) Set(ctx context.Context, r *corev1.McpRequest) (*corev1.McpSavedValues, error) {
	request := &corev1.McpRequest{Client: r.GetClient(), Tool: corev1.McpTool_MCP_TOOL_SET_VALUES, Action: true,
		Repository: r.GetRepository(), Set: r.GetSet(), Secrets: r.GetSecrets(), Variables: r.GetVariables()}
	if err := CheckSet(request); err != nil {
		return nil, err
	}
	answer, err := b.ask(ctx, request)
	if errors.Is(err, ErrTimeout) {
		return nil, ErrSetTimeout
	}
	if err != nil {
		return nil, err
	}
	return answered(answer.GetSaved(), answer, "Runnir gave no answer about the values.")
}

// answered is the app's answer of the kind asked, or its refusal.
func answered[T comparable](got T, a *corev1.AnswerMcpRequestRequest, missing string) (T, error) {
	var none T
	if refusal, ok := a.GetAnswer().(*corev1.AnswerMcpRequestRequest_Refusal); ok {
		return none, Refusal(refusal.Refusal)
	}
	if got == none {
		return none, Refusal(missing)
	}
	return got, nil
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
	request.ExpiresAt = timestamppb.New(time.Now().Add(b.wait))
	p := &pending{set: set, done: make(chan result, 1), claim: make(chan struct{})}
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
	claim, claimed := p.claim, false
	for {
		select {
		case r := <-p.done:
			return r.answer, r.err
		case <-claim:
			claim, claimed = nil, true
			timer.Reset(b.claimedWait)
		case <-ctx.Done():
			b.end(request.Id)
			return nil, ctx.Err()
		case <-timer.C:
			if claimed {
				b.end(request.Id)
				return nil, ErrUnfinished
			}
			if b.expire(request.Id) {
				return nil, ErrTimeout
			}
			// Claimed as the time ran out.
			claim, claimed = nil, true
			timer.Reset(b.claimedWait)
		}
	}
}

// expire ends a request that was not claimed and says so to the app; false
// when the app claimed it.
func (b *Broker) expire(id string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	if p, ok := b.waiting[id]; ok && p.claimed {
		return false
	}
	b.endLocked(id)
	return true
}

// end ends a request whose call no longer waits.
func (b *Broker) end(id string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.endLocked(id)
}

// endLocked forgets a request and, unless the app claimed it and acts on it,
// tells the app it no longer waits, so it takes its question down.
func (b *Broker) endLocked(id string) {
	p, ok := b.waiting[id]
	if !ok {
		return
	}
	delete(b.waiting, id)
	if !p.claimed && b.subscriber != nil {
		select {
		case b.subscriber <- &corev1.McpRequest{Id: id, Withdrawn: true}:
		default: // the app finds out when it claims or answers it
		}
	}
}

func newID() string {
	var raw [12]byte
	_, _ = rand.Read(raw[:])
	return "mcp_" + hex.EncodeToString(raw[:])
}
