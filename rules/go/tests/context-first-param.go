package fixtures

import "context"

// kata-expect: context-first-param
func fetch(id string, ctx context.Context) error {
	return ctx.Err()
}

func load(ctx context.Context, id string) error {
	_ = id
	return ctx.Err()
}
