// kata-expect: no-runtime-type-checks
const equalsLeft = typeof value == "string";

// kata-expect: no-runtime-type-checks
const notEqualsLeft = typeof value != "number";

// kata-expect: no-runtime-type-checks
const strictEqualsLeft = typeof value === "boolean";

// kata-expect: no-runtime-type-checks
const strictNotEqualsLeft = typeof value !== "object";

// kata-expect: no-runtime-type-checks
const equalsRight = "string" == typeof value;

// kata-expect: no-runtime-type-checks
const notEqualsRight = "number" != typeof value;

// kata-expect: no-runtime-type-checks
const strictEqualsRight = "boolean" === typeof value;

// kata-expect: no-runtime-type-checks
const strictNotEqualsRight = "object" !== typeof value;

// kata-expect: no-runtime-type-checks
const templateLeft = typeof value === `string`;

// kata-expect: no-runtime-type-checks
const templateRight = `number` !== typeof value;

// kata-expect: no-runtime-type-checks
switch (typeof value) {
  case "string":
    run();
    break;
  default:
    break;
}

// kata-expect: no-runtime-type-checks
if (value instanceof Date) {
  run();
}

// kata-expect: no-runtime-type-checks
if ("kind" in value) {
  run();
}

// kata-expect: no-runtime-type-checks
if (Array.isArray(value)) {
  run();
}

const equality = first === second;
const contains = values.includes(value);
isReady(value);

for (const key in value) {
  run();
}

switch (value) {
  case "string":
    run();
    break;
  default:
    break;
}

try {
  run();
} catch (error) {
  if (error instanceof Error) {
    run();
  }
  if (typeof error === "string") {
    run();
  }
  if ("code" in error) {
    run();
  }
  if (Array.isArray(error)) {
    run();
  }
  switch (typeof error) {
    case "string":
      run();
      break;
    default:
      break;
  }
}
