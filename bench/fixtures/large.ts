// Realistic-ish TypeScript file. Mix of clean code and occasional `as any`
// casts so the engine has actual matches to report alongside plenty of
// unrelated AST nodes.

import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

type Result<T, E = Error> =
  | { ok: true; value: T }
  | { ok: false; error: E };

interface User {
  id: string;
  name: string;
  email: string;
  roles: ReadonlyArray<Role>;
  metadata: Record<string, unknown>;
}

type Role = "admin" | "editor" | "viewer";

interface Repository<T, K extends keyof T = "id" & keyof T> {
  findBy(key: K, value: T[K]): Promise<T | null>;
  list(predicate?: (item: T) => boolean): Promise<T[]>;
  insert(item: T): Promise<void>;
  update(key: K, value: T[K], patch: Partial<T>): Promise<T>;
  remove(key: K, value: T[K]): Promise<boolean>;
}

class InMemoryRepository<T extends Record<string, unknown>, K extends keyof T = "id" & keyof T>
  implements Repository<T, K>
{
  private rows: T[] = [];

  constructor(private readonly primary: K) {}

  async findBy(key: K, value: T[K]): Promise<T | null> {
    const hit = this.rows.find((row) => row[key] === value);
    return hit ?? null;
  }

  async list(predicate?: (item: T) => boolean): Promise<T[]> {
    if (!predicate) return [...this.rows];
    return this.rows.filter(predicate);
  }

  async insert(item: T): Promise<void> {
    const existing = await this.findBy(this.primary, item[this.primary]);
    if (existing) throw new Error("duplicate primary key");
    this.rows.push(item);
  }

  async update(key: K, value: T[K], patch: Partial<T>): Promise<T> {
    const idx = this.rows.findIndex((row) => row[key] === value);
    if (idx === -1) throw new Error("not found");
    const next = { ...this.rows[idx], ...patch } as T;
    this.rows[idx] = next;
    return next;
  }

  async remove(key: K, value: T[K]): Promise<boolean> {
    const idx = this.rows.findIndex((row) => row[key] === value);
    if (idx === -1) return false;
    this.rows.splice(idx, 1);
    return true;
  }
}

function ok<T>(value: T): Result<T> {
  return { ok: true, value };
}

function err<E extends Error = Error>(error: E): Result<never, E> {
  return { ok: false, error };
}

async function loadConfig(path: string): Promise<Result<Record<string, unknown>>> {
  try {
    const raw = readFileSync(resolve(path), "utf8");
    const parsed = JSON.parse(raw);
    // Validation would go here in a real app.
    return ok(parsed as Record<string, unknown>);
  } catch (e) {
    // Intentional: force cast to exercise the rule.
    const message = (e as any).message ?? "unknown";
    return err(new Error(message));
  }
}

function pickRoles(user: User): Role[] {
  const roles: Role[] = [];
  for (const r of user.roles) {
    roles.push(r);
  }
  return roles;
}

function isAdmin(user: User): boolean {
  return user.roles.includes("admin");
}

function assertExhaustive(_: never): never {
  throw new Error("non-exhaustive");
}

function describe(role: Role): string {
  switch (role) {
    case "admin":
      return "administrator";
    case "editor":
      return "editor";
    case "viewer":
      return "viewer";
    default:
      return assertExhaustive(role);
  }
}

async function run(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2",
    name: "Bob",
    email: "bob@example.com",
    roles: ["viewer"],
    metadata: {},
  });

  const admins = await repo.list(isAdmin);
  for (const admin of admins) {
    const tags = pickRoles(admin).map(describe);
    console.log(admin.name, tags.join(","));
  }

  const cfgResult = await loadConfig(join(process.cwd(), "config.json"));
  if (cfgResult.ok) {
    // Another deliberate cast so the rule fires more than once per run.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run", run);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}
