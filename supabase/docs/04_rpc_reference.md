# Part 4 — RPC Reference

All functions are `SECURITY DEFINER` with `SET search_path = pg_catalog, public`.
`EXECUTE` is revoked from `PUBLIC` and `anon` and granted to `authenticated`
only. Every function derives the caller from `auth.uid()` and re-checks store
membership; none of them accept a caller id as an argument.

## 4.1 `create_sale`

```sql
public.create_sale(
  p_store_id        uuid,
  p_items           jsonb,            -- [{"product_id": uuid, "quantity": numeric,
                                      --   "discount_amount": numeric (optional)}]
  p_payment_method  public.payment_method,
  p_customer_id     uuid  DEFAULT NULL,
  p_discount_amount numeric DEFAULT 0,   -- bill-level discount
  p_tax_amount      numeric DEFAULT 0,   -- bill-level tax
  p_notes           text  DEFAULT NULL,
  p_payments        jsonb DEFAULT NULL,  -- required when method = 'mixed'
  p_request_id      uuid  DEFAULT NULL   -- idempotency key
) RETURNS jsonb
```

Returns:

```json
{ "sale_id": "...", "invoice_number": "INV-2026-000001",
  "subtotal": 773.00, "discount_amount": 0.00, "tax_amount": 0.00,
  "total_amount": 773.00, "payment_status": "paid", "amount_paid": 773.00 }
```

Behaviour and guarantees:

* requires role `cashier` or above;
* unit prices are read from `products.selling_price` — a client cannot send a
  price;
* `total = subtotal - discount + tax` is computed here and re-validated by the
  `sales_total_check` constraint on insert;
* each product row is locked `FOR UPDATE` in a deterministic order, so two
  concurrent bills cannot oversell the same item or deadlock;
* stock cannot go negative unless `store_settings.allow_negative_stock` is on;
* one `stock_movements` row per line;
* `payment_status` is `paid` when fully settled, `partial` when partly settled,
  `pending` when nothing was paid;
* any unpaid remainder is written to `customer_transactions` as a `credit_sale`
  and checked against `customers.credit_limit`;
* `p_request_id` makes the call idempotent — a repeat returns the first result
  and creates nothing.

Errors: `42501` not a member / insufficient role, `22023` invalid input,
`23503` unknown product or customer, `P0001` insufficient stock or credit limit
exceeded, `40001` concurrent stock change (retry).

## 4.2 `create_purchase`

```sql
public.create_purchase(
  p_store_id        uuid,
  p_items           jsonb,            -- [{"product_id": uuid, "quantity": numeric,
                                      --   "unit_cost": numeric}]
  p_supplier_id     uuid DEFAULT NULL,
  p_invoice_number  text DEFAULT NULL,   -- supplier's number; generated if omitted
  p_payment_status  public.payment_status DEFAULT 'paid',
  p_tax_amount      numeric DEFAULT 0,
  p_discount_amount numeric DEFAULT 0,
  p_notes           text DEFAULT NULL,
  p_request_id      uuid DEFAULT NULL
) RETURNS jsonb
```

Behaviour and guarantees:

* requires role `manager` or above;
* `total_cost = round(quantity * unit_cost, 2)` per line and
  `total = subtotal + tax - discount` for the header, both re-validated by
  constraints;
* stock increases and one `purchase` movement is written per line;
* `products.cost_price` is updated to the weighted average of the stock on hand
  and the incoming quantity, so profit estimates stay meaningful;
* the same supplier invoice number cannot be entered twice for a store
  (`purchases_supplier_invoice_unique`);
* idempotent via `p_request_id`.

## 4.3 `record_customer_payment`

```sql
public.record_customer_payment(
  p_store_id       uuid,
  p_customer_id    uuid,
  p_amount         numeric,
  p_payment_method public.payment_method DEFAULT 'cash',
  p_notes          text DEFAULT NULL,
  p_request_id     uuid DEFAULT NULL
) RETURNS jsonb
```

Returns `{customer_id, amount, previous_balance, current_balance,
customer_transaction_id}`.

Behaviour and guarantees:

* owners and managers may always call it; a cashier may call it only when
  `store_settings.cashier_can_record_payments` is true;
* the customer row is locked `FOR UPDATE`, so two concurrent payments cannot
  both read the same starting balance and overpay;
* the payment may not exceed the outstanding balance;
* a negative `payment` ledger row is appended, and the
  `apply_customer_ledger` trigger updates `current_balance`;
* a matching `credit_payments` row records the method and notes.

## 4.4 `cancel_sale`

```sql
public.cancel_sale(p_store_id uuid, p_sale_id uuid, p_reason text) RETURNS jsonb
```

* requires role `manager` or above and a reason of at least 3 characters;
* returns every sold quantity to stock with `sale_return` movements;
* reverses any credit the bill created with a negative `refund` ledger row;
* marks the sale cancelled (`cancelled_at`, `cancelled_by`, `cancel_reason`)
  without deleting the invoice or its lines;
* received payments stay on record — refunding cash is a separate business
  decision, and the audit trail shows both sides.

## 4.5 Supporting RPCs

| Function | Role | Purpose |
|---|---|---|
| `create_store(...)` | any signed-in user | creates a store owned by the caller; the bootstrap trigger adds the owner membership and default settings |
| `update_store_settings(...)` | owner | partial update of store settings |
| `add_store_member(store, user, role)` | owner | invites an existing auth user |
| `set_store_member_role(store, member, role)` | owner | changes a member's role |
| `set_store_member_active(store, member, bool)` | owner | enables or disables access |
| `remove_store_member(store, member)` | owner | removes a member |
| `archive_product(store, product)` | manager+ | soft-deletes a product |
| `adjust_inventory(store, product, type, qty, reason)` | manager+ | damage, expiry or manual correction; always writes a movement |
| `find_products_for_billing(store, search, category, limit)` | member | till search by name, SKU or barcode |
| `find_customers_for_billing(store, search, limit)` | member | till customer search without sensitive columns |

## 4.6 Invoice numbering

Format: `PREFIX-YYYY-NNNNNN`, for example `INV-2026-000001`.

`private.next_document_number(store_id, doc_type, prefix)` performs a single
`INSERT ... ON CONFLICT (store_id, doc_type, year) DO UPDATE SET last_value =
last_value + 1 RETURNING last_value`. The upsert takes a row lock on the counter
row, so two concurrent checkouts serialise and can never receive the same
number. The year comes from the store's own timezone, so a bill rung up at
00:30 IST on 1 January belongs to the new year.

`sales` additionally has `UNIQUE (store_id, invoice_number)` as a hard backstop:
even if the counter were bypassed, a duplicate invoice number is impossible.

## 4.7 Idempotency

`rpc_requests (store_id, request_id)` stores the result of a completed
`create_sale`, `create_purchase` or `record_customer_payment`. The client
generates a UUID per user action and reuses it on retry; the second call returns
the stored result instead of creating a second document. This is what makes a
double-tapped "Generate bill" button safe on a flaky connection.
