package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestDenied(t *testing.T) {
	for _, tc := range []struct {
		out  string
		want bool
	}{
		{"Error: failed to publish images: error publishing ko://go.ate.dev/substrate/cmd/ateapi: writing sbom: PUT https://ghcr.io/v2/holos-run/substrate/ateapi/manifests/sha256-0f68.sbom: DENIED: requested access to the resource is denied", true},
		{"ERROR: failed to push ghcr.io/holos-run/kagent/controller:0.0.0: denied: requested access to the resource is denied", true},
		{"/bin/sh: 1: ./build.sh: Permission denied", false},
		{"Error: failed to build: exit status 1", false},
	} {
		if got := denied([]byte(tc.out)); got != tc.want {
			t.Errorf("denied(%q) = %v, want %v", tc.out, got, tc.want)
		}
	}
}

func TestTailWriter(t *testing.T) {
	var w tailWriter
	fmt.Fprint(&w, strings.Repeat("x", tailSize))
	fmt.Fprint(&w, "the end")
	if got := len(w.Bytes()); got != tailSize {
		t.Fatalf("kept %d bytes, want %d", got, tailSize)
	}
	if !bytes.HasSuffix(w.Bytes(), []byte("the end")) {
		t.Fatalf("lost the last write")
	}
}

func TestRetryDenied(t *testing.T) {
	defer func(a int, b time.Duration) { publishAttempts, publishBackoff = a, b }(publishAttempts, publishBackoff)
	publishAttempts, publishBackoff = 3, 0
	refusal := "DENIED: requested access to the resource is denied"
	failed := errors.New("exit status 1")

	for _, tc := range []struct {
		name    string
		results []string // stderr of each attempt; "" succeeds
		calls   int
		wantErr bool
	}{
		{"succeeds first time", []string{""}, 1, false},
		{"denied then succeeds", []string{refusal, refusal, ""}, 3, false},
		{"other failure is not retried", []string{"Permission denied"}, 1, true},
		{"denied every time", []string{refusal, refusal, refusal, ""}, 3, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			err := retryDenied(context.Background(), &executor{stderr: &bytes.Buffer{}}, "test", func(x *executor) error {
				out := tc.results[calls]
				calls++
				if out == "" {
					return nil
				}
				fmt.Fprintln(x.stderr, out)
				return failed
			})
			if calls != tc.calls {
				t.Errorf("ran %d times, want %d", calls, tc.calls)
			}
			if (err != nil) != tc.wantErr {
				t.Errorf("err = %v, want error %v", err, tc.wantErr)
			}
		})
	}
}
