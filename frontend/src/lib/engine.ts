import type { Customer, Product, ResolvedSaleLine, SaleRecord } from './types';
import type { DemoState } from './demo';
import { uid } from './format';

export interface CartInput {
  product_id: string;
  quantity: number;
  discount_amount?: number;
}

export interface CheckoutInput {
  items: CartInput[];
  payment_method: string;
  customer_id?: string | null;
  discount_amount?: number;
  tax_amount?: number;
  request_id: string;
}

function coded(message: string, code: string): Error {
  return Object.assign(new Error(message), { code });
}

// Local mirror of the create_sale / record_customer_payment contract in
// the SQL migrations: server-side pricing, stock guard, payment ceiling,
// credit-limit guard and per-action idempotency.
export class DemoEngine {
  state: DemoState;
  private lastSaleByRequest = new Map<string, SaleRecord>();

  constructor(state: DemoState) {
    this.state = state;
  }

  nextInvoice(): string {
    const s = this.state.store;
    s.invoice_seq += 1;
    return `${s.invoice_prefix}-${s.invoice_year}-${String(s.invoice_seq).padStart(6, '0')}`;
  }

  peekInvoice(): string {
    const s = this.state.store;
    return `${s.invoice_prefix}-${s.invoice_year}-${String(s.invoice_seq + 1).padStart(6, '0')}`;
  }

  checkout(input: CheckoutInput): SaleRecord {
    if (!input.items.length) throw coded('Add at least one item to the bill.', 'P0001');
    const prior = this.lastSaleByRequest.get(input.request_id);
    if (prior) return prior;

    const lines: ResolvedSaleLine[] = [];
    let subtotal = 0;
    for (const it of input.items) {
      const p = this.state.products.find((x) => x.id === it.product_id && !x.deleted_at);
      if (!p) throw coded('A product on this bill is no longer available.', 'P0001');
      if (it.quantity <= 0) throw coded('Quantity must be greater than zero.', '22023');
      if (p.stock_quantity < it.quantity) {
        throw coded(`Insufficient stock for ${p.name} (have ${p.stock_quantity}).`, 'P0001');
      }
      const disc = it.discount_amount ?? 0;
      const lineTotal = Math.round((p.selling_price * it.quantity - disc) * 100) / 100;
      if (lineTotal < 0) throw coded('Line discount exceeds the line total.', '22023');
      subtotal += lineTotal;
      lines.push({
        product_id: p.id, quantity: it.quantity, discount_amount: disc,
        product_name: p.name, unit_price: p.selling_price, line_total: lineTotal,
      });
    }
    subtotal = Math.round(subtotal * 100) / 100;
    const billDisc = input.discount_amount ?? 0;
    const tax = input.tax_amount ?? 0;
    const total = Math.round((subtotal - billDisc + tax) * 100) / 100;
    if (total <= 0) throw coded('Bill total must be greater than zero.', '22023');

    const isCredit = input.payment_method === 'credit';
    if (isCredit && input.customer_id) {
      const c = this.state.customers.find((x) => x.id === input.customer_id);
      if (c && c.current_balance + total > c.credit_limit) {
        throw coded(`${c.name} would exceed the credit limit of Rs.${c.credit_limit}.`, 'P0001');
      }
    }

    for (const ln of lines) {
      const p = this.state.products.find((x) => x.id === ln.product_id)!;
      const prev = p.stock_quantity;
      p.stock_quantity = Math.round((p.stock_quantity - ln.quantity) * 1000) / 1000;
      this.state.stockMovements.unshift({
        id: uid('m'), product_id: p.id, product_name: p.name,
        movement_type: 'sale', quantity: -ln.quantity,
        previous_quantity: prev, new_quantity: p.stock_quantity,
        created_at: new Date().toISOString(),
      });
    }

    if (isCredit && input.customer_id) {
      const c = this.state.customers.find((x) => x.id === input.customer_id);
      if (c) c.current_balance = Math.round((c.current_balance + total) * 100) / 100;
    }

    const sale: SaleRecord = {
      id: uid('s'), invoice_number: this.nextInvoice(), total_amount: total,
      subtotal, discount_amount: billDisc, tax_amount: tax,
      payment_method: input.payment_method,
      payment_status: isCredit ? 'pending' : 'paid',
      customer_id: input.customer_id ?? null,
      sold_at: new Date().toISOString(), lines,
      amount_paid: isCredit ? 0 : total,
    };
    this.state.sales.unshift(sale);
    this.lastSaleByRequest.set(input.request_id, sale);
    return sale;
  }

  recordPayment(customerId: string, amount: number): Customer {
    const c = this.state.customers.find((x) => x.id === customerId);
    if (!c) throw new Error('Customer not found.');
    if (amount <= 0) throw coded('Amount must be greater than zero.', '22023');
    if (amount > c.current_balance) throw coded('Payment exceeds the outstanding balance.', 'P0001');
    c.current_balance = Math.round((c.current_balance - amount) * 100) / 100;
    return c;
  }

  addStock(productId: string, qty: number): Product {
    const p = this.state.products.find((x) => x.id === productId);
    if (!p) throw new Error('Product not found.');
    if (qty <= 0) throw coded('Quantity must be greater than zero.', '22023');
    const prev = p.stock_quantity;
    p.stock_quantity = Math.round((p.stock_quantity + qty) * 1000) / 1000;
    this.state.stockMovements.unshift({
      id: uid('m'), product_id: p.id, product_name: p.name,
      movement_type: 'purchase', quantity: qty,
      previous_quantity: prev, new_quantity: p.stock_quantity,
      created_at: new Date().toISOString(),
    });
    return p;
  }
}
