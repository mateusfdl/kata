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

function chained(a, b) {
  if (a) {
    return 1;
  } else if (b) {
    return 2;
  } else if (a) {
    return 3;
  } else if (b) {
    if (a) {
      return 4;
    }
  }
  return 5;
}
