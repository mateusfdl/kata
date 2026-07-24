package fixtures

import "sync"

var mu sync.RWMutex

func paired() {
	mu.Lock()
	work()
	mu.Unlock()
}

func deferred() {
	mu.Lock()
	defer mu.Unlock()
	work()
}

func readPaired() {
	mu.RLock()
	work()
	mu.RUnlock()
}

func leaked() {
	// kata-expect: unlock-follows-lock
	mu.Lock()
	work()
}

func trailing() {
	// kata-expect: unlock-follows-lock
	mu.Lock()
}

func unlockedBefore() {
	mu.Unlock()
	// kata-expect: unlock-follows-lock
	mu.Lock()
}

func unlockedInClosure() {
	// kata-expect: unlock-follows-lock
	mu.Lock()
	go func() {
		mu.Unlock()
	}()
}

func unlockedInNestedBlock() {
	// kata-expect: unlock-follows-lock
	mu.Lock()
	if ready() {
		mu.Unlock()
	}
}

func separateBlocks() {
	if ready() {
		// kata-expect: unlock-follows-lock
		mu.Lock()
	}
	mu.Unlock()
}

func work() {}

func ready() bool { return true }
