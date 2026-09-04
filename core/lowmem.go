//go:build with_low_memory

package main

import "runtime/debug"

// iOS Network Extension is memory constrained, but xhttp+REALITY needs
// more headroom than the old 32 MiB limit. Keep a soft limit below typical
// extension budgets without forcing the Go runtime into constant GC cycles.
const lowMemoryLimit = 96 * 1024 * 1024

func init() {
	debug.SetMemoryLimit(lowMemoryLimit)
}
