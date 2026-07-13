// kata-expect: no-misused-labels
retry: if (ready) {
  break retry;
}

export function Component() {
  return <button>Run</button>;
}

outer: for (let i = 0; i < 10; i++) {
  if (done(i)) {
    break outer;
  }
}
