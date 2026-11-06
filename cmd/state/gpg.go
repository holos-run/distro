package main

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// crypter is the gpg half of the program.
type crypter interface {
	// encrypt writes plaintext, encrypted to recipient, to out.
	encrypt(ctx context.Context, recipient string, plaintext []byte, out *os.File) error
	// decrypt returns the plaintext of the file at path.
	decrypt(ctx context.Context, path string) ([]byte, error)
}

// gnupg runs gpg, which needs only the public key to encrypt and the secret
// key, unlocked, to decrypt. --trust-model always because the recipient is
// the one the operator named. --batch asks nothing on the terminal; a
// passphrase, if the agent needs one, goes through its pinentry.
type gnupg struct{}

func (gnupg) encrypt(ctx context.Context, recipient string, plaintext []byte, out *os.File) error {
	cmd := exec.CommandContext(ctx, "gpg", "--batch", "--trust-model", "always",
		"--encrypt", "--recipient", recipient, "--output", "-")
	cmd.Stdin = bytes.NewReader(plaintext)
	cmd.Stdout = out
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("gpg --encrypt to %s: %w: %s", recipient, err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func (gnupg) decrypt(ctx context.Context, path string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "gpg", "--batch", "--quiet", "--decrypt", path)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("gpg --decrypt %s: %w: %s", path, err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), nil
}
