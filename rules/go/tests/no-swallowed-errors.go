package fixtures

func send() (int, error) { return 0, nil }

func swallow() {
	// kata-expect: no-swallowed-errors
	n, _ := send()
	_ = n
}

func handle() error {
	n, err := send()
	_ = n
	return err
}

func handleDiscardingValue() error {
	_, err := send()
	return err
}
