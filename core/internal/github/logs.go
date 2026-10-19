package github

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// ErrLogUnavailable: GitHub has no log for the job (expired, deleted or never
// written). The job itself may still be readable.
var ErrLogUnavailable = errors.New("the job log is not available")

const (
	// DefaultLogTail is how much of the end of a log is kept.
	DefaultLogTail = 2 << 20
	// maxLogDownload stops reading a huge log; what was read is still used.
	maxLogDownload = 256 << 20
)

// JobLog is the end of a job's plain-text log.
type JobLog struct {
	// The kept tail, starting at a line boundary.
	Data []byte
	// Lines before Data that were dropped to stay within the limit.
	DroppedLines int
	// True when lines were dropped at the start or reading stopped early.
	Truncated bool
	// True when the log was larger than maxLogDownload: Data is the end of
	// what was read, not the end of the log.
	StoppedEarly bool
}

// JobLog downloads a job's log and keeps at most tail bytes from its end.
// GitHub answers with a redirect to short-lived storage; the token is sent
// only to the API, never to the redirect target.
func (c *Client) JobLog(ctx context.Context, owner, name string, jobID int64, tail int) (JobLog, error) {
	if jobID <= 0 {
		return JobLog{}, ErrInvalid
	}
	if tail <= 0 {
		tail = DefaultLogTail
	}
	token, ok := c.credential.Token()
	if !ok {
		return JobLog{}, ErrNoCredential
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet,
		c.baseURL+repoPath(owner, name, fmt.Sprintf("/actions/jobs/%d/logs", jobID)), nil)
	if err != nil {
		return JobLog{}, ErrInvalid
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("User-Agent", c.userAgent)

	noRedirects := &http.Client{
		Timeout:       c.http.Timeout,
		Transport:     c.http.Transport,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	response, err := noRedirects.Do(request)
	if err != nil {
		return JobLog{}, transportError(ctx)
	}
	status := response.StatusCode
	if location, err := response.Location(); status >= 300 && status < 400 && err == nil {
		response.Body.Close()
		return c.downloadLog(ctx, location, tail)
	}
	defer response.Body.Close()
	switch {
	case status == http.StatusOK:
		return readTail(response.Body, tail)
	case status == http.StatusNotFound, status == http.StatusGone:
		return JobLog{}, ErrLogUnavailable
	case status == http.StatusUnauthorized:
		return JobLog{}, ErrUnauthorized
	case status == http.StatusTooManyRequests, status == http.StatusForbidden && isRateLimited(response):
		return JobLog{}, &RateLimitError{Reset: rateLimitReset(response)}
	case status == http.StatusForbidden:
		return JobLog{}, ErrNotVisible
	case status >= 500:
		return JobLog{}, ErrUnavailable
	default:
		return JobLog{}, ErrInvalid
	}
}

// downloadLog fetches the redirect target without credentials. Only https
// targets are followed, or the API's own host when tests run it over http.
func (c *Client) downloadLog(ctx context.Context, target *url.URL, tail int) (JobLog, error) {
	api, _ := url.Parse(c.baseURL)
	if target.Scheme != "https" && (api == nil || target.Host != api.Host) {
		return JobLog{}, ErrInvalid
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return JobLog{}, ErrInvalid
	}
	request.Header.Set("User-Agent", c.userAgent)
	download := &http.Client{Timeout: 2 * time.Minute, Transport: c.http.Transport}
	response, err := download.Do(request)
	if err != nil {
		return JobLog{}, transportError(ctx)
	}
	defer response.Body.Close()
	switch status := response.StatusCode; {
	case status == http.StatusOK:
		return readTail(response.Body, tail)
	case status == http.StatusNotFound, status == http.StatusGone, status == http.StatusForbidden:
		// Storage answers 403 or 404 for an expired or removed blob.
		return JobLog{}, ErrLogUnavailable
	case status >= 500:
		return JobLog{}, ErrUnavailable
	default:
		return JobLog{}, ErrInvalid
	}
}

func transportError(ctx context.Context) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	return ErrUnavailable
}

// readTail keeps the last tail bytes of body, cut at a line start, counting
// the lines it drops. It reads at most maxLogDownload bytes.
func readTail(body io.Reader, tail int) (JobLog, error) {
	return readTailUpTo(body, tail, maxLogDownload)
}

func readTailUpTo(body io.Reader, tail, limit int) (JobLog, error) {
	var (
		kept    []byte
		dropped int
		chunk   = make([]byte, 64<<10)
		total   int
	)
	trim := func(limit int) {
		if len(kept) <= limit {
			return
		}
		cut := len(kept) - limit
		if newline := bytes.IndexByte(kept[cut:], '\n'); newline >= 0 {
			cut += newline + 1
		} else {
			cut = len(kept)
		}
		dropped += bytes.Count(kept[:cut], []byte{'\n'})
		kept = append(kept[:0:0], kept[cut:]...)
	}
	for total < limit {
		n, err := body.Read(chunk)
		if n > 0 {
			total += n
			kept = append(kept, chunk[:n]...)
			if len(kept) > 2*tail {
				trim(tail)
			}
		}
		if errors.Is(err, io.EOF) {
			trim(tail)
			return JobLog{Data: kept, DroppedLines: dropped, Truncated: dropped > 0}, nil
		}
		if err != nil {
			return JobLog{}, ErrUnavailable
		}
	}
	trim(tail)
	// The limit can fall exactly at the end; only more data means we stopped.
	if n, _ := body.Read(make([]byte, 1)); n == 0 {
		return JobLog{Data: kept, DroppedLines: dropped, Truncated: dropped > 0}, nil
	}
	return JobLog{Data: kept, DroppedLines: dropped, Truncated: true, StoppedEarly: true}, nil
}
