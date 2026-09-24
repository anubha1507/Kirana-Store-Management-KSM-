# KSM Backend — Express REST API

Layered Express service (ESM, Node 20+) exposing the KSM REST API over the
original Supabase-era PostgreSQL schema (Supabase clients removed; plain
`pg` + JWT now). Architecture:

```
routes/ (express-validator shells) → controllers/ (HTTP) → models/ (parameterised SQL)
```

- `src/config/db.js` — pg pool + `withAuth(user, fn)`: transaction with
  `request.jwt.claims` set so SECURITY DEFINER RPCs (`create_sale`,
  `create_purchase`, `record_customer_payment`, `create_store`) see `auth.uid()`.
- `src/utils/auth.js` — JWT sign/verify only (stateless, 8 h; claims: email, storeId, role).
- `src/middleware/error.js` — maps SQL error codes (23505/23503/22P02/42501/…) to client statuses.
- `database/schema.sql` — GENERATED snapshot of `supabase/migrations/001…028`.
  The migrations are the source of truth; regenerate the snapshot after editing them.

## Setup & run

```bash
cd backend
npm install
cp .env.example .env      # DATABASE_URL, JWT_SECRET (required), FRONTEND_URL, PORT
npm run dev               # node --watch src/server.js → :5000
npm start                 # production
npm run smoke             # boots the API and exercises routes (needs DATABASE_URL)
```

Health check: `GET http://localhost:5000/api/ping`.

## Environment variables

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection string |
| `JWT_SECRET` | **Required** — signing secret (API refuses to boot without it) |
| `JWT_ISSUER` / `JWT_AUDIENCE` | JWT claims (defaults: `http://localhost:5000/api` / `kirana-store-admin`) |
| `FRONTEND_URL` | CORS origins, comma-separated (default `http://localhost:5173`) |
| `PORT` | Server port (default 5000) |
| `NODE_ENV` | e.g. `development` |

## Endpoints (base `/api`)

- **auth** — `POST /auth/signup` · `POST /auth/login` · `POST /auth/logout` · `POST /auth/refresh` · `GET /auth/me` · `GET /auth/validate`
- **users** — `GET /users` · `GET /users/:id` · `PUT /users/:id` · `DELETE /users/:id`
- **products** — `GET /products` · `GET /products/lookup` · `GET /products/:id` · `POST /products` · `PUT /products/:id` · `DELETE /products/:id`
- **customers** — `GET /customers` · `GET /customers/lookup` · `GET /customers/:id` · `POST /customers` · `PUT /customers/:id` · `DELETE /customers/:id` · `POST /customers/:id/pay`
- **sales** — `GET /sales` · `GET /sales/:id` · `POST /sales` · `POST /sales/:id/cancel`
- **purchases** — `GET /purchases` · `GET /purchases/:id` · `POST /purchases` · `POST /purchases/:id/cancel`
- **reports** — `GET /reports/summary` · `GET /reports/product-sales` · `GET /reports/movements`
- **misc** — `GET /ping`

All routes except signup/login/validate/ping require `Authorization: Bearer <JWT>`.
Pricing, stock, payment-ceiling and credit-limit rules are enforced by the SQL
RPCs, not the API layer. See the [root README](../README.md) for the frontend
mapping and full setup.
