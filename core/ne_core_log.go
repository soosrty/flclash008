//go:build ios && cgo

package main

import (
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	neCoreLogMaxSize = 1 << 20 // 1MB
)

var (
	neCoreLogMu       sync.Mutex
	neCoreLogRotated  bool
)

// neCoreFileLog appends NE-side core logs to <home-dir>/ne-core.log so that
// Network Extension failures can be diagnosed directly from the device.
func neCoreFileLog(level, message string) {
	neCoreLogMu.Lock()
	defer neCoreLogMu.Unlock()
	homeDir := os.Getenv("CLASH_HOME_DIR")
	if homeDir == "" {
		return
	}
	logPath := filepath.Join(homeDir, "ne-core.log")
	if st, err := os.Stat(logPath); err == nil {
		if st.Size() > neCoreLogMaxSize {
			os.Remove(logPath)
		}
	}
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	ts := time.Now().Format("2006-01-02T15:04:05.000")
	f.WriteString(ts + " [" + level + "] " + message + "\n")
}
