//go:build !darwin && !linux

package main

import "fmt"

func sampleUsage(pid int) (usage, error) {
	return usage{}, fmt.Errorf("process accounting requires Darwin or Linux")
}
