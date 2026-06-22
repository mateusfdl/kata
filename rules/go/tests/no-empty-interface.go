package fixtures

// kata-expect: no-empty-interface
func accept(v any) {
	_ = v
}

// kata-expect: no-empty-interface
func produce() any {
	return nil
}

type Holder struct {
	// kata-expect: no-empty-interface
	value any
}

func declare() {
	// kata-expect: no-empty-interface
	var x any
	_ = x
	// kata-expect: no-empty-interface
	var y interface{}
	_ = y
}

func generic[T any](v T) T {
	return v
}
