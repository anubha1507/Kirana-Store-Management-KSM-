import type { Database } from './database.types';

export type AppRole = 'owner' | 'manager' | 'cashier';

export interface Product {
  id: string;
  store_id: string;
  category_id: string | null;
  name: string;
  sku: string | null;
  barcode: string | null;
  description: string | null;
  cost_price: number;
  selling_price: number;
  stock_quantity: number;
  unit: string;
  low_stock_threshold: number;
  is_active: boolean;
  created_at: string;
  updated_at: string;
  deleted_at: string | null;
}

export interface Category {
  id: string;
  store_id: string;
  name: string;
  description: string | null;
}

export interface Supplier {
  id: string;
  store_id: string;
  name: string;
  phone: string | null;
  email: string | null;
  address: string | null;
  gst_number: string | null;
  is_active: boolean;
}

export interface Customer {
  id: string;
  store_id: string;
  name: string;
  phone: string | null;
  email: string | null;
  address: string | null;
  credit_limit: number;
  current_balance: number;
  is_active: boolean;
}

export interface SaleLine {
  product_id: string;
  quantity: number;
  discount_amount?: number;
}

export interface ResolvedSaleLine extends SaleLine {
  product_name: string;
  unit_price: number;
  line_total: number;
}

export interface SaleRecord {
  id: string;
  invoice_number: string;
  total_amount: number;
  subtotal: number;
  discount_amount: number;
  tax_amount: number;
  payment_method: string;
  payment_status: string;
  customer_id: string | null;
  sold_at: string;
  lines: ResolvedSaleLine[];
  amount_paid: number;
}

export type Db = Database;
