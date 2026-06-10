// kata-expect: max-nesting
function deep(a, b, c, d) {
  if (a) {
    if (b) {
      if (c) {
        if (d) {
          return 1;
        }
      }
    }
  }
  return 2;
}

function shallow(a) {
  if (a) {
    return 1;
  }
  return 2;
}
