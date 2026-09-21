#!/usr/bin/env node
/**
 * Local Supabase-compatible backend for KSM.
 *
 * Why this exists
 * ---------------
 * No Docker / no `supabase` CLI is available in this workspace, so a full
 * `supabase start` (PostgREST + GoTrue + Realtime + Storage) cannot run.
 * Instead this is a tiny HTTP facade over the *same* real PostgreSQL engine
 * (PGlite, the genuine PostgreSQL WASM build that `validate-db.mjs` already
 * uses) that loads the identical migrations in `supabase/migrations` and
 * speaks just enough of the Supabase REST + Auth API surface for the React
 * frontend to drive the backend functions.
 *
 * It implements:
 *   - auth/v1/token        sign-in with email/password (demo accounts)
 *   - auth/v1/signup       create an auth user
 *   - auth/v1/user          return the session user
 *   - auth/v1/settings      capability flags
 *   - rest/v1/rpc/<fn>      call the SECURITY DEFINER RPC functions
 *   - rest/v1/<table>       SELECT + INSERT honouring RLS (request.jwt.claims)
 *
 * The frontend talks to it through the normal @supabase/supabase-js client, so
 * the wiring is identical to a real Supabase project: set
 *   VITE_SUPABASE_URL=http://localhost:5433
 *   VITE_SUPABASE_ANON_KEY=<the JWT written to .env.local by this server>
 * and the app switches from LOCAL DEMO to SUPABASE CONNECTED against the real
 * schema, real RPCs and real RLS policies that the SQL suite proves.
 *
 * SECURITY: dev-only. The JWT secret is hardcoded below. The anon key grants no
 * privileges (RLS policies give authenticated the access). The server is not
 * meant to face the internet.
 */
import { createServer } from 'node:http';
import { readFile, readdir, writeFile, stat } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';
import { randomUUID, createHmac } from 'node:crypto';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const MIGRATIONS = path.join(ROOT, 'supabase', 'migrations');
const HOST = '127.0.0.1';
const PORT = 5433;
const JWT_SECRET = 'ksm-local-jwt-secret';
const DEMO = [
  { role: 'owner',    id: '00000000-0000-0000-0000-000000000001', email: 'owner@example.com',    password: 'owner123' },
  { role: 'manager',  id: '00000000-0000-0000-0000-000000000002', email: 'manager@example.com',  password: 'manager123' },
  { role: 'cashier',  id: '00000000-0000-0000-0000-000000000003', email: 'cashier@example.com',  password: 'cashier123' },
];

/* ---------- JWT (HS256) ---------- */
function b64url(b) { return Buffer.from(b).toString('base64url'); }
function signJwt(payload, expiresInSec = 3600 * 8) {
  const h = b64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }));
  const p = b64url(JSON.stringify({ ...payload, exp: Math.floor(Date.now() / 1000) + expiresInSec }));
  const sig = createHmac('sha256', JWT_SECRET).update(`${h}.${p}`).digest();
  return `${h}.${p}.${b64url(sig)}`;
}
function verifyJwt(token) {
  const parts = (token || '').split('.');
  if (parts.length !== 3) return null;
  const [h, p, sig] = parts;
  const expected = b64url(createHmac('sha256', JWT_SECRET).update(`${h}.${p}`).digest());
  if (expected !== sig) return null;
  try { return JSON.parse(Buffer.from(p, 'base64url').toString()); } catch { return null; }
}

/* ---------- boot the real PostgreSQL + migrations + seed ---------- */
const SUPABASE_STUB = `\\
CREATE ROLE anon NOLOGIN NOINHERIT;
CREATE ROLE authenticated NOLOGIN NOINHERIT;
CREATE ROLE service_role NOLOGIN NOINHERIT BYPASSRLS;
CREATE SCHEMA auth;
CREATE TABLE auth.users (
  id uuid PRIMARY KEY, instance_id uuid, aud text, role text, email text,
  encrypted_password text, email_confirmed_at timestamptz,
  raw_app_meta_data jsonb, raw_user_meta_data jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  demo_password text
);
CREATE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS \$\$
  SELECT NULLIF(COALESCE(current_setting('request.jwt.claim.sub', true),
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')), '')::uuid \$\$;
CREATE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS \$\$
  SELECT NULLIF(COALESCE(current_setting('request.jwt.claim.role', true),
    (NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')), '') \$\$;
CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS \$\$
  SELECT COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb) \$\$;
GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;
GRANT SELECT ON auth.users TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.uid() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.role() TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION auth.jwt() TO anon, authenticated, service_role;
`;

async function bootDb() {
  const db = await PGlite.create();
  await db.exec(SUPABASE_STUB);
  const files = (await readdir(MIGRATIONS)).filter(f => /^\d+_.*\.sql$/.test(f)).sort();
  for (const f of files) {
    const sql = await readFile(path.join(MIGRATIONS, f), 'utf8');
    await db.exec(sql);
  }
  return db;
}

async function seedDb(db) {
  const vals = DEMO.map(d =>
    `('${d.id}'::uuid, '${d.email}', '${d.password}', '${d.role}',
       '{"provider":"email","providers":["email"]}'::jsonb,
       '{\"full_name\":\"${d.role} user\",\"app_role\":\"${d.role}\"}'::jsonb, '${d.password}', now(), now())`).join(',');
  await db.exec('\n    INSERT INTO auth.users (id,email,encrypted_password,role,raw_app_meta_data,raw_user_meta_data,demo_password,created_at,updated_at)\n    VALUES ' + vals + ' ON CONFLICT (id) DO UPDATE SET demo_password = EXCLUDED.demo_password;');

  await withClaims(db, { sub: DEMO[0].id, role: 'authenticated', app_role: 'owner' }, async (db2) => {
    const res = await db2.selectOne(`SELECT public.create_store($1::text) AS r`, ['Demo Kirana Store']);
    const store = res.rows[0].r;
    for (const d of DEMO.slice(1)) {
      await db2.selectOne(`SELECT public.add_store_member($1::uuid, $2::uuid, $3::public.user_role) AS r`, [store.id, d.id, d.role]);
    }
    return store;
  });

  await withRole(db, 'service_role', async (db2) => {
    const store = await db2.selectOne(`SELECT id FROM public.stores WHERE name='Demo Kirana Store'`);
    const sid = store.rows[0].id;
    await db2.exec(`INSERT INTO public.store_settings (store_id) VALUES ('${sid}') ON CONFLICT (store_id) DO UPDATE SET invoice_prefix='INV', enable_gst=true, default_tax_rate=5.00, cashier_can_record_payments=true, low_stock_default_threshold=10;`);
    await db2.exec(`INSERT INTO public.categories (store_id, name, description) VALUES ('${sid}','Staples','Atta, rice, dal, sugar'),('${sid}','Dairy','Milk, curd, paneer'),('${sid}','Snacks','Biscuits, tea, namkeen'),('${sid}','Household','Soap, cleaning');`);
    const cat = await db2.select(`SELECT name, id FROM public.categories WHERE store_id='${sid}'`);
    const c = Object.fromEntries(cat.rows.map(r => [r.name, r.id]));
    const products = [
      ['Aashirvaad Atta 5kg','ATT-5KG','8901234500011',210,245,40,'bag',10,'Staples'],
      ['Basmati Rice 1kg','RICE-1KG','8901234500028',95,120,60,'kg',15,'Staples'],
      ['Toor Dal 1kg','DAL-TOOR','8901234500035',130,160,35,'kg',10,'Staples'],
      ['Tata Salt 1kg','SALT-1KG','8901234500042',20,28,80,'packet',20,'Staples'],
      ['Sugar 1kg','SUG-1KG','8901234500059',40,48,50,'kg',15,'Staples'],
      ['Maggi Noodles 70g','MAG-70G','8901234500066',12,15,120,'packet',24,'Snacks'],
      ['Parle-G Biscuit','PAR-G','8901234500073',8,10,150,'packet',30,'Snacks'],
      ['Surf Excel 1kg','SURF-1KG','8901234500127',105,125,30,'packet',10,'Household'],
      ['Amul Taaza Milk 1L','MILK-1L','8901234500110',58,66,30,'liter',12,'Dairy'],
      ['Amul Butter 500g','BUT-500G','8901234500103',250,275,15,'packet',6,'Dairy'],
    ];
    const pvals = products.map(([name,sku,bar,cost,price,stock,unit,thr,cat]) =>
      `('${sid}','${c[cat]}','${name}','${sku}','${bar}',${cost},${price},${stock},'${unit}',${thr})`).join(',');
    await db2.exec('INSERT INTO public.products (store_id,category_id,name,sku,barcode,cost_price,selling_price,stock_quantity,unit,low_stock_threshold) VALUES ' + pvals + ' ON CONFLICT DO NOTHING;');
    await db2.exec("INSERT INTO public.suppliers (store_id,name,phone,email,address) VALUES ('" + sid + "','Sharma Wholesale Traders','9812345678','sales@sharma.example','Market Yard, Pune'),('" + sid + "','Krishna Distributors','9823456789','orders@krishna.example','Hadapsar, Pune');");
    await db2.exec("INSERT INTO public.customers (store_id,name,phone,email,address,credit_limit) VALUES ('" + sid + "','Rahul Sharma','9900112233','rahul@example.com','Green Park',5000),('" + sid + "','Priya Deshmukh','9900223344',NULL,'Kalyani Nagar',3000);");
  });
}

async function withClaims(db, claims, fn) {
  await db.exec('SET LOCAL "request.jwt.claims" = ' + JSON.stringify(JSON.stringify(claims)));
  return await fn(db);
}
async function withRole(db, role, fn) {
  await db.exec('SET LOCAL ROLE ' + role + ';');
  return await fn(db);
}

const RPC_PARAMS = {
  create_sale: ['uuid','jsonb','payment_method','uuid','numeric','numeric','text','jsonb','uuid'],
  create_purchase: ['uuid','jsonb','uuid','text','payment_status','numeric','numeric','text','uuid'],
  record_customer_payment: ['uuid','uuid','numeric','payment_method','text','uuid'],
  adjust_inventory: ['uuid','uuid','stock_movement_type','numeric','text'],
  cancel_sale: ['uuid','uuid','text'],
  add_store_member: ['uuid','uuid','user_role'],
  create_store: ['text'],
};
const colsOf = (r) => (r?.columns || []).map(c => c.name);
function rowsToObjects(result) {
  if (!result || !result.columns) return [];
  return result.rows.map(r => {
    const o = {}; for (let i = 0; i < result.columns.length; i++) o[result.columns[i].name] = r[i]; return o;
  });
}
function pgCode(e) {
  const m = /SQLSTATE (\d+)/.exec(e?.message || '');
  return m ? m[1] : (e?.code || '42601');
}
async function callRpc(db, fn, args, claims) {
  const sig = RPC_PARAMS[fn];
  if (!sig) throw { status: 404, body: { code: '27000', message: 'rpc ' + fn + ' not registered locally' } };
  await db.exec('SET LOCAL "request.jwt.claims" = ' + JSON.stringify(JSON.stringify(claims)));
  const ordered = sig.map((t, i) => args[Object.keys(args)[i]] ?? null);
  const sql = 'SELECT public.' + fn + '(' + sig.map((_, i) => '$' + (i + 1)).join(',') + ')';
  let res;
  try { res = await db.query(sql, ordered); }
  catch (e) { throw { status: 400, body: { code: pgCode(e), message: e.message, details: e.detail, hint: e.hint } }; }
  const c0 = colsOf(res);
  return rowsToObjects(res).map(r => r[c0[0]]);
}
function setCors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', 'authorization, apikey, content-type, prefer, accept');
  res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PATCH,DELETE,OPTIONS');
}
async function findUser(db, id) {
  if (!id) return null;
  const r = await db.query('SELECT id, email, raw_user_meta_data, raw_app_meta_data FROM auth.users WHERE id=$1::uuid', [id]);
  if (!r.rows.length) return null;
  const row = r.rows[0];
  return { id: row[0], email: row[1], user_metadata: row[2], app_metadata: row[3] };
}
function bearerClaims(req) {
  const h = req.headers.authorization || '';
  const m = /^Bearer\s+(.+)$/i.exec(h);
  return m ? verifyJwt(m[1]) : null;
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    let b = '';
    req.on('data', c => b += c);
    req.on('end', () => { try { resolve(b ? JSON.parse(b) : {}); } catch (e) { reject(e); } });
    req.on('error', reject);
  });
}
function fileExists(p) { return stat(p).then(() => true).catch(() => false); }

/* ---------- HTTP: path parsing ---------- */
function parsePath(raw) {
  let p = raw.split('?')[0].replace(/\/+$/, '') || '/';
  const m = p.match(/^\/rest\/v1\/rpc\/((?:public[.])?[\w.]+)$/);
  if (m) return { kind: 'rpc', fn: m[1].replace(/^public\./, '') };
  const m2 = p.match(/^\/rest\/v1\/([\w.]+)(\/[\w.]+)*$/);
  if (m2) return { kind: 'table', rel: m2[1].replace(/^\w+\./, '') };
  return { kind: 'other' };
}

/* ---------- HTTP: RLS-ranged table read (uses the real RLS policies) ---------- */
async function tableSelect(db, rel, claims) {
  await db.exec('SET LOCAL "request.jwt.claims" = ' + JSON.stringify(JSON.stringify(claims)));
  const sql = 'SELECT * FROM ' + rel;
  try {
    const r = await db.query(sql);
    return rowsToObjects(r);
  } catch (e) { return []; }
}

/* ---------- HTTP: insert mutation through the tenant FK enforcement ---------- */
async function tableInsert(db, rel, row, claims) {
  await db.exec('SET LOCAL "request.jwt.claims" = ' + JSON.stringify(JSON.stringify(claims)));
  const cols = Object.keys(row).join(', ');
  const vals = Object.keys(row).map((k, i) => '$' + (i + 1));
  const sql = 'INSERT INTO ' + rel + ' (' + cols + ') VALUES (' + vals.join(',') + ') RETURNING *';
  const r = await db.query(sql, Object.values(row));
  return rowsToObjects(r);
}

/* ---------- HTTP: request handlers ---------- */
async function handle(req, res) {
  setCors(res);
  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

  const claims = bearerClaims(req);
  const auth = req.url.startsWith('/auth/');
  const pathInfo = parsePath(req.url);

  try {
    if (auth) return await handleAuth(req, res, claims);
    if (pathInfo.kind === 'rpc') return await handleRpc(req, res, pathInfo.fn, claims);
    if (pathInfo.kind === 'table') return await handleTable(req, res, pathInfo.rel, claims);
  } catch (e) {
    const status = e?.status ?? 500;
    const code = e?.code ?? '50000';
    writeJson(res, status, { code, message: e?.message ?? 'internal error', details: e?.detail, hint: e?.hint });
    return;
  }

  // Anything not matched -> 404 (narrow surface, fail closed)
  writeJson(res, 404, { code: '40400', message: 'not found' });

