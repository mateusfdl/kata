package fixtures

func process(items []int) {
	for _, item := range items {
		_ = item
		// kata-expect: no-defer-in-loop
		defer cleanup()
	}
}

func guarded(items []int, verbose bool) {
	for _, item := range items {
		_ = item
		if verbose {
			// kata-expect: no-defer-in-loop
			defer cleanup()
		}
	}
}

func spawned(items []int) {
	for _, item := range items {
		_ = item
		fn := func() {
			defer cleanup()
		}
		fn()
	}
}

func insideClosure(items []int) func() {
	return func() {
		for _, item := range items {
			_ = item
			// kata-expect: no-defer-in-loop
			defer cleanup()
		}
	}
}

func once() {
	defer cleanup()
}

func cleanup() {}
