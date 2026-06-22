package fixtures

import "fmt"

func debug(id string) {
	// kata-expect: no-builtin-print
	println("id", id)
	// kata-expect: no-builtin-print
	print("done")
}

func report(id string) {
	fmt.Println(id)
}
