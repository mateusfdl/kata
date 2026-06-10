package fixtures

// kata-expect: max-nesting
func deep(a, b, c, d bool) int {
	if a {
		if b {
			if c {
				if d {
					return 1
				}
			}
		}
	}
	return 2
}

func shallow(a bool) int {
	if a {
		return 1
	}
	return 2
}
