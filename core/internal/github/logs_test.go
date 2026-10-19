package github

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func numberedLog(lines int) string {
	var b strings.Builder
	for i := 1; i <= lines; i++ {
		fmt.Fprintf(&b, "line %04d\n", i)
	}
	return b.String()
}

func TestReadTailKeepsWholeLinesFromTheEnd(t *testing.T) {
	log := numberedLog(1000) // 10 bytes per line
	got, err := readTail(strings.NewReader(log), 95)
	if err != nil {
		t.Fatal(err)
	}
	if string(got.Data) != numberedLog(1000)[9910:] || got.DroppedLines != 991 || !got.Truncated {
		t.Fatalf("tail = %q, dropped %d, truncated %v", got.Data, got.DroppedLines, got.Truncated)
	}
	small, _ := readTail(strings.NewReader("a\nb\n"), 95)
	if string(small.Data) != "a\nb\n" || small.DroppedLines != 0 || small.Truncated {
		t.Fatalf("small = %+v", small)
	}
}

func TestJobLogFollowsTheRedirectWithoutTheToken(t *testing.T) {
	var blobAuthorization string
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/o/r/actions/jobs/5/logs", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer ghu_secret" {
			t.Errorf("API request without the token")
		}
		http.Redirect(w, r, "/blob/5.txt?sig=abc", http.StatusFound)
	})
	mux.HandleFunc("/blob/5.txt", func(w http.ResponseWriter, r *http.Request) {
		blobAuthorization = r.Header.Get("Authorization")
		_, _ = w.Write([]byte(numberedLog(3)))
	})
	mux.HandleFunc("/repos/o/r/actions/jobs/6/logs", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusGone)
	})
	mux.HandleFunc("/repos/o/r/actions/jobs/7/logs", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/blob/missing", http.StatusFound)
	})
	mux.HandleFunc("/repos/o/r/actions/jobs/8/logs", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "http://elsewhere.invalid/blob", http.StatusFound)
	})
	server := httptest.NewServer(mux)
	defer server.Close()
	credential := &Credential{}
	_ = credential.Set("ghu_secret")
	client := NewClient(credential, server.URL, "test")
	ctx := context.Background()

	log, err := client.JobLog(ctx, "o", "r", 5, 0)
	if err != nil || string(log.Data) != numberedLog(3) || log.Truncated {
		t.Fatalf("log = %+v, %v", log, err)
	}
	if blobAuthorization != "" {
		t.Fatalf("the token was sent to the log storage")
	}
	for _, job := range []int64{6, 7} {
		if _, err := client.JobLog(ctx, "o", "r", job, 0); !errors.Is(err, ErrLogUnavailable) {
			t.Errorf("job %d = %v, want ErrLogUnavailable", job, err)
		}
	}
	if _, err := client.JobLog(ctx, "o", "r", 8, 0); !errors.Is(err, ErrInvalid) {
		t.Errorf("plain-http redirect elsewhere = %v, want ErrInvalid", err)
	}
	credential.Clear()
	if _, err := client.JobLog(ctx, "o", "r", 5, 0); !errors.Is(err, ErrNoCredential) {
		t.Errorf("signed out = %v", err)
	}
}
