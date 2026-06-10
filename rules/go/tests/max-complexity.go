package fixtures

// kata-expect: max-complexity
func dispatch(a, b, c bool) int {
	if a {
		return 1
	}
	if b {
		return 2
	}
	if c {
		return 3
	}
	if a && b {
		return 4
	}
	if a || c {
		return 5
	}
	if b && c {
		return 6
	}
	if b || c {
		return 7
	}
	return 8
}

func simple(a int) int {
	return a
}
