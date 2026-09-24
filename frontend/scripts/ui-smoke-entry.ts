/**
 * Headless smoke test for the in-browser working model.
 *
 * The app runs in two modes. With `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY`
 * set it talks to the PostgreSQL backend in `supabase/migrations`. Without them
 * it runs LOCAL DEMO MODE, where `src/lib/engine.ts` mirrors the database
 * contract so `npm run dev` shows the whole product on localhost.
 *
 * That mirror is application code, so it needs its own verification. This file
 * drives the same lib modules the pages use (`engine`, `demo`, `mutations`,
 * `permissions`, `format`) and asserts the identical business rules that
 * `supabase/tests/01_rls_and_business_rules.sql` proves for PostgreSQL:
 * server-side pricing, the stock ledger invariant, the payment ceiling, the
 * udhaar credit limit, idempotent billing and the role ladder.
 *
 * It is bundled and executed by `scripts/validate-ui.mjs` (`npm run validate:ui`),
 * which also probes the Vite dev server on http://localhost:5173.
 */
import { seedDemo, seedDemoWithHistory, type DemoState } from '../src/lib/demo';
import { DemoEngine } from '../src/lib/engine';
import { applyCustomerCreate, applyProductCreate, demoSupplierNames } from '../src/lib/mutations';
import { can } from '../src/lib/permissions';
import { fmtDate, fmtDateTime, inr, num, todayKey, uid } from '../src/lib/format';

export interface Check {
  name: string;
  ok: boolean;
  detail: string;
}

const round3 = (n: number) => Math.round(n * 1000) / 1000;

/** Reports the SQLSTATE-style code a call produced (or that nothing threw). */
function errorCode(fn: () => unknown): string {
  try {
    fn();
    return '(no error)';
  } catch (e) {
    return (e as { code?: string } | null)?.code ?? '(no code)';
  }
}

export function runUiSmoke(): Check[] {
  const results: Check[] = [];
  const eq = (name: string, actual: unknown, expected: unknown) => {
    const same = typeof actual === 'number' && typeof expected === 'number'
      ? Math.abs(actual - expected) < 1e-9
      : actual === expected;
    results.push({
      name, ok: same,
      detail: same ? `value = ${String(actual)}` : `expected ${String(expected)}, got ${String(actual)}`,
    });
  };
  const ok = (name: string, condition: boolean, detail = '') => {
    results.push({ name, ok: condition, detail: condition ? detail || 'ok' : detail || 'condition failed' });
  };
  const rejects = (name: string, fn: () => unknown, expectedCode: string) => {
    const got = errorCode(fn);
    results.push({
      name, ok: got === expectedCode,
      detail: got === expectedCode ? `rejected with ${expectedCode}` : `expected ${expectedCode}, got ${got}`,
    });
  };

  const year = new Date().getFullYear();
  const state: DemoState = seedDemoWithHistory();
  const engine = new DemoEngine(state);
  const atta = state.products[0];
  const sugar = state.products[2];
  const milk = state.products[4];
  const tea = state.products[7];
  const salt = state.products[9];
  const rahul = state.customers[0];
  const priya = state.customers[1];

  // -------------------------------------------------------------------------
  // 1. the seeded demo store (mirrors supabase/migrations/021_seed_data.sql)
  // -------------------------------------------------------------------------
  eq('U01.1 the demo store is seeded', state.store.name, 'Sharma Kirana Store');
  eq('U01.2 the invoice prefix and year are set',
    `${state.store.invoice_prefix}-${state.store.invoice_year}`, `INV-${year}`);
  eq('U01.3 the opening counter reflects the seeded history', state.store.invoice_seq, 3);
  eq('U01.4 ten catalogue products are seeded', state.products.length, 10);
  eq('U01.5 four categories are seeded', state.categories.length, 4);
  eq('U01.6 two udhaar customers are seeded', state.customers.length, 2);
  eq('U01.7 the demo history holds two bills', state.sales.length, 2);
  eq('U01.8 the demo history holds one purchase', state.purchases.length, 1);
  ok('U01.9 every product belongs to the store',
    state.products.every((p) => p.store_id === state.store.id));
  ok('U01.10 every product is active and unarchived',
    state.products.every((p) => p.is_active && p.deleted_at === null));
  eq('U01.11 a fresh seed has no stock movements', seedDemo().stockMovements.length, 0);
  eq('U01.12 a fresh seed has no bills', seedDemo().sales.length, 0);

  // -------------------------------------------------------------------------
  // 2. invoice numbering (mirrors the invoice_counters sequence)
  // -------------------------------------------------------------------------
  eq('U02.1 the next invoice continues the counter', engine.peekInvoice(), `INV-${year}-000004`);
  ok('U02.2 the invoice number is zero padded to six digits',
    /^INV-\d{4}-000004$/.test(engine.peekInvoice()), engine.peekInvoice());

  // -------------------------------------------------------------------------
  // 3. checkout: server-side pricing and the stock ledger
  // -------------------------------------------------------------------------
  const cash = engine.checkout({
    items: [
      { product_id: atta.id, quantity: 2 },
      { product_id: milk.id, quantity: 3 },
    ],
    payment_method: 'cash',
    discount_amount: 8,
    request_id: 'req-cash-1',
  });

  eq('U03.1 the invoice continues the counter', cash.invoice_number, `INV-${year}-000004`);
  eq('U03.2 subtotal is priced from the catalogue, not the form', cash.subtotal, 688.0);
  eq('U03.3 total = subtotal - discount + tax', cash.total_amount, 680.0);
  eq('U03.4 a settled bill is paid', cash.payment_status, 'paid');
  eq('U03.5 the settled amount equals the total', cash.amount_paid, 680.0);
  eq('U03.6 stock was deducted for the first line', atta.stock_quantity, 20);
  eq('U03.7 stock was deducted for the second line', milk.stock_quantity, 22);
  eq('U03.8 the snapshot keeps the unit price from checkout', cash.lines[1].unit_price, 66);
  eq('U03.9 the line total is quantity * unit price', cash.lines[0].line_total, 490.0);

  const saleMovements = state.stockMovements.filter((m) => m.movement_type === 'sale');
  eq('U03.10 one negative movement per line', saleMovements.length, 2);
  ok('U03.11 sale movements are negative',
    saleMovements.every((m) => m.quantity < 0),
    saleMovements.map((m) => m.quantity).join(', '));
  ok('U03.12 every movement balances previous + quantity = new',
    state.stockMovements.every(
      (m) => round3(m.previous_quantity + m.quantity) === round3(m.new_quantity)),
    `${state.stockMovements.length} movements checked`);
  ok('U03.13 the product was not removed from the catalogue',
    state.products.some((p) => p.id === atta.id));

  // A later price change must not rewrite an invoice that was already issued.
  const milkPriceBefore = milk.selling_price;
  milk.selling_price = 99;
  eq('U03.14 repricing a product leaves the old invoice untouched', cash.lines[1].unit_price, 66);
  milk.selling_price = milkPriceBefore;

  // -------------------------------------------------------------------------
  // 4. idempotent billing (p_request_id)
  // -------------------------------------------------------------------------
  const salesBefore = state.sales.length;
  const attaBefore = atta.stock_quantity;
  const repeat = engine.checkout({
    items: [
      { product_id: atta.id, quantity: 2 },
      { product_id: milk.id, quantity: 3 },
    ],
    payment_method: 'cash',
    discount_amount: 8,
    request_id: 'req-cash-1',
  });
  eq('U04.1 a repeated request returns the same invoice', repeat.invoice_number, cash.invoice_number);
  eq('U04.2 a double tap does not create a second bill', state.sales.length, salesBefore);
  eq('U04.3 a double tap does not deduct stock twice', atta.stock_quantity, attaBefore);
  eq('U04.4 the returned bill is the original one', repeat.id, cash.id);

  // -------------------------------------------------------------------------
  // 5. checkout guards (the database checks these again, independently)
  // -------------------------------------------------------------------------
  const saltStock = salt.stock_quantity;
  rejects('U05.1 an empty bill is refused',
    () => engine.checkout({ items: [], payment_method: 'cash', request_id: uid('r') }), 'P0001');
  rejects('U05.2 a zero quantity is refused',
    () => engine.checkout({ items: [{ product_id: salt.id, quantity: 0 }], payment_method: 'cash', request_id: uid('r') }), '22023');
  rejects('U05.3 a negative quantity is refused',
    () => engine.checkout({ items: [{ product_id: salt.id, quantity: -2 }], payment_method: 'cash', request_id: uid('r') }), '22023');
  rejects('U05.4 a bill beyond the shelf stock is refused',
    () => engine.checkout({ items: [{ product_id: salt.id, quantity: 99999 }], payment_method: 'cash', request_id: uid('r') }), 'P0001');
  rejects('U05.5 an unknown product is refused',
    () => engine.checkout({ items: [{ product_id: 'does-not-exist', quantity: 1 }], payment_method: 'cash', request_id: uid('r') }), 'P0001');
  rejects('U05.6 a line discount above the line total is refused',
    () => engine.checkout({ items: [{ product_id: salt.id, quantity: 1, discount_amount: 500 }], payment_method: 'cash', request_id: uid('r') }), '22023');
  eq('U05.7 a refused bill leaves the stock alone', salt.stock_quantity, saltStock);

  // -------------------------------------------------------------------------
  // 6. udhaar: credit limit, balance and collection
  // -------------------------------------------------------------------------
  eq('U06.1 the seeded customer starts with no udhaar', priya.current_balance, 0);

  const creditSale = engine.checkout({
    items: [{ product_id: tea.id, quantity: 4 }],
    payment_method: 'credit', customer_id: priya.id, request_id: uid('r'),
  });
  eq('U06.2 an unpaid bill is pending, not paid', creditSale.payment_status, 'pending');
  eq('U06.3 nothing has been collected yet on udhaar', creditSale.amount_paid, 0);
  eq('U06.4 the credit sale increases the outstanding balance', priya.current_balance, 1140);
  eq('U06.5 a credit sale still moves stock', tea.stock_quantity, 10);

  rejects('U06.6 a bill beyond the credit limit is refused',
    () => engine.checkout({
      items: [{ product_id: tea.id, quantity: 4 }],
      payment_method: 'credit', customer_id: priya.id, request_id: uid('r'),
    }), 'P0001');
  eq('U06.7 a refused credit bill leaves the shelf alone', tea.stock_quantity, 10);
  eq('U06.8 a refused credit bill leaves the balance alone', priya.current_balance, 1140);

  engine.recordPayment(priya.id, 140);
  eq('U06.9 a payment reduces the outstanding balance', priya.current_balance, 1000);
  rejects('U06.10 a payment above the outstanding balance is refused',
    () => engine.recordPayment(priya.id, 5000), 'P0001');
  rejects('U06.11 a zero payment is refused',
    () => engine.recordPayment(priya.id, 0), '22023');
  rejects('U06.12 a negative payment is refused',
    () => engine.recordPayment(priya.id, -50), '22023');
  eq('U06.13 a refused payment leaves the balance alone', priya.current_balance, 1000);
  eq('U06.14 another customer is unaffected by this ledger', rahul.current_balance, 70);

  // Settling the rest clears the udhaar completely.
  engine.recordPayment(priya.id, 1000);
  eq('U06.15 the udhaar can be cleared to zero', priya.current_balance, 0);

  // -------------------------------------------------------------------------
  // 7. catalogue and customer mutations
  // -------------------------------------------------------------------------
  const created = applyProductCreate(state, {
    name: 'Amul Butter 500g', selling_price: 265, stock_quantity: 8,
    store_id: state.store.id, category_id: state.categories[1].id,
    sku: 'BUTTER-500', barcode: '8901234599999', unit: 'packet',
  });
  ok('U07.1 the new product is in the catalogue',
    state.products.some((p) => p.id === created.id));
  eq('U07.2 a new product starts active', created.is_active, true);
  eq('U07.3 the opening stock is stored', created.stock_quantity, 8);
  eq('U07.4 the unit is stored', created.unit, 'packet');

  rejects('U07.5 a duplicate SKU is refused',
    () => applyProductCreate(state, {
      name: 'Clone', selling_price: 10, stock_quantity: 1, store_id: state.store.id, sku: 'BUTTER-500',
    }), '23505');
  rejects('U07.6 a duplicate barcode is refused',
    () => applyProductCreate(state, {
      name: 'Clone', selling_price: 10, stock_quantity: 1, store_id: state.store.id, barcode: '8901234599999',
    }), '23505');
  const blankSku = applyProductCreate(state, {
    name: 'Loose Dal 1kg', selling_price: 120, stock_quantity: 15,
    store_id: state.store.id, sku: '   ',
  });
  eq('U07.7 a blank SKU is stored as null, not as a duplicate string', blankSku.sku, null);
  ok('U07.8 several products may have no SKU',
    state.products.filter((p) => p.sku === null).length > 1);

  const newCustomer = applyCustomerCreate(state, {
    name: 'Imran Shaikh', phone: ' 99000 11223 ', credit_limit: 3000, store_id: state.store.id,
  });
  eq('U07.9 a new customer starts with no udhaar', newCustomer.current_balance, 0);
  eq('U07.10 the credit limit is stored', newCustomer.credit_limit, 3000);
  eq('U07.11 the phone number is trimmed', newCustomer.phone, '99000 11223');
  ok('U07.12 the new customer is active', newCustomer.is_active);
  ok('U07.13 supplier names are available for purchases', demoSupplierNames().length >= 1);

  // -------------------------------------------------------------------------
  // 8. the role ladder (mirrors supabase/docs/03_rls_matrix.md)
  // -------------------------------------------------------------------------
  for (const action of ['billing', 'sales', 'products-read', 'products-write', 'products-delete',
                        'purchases', 'customers-read', 'customers-write', 'payments',
                        'reports', 'members', 'settings']) {
    ok(`U08.1 the owner may use "${action}"`, can('owner', action));
  }
  for (const action of ['billing', 'sales', 'products-read', 'products-write', 'purchases',
                        'customers-read', 'customers-write', 'payments', 'reports']) {
    ok(`U08.2 the manager may use "${action}"`, can('manager', action));
  }
  ok('U08.3 the manager may not manage members', !can('manager', 'members'));
  ok('U08.4 the manager may not change store settings', !can('manager', 'settings'));
  for (const action of ['billing', 'sales', 'products-read', 'customers-read', 'payments']) {
    ok(`U08.5 the cashier may use "${action}"`, can('cashier', action));
  }
  for (const action of ['products-write', 'products-delete', 'purchases', 'customers-write',
                        'reports', 'members', 'settings']) {
    ok(`U08.6 the cashier may not use "${action}"`, !can('cashier', action));
  }

  return results;
}
