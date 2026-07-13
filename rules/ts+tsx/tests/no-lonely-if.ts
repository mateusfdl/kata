if (a) {
  first();
// kata-expect: no-lonely-if
} else { if (b) { second(); } }

if (c) {
  third();
} else {
  fourth();
  if (d) {
    fifth();
  }
}

if (e) {
  sixth();
} else if (f) {
  seventh();
}
