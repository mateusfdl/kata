function make() {
  // kata-expect: no-return-promise-resolve
  return Promise.resolve(5);
}

function plain() {
  return 5;
}
