package fixtures

func boom(id string) {
	// kata-expect: no-panic
	panic("boom")
}

func safe(id string) error {
	return nil
}
