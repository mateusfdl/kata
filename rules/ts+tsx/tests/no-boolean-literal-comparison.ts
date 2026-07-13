// kata-expect: no-boolean-literal-comparison
if (someValue == true) {
  run();
}

// kata-expect: no-boolean-literal-comparison
if (false || enabled()) {
  run();
}

// kata-expect: no-boolean-literal-comparison
call(!false);

if (enabled()) {
  run();
}

// kata-expect: no-boolean-literal-comparison
const strict = value === true;

// kata-expect: no-boolean-literal-comparison
const strictNe = value !== false;

const ok = enabled();
