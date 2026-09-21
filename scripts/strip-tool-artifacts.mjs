#!/usr/bin/env node
/**
 * One-off repair utility. Some files in this repository were saved with an
 * editor's bookkeeping tail appended, e.g.
 *
 *     COMMIT;
 *     </content>
 *     <task_progress>
 *     - [x] ...
 *     </task_progress>
 *
 * In a .sql file that is a syntax error, and it made several migrations
 * impossible to run in the Supabase SQL Editor. This script truncates every
 * affected file at the first marker and normalises the trailing newline.
 *
 *   node scripts/strip-tool-artifacts.mjs          # report only
 *   node scripts/strip-tool-artifacts.mjs --write   # apply
 */
import { readdir, readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');

const TARGETS = [
  path.join(root, 'supabase', 'migrations'),
  path.join(root, 'supabase', 'tests'),
  path.join(root, 'supabase', 'docs'),
];
const EXTRA_FILES = [path.join(root, 'supabase', 'README.md')];

const MARKERS = ['</content>', '<task_progress>', '</write_to_file>'];
const write = process.argv.includes('--write');

async function collectFiles(dir) {
  const entries = await readdir(dir, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) files.push(...(await collectFiles(full)));
    else if (/\.(sql|md)$/i.test(entry.name)) files.push(full);
  }
  return files;
}

async function main() {
  const files = [...EXTRA_FILES];
  for (const dir of TARGETS) files.push(...(await collectFiles(dir)));

  let repaired = 0;
  for (const file of files) {
    const original = await readFile(file, 'utf8');
    const cuts = MARKERS.map((m) => original.indexOf(m)).filter((i) => i >= 0);
    if (cuts.length === 0) continue;

    const cut = Math.min(...cuts);
    const cleaned = `${original.slice(0, cut).replace(/\s+$/, '')}\n`;

    repaired += 1;
    process.stdout.write(
      `${write ? 'fixed  ' : 'found  '}${path.relative(root, file)} (${original.length - cleaned.length} trailing characters)\n`,
    );
    if (write) await writeFile(file, cleaned, 'utf8');
  }

  process.stdout.write(
    `\n${repaired} file(s) ${write ? 'repaired' : 'need repair'}.${write ? '' : ' Re-run with --write.'}\n`,
  );
}

main().catch((error) => {
  process.stderr.write(`${error.stack}\n`);
  process.exit(1);
});
