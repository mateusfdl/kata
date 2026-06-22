package fixtures

// kata-expect: no-init-func
func init() {
	configure()
}

func NewThing() int {
	return 1
}

func configure() {}
