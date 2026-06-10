package fixtures

type UserRepository struct{}

// kata-expect: simple-repositories
func (r *UserRepository) FindActive(a, b, c bool) int {
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
	return 5
}

type OrderService struct{}

func (s *OrderService) Create(a bool) int {
	if a {
		return 1
	}
	return 2
}
