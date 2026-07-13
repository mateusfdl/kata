function fail(message) {
  // kata-expect: no-generic-error
  throw new Error(message);
}

function domainFail(message) {
  throw new NotFoundError(message);
}

function rethrow(error) {
  throw error;
}
