class UserRepository {
  // kata-expect: simple-repositories
  findActive(a, b, c) {
    if (a) { return 1; }
    if (b) { return 2; }
    if (c) { return 3; }
    if (a && b) { return 4; }
    return 5;
  }
}

class OrderService {
  create(a, b, c) {
    if (a) { return 1; }
    if (b) { return 2; }
    if (c) { return 3; }
    if (a && b) { return 4; }
    return 5;
  }
}
