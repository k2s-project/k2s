// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package poller

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/kubernetes"
)

func Suspend(ctx context.Context, client kubernetes.Interface, namespace, name string) (types.UID, func(context.Context) error, error) {
	poller, err := client.BatchV1().CronJobs(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		return "", nil, err
	}
	setSuspended := func(ctx context.Context, suspended *bool) error {
		patch, err := json.Marshal([]map[string]any{
			{"op": "test", "path": "/metadata/uid", "value": poller.UID},
			{"op": "add", "path": "/spec/suspend", "value": suspended},
		})
		if err != nil {
			return err
		}
		_, err = client.BatchV1().CronJobs(namespace).Patch(ctx, name, types.JSONPatchType, patch, metav1.PatchOptions{})
		return err
	}
	suspended := true
	if err := setSuspended(ctx, &suspended); err != nil {
		return "", nil, err
	}
	return poller.UID, func(ctx context.Context) error {
		return setSuspended(ctx, poller.Spec.Suspend)
	}, nil
}

func WaitForIdle(ctx context.Context, client kubernetes.Interface, namespace string, uid types.UID, idlePeriod, pollInterval time.Duration) error {
	if idlePeriod <= 0 {
		return fmt.Errorf("idle period must be positive")
	}
	if pollInterval <= 0 {
		return fmt.Errorf("poll interval must be positive")
	}

	var previousJobs map[types.UID]struct{}
	var idleSince time.Time
	for {
		idle, currentJobs, err := pollerStatus(ctx, client, namespace, uid)
		if err != nil {
			return err
		}
		now := time.Now()
		switch {
		case !idle:
			idleSince = time.Time{}
		case idleSince.IsZero() || hasNewJob(previousJobs, currentJobs):
			idleSince = now
		case now.Sub(idleSince) >= idlePeriod:
			return nil
		}
		previousJobs = currentJobs

		timer := time.NewTimer(pollInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
}

func pollerIsIdle(ctx context.Context, client kubernetes.Interface, namespace string, uid types.UID) (bool, error) {
	idle, _, err := pollerStatus(ctx, client, namespace, uid)
	return idle, err
}

func pollerStatus(ctx context.Context, client kubernetes.Interface, namespace string, uid types.UID) (bool, map[types.UID]struct{}, error) {
	jobs, err := client.BatchV1().Jobs(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return false, nil, err
	}
	ownedJobs := map[types.UID]struct{}{}
	idle := true
	for _, job := range jobs.Items {
		if owner := metav1.GetControllerOf(&job); owner == nil || owner.UID != uid {
			continue
		}
		ownedJobs[job.UID] = struct{}{}
		finished := false
		for _, condition := range job.Status.Conditions {
			if (condition.Type == batchv1.JobComplete || condition.Type == batchv1.JobFailed) && condition.Status == corev1.ConditionTrue {
				finished = true
				break
			}
		}
		if !finished {
			idle = false
		}
	}
	pods, err := client.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		return false, nil, err
	}
	for _, pod := range pods.Items {
		if owner := metav1.GetControllerOf(&pod); owner != nil {
			if _, owned := ownedJobs[owner.UID]; owned && pod.Status.Phase != corev1.PodSucceeded && pod.Status.Phase != corev1.PodFailed {
				idle = false
			}
		}
	}
	return idle, ownedJobs, nil
}

func hasNewJob(previous, current map[types.UID]struct{}) bool {
	for uid := range current {
		if _, seen := previous[uid]; !seen {
			return true
		}
	}
	return false
}

func ResetSyncDigest(path string) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect sync digest: %w", err)
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("sync digest is not a regular file: %s", path)
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("remove sync digest: %w", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		return fmt.Errorf("sync digest is not confirmed absent: %v", err)
	}
	return nil
}
