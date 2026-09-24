# Kirana Store Management (KSM)

Full-stack kirana (grocery) POS: a **React + TypeScript frontend** (`frontend/`) talking to an **Express REST API** (`backend/`) over the original Supabase-era PostgreSQL schema — RLS policies, SECURITY DEFINER RPCs and reporting views preserved, while all Supabase client code has been removed from the application.

## Repository layout

```
KSM/
├── frontend/                 React 18 + Vite + TS app
│   ├── src/                  app/  lib/  pages/   (REST only — zero DB logic)
│   └── scripts/              validate:ui + validate:db (PGlite) harnesses
├── backend/                  Express API (ESM, Node 20+)
│   ├── src/
│   │   ├── routes/           thin express-validator shells
│   │   ├── controllers/      HTTP layer
│   │   ├── models/           parameterised SQL (one file per aggregate)
│   │   ├── middleware/       auth · validate · error
│   │   ├── config/           env.js · db.js (pool + withAuth RPC helper)
│   │   ├── utils/            jwt sign/verify
│   │   └── app.js  server.js  smoke.js
│   ├── database/schema.sql   GENERATED: concatenation of migrations 001–028
│   └── .env.example
├── supabase/
│   ├── migrations/           001–028 — source of truth (tables, RLS, RPCs, views)
│   └── tests/                DB rule assertions (executed by validate:db)
└── scripts/                  legacy one-off helpers (gitignored)
```

## Stack

- **Frontend:** React 18, TypeScript 5.6, Vite 5, react-router 6, lucide-react. When `VITE_API_BASE_URL` is unset the app runs an offline in-memory **DemoEngine** — no server needed.
- **Backend:** Express 4, pg, express-validator, jsonwebtoken, bcryptjs, helmet, cors.
- **Database:** PostgreSQL with RLS everywhere; writes go through SECURITY DEFINER RPCs (`create_sale`, `create_purchase`, `record_customer_payment`, `create_store`) so pricing, stock and credit-limit rules stay server-side.

## Quick start

### 1. Database
```bash
createdb kirana_store    # any Postgres (or a Supabase project's direct connection)
psql "$DATABASE_URL" -f backend/database/schema.sql   # fresh DB, migrations 001→028
# (equivalently: apply supabase/migrations/*.sql in filename order)
npm run validate:db --prefix frontend   # PGlite: applies migrations + asserts RLS/RPC rules
```

### 2. Backend — http://localhost:5000/api
```bash
cd backend && npm install
cp .env.example .env     # set DATABASE_URL + a strong JWT_SECRET
npm run dev              # node --watch src/server.js
curl http://localhost:5000/api/ping
```

### 3. Frontend — http://localhost:5173
```bash
cd frontend && npm install
cp .env.example .env     # VITE_API_BASE_URL=http://localhost:5000/api
npm run dev              # delete .env instead to run the offline demo
```
Open http://localhost:5173/login — the **first signup creates the owner account and store**.

## API reference (base `/api`)

| Area | Endpoints |
|------|-----------|
| auth | `POST /auth/signup` · `POST /auth/login` · `POST /auth/logout` · `POST /auth/refresh` · `GET /auth/me` · `GET /auth/validate` |
| users | `GET /users` · `GET /users/:id` · `PUT /users/:id` · `DELETE /users/:id` |
| products | `GET /products` · `GET /products/lookup?q=` · `GET /products/:id` · `POST /products` · `PUT /products/:id` · `DELETE /products/:id` |
| customers | `GET /customers` · `GET /customers/lookup?q=` · `GET /customers/:id` · `POST /customers` · `PUT /customers/:id` · `DELETE /customers/:id` · `POST /customers/:id/pay` |
| sales | `GET /sales` · `GET /sales/:id` · `POST /sales` · `POST /sales/:id/cancel` |
| purchases | `GET /purchases` · `GET /purchases/:id` · `POST /purchases` · `POST /purchases/:id/cancel` |
| reports | `GET /reports/summary` · `GET /reports/product-sales` · `GET /reports/movements` |
| misc | `GET /ping` |

Authentication: `Authorization: Bearer <JWT>` — stateless 8-hour tokens (email + storeId claims). Mutations run inside `withAuth` transactions (`SET LOCAL request.jwt.claims`) so `auth.uid()` resolves inside the RPCs.

## Frontend → backend mapping

| Page | Backend-mode calls |
|------|--------------------|
| Dashboard | `GET reports/summary` + `sales` + `products` + `customers` |
| Billing / POS | `GET products`, `GET customers`, `POST sales` (server-side pricing) |
| Sales | `GET sales`, `POST sales/:id/cancel` |
| Products | `GET/POST/PUT/DELETE products` |
| Purchases | `GET products`, `GET purchases`, `POST purchases` |
| Customers | `GET/POST/PUT/DELETE customers`, `POST customers/:id/pay` |
| Reports | `GET reports/summary`, `reports/product-sales`, `reports/movements` |
| Login / Signup | `POST auth/signup`, `POST auth/login`, `GET auth/me` |

## Environment variables

**backend/.env** (see `backend/.env.example`): `DATABASE_URL` · `JWT_SECRET` (required) · `JWT_ISSUER` · `JWT_AUDIENCE` · `FRONTEND_URL` (comma-separated CORS origins, default `http://localhost:5173`) · `PORT` (5000) · `NODE_ENV`.

**frontend/.env** (see `frontend/.env.example`): `VITE_API_BASE_URL` · `VITE_APP_NAME`. The frontend holds no secrets; `.env` files are gitignored.

## Validation commands

```bash
# Backend — syntax check every file, boot + ping, optional live smoke
cd backend
node --check src/app.js            # …repeat for each src/**/*.js
npm run smoke                      # needs DATABASE_URL; boots API and exercises routes

# Frontend
cd frontend
npm run typecheck                  # tsc --noEmit
npm run build                      # tsc + vite build
npm run validate:ui                # headless render of every page
npm run validate:db                # PGlite: migrations + RLS/RPC assertions
```

---
`supabase/migrations/001–028` is the **source of truth** for the schema; `backend/database/schema.sql` is a generated snapshot — edit the migrations, then regenerate the snapshot.
