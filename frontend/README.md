> **📁 This README documents the `frontend/` app only.** The full repository
> (frontend + backend + database) is documented in the
> [root README](../README.md).


# Kirana Store Management (KSM)

A production-oriented **Kirana / grocery store management** application for small
Indian shops: products, inventory, purchases, POS billing, customers, *udhaar*
(credit) tracking, payments, reports, roles and store settings.

Two halves that are deliberately independent:

| Half | Location | What it is |
|---|---|---|
| **Database** | `supabase/` | The real Supabase/PostgreSQL backend: 27 migrations, full RLS, triggers, RPC functions, reporting views, seed data and a 198-assertion verification suite. |
| **Frontend** | `src/` | React 18 + TypeScript + Vite SPA with light/dark mode that talks to that backend — and, with no configuration, to an in-browser engine that mirrors it. |

---

## 1. Run it on localhost (zero setup)

```bash
npm install
npm run dev
```

Then open **http://localhost:5173/**.

The sign-in screen offers three roles — **owner**, **manager**, **cashier**.
Pick one and press *Enter local demo*. No Supabase project, no Docker, no
database server is needed: `src/lib/engine.ts` + `src/lib/demo.ts` implement the
same contract as `supabase/migrations` (server-side pricing, the stock ledger
invariant, the payment ceiling, the udhaar credit limit, idempotent billing and
the role ladder) so every screen has real data to show.

> **Local demo mode vs. backend mode.** When `VITE_API_BASE_URL` is absent the
> app runs in *local demo mode*. When it is present the same pages are served by
> the Node/Express REST API in `backend/`. To switch, copy `.env.example` to
> `.env.local` and set `VITE_API_BASE_URL` (e.g. `http://localhost:5000/api`).

### Demo credentials

There is no password in demo mode — the role buttons *are* the credentials. The
seed data behind them is the same shop described in
`supabase/migrations/021_seed_data.sql`.

---

## 2. Other scripts

```bash
npm run dev            # Vite dev server on http://localhost:5173
npm run build          # tsc --noEmit && vite build  ->  dist/
npm run preview        # serve dist/ on http://localhost:4173
npm run typecheck      # tsc --noEmit
npm run validate:db    # run every migration + the 198 SQL assertions in PGlite
npm run validate:ui    # 102 working-model assertions + dev-server module probe
```

### `npm run validate:db`

Boots genuine PostgreSQL (PGlite/WASM — the same server code Supabase runs) in
Node, creates a Supabase-shaped `auth` schema with the real `auth.uid()`, applies
every file in `supabase/migrations/` in filename order, then runs
`supabase/tests/01_rls_and_business_rules.sql`.

It proves, without a Supabase project:

* tenant isolation (an outsider sees 0 rows in every table and view),
* the cashier / manager / owner permission matrix,
* invoice numbering (`INV-2026-000001`, independent per store and per document type),
* purchases raising stock and sales deducting it, with a balancing stock movement,
* the payment ceiling, the udhaar ledger and the credit limit,
* append-only ledgers (UPDATE/DELETE on `stock_movements`, `payments`,
  `sale_items`, `customer_transactions` and `audit_logs` are rejected),
* cancellation semantics (stock returns, money stays on record).

Current result: **198/198 assertions passed**.

### `npm run validate:ui`

Bundles `scripts/ui-smoke-entry.ts` with esbuild (the same bundler Vite uses) so
the TypeScript under test is the code that ships, drives it through the demo
engine, and asserts 102 working-model checks. Then it probes the running Vite
server for every app module and requires HTTP 200.

Current result: **102/102 working-model checks passed**, **18/18 modules served**.


---

## 3. Architecture

### 3.1 Entity relationships

```
auth.users ──1:1── profiles
     │
     └──1:N── store_members ──N:1── stores ──1:1── store_settings
                                      │
                                      ├──1:N── categories ──1:N── products
                                      ├──1:N── suppliers
                                      ├──1:N── customers ──1:N── customer_transactions
                                      │                              └──1:1── credit_payments
                                      ├──1:N── purchases ──1:N── purchase_items
                                      ├──1:N── sales ──1:N── sale_items
                                      │            └──1:N── payments
                                      ├──1:N── stock_movements
                                      ├──1:N── inventory_adjustments
                                      ├──1:N── invoice_counters
                                      ├──1:N── rpc_requests
                                      └──1:N── audit_logs
```

### 3.2 Multi-tenant strategy

Tenancy is enforced in three independent layers, so one mistake is not enough to
leak data:

1. **RLS policies** on every table, all keyed on `store_id` membership via
   `public.is_store_member(store_id)` and `public.has_store_role(store_id, role)`.
2. **Composite tenant foreign keys** — child tables reference parents through
   `(id, store_id)` pairs, so attaching a product to another store's category is
   structurally impossible even from a crafted request.
3. **RPC-only writes** for financial data: `create_sale`, `create_purchase`,
   `record_customer_payment`, `cancel_sale`, `adjust_inventory` re-derive the
   caller's role from `auth.uid()` and re-validate every store-scoped id. The
   tables themselves reject direct writes from `authenticated`.

### 3.3 Authentication integration

* `profiles.id → auth.users(id)` `ON DELETE CASCADE`.
* `on_auth_user_created` creates the profile row, copying `full_name`, `phone`
  and `avatar_url` from signup metadata.
* `auth.uid()` is the only source of caller identity — no function accepts a
  "current user" argument.

### 3.4 Inventory flow

Every quantity change is one `stock_movements` row with a signed `quantity`
(positive = in, negative = out) and a CHECK enforcing

---

## 4. Repository layout

```
.
├── index.html                  Vite entry document
├── vite.config.ts              dev server: localhost:5173, preview: 4173
├── tsconfig.json               strict TS, noUnusedLocals/Parameters
├── .env.example                the only two env vars the frontend needs
├── src/
│   ├── main.tsx                React root + router
│   ├── App.tsx                 routes, auth gate, theme provider
│   ├── styles.css              design tokens, light + dark, layout
│   ├── app/
│   │   ├── shell.tsx           sidebar, top bar, theme toggle
│   │   └── store.tsx           app context: session, role, data, actions
│   ├── lib/
│   │   ├── engine.ts           in-browser mirror of the PostgreSQL contract
│   │   ├── demo.ts             demo dataset (mirrors 021_seed_data.sql)
│   │   ├── mutations.ts        write helpers used by the pages
│   │   ├── permissions.ts      pure role ladder (testable without React)
│   │   ├── api.ts             REST client for the Node/Express backend
│   │   ├── auth.ts            backend session: sign-in, refresh, normalize
│   │   ├── types.ts            domain types
│   │   └── format.ts           INR currency, dates, quantities
│   └── pages/                  Login, Dashboard, Billing, Products, Purchases,
│                               Sales, Customers, Reports, Settings
├── scripts/
│   ├── validate-db.mjs         migrations + SQL suite runner (PGlite)
│   ├── ui-smoke-entry.ts       working-model scenarios (bundled by esbuild)
│   ├── render-entry.tsx        SSR smoke render of the React tree
│   ├── validate-ui.mjs         UI validator + dev-server probe
│   └── strip-tool-artifacts.mjs
└── supabase/
    ├── README.md               database architecture (start here)
    ├── docs/                   03 RLS matrix, 04 RPC reference, 07 setup
    ├── migrations/             001 … 027
    └── tests/01_rls_and_business_rules.sql
```

---

## 5. Connecting the real database

Full instructions: **`supabase/docs/07_setup.md`**.

1. Create a Supabase project (region `ap-south-1` / Mumbai for India).
2. Run the migrations in `supabase/migrations/` in numeric order — SQL Editor,
   or `supabase link` + `supabase db push`.
3. Enable the Email provider under **Authentication → Providers**.
4. Sign up, then call `select public.create_store(...)`; the `bootstrap_store`
   trigger adds the caller as `owner` and creates `store_settings`.
5. Add staff with `select public.add_store_member(store_id, user_id, 'cashier')`.
6. Verify with `supabase/tests/01_rls_and_business_rules.sql`.
7. Copy `.env.example` to `.env.local`, set the two `VITE_*` values, restart
   `npm run dev`.

### Frontend rules

* Never ship the `service_role` key.
* Never compute a total client-side and send it — send items, let PostgreSQL price them.
* Send a fresh `p_request_id` per user action and reuse it on retry.
* Treat `error.code` as the contract: `42501` permission, `22023` bad input,
  `P0001` business rule, `40001` concurrency retry.

---

## 6. Roles

| Capability | Owner | Manager | Cashier |
|---|:--:|:--:|:--:|
| Billing / POS | ✅ | ✅ | ✅ |
| Sales history | ✅ | ✅ | ✅ |
| Product lookup (active only) | ✅ | ✅ | ✅ |
| Read customers | ✅ | ✅ | ✅ (limited) |
| Record customer payments | ✅ | ✅ | ✅ (setting-gated) |
| Create / edit products | ✅ | ✅ | ❌ |
| Delete (archive) products | ✅ | ❌ | ❌ |
| Purchases | ✅ | ✅ | ❌ |
| Stock ledger, adjustments | ✅ | ✅ | ❌ |
| Reports | ✅ | ✅ | ❌ |
| Members | ✅ | ❌ | ❌ |
| Store settings | ✅ | ❌ | ❌ |
| Audit log | ✅ | ❌ | ❌ |

The full policy matrix, table by table, is in `supabase/docs/03_rls_matrix.md`.

`previous_quantity + quantity = new_quantity`. `products.stock_quantity` is a
cached total writable only by RPCs; a trigger rejects direct edits (`55000`).

```
purchase          → +qty   create_purchase
sale              → -qty   create_sale
sale_return       → +qty   cancel_sale
purchase_return   → -qty   adjust_inventory
damage, expiry    → -qty   adjust_inventory
manual_adjustment → ±qty   adjust_inventory (also opening stock)
```

Because the ledger is complete, `products.stock_quantity` can always be
reconstructed and reconciled.

### 3.5 Sales flow — `create_sale()`

One atomic transaction:

1. verify membership (cashier or above),
2. advisory-lock the store and `SELECT … FOR UPDATE` each product row,
3. price every line from `products.selling_price` (the client sends ids and
   quantities only — never totals),
4. compute `subtotal` and `total = subtotal − discount + tax`,
5. insert the `sales` header with its final status,
6. insert `sale_items`, deduct stock, write `stock_movements`,
7. write `payments` for the settled portion,
8. append a `customer_transactions` credit row for any unpaid remainder,
9. append an `audit_logs` entry.

Any failure rolls back all of it. `p_request_id` makes the call idempotent, so a
double-tapped *Generate bill* cannot produce two invoices.

### 3.6 Credit (udhaar) flow

`customers.current_balance` is derived, never typed in:

* a credit or part-paid sale appends a positive `credit_sale` row,
* `record_customer_payment()` appends a negative `payment` row,
* `cancel_sale()` appends a negative `refund` row,
* an `AFTER INSERT` trigger applies the delta to `current_balance` and rejects
  any entry that would push the balance below zero.

`credit_limit` is checked inside the same transaction, so a customer cannot
exceed their limit through concurrent checkouts.
