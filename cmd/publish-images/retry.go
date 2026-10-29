package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"time"
)

// ghcr.io refuses writes to a package for a moment after the push that
// creates it: the first dispatch saw ko's third push to a new package denied
// a second after its first two were accepted, and a re-run then got that
// package through and was denied on the next new one. So the first publish
// of each package can fail once with "denied", and a retry, which builds from
// a warm cache and pushes the same content again, gets it through.
// publishAttempts covers a first run that creates every package, one new
// package per attempt at worst.
var (
	publishAttempts = 16
	publishBackoff  = 20 * time.Second
)

// retryDenied runs publish until it succeeds, giving up at once on a failure
// that does not mention a denied push, and after publishAttempts on one that
// does. publish runs its commands through the executor it is given, whose
// stderr is also kept so the refusal can be seen.
func retryDenied(ctx context.Context, x *executor, what string, publish func(*executor) error) error {
	for attempt := 1; ; attempt++ {
		var tail tailWriter
		err := publish(&executor{stderr: io.MultiWriter(x.stderr, &tail)})
		if err == nil || !denied(tail.Bytes()) {
			return err
		}
		if attempt == publishAttempts {
			return fmt.Errorf("%s: registry still denied the push after %d attempts: %w", what, attempt, err)
		}
		logf(x.stderr, "%s: the registry denied a push, as it does just after creating a package; retrying in %s (attempt %d of %d)",
			what, publishBackoff, attempt+1, publishAttempts)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(publishBackoff):
		}
	}
}

// denied reports whether a registry refused a write. ko, buildx and helm all
// print the registry's message, after a DENIED or denied error code. The
// message, not the bare word, so a build step's "permission denied" is not
// retried.
func denied(out []byte) bool {
	return bytes.Contains(bytes.ToLower(out), []byte("requested access to the resource is denied"))
}

// tailWriter keeps the last tailSize bytes written to it, enough to hold a
// failed command's closing error without keeping a whole build log.
type tailWriter struct{ buf []byte }

const tailSize = 64 << 10

func (t *tailWriter) Write(p []byte) (int, error) {
	t.buf = append(t.buf, p...)
	if over := len(t.buf) - tailSize; over > 0 {
		t.buf = append(t.buf[:0], t.buf[over:]...)
	}
	return len(p), nil
}

func (t *tailWriter) Bytes() []byte { return t.buf }
