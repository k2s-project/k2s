// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package argocdgitopssync

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

func TestPollerSuspensionRestoresOriginalState(t *testing.T) {
	for name, original := range map[string]*bool{"omitted": nil, "running": new(bool), "suspended": boolPointer(true)} {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			poller := &batchv1.CronJob{
				ObjectMeta: metav1.ObjectMeta{Name: "poller", Namespace: "sync", UID: "poller-uid"},
				Spec:       batchv1.CronJobSpec{Suspend: original},
			}
			client := fake.NewClientset(poller)
			uid, restore, err := suspendPoller(ctx, client, "sync", "poller")
			if err != nil || uid != poller.UID {
				t.Fatalf("suspend: uid=%s, err=%v", uid, err)
			}
			current, err := client.BatchV1().CronJobs("sync").Get(ctx, "poller", metav1.GetOptions{})
			if err != nil || current.Spec.Suspend == nil || !*current.Spec.Suspend {
				t.Fatalf("poller was not suspended: %v, %v", current, err)
			}
			if err := restore(ctx); err != nil {
				t.Fatal(err)
			}
			current, err = client.BatchV1().CronJobs("sync").Get(ctx, "poller", metav1.GetOptions{})
			if err != nil {
				t.Fatal(err)
			}
			if original == nil {
				if current.Spec.Suspend != nil {
					t.Fatal("restore must preserve an omitted suspend field")
				}
			} else if current.Spec.Suspend == nil || *current.Spec.Suspend != *original {
				t.Fatal("restore changed the original suspension state")
			}
		})
	}
}

func TestPollerIdleWaitsForOwnedJobsAndPods(t *testing.T) {
	ctx := context.Background()
	controller := true
	job := &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name: "scheduled", Namespace: "sync", UID: "job-uid",
			OwnerReferences: []metav1.OwnerReference{{UID: "poller-uid", Controller: &controller}},
		},
	}

	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: "scheduled-pod", Namespace: "sync",
			OwnerReferences: []metav1.OwnerReference{{UID: job.UID, Controller: &controller}},
		},
		Status: corev1.PodStatus{Phase: corev1.PodRunning},
	}
	unrelated := &batchv1.Job{ObjectMeta: metav1.ObjectMeta{Name: "unrelated", Namespace: "sync"}}
	client := fake.NewClientset(job, pod, unrelated)
	expectIdle := func(expected bool) {
		t.Helper()
		idle, err := pollerIsIdle(ctx, client, "sync", "poller-uid")
		if err != nil || idle != expected {
			t.Fatalf("idle=%v, want=%v, err=%v", idle, expected, err)
		}
	}
	expectIdle(false)
	job.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobFailed, Status: corev1.ConditionTrue}}
	if _, err := client.BatchV1().Jobs("sync").UpdateStatus(ctx, job, metav1.UpdateOptions{}); err != nil {
		t.Fatal(err)
	}
	expectIdle(false)
	pod.Status.Phase = corev1.PodFailed
	if _, err := client.CoreV1().Pods("sync").UpdateStatus(ctx, pod, metav1.UpdateOptions{}); err != nil {
		t.Fatal(err)
	}
	expectIdle(true)
}

func TestPollerIdleDoesNotHideAPIError(t *testing.T) {
	client := fake.NewClientset()
	client.PrependReactor("list", "jobs", func(k8stesting.Action) (bool, runtime.Object, error) {
		return true, nil, fmt.Errorf("access denied")
	})
	if idle, err := pollerIsIdle(context.Background(), client, "sync", "poller-uid"); err == nil || idle {
		t.Fatalf("API error must not be treated as idle: idle=%v, err=%v", idle, err)
	}
}

func TestSyncDigestResetRejectsFailedRemoval(t *testing.T) {
	dir := t.TempDir()
	digest := filepath.Join(dir, "metrics")
	if err := os.WriteFile(digest, []byte("old-digest"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := resetSyncDigest(digest); err != nil {
		t.Fatal(err)
	}
	if err := resetSyncDigest(digest); err != nil {
		t.Fatalf("absent digest should be accepted: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "keep"), []byte("not a digest"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := resetSyncDigest(dir); err == nil {
		t.Fatal("an invalid digest path must fail")
	}
}

func TestPollerRestoreRejectsReplacement(t *testing.T) {
	ctx := context.Background()
	poller := &batchv1.CronJob{
		ObjectMeta: metav1.ObjectMeta{Name: "poller", Namespace: "sync", UID: "original"},
	}
	client := fake.NewClientset(poller)
	_, restore, err := suspendPoller(ctx, client, "sync", "poller")
	if err != nil {
		t.Fatal(err)
	}
	if err := client.BatchV1().CronJobs("sync").Delete(ctx, "poller", metav1.DeleteOptions{}); err != nil {
		t.Fatal(err)
	}
	poller.UID = "replacement"
	poller.Spec.Suspend = boolPointer(true)
	if _, err := client.BatchV1().CronJobs("sync").Create(ctx, poller, metav1.CreateOptions{}); err != nil {
		t.Fatal(err)
	}
	if err := restore(ctx); err == nil {
		t.Fatal("cleanup must not change a replacement CronJob")
	}
}

func boolPointer(value bool) *bool {
	return &value
}
