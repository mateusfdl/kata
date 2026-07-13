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

// kata-expect: max-nesting
func switchDeep(a, b, c bool, v int) int {
	if a {
		if b {
			switch v {
			case 1:
				if c {
					return 1
				}
			}
		}
	}
	return 2
}
