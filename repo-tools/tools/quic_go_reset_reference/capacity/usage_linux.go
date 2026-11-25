package main

// #include <unistd.h>
import "C"

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

func sampleUsage(pid int) (usage, error) {
	root := fmt.Sprintf("/proc/%d/", pid)
	st, err := os.ReadFile(root + "stat")
	if err != nil {
		return usage{}, err
	}
	// The name within parentheses may itself contain parentheses or whitespace.
	end := strings.LastIndexByte(string(st), ')')
	if end < 0 {
		return usage{}, fmt.Errorf("invalid process stat")
	}
	fields := strings.Fields(string(st[end+1:]))
	if len(fields) < 13 {
		return usage{}, fmt.Errorf("short process stat")
	}
	user, err := strconv.ParseUint(fields[11], 10, 64)
	if err != nil {
		return usage{}, err
	}
	system, err := strconv.ParseUint(fields[12], 10, 64)
	if err != nil {
		return usage{}, err
	}
	hz := C.sysconf(C._SC_CLK_TCK)
	if hz <= 0 {
		return usage{}, fmt.Errorf("invalid process clock frequency")
	}
	status, err := os.ReadFile(root + "status")
	if err != nil {
		return usage{}, err
	}
	u := usage{CPUSeconds: float64(user+system) / float64(hz), Kind: "scheduler wakeups unavailable"}
	for _, line := range strings.Split(string(status), "\n") {
		if strings.HasPrefix(line, "VmRSS:") {
			var kib int64
			if _, err = fmt.Sscan(strings.TrimPrefix(line, "VmRSS:"), &kib); err != nil {
				return usage{}, err
			}
			u.RSSBytes = kib * 1024
			break
		}
	}
	if u.RSSBytes == 0 {
		return usage{}, fmt.Errorf("process has no resident size")
	}
	// Linux exposes this optional counter per thread. Select the event loop
	// thread explicitly, without conflating context switches with wakeups.
	if b, err := os.ReadFile(root + "sched"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			key, val, ok := strings.Cut(line, ":")
			if ok && strings.TrimSpace(key) == "se.statistics.nr_wakeups" {
				w, err := strconv.ParseInt(strings.TrimSpace(val), 10, 64)
				if err != nil {
					return usage{}, err
				}
				u.Wakeups = &w
				u.Kind = "main thread sched se.statistics.nr_wakeups"
				break
			}
		}
	}
	return u, nil
}
