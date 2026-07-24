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

func spawn(ctx context.Context) (Runner, context.Context, context.CancelFunc, error) {
	child, cancel := context.WithCancel(ctx)
	return Runner{}, child, cancel, nil
}

type Runner struct{}

// kata-expect: context-first-param
func (r Runner) Run(id string, ctx context.Context) error {
	return ctx.Err()
}

func (r Runner) Wait(ctx context.Context, id string) error {
	_ = id
	return ctx.Err()
}

// kata-expect: context-first-param
var handleLate = func(id string, ctx context.Context) error {
	return ctx.Err()
}

var respond = func(ctx context.Context, id string) error {
	_ = id
	return ctx.Err()
}

// kata-expect: context-first-param
type Callback func(id string, ctx context.Context) error

type Notifier func(ctx context.Context, id string) error

type Dispatcher interface {
	// kata-expect: context-first-param
	Dispatch(id string, ctx context.Context) error
	Cancel(ctx context.Context, id string) error
}
