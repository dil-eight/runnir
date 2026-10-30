package workspace

import (
	"context"
	"sort"
	"time"

	"runnir/core/internal/github"
	"runnir/core/internal/store"
)

// OpenRuns reads, from the first workspace among ids that is open with
// source's saved data, actor's newest limit saved runs and when a pass last
// reached GitHub. false when none is; nothing is sent to GitHub.
func (m *Runtimes) OpenRuns(ctx context.Context, ids []string, source store.Source, actor string, limit int) ([]github.Run, time.Time, bool) {
	for _, raw := range ids {
		id, ok := store.NormalizeWorkspaceID(raw)
		if !ok {
			continue
		}
		m.mu.Lock()
		rt := m.byWorkspace[id]
		m.mu.Unlock()
		if rt == nil {
			continue
		}
		w, err := rt.cfg.store.WatchedRuns(ctx, actor, limit)
		if err != nil || !w.HasSource || w.Source != source {
			continue
		}
		return w.Runs, w.SyncedAt, true
	}
	return nil, time.Time{}, false
}

// Starts joins the attempts Runnir started of source's runs (B46) in the
// workspaces ids: an open one's from its store, a closed one's from its
// database opened read-only, as SearchAll reads it. A workspace that cannot
// be read adds nothing. Each run's attempts are oldest first.
func (m *Runtimes) Starts(ctx context.Context, ids []string, source store.Source) map[int64][]store.RunStart {
	out := map[int64][]store.RunStart{}
	for _, raw := range ids {
		id, ok := store.NormalizeWorkspaceID(raw)
		if !ok {
			continue
		}
		for run, starts := range m.startsOf(ctx, id, source) {
			out[run] = append(out[run], starts...)
		}
	}
	for _, starts := range out {
		sort.Slice(starts, func(i, j int) bool { return starts[i].Attempt < starts[j].Attempt })
	}
	return out
}

func (m *Runtimes) startsOf(ctx context.Context, id string, source store.Source) map[int64][]store.RunStart {
	rt, release := m.claim(id)
	defer release()
	if rt != nil {
		starts, _ := rt.cfg.store.RunStarts(ctx, source)
		return starts
	}
	if m.opts.DataDir == "" {
		return nil
	}
	st, ok, err := store.OpenReadOnly(m.dir(id))
	if err != nil || !ok {
		return nil
	}
	defer st.Close()
	starts, _ := st.RunStarts(ctx, source)
	return starts
}
