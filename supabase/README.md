# Kirana Store Management — Supabase Database

Production-oriented PostgreSQL schema for a multi-store Kirana (grocery) store
management application, built for Supabase (PostgreSQL + Supabase Auth).

Everything lives in `supabase/migrations/` and is applied in numeric order.

## 1. Architecture

### 1.1 Entity relationships

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

Key design decisions:

* **`store_id` on every business table.** Multi-store is a first-class concept,
  not a later migration. A user can own or work in several stores.
* **Composite tenant foreign keys.** Child tables reference parents through
  `(id, store_id)` pairs, for example
  `products (category_id, store_id) → categories (id, store_id)`. This makes it
  structurally impossible to attach a product to another store's category, even
  if an application bug or a crafted request tries to.
* **Snapshot columns on `sale_items`.** `product_name` and `unit_price` are
  copied at checkout, so an old invoice still reads correctly after the product
  is renamed, repriced, or archived.
* **Ledgers are append-only.** `stock_movements`, `customer_transactions`,
  `payments`, `sale_items`, `purchase_items`, `credit_payments` and `audit_logs`
  reject UPDATE and DELETE at the trigger level. Corrections are new rows.

### 1.2 Multi-tenant strategy

Tenancy is enforced in three independent layers, so a single mistake is not
enough to leak data:

1. **RLS policies** on every table, all keyed on `store_id` membership.
2. **Composite foreign keys** that make cross-store references invalid.
3. **RPC-only writes** for financial data, where the function re-derives the
   caller's role from `auth.uid()` and re-validates every store-scoped id.

### 1.3 Authentication integration

* `profiles.id` references `auth.users(id)` with `ON DELETE CASCADE`.
* A trigger on `auth.users` (`on_auth_user_created`) creates the profile row
  automatically, copying `full_name`, `phone` and `avatar_url` from the signup
  metadata when present.
* `auth.uid()` is the only source of caller identity. No function accepts a
  "current user" argument.

### 1.4 Inventory flow

Every quantity change is a `stock_movements` row with a signed `quantity`
(positive = stock in, negative = stock out) and a CHECK constraint enforcing
`previous_quantity + quantity = new_quantity`. `products.stock_quantity` is a
cached total that can only be written by RPCs; a trigger rejects direct edits.

```
purchase        → +qty   (create_purchase)
sale            → -qty   (create_sale)
sale_return     → +qty   (cancel_sale)
purchase_return → -qty   (adjust_inventory / future RPC)
damage, expiry  → -qty   (adjust_inventory)
manual_adjustment → ±qty (adjust_inventory, opening stock)
```

Because the ledger is complete, `products.stock_quantity` can always be
reconstructed and reconciled.

### 1.5 Sales flow

`create_sale()` is one transaction:

1. verify membership (cashier or above),
2. lock the store (advisory lock) and each product row (`FOR UPDATE`),
3. price every line from `products.selling_price`,
4. compute `subtotal`, `total = subtotal - discount + tax`,
5. insert the `sales` header with its final status,
6. insert `sale_items`, deduct stock, write `stock_movements`,
7. write `payments` for the settled portion,
8. write a `customer_transactions` credit row for any unpaid remainder,
9. write an `audit_logs` entry.

Any failure rolls back all of it. `p_request_id` makes the call idempotent, so a
double-tapped "Generate bill" cannot produce two invoices.

### 1.6 Credit (udhaar) flow

`customers.current_balance` is derived, never typed in:

* a credit or partially paid sale appends a positive `credit_sale` row,
* `record_customer_payment()` appends a negative `payment` row,
* `cancel_sale()` appends a negative `refund` row,
* an `AFTER INSERT` trigger applies the delta to `current_balance` and rejects
  any entry that would push the balance below zero.

`credit_limit` is checked inside the same transaction, so a customer cannot
exceed their limit through concurrent checkouts.

## 2. Migration index

| File | Contents |
|---|---|
| `001_foundation.sql` | extensions, enums, domains, profiles, stores, members, settings, counters, audit |
| `002_catalog.sql` | categories, products, suppliers, customers |
| `003_transactions.sql` | purchases, sales, payments, stock movements, adjustments, ledgers |
| `004_rls.sql` | helper functions, privilege lockdown, all RLS policies |
| `005_trigger_functions.sql` | trigger function bodies |
| `006_triggers.sql` | trigger wiring |
| `007_rpc_store_and_members.sql` | `create_store`, `update_store_settings` |
| `008_rpc_catalog_admin.sql` | `archive_product`, `adjust_inventory` |
| `009_rpc_product_lookup.sql` | `find_products_for_billing` |
| `010_rpc_customer_lookup.sql` | `find_customers_for_billing` |
| `011_rpc_sale_payment_helper.sql` | `validate_sale_payments` |
| `012_rpc_price_sale_lines.sql` | `price_sale_lines` |
| `012_rpc_sale_lines.sql` | `persist_sale_lines` |
| `013_rpc_write_sale_payments.sql` | `write_sale_payments` |
| `014_rpc_credit_sale_helper.sql` | `apply_credit_sale` |
| `015_rpc_create_sale.sql` | `create_sale` |
| `016_rpc_create_purchase.sql` | `create_purchase` |
| `017_rpc_record_customer_payment.sql` | `record_customer_payment` |
| `018_rpc_cancel_sale.sql` | `cancel_sale` |
| `019_indexes.sql` | all indexes, including store-scoped uniqueness |
| `020_views.sql` | reporting views |
| `021_seed_data.sql` | optional demo data |
| `022_payment_ceiling.sql` | payments may not exceed the sale total |
| `023_purchase_invoice_unique.sql` | one supplier invoice per store |
| `024_rpc_store_members.sql` | `add_store_member`, `update_store_member_role`, `deactivate_store_member`, `remove_store_member` |
| `026_fix_customer_balance_domain.sql` | `customers.current_balance` widened off the `money_amount` domain so `cancel_sale()` raises the documented `P0001` |

> Note: two files share the `012_` prefix because they were split for
> readability. Apply them in the order listed above (price, then persist).
