// kata-expect: max-complexity
function dispatch(a, b, c) {
  if (a) { return 1; }
  if (b) { return 2; }
  if (c) { return 3; }
  if (a && b) { return 4; }
  if (a || c) { return 5; }
  if (b && c) { return 6; }
  if (b || c) { return 7; }
  return 8;
}

function simple(a) {
  return a;
}

function outer(a, b, c) {
  // kata-expect: max-complexity
  function nested(x, y, z) {
    if (x) { return 1; }
    if (y) { return 2; }
    if (z) { return 3; }
    if (x && y) { return 4; }
    if (x || z) { return 5; }
    if (y && z) { return 6; }
    if (y || z) { return 7; }
    return 8;
  }
  return nested(a, b, c);
}
