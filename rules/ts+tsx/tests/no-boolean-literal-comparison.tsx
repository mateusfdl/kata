// kata-expect: no-boolean-literal-comparison
if (true && enabled) {
  render();
}

export function Component() {
  return <button disabled={enabled}>Run</button>;
}
