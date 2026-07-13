package fixtures

import (
	"errors"
	"fmt"
)

// kata-expect: error-strings
var ErrBad = errors.New("Bad thing happened")

// kata-expect: error-strings
var ErrRaw = errors.New(`Raw bad thing`)

func loadCapitalized(id string) error {
	// kata-expect: error-strings
	return fmt.Errorf("Loading user %s failed", id)
}

func loadLowercase(id string) error {
	if id == "" {
		return errors.New("empty id")
	}
	return fmt.Errorf("loading user %s failed", id)
}
