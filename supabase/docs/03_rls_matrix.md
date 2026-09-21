# Part 3 — Row Level Security

## 3.1 How enforcement works

Every application table has `ENABLE ROW LEVEL SECURITY`. No table was left
without policies except the two server-only tables noted at the end.

Two helpers are used by nearly every policy. Both are `SECURITY DEFINER` and
owned by the migration runner, which is why they can read `store_members`
without triggering its own policies (that is the standard way to avoid RLS
recursion):

```sql
public.is_store_member(store_id uuid) -> boolean
public.has_store_role(store_id uuid, required_role text) -> boolean
```

`has_store_role` treats roles as a ladder: `owner (3) > manager (2) > cashier (1)`.
Asking for `manager` therefore also satisfies an owner.

`EXECUTE` on both helpers is granted **only** to `authenticated`; `anon` has no
table privileges at all, so an unauthenticated request reads nothing.

## 3.2 Access matrix

| Table | SELECT | INSERT | UPDATE | DELETE |
|---|---|---|---|---|
| `profiles` | self, or a colleague in a shared store | self | self | — |
| `user_roles` | any signed-in user | — | — | — |
| `stores` | member or owner | `owner_id = auth.uid()` | owner | — |
| `store_members` | self, or manager+ | owner | owner | owner (never self) |
| `store_settings` | member | owner | owner | — |
| `categories` | member | manager+ | manager+ | owner |
| `products` | manager+; cashier sees active only | manager+ | manager+ | owner |
| `suppliers` | manager+ | manager+ | manager+ | owner |
| `customers` | manager+ | manager+ | manager+ | owner |
| `sales`, `sale_items`, `payments` | member | RPC only | RPC only | RPC only |
| `purchases`, `purchase_items` | manager+ | RPC only | RPC only | RPC only |
| `stock_movements`, `inventory_adjustments` | manager+ | RPC only | RPC only | RPC only |
| `customer_transactions`, `credit_payments` | manager+ | RPC only | RPC only | RPC only |
| `audit_logs` | owner | RPC only | — | — |
| `invoice_counters` | — | — | — | — |
| `rpc_requests` | — | — | — | — |

"RPC only" means: no INSERT/UPDATE/DELETE policy exists **and** the privilege
was revoked in `004_rls.sql`, so a `POST` to PostgREST is rejected before a
policy is even consulted.

## 3.3 Role capabilities

**Owner** — everything. Reads and writes all store data, manages members and
settings, reads the audit log, can delete master data, can cancel sales.

**Manager** — the operational role. Reads and writes products, categories,
suppliers, customers, purchases, inventory and reports. Creates sales and
purchases, records customer payments, adjusts inventory, cancels sales. Cannot
manage members or settings, and cannot delete master data.

**Cashier** — the counter role. Bills customers through `create_sale`, reads the
sales history for the store, and may record customer payments only when the
store enables `cashier_can_record_payments`. Cannot read `products` (cost
prices) or `customers` (credit limits, addresses) directly; billing uses the
`find_products_for_billing` / `find_customers_for_billing` RPCs, which return
only the columns a till needs. Cannot change prices, delete products, modify
historical sales, or touch settings and users.

## 3.4 Deliberately restricted tables

`invoice_counters` and `rpc_requests` have RLS enabled with **zero** policies and
zero client privileges. They are reachable only from `SECURITY DEFINER`
functions, which run as the table owner.

## 3.5 Why some checks are triggers rather than policies

RLS decides *which rows* a role may touch. It cannot express these rules, so
they are triggers:

| Rule | Mechanism |
|---|---|
| `products.stock_quantity` only changes with a movement | `guard_product_stock` + `ksm.allow_stock_change` flag |
| `customers.current_balance` is derived from the ledger | `guard_customer_balance` + `ksm.allow_balance_change` flag |
| ledgers are append-only | `block_write` |
| sales/purchases are immutable except cancellation bookkeeping | `guard_sale_change`, `guard_purchase_change` |
| the owner membership always exists and cannot be demoted | `guard_store_member_change` |
| one owner per store | `guard_store_member_change` |
| payments never exceed the sale total | `guard_payment_total` |
| customer balance never goes negative | `apply_customer_ledger` |

The `ksm.*` flags are transaction-local GUCs set by the owning RPC with
`set_config(..., is_local => true)`. A client cannot set them: it has no
privilege to run `set_config` on another session, and the flags are used only
inside functions the client cannot read.
