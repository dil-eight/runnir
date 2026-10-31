package workspace

import (
	"context"
	"sort"

	"runnir/core/internal/store"
)

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
