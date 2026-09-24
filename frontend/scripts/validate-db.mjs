#!/usr/bin/env node
/**
 * Local backend validator - runs the real PostgreSQL engine (PGlite, WASM) in
 * Node so the migrations and the verification suite can be executed without a
 * Supabase project, Docker or a local PostgreSQL install.
 *
 *   npm run validate:db
 *
 * What it does
 *   1. Creates a Supabase-shaped PostgreSQL environment: the `anon`,
 *      `authenticated` and `service_role` roles, the `auth` schema with a
 *      `users` table and the real `auth.uid()` / `auth.role()` definitions that
 *      read `request.jwt.claims`.
 *   2. Applies every file in supabase/migrations in filename order.
 *   3. Runs the SQL suite in supabase/tests and prints the per-assertion log.
 *
 * Faithfulness notes (read before trusting the output)
 *   * PGlite is genuine PostgreSQL (the same server code Supabase runs)
 *     compiled to WebAssembly, so constraint, trigger, RLS and plpgsql
 *     behaviour is real, not simulated.
 *   * The `auth` schema is a faithful stub. Supabase owns the real one; the
 *     columns used here are the ones the migrations and tests reference.
 *   * `pg_trgm` is a contrib extension. When PGlite cannot load it the three
 *     trigram indexes are skipped and reported - they are search accelerators,
 *     not correctness constraints.
 *   * Supabase-specific plumbing (PostgREST, GoTrue, Storage, Realtime) is not
 *     part of this check.
 */
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const migrationsDir = path.join(root, 'supabase', 'migrations');
const testsDir = path.join(root, 'supabase', 'tests');

const colours = process.stdout.isTTY
  ? {
      green: (s) => `\u001b[32m${s}\u001b[0m`,
      red: (s) => `\u001b[31m${s}\u001b[0m`,
      yellow: (s) => `\u001b[33m${s}\u001b[0m`,
      dim: (s) => `\u001b[2m${s}\u001b[0m`,
      bold: (s) => `\u001b[1m${s}\u001b[0m`,
    }
  : {
      green: (s) => s,
      red: (s) => s,
      yellow: (s) => s,
      dim: (s) => s,
      bold: (s) => s,
    };

/**
 * Supabase-shaped environment. `auth.uid()` and `auth.role()` mirror the
 * definitions Supabase ships, so RLS behaves exactly as it does in production.
 */
const SUPABASE_STUB = `
CREATE ROLE anon NOLOGIN NOINHERIT;
CREATE ROLE authenticated NOLOGIN NOINHERIT;
CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;

CREATE SCHEMA auth;

CREATE TABLE auth.users (
  id uuid PRIMARY KEY,
  instance_id uuid,
  aud text,
  role text,
  email text,
  encrypted_password text,
  email_confirmed_at timestamptz,
  raw_app_meta_data jsonb,
  raw_user_meta_data jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE AS $fn$
  SELECT NULLIF(
    COALESCE(
      current_setting('request.jwt.claim.sub', true),
      (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    ), ''
  )::uuid
$fn$;

CREATE FUNCTION auth.role() RETURNS text
LANGUAGE sql STABLE AS $fn$
  SELECT NULLIF(
    COALESCE(
      current_setting('request.jwt.claim.role', true),
      (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
    ), ''
  )
$fn$;

CREATE FUNCTION auth.jwt() RETURNS jsonb
LANGUAGE sql STABLE AS $fn$
  SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb)
$fn$;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT SELECT ON auth.users TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.role() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.jwt() TO anon, authenticated, service_role;
`;

/** Extensions PGlite may not ship; skipped loudly, never silently.
 *  pgcrypto: only needed for gen_random_uuid() before PostgreSQL 13. Supabase
 *  runs 15+, where the function is built in, so skipping it changes nothing.
 *  pg_trgm: powers the product/supplier/customer name search indexes. */
const OPTIONAL_EXTENSIONS = ['pgcrypto', 'pg_trgm'];
const skipped = [];

function log(step, message) {
  process.stdout.write(`${colours.dim(`[${step}]`)} ${message}\n`);
}

async function loadSql(file) {
  return readFile(file, 'utf8');
}

function reportSqlError(label, sql, error) {
  process.stdout.write('\n');
  process.stdout.write(colours.red(`${label}\n`));
  process.stdout.write(`${error.message}\n`);
  if (error.detail) process.stdout.write(`detail: ${error.detail}\n`);
  if (error.hint) process.stdout.write(`hint:   ${error.hint}\n`);
  if (error.where) process.stdout.write(`where:  ${error.where}\n`);
  if (typeof error.position === 'number' && error.position > 0) {
    const before = sql.slice(0, error.position - 1);
    const line = before.split('\n').length;
    const column = error.position - before.lastIndexOf('\n');
    process.stdout.write(colours.dim(`position: line ${line}, column ${column}\n`));
    const from = Math.max(0, error.position - 120);
    const to = Math.min(sql.length, error.position + 120);
    process.stdout.write(
      colours.dim(`${sql.slice(from, to).replace(/\n/g, '\n          ')}\n`),
    );
  }
}

async function main() {
  const db = new PGlite();

  log('1/4', 'Booting PostgreSQL (PGlite, in-memory)...');
  await db.exec(SUPABASE_STUB);

  const available = new Set();
  for (const ext of OPTIONAL_EXTENSIONS) {
    try {
      await db.exec(`CREATE EXTENSION IF NOT EXISTS ${ext};`);
      available.add(ext);
    } catch {
      log('   ', colours.yellow(
        `extension "${ext}" is unavailable in this build - related indexes will be skipped`,
      ));
    }
  }

  log('2/4', 'Applying migrations...');
  const files = (await readdir(migrationsDir)).filter((f) => f.endsWith('.sql')).sort();
  if (files.length === 0) throw new Error('no migrations found in supabase/migrations');

  for (const file of files) {
    let sql = await loadSql(path.join(migrationsDir, file));

    for (const ext of OPTIONAL_EXTENSIONS) {
      if (available.has(ext)) continue;
      sql = sql.replace(
        new RegExp(`CREATE EXTENSION IF NOT EXISTS ${ext}\\s*;`, 'gi'),
        `-- skipped by validate-db.mjs: ${ext} unavailable`,
      );
      // pg_trgm is the only one with dependent objects (GIN trigram indexes).
      if (ext !== 'pg_trgm') continue;
      sql = sql.replace(
        /CREATE INDEX [^;]*USING gin \([^;]*gin_trgm_ops[^;]*;\s*/gi,
        (match) => {
          const name = /CREATE INDEX (\S+)/i.exec(match)?.[1] ?? 'unknown';
          skipped.push(`${file}: index ${name} (needs ${ext})`);
          return `-- skipped by validate-db.mjs: needs ${ext}\n`;
        },
      );
    }

    const started = Date.now();
    try {
      await db.exec(sql);
      log('   ', `${file} ${colours.dim(`${Date.now() - started}ms`)}`);
    } catch (error) {
      reportSqlError(`Migration failed: ${file}`, sql, error);
      await db.exec('ROLLBACK;').catch(() => {});
      await db.close();
      process.exit(1);
    }
  }

  log('3/4', 'Running the SQL test suite...');
  const suite = (await readdir(testsDir)).filter((f) => f.endsWith('.sql')).sort();
  let failed = false;

  for (const file of suite) {
    let sql = await loadSql(path.join(testsDir, file));
    // The suite ends with ROLLBACK so an operator can run it by hand and leave
    // nothing behind. Here the rollback is deferred until the log is collected.
    sql = sql.replace(/\bROLLBACK\s*;\s*$/i, '');

    const started = Date.now();
    try {
      await db.exec(sql);
      log('   ', `${file} ${colours.dim(`${Date.now() - started}ms`)}`);
    } catch (error) {
      failed = true;
      reportSqlError(`Test suite failed: ${file}`, sql, error);
    }

    const report = await db
      .query('SELECT seq, name, status, detail FROM ksm_test.results ORDER BY seq')
      .catch(() => null);

    if (report && report.rows.length > 0) {
      process.stdout.write('\n');
      for (const row of report.rows) {
        const mark = row.status === 'pass' ? colours.green('PASS') : colours.red('FAIL');
        const detail = row.detail ? colours.dim(` - ${row.detail}`) : '';
        process.stdout.write(`  ${mark}  ${row.name}${detail}\n`);
      }
      const passed = report.rows.filter((r) => r.status === 'pass').length;
      process.stdout.write(
        `\n  ${colours.bold(`${passed}/${report.rows.length} assertions passed`)}\n`,
      );
    }

    // Abandon every test identity, store and ledger row.
    await db.exec('ROLLBACK;').catch(() => {});
  }

  log('4/4', 'Done.');
  if (skipped.length > 0) {
    process.stdout.write('\n');
    process.stdout.write(colours.yellow('Skipped in this environment:\n'));
    for (const item of skipped) process.stdout.write(`  - ${item}\n`);
  }

  await db.close();
  process.exit(failed ? 1 : 0);
}

main().catch((error) => {
  process.stdout.write(colours.red(`validate-db crashed: ${error.stack}\n`));
  process.exit(1);
});