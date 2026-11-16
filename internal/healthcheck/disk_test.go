// SPDX-FileCopyrightText: © 2026 The K2s Authors
// SPDX-License-Identifier: Apache-2.0

package healthcheck_test

import (
	"errors"

	"github.com/k2s-project/k2s/internal/healthcheck"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
)

const gib = 1024 * 1024 * 1024

func fakeDiskInfo(infos map[string]healthcheck.DiskInfo) healthcheck.DiskInfoFunc {
	return func(path string) (healthcheck.DiskInfo, error) {
		info, found := infos[path]
		if !found {
			return healthcheck.DiskInfo{}, errors.New("path not found")
		}
		return info, nil
	}
}

var _ = Describe("disk space check", func() {
	It("passes when all volumes have enough free space", func() {
		check := healthcheck.NewDiskSpaceCheck([]string{"C:\\", "D:\\k2s"}, fakeDiskInfo(map[string]healthcheck.DiskInfo{
			"C:\\":    {VolumeID: "C:", FreeBytes: 50 * gib},
			"D:\\k2s": {VolumeID: "D:", FreeBytes: 100 * gib},
		}))

		result := runSingle(check)

		Expect(result.Name).To(Equal("host-disk-space"))
		Expect(result.Status).To(Equal(healthcheck.StatusPass))
		Expect(result.Message).To(Equal("C:\\: 50GiB free, D:\\k2s: 100GiB free"))
		Expect(result.Hint).To(BeEmpty())
	})

	It("evaluates paths on the same volume only once", func() {
		check := healthcheck.NewDiskSpaceCheck([]string{"C:\\", "C:\\k", "C:\\ProgramData\\K2s"}, fakeDiskInfo(map[string]healthcheck.DiskInfo{
			"C:\\":                 {VolumeID: "C:", FreeBytes: 50 * gib},
			"C:\\k":                {VolumeID: "C:", FreeBytes: 50 * gib},
			"C:\\ProgramData\\K2s": {VolumeID: "C:", FreeBytes: 50 * gib},
		}))

		result := runSingle(check)

		Expect(result.Status).To(Equal(healthcheck.StatusPass))
		Expect(result.Message).To(Equal("C:\\: 50GiB free"))
	})

	It("warns when a volume has less than 20 GiB free", func() {
		check := healthcheck.NewDiskSpaceCheck([]string{"C:\\", "D:\\k2s"}, fakeDiskInfo(map[string]healthcheck.DiskInfo{
			"C:\\":    {VolumeID: "C:", FreeBytes: 50 * gib},
			"D:\\k2s": {VolumeID: "D:", FreeBytes: 15 * gib},
		}))

		result := runSingle(check)

		Expect(result.Status).To(Equal(healthcheck.StatusWarn))
		Expect(result.Message).To(Equal("less than 20GiB free on D:\\k2s: 15GiB free"))
		Expect(result.Hint).To(ContainSubstring("k2s image rm"))
	})

	It("fails when a volume has less than 10 GiB free", func() {
		check := healthcheck.NewDiskSpaceCheck([]string{"C:\\", "D:\\k2s"}, fakeDiskInfo(map[string]healthcheck.DiskInfo{
			"C:\\":    {VolumeID: "C:", FreeBytes: 15 * gib},
			"D:\\k2s": {VolumeID: "D:", FreeBytes: 5 * gib},
		}))

		result := runSingle(check)

		Expect(result.Status).To(Equal(healthcheck.StatusFail))
		Expect(result.Message).To(Equal("less than 10GiB free on D:\\k2s: 5GiB free; less than 20GiB free on C:\\: 15GiB free"))
		Expect(result.Hint).To(ContainSubstring("Disk Pressure"))
	})

	It("reports all affected volumes when some are critical and others low or unreadable", func() {
		check := healthcheck.NewDiskSpaceCheck([]string{"C:\\", "D:\\k2s", "E:\\k2s", "X:\\missing"}, fakeDiskInfo(map[string]healthcheck.DiskInfo{
			"C:\\":    {VolumeID: "C:", FreeBytes: 15 * gib},
			"D:\\k2s": {VolumeID: "D:", FreeBytes: 5 * gib},
			"E:\\k2s": {VolumeID: "E:", FreeBytes: 50 * gib},
		}))

		result := runSingle(check)

		Expect(result.Status).To(Equal(healthcheck.StatusFail))
		Expect(result.Message).To(Equal("less than 10GiB free on D:\\k2s: 5GiB free; less than 20GiB free on C:\\: 15GiB free; " +
			"could not determine free disk space for X:\\missing (path not found)"))
	})

	It("treats exactly the threshold as enough free space", func() {
		check := healthcheck.NewDiskSpaceCheck([]string{"/"}, fakeDiskInfo(map[string]healthcheck.DiskInfo{
			"/": {VolumeID: "1", FreeBytes: healthcheck.LowFreeDiskBytes},
		}))

		Expect(runSingle(check).Status).To(Equal(healthcheck.StatusPass))
	})

	It("warns when free space of some paths cannot be determined", func() {
		check := healthcheck.NewDiskSpaceCheck([]string{"C:\\", "X:\\missing"}, fakeDiskInfo(map[string]healthcheck.DiskInfo{
			"C:\\": {VolumeID: "C:", FreeBytes: 50 * gib},
		}))

		result := runSingle(check)

		Expect(result.Status).To(Equal(healthcheck.StatusWarn))
		Expect(result.Message).To(Equal("C:\\: 50GiB free; could not determine free disk space for X:\\missing (path not found)"))
	})

	It("skips when free space cannot be determined for any path", func() {
		check := healthcheck.NewDiskSpaceCheck([]string{"X:\\missing"}, fakeDiskInfo(nil))

		result := runSingle(check)

		Expect(result.Status).To(Equal(healthcheck.StatusSkip))
		Expect(result.Message).To(Equal("could not determine free disk space for X:\\missing (path not found)"))
	})
})
