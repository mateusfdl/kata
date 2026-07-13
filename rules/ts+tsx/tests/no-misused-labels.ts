// kata-expect: no-misused-labels
retry: if (ready) {
  break retry;
}

// kata-expect: no-misused-labels
block: {
  run();
}

outer: for (let i = 0; i < 10; i++) {
  if (done(i)) {
    break outer;
  }
}

scan: while (next()) {
  continue scan;
}

choose: switch (value) {
  case 1:
    break choose;
}

// kata-expect: no-misused-labels
decl: function labeled() { return 1; }
