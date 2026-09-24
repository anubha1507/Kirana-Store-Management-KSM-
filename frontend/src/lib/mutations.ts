import type { Customer, Product } from './types';
import type { DemoState } from './demo';

export function demoSupplierNames(): string[] {
  return ['Metro Wholesale', 'Amul Distributor', 'Local Mandi Agent'];
}

export function applyProductCreate(
  state: DemoState,
  input: { name: string; selling_price: number; stock_quantity: number; store_id: string; category_id?: string | null; sku?: string | null; barcode?: string | null; unit?: string },
): Product {
  const now = new Date().toISOString();
  const cleanSku = input.sku?.trim() ? input.sku.trim() : null;
  const cleanBarcode = input.barcode?.trim() ? input.barcode.trim() : null;
  if (cleanSku && state.products.some((p) => p.sku === cleanSku)) {
    throw Object.assign(new Error('SKU must be unique inside this store.'), { code: '23505' });
  }
  if (cleanBarcode && state.products.some((p) => p.barcode === cleanBarcode)) {
    throw Object.assign(new Error('Barcode must be unique inside this store.'), { code: '23505' });
  }
  const p: Product = {
    id: `p-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
    store_id: input.store_id,
    category_id: input.category_id ?? null,
    name: input.name,
    sku: cleanSku,
    barcode: cleanBarcode,
    description: null,
    cost_price: Math.round(input.selling_price * 0.8 * 100) / 100,
    selling_price: input.selling_price,
    stock_quantity: input.stock_quantity,
    unit: input.unit ?? 'piece',
    low_stock_threshold: 5,
    is_active: true,
    created_at: now,
    updated_at: now,
    deleted_at: null,
  };
  state.products.unshift(p);
  return p;
}

export function applyCustomerCreate(
  state: { customers: Customer[] },
  input: { name: string; phone?: string | null; credit_limit?: number; store_id: string },
): Customer {
  const c: Customer = {
    id: `c-${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`,
    store_id: input.store_id,
    name: input.name,
    phone: input.phone?.trim() ? input.phone.trim() : null,
    email: null,
    address: null,
    credit_limit: input.credit_limit ?? 0,
    current_balance: 0,
    is_active: true,
  };
  state.customers.unshift(c);
  return c;
}
