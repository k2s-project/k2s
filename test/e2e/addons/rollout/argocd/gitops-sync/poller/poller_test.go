// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package poller

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes/fake"
	k8stesting "k8s.io/client-go/testing"
)

var _ = Describe("scheduled poller isolation", Label("unit", "ci"), func() {
	It("restores the original suspension state", func() {
		for name, original := range map[string]*bool{"omitted": nil, "running": new(bool), "suspended": boolPointer(true)} {
			By(fmt.Sprintf("preserving the %s suspension value", name))
			ctx := context.Background()
			poller := &batchv1.CronJob{
				ObjectMeta: metav1.ObjectMeta{Name: "poller", Namespace: "sync", UID: "poller-uid"},
				Spec:       batchv1.CronJobSpec{Suspend: original},
			}
			client := fake.NewClientset(poller)
			uid, restore, err := Suspend(ctx, client, "sync", "poller")
			Expect(err).NotTo(HaveOccurred())
			Expect(uid).To(Equal(poller.UID))

			current, err := client.BatchV1().CronJobs("sync").Get(ctx, "poller", metav1.GetOptions{})
			Expect(err).NotTo(HaveOccurred())
			Expect(current.Spec.Suspend).NotTo(BeNil())
			Expect(*current.Spec.Suspend).To(BeTrue())

			Expect(restore(ctx)).To(Succeed())
			current, err = client.BatchV1().CronJobs("sync").Get(ctx, "poller", metav1.GetOptions{})
			Expect(err).NotTo(HaveOccurred())
			if original == nil {
				Expect(current.Spec.Suspend).To(BeNil())
			} else {
				Expect(current.Spec.Suspend).NotTo(BeNil())
				Expect(*current.Spec.Suspend).To(Equal(*original))
			}
		}
	})

	It("waits for owned Jobs and Pods to finish", func() {
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
			idle, err := pollerIsIdle(ctx, client, "sync", "poller-uid")
			Expect(err).NotTo(HaveOccurred())
			Expect(idle).To(Equal(expected))
		}
		expectIdle(false)
		job.Status.Conditions = []batchv1.JobCondition{{Type: batchv1.JobFailed, Status: corev1.ConditionTrue}}
		_, err := client.BatchV1().Jobs("sync").UpdateStatus(ctx, job, metav1.UpdateOptions{})
		Expect(err).NotTo(HaveOccurred())
		expectIdle(false)
		pod.Status.Phase = corev1.PodFailed
		_, err = client.CoreV1().Pods("sync").UpdateStatus(ctx, pod, metav1.UpdateOptions{})
		Expect(err).NotTo(HaveOccurred())
		expectIdle(true)
	})

	It("restarts the idle interval when a delayed owned Job appears", func() {
		ctx := context.Background()
		controller := true
		job := batchv1.Job{
			ObjectMeta: metav1.ObjectMeta{
				Name: "delayed", Namespace: "sync", UID: "delayed-job-uid",
				OwnerReferences: []metav1.OwnerReference{{UID: "poller-uid", Controller: &controller}},
			},
			Status: batchv1.JobStatus{Conditions: []batchv1.JobCondition{{Type: batchv1.JobComplete, Status: corev1.ConditionTrue}}},
		}
		client := fake.NewClientset()
		var listCalls atomic.Int32
		var appearedAt time.Time
		client.PrependReactor("list", "jobs", func(k8stesting.Action) (bool, runtime.Object, error) {
			if listCalls.Add(1) == 1 {
				return true, &batchv1.JobList{}, nil
			}
			if appearedAt.IsZero() {
				appearedAt = time.Now()
			}
			return true, &batchv1.JobList{Items: []batchv1.Job{job}}, nil
		})

		idlePeriod := 40 * time.Millisecond
		err := WaitForIdle(ctx, client, "sync", types.UID("poller-uid"), idlePeriod, 2*time.Millisecond)
		Expect(err).NotTo(HaveOccurred())
		Expect(listCalls.Load()).To(BeNumerically(">=", 2))
		Expect(time.Since(appearedAt)).To(BeNumerically(">=", idlePeriod))
	})

	It("does not treat API errors as idle", func() {
		client := fake.NewClientset()
		client.PrependReactor("list", "jobs", func(k8stesting.Action) (bool, runtime.Object, error) {
			return true, nil, fmt.Errorf("access denied")
		})
		idle, err := pollerIsIdle(context.Background(), client, "sync", "poller-uid")
		Expect(err).To(MatchError("access denied"))
		Expect(idle).To(BeFalse())
	})

	It("rejects failed digest removal", func() {
		dir := GinkgoT().TempDir()
		digest := filepath.Join(dir, "metrics")
		Expect(os.WriteFile(digest, []byte("old-digest"), 0600)).To(Succeed())
		Expect(ResetSyncDigest(digest)).To(Succeed())
		Expect(ResetSyncDigest(digest)).To(Succeed())
		Expect(os.WriteFile(filepath.Join(dir, "keep"), []byte("not a digest"), 0600)).To(Succeed())
		Expect(ResetSyncDigest(dir)).To(MatchError(ContainSubstring("not a regular file")))
	})

	It("does not restore suspension onto a replacement CronJob", func() {
		ctx := context.Background()
		poller := &batchv1.CronJob{
			ObjectMeta: metav1.ObjectMeta{Name: "poller", Namespace: "sync", UID: "original"},
		}
		client := fake.NewClientset(poller)
		_, restore, err := Suspend(ctx, client, "sync", "poller")
		Expect(err).NotTo(HaveOccurred())
		Expect(client.BatchV1().CronJobs("sync").Delete(ctx, "poller", metav1.DeleteOptions{})).To(Succeed())
		poller.UID = "replacement"
		poller.Spec.Suspend = boolPointer(true)
		_, err = client.BatchV1().CronJobs("sync").Create(ctx, poller, metav1.CreateOptions{})
		Expect(err).NotTo(HaveOccurred())
		Expect(restore(ctx)).To(HaveOccurred())
	})
})

func boolPointer(value bool) *bool {
	return &value
}
