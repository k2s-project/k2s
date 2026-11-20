// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package smb_share

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/onsi/ginkgo/v2"
	"github.com/onsi/gomega"
)

func TestPreservedTestFiles(t *testing.T) {
	gomega.RegisterFailHandler(ginkgo.Fail)

	for _, tc := range []struct {
		name    string
		content string
		missing bool
		wantErr bool
	}{
		{name: "unchanged old files", content: "test content"},
		{name: "missing file", missing: true, wantErr: true},
		{name: "empty file", wantErr: true},
		{name: "changed content", content: "corrupted content", wantErr: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir := t.TempDir()
			old := time.Now().Add(-time.Hour)
			for _, name := range []string{"file1.txt", "file2.txt", "file3.txt"} {
				content := "test content"
				if name == "file2.txt" {
					if tc.missing {
						continue
					}
					content = tc.content
				}
				path := filepath.Join(dir, name)
				if err := os.WriteFile(path, []byte(content), 0600); err != nil {
					t.Fatal(err)
				}
				if err := os.Chtimes(path, old, old); err != nil {
					t.Fatal(err)
				}
			}

			ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
			defer cancel()
			failures := gomega.InterceptGomegaFailures(func() {
				expectTestFilesAreAvailable(ctx, dir, time.Millisecond)
			})
			if (len(failures) != 0) != tc.wantErr {
				t.Fatalf("failures = %v, wantErr = %v", failures, tc.wantErr)
			}
		})
	}
}
