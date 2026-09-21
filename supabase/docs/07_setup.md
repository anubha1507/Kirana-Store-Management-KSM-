# Part 7 — Supabase Setup

## 7.1 Create the project

1. Sign in at <https://supabase.com/dashboard> and choose **New project**.
2. Pick a region close to the shop (for India, `ap-south-1` / Mumbai).
3. Save the database password in a password manager.
4. Wait for provisioning to finish, then open **Project Settings → API** and note:
   * **Project URL** — `https://<ref>.supabase.co`
   * **anon public key** — safe for the browser
   * **service_role key** — server only, never in frontend code

## 7.2 Run the migrations

### Option A — SQL Editor (no tooling)

Open **SQL Editor**, then paste and run each file in `supabase/migrations/` in
numeric order. Run them one at a time so an error is easy to attribute:

```
001_foundation.sql
002_catalog.sql
003_transactions.sql
004_rls.sql
005_trigger_functions.sql
006_triggers.sql
007_rpc_store_and_members.sql
008_rpc_catalog_admin.sql
009_rpc_product_lookup.sql
010_rpc_customer_lookup.sql
011_rpc_sale_payment_helper.sql
012_rpc_price_sale_lines.sql
012_rpc_sale_lines.sql
013_rpc_write_sale_payments.sql
014_rpc_credit_sale_helper.sql
015_rpc_create_sale.sql
016_rpc_create_purchase.sql
017_rpc_record_customer_payment.sql
018_rpc_cancel_sale.sql
019_indexes.sql
020_views.sql
021_seed_data.sql      -- optional, development only
022_payment_ceiling.sql
023_purchase_invoice_unique.sql
024_rpc_store_members.sql
026_fix_customer_balance_domain.sql
```

### Option B — Supabase CLI

```bash
supabase link --project-ref <your-project-ref>
supabase db push
```

The CLI applies files in lexicographic order, which is why the two `012_` files
are named `012_rpc_price_sale_lines.sql` and `012_rpc_sale_lines.sql`: `p` sorts
before `s`, so pricing is created before persistence.

## 7.3 Enable authentication

1. **Authentication → Providers → Email**: enable it.
2. For a shop-floor app, turn **Confirm email** off so staff can be created
   without a mailbox; keep it on if owners self-register.
3. **Authentication → URL Configuration**: set the Site URL and add your
   frontend origins to the redirect allow-list.
4. Optionally enable **Phone** auth for OTP login, which suits shop staff.

The `on_auth_user_created` trigger creates a `profiles` row for every new user
automatically. If you pass `full_name` or `phone` in the signup metadata, they
are copied across.

## 7.4 Create the first store and owner

Sign up through the app (or **Authentication → Add user**), then call:

```sql
-- Run in the SQL Editor while signed in as that user, or from the app:
select public.create_store(
  p_name       => 'Sharma Kirana Store',
  p_phone      => '9876543210',
  p_city       => 'Pune',
  p_state      => 'Maharashtra',
  p_pincode    => '411001',
  p_gst_number => '27ABCDE1234F1Z5'
);
```

The `bootstrap_store` trigger then:

* inserts the caller into `store_members` with role `owner`,
* creates the `store_settings` row with defaults.

A store therefore cannot exist without an owner and configuration.

To add staff, have them sign up first, then:

```sql
select public.add_store_member(
  p_store_id => '<store-uuid>',
  p_user_id  => '<their-auth-user-uuid>',
  p_role     => 'cashier'
);
```

## 7.5 Test RLS

The fastest check is to impersonate a user inside a transaction:

```sql
begin;
-- Pretend to be a specific user for the rest of this transaction.
select set_config('request.jwt.claims',
                  json_build_object('sub', '<user-uuid>', 'role', 'authenticated')::text,
                  true);
set local role authenticated;

select count(*) from public.products;   -- only stores this user belongs to
select count(*) from public.sales;      -- cashier sees their store's sales

rollback;
```

`supabase/tests/01_rls_and_business_rules.sql` automates this for every role and
is the recommended way to verify a fresh deployment.

## 7.6 Connect the React frontend

```bash
npm install @supabase/supabase-js
```

```ts
// src/lib/supabase.ts
import { createClient } from '@supabase/supabase-js';

export const supabase = createClient(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY,
  { auth: { persistSession: true, autoRefreshToken: true } }
);
```

```ts
// Checkout. The client sends product ids and quantities only: prices, totals,
// stock and invoice numbers are all decided by the database.
const requestId = crypto.randomUUID();

const { data, error } = await supabase.rpc('create_sale', {
  p_store_id: storeId,
  p_items: cart.map((l) => ({
    product_id: l.productId,
    quantity: l.quantity,
    discount_amount: l.discount ?? 0,
  })),
  p_payment_method: 'cash',
  p_customer_id: customerId ?? null,
  p_discount_amount: billDiscount,
  p_tax_amount: billTax,
  p_request_id: requestId,
});

if (error) {
  // error.code 'P0001' -> insufficient stock or credit limit
  // error.code '40001' -> concurrent stock change, retry
  showError(error.message);
} else {
  printInvoice(data.invoice_number, data.total_amount);
}
```

```ts
// Till search (works for cashiers, who cannot read the products table).
const { data: products } = await supabase.rpc('find_products_for_billing', {
  p_store_id: storeId,
  p_search: query,
  p_limit: 25,
});
```

```ts
// Reports read the views directly; RLS still applies.
const { data: today } = await supabase
  .from('daily_sales_summary')
  .select('*')
  .eq('store_id', storeId)
  .order('sale_date', { ascending: false })
  .limit(30);
```

### Frontend rules

* Never put the `service_role` key in frontend code or a public bundle.
* Never compute a total in the client and send it: send items, let the database
  price them.
* Always send a fresh `p_request_id` per user action, and reuse it on retry.
* Treat `error.code` as the contract: `42501` permission, `22023` bad input,
  `P0001` business rule, `40001` retry.

## 7.7 Operational notes

* **Backups** — Supabase takes daily backups on paid plans; verify the retention
  window matches the shop's needs.
* **Connection pooling** — use the pooled connection string (port 6543) for
  serverless or edge functions.
* **Migrations in production** — apply new files through the CLI, never by hand
  in the SQL Editor, so the migration history stays consistent.
* **Audit retention** — `audit_logs` grows with every product, customer, member
  and settings change plus every sale, purchase and payment. Plan a periodic
  archive job if the store is busy.
