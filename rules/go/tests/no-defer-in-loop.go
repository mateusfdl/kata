package fixtures

func process(items []int) {
	for _, item := range items {
		_ = item
		// kata-expect: no-defer-in-loop
		defer cleanup()
	}
}

func once() {
	defer cleanup()
}

func cleanup() {}
