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

async function run_1(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_1",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_1",
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
    // Another deliberate cast so the rule fires more than once per run_1.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_1", run_1);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_2(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_2",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_2",
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
    // Another deliberate cast so the rule fires more than once per run_2.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_2", run_2);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_3(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_3",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_3",
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
    // Another deliberate cast so the rule fires more than once per run_3.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_3", run_3);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_4(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_4",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_4",
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
    // Another deliberate cast so the rule fires more than once per run_4.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_4", run_4);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_5(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_5",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_5",
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
    // Another deliberate cast so the rule fires more than once per run_5.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_5", run_5);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_6(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_6",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_6",
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
    // Another deliberate cast so the rule fires more than once per run_6.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_6", run_6);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_7(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_7",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_7",
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
    // Another deliberate cast so the rule fires more than once per run_7.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_7", run_7);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_8(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_8",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_8",
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
    // Another deliberate cast so the rule fires more than once per run_8.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_8", run_8);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_9(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_9",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_9",
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
    // Another deliberate cast so the rule fires more than once per run_9.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_9", run_9);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_10(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_10",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_10",
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
    // Another deliberate cast so the rule fires more than once per run_10.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_10", run_10);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_11(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_11",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_11",
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
    // Another deliberate cast so the rule fires more than once per run_11.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_11", run_11);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_12(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_12",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_12",
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
    // Another deliberate cast so the rule fires more than once per run_12.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_12", run_12);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_13(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_13",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_13",
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
    // Another deliberate cast so the rule fires more than once per run_13.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_13", run_13);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_14(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_14",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_14",
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
    // Another deliberate cast so the rule fires more than once per run_14.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_14", run_14);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_15(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_15",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_15",
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
    // Another deliberate cast so the rule fires more than once per run_15.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_15", run_15);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_16(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_16",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_16",
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
    // Another deliberate cast so the rule fires more than once per run_16.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_16", run_16);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_17(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_17",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_17",
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
    // Another deliberate cast so the rule fires more than once per run_17.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_17", run_17);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_18(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_18",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_18",
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
    // Another deliberate cast so the rule fires more than once per run_18.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_18", run_18);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_19(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_19",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_19",
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
    // Another deliberate cast so the rule fires more than once per run_19.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_19", run_19);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_20(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_20",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_20",
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
    // Another deliberate cast so the rule fires more than once per run_20.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_20", run_20);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_21(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_21",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_21",
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
    // Another deliberate cast so the rule fires more than once per run_21.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_21", run_21);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_22(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_22",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_22",
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
    // Another deliberate cast so the rule fires more than once per run_22.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_22", run_22);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_23(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_23",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_23",
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
    // Another deliberate cast so the rule fires more than once per run_23.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_23", run_23);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_24(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_24",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_24",
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
    // Another deliberate cast so the rule fires more than once per run_24.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_24", run_24);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_25(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_25",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_25",
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
    // Another deliberate cast so the rule fires more than once per run_25.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_25", run_25);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_26(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_26",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_26",
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
    // Another deliberate cast so the rule fires more than once per run_26.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_26", run_26);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_27(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_27",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_27",
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
    // Another deliberate cast so the rule fires more than once per run_27.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_27", run_27);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_28(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_28",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_28",
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
    // Another deliberate cast so the rule fires more than once per run_28.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_28", run_28);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_29(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_29",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_29",
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
    // Another deliberate cast so the rule fires more than once per run_29.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_29", run_29);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

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

async function run_30(): Promise<void> {
  const repo = new InMemoryRepository<User>("id");
  await repo.insert({
    id: "u1_30",
    name: "Alice",
    email: "alice@example.com",
    roles: ["admin", "editor"],
    metadata: { source: "seed" },
  });
  await repo.insert({
    id: "u2_30",
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
    // Another deliberate cast so the rule fires more than once per run_30.
    const port = (cfgResult.value as any).port ?? 8080;
    console.log("port:", port);
  } else {
    console.error(cfgResult.error.message);
  }
}

const registry = new Map<string, (...args: any[]) => unknown>();
registry.set("run_30", run_30);

for (const [name, fn] of registry) {
  if (typeof fn === "function") {
    void Promise.resolve().then(() => fn()).catch((e) => {
      const code = (e as any).code;
      writeFileSync("/tmp/err.log", String(code ?? "x"));
    });
    console.log("scheduled:", name);
  }
}

