// kata-expect: no-nested-ternary
const a = c1 ? v1 : c2 ? v2 : v3;

// kata-expect: no-nested-ternary
const b = c1 ? c2 ? v1 : v2 : v3;

// kata-expect: no-nested-ternary
const c = (c1 ? v1 : v2) ? v3 : v4;

// kata-expect: no-nested-ternary
const d = c1 ? (c2 ? v1 : v2) : v3;

// kata-expect: no-nested-ternary, no-nested-ternary
const e = c1 ? (c2 ? v1 : v2) : (c3 ? v3 : v4);

const f = c1 ? v1 : v2;
