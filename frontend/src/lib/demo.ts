import type { Customer, Product, SaleRecord } from './types';
import { uid } from './format';

export interface DemoCategory {
  id: string;
  name: string;
  description: string | null;
}

export interface DemoSupplier {
  id: string;
  name: string;
  phone: string | null;
  address: string | null;
}

export interface DemoPurchaseLine {
  product_name: string;
  quantity: number;
  unit_cost: number;
  total_cost: number;
}

export interface DemoPurchase {
  id: string;
  invoice_number: string;
  supplier_id: string | null;
  supplier_name: string;
  total_amount: number;
  payment_status: string;
  purchased_at: string;
  lines: DemoPurchaseLine[];
}

export interface DemoMovement {
  id: string;
  product_id: string;
  product_name: string;
  movement_type: string;
  quantity: number;
  previous_quantity: number;
  new_quantity: number;
  created_at: string;
}

export interface DemoStoreInfo {
  id: string;
  name: string;
  phone: string;
  city: string;
  invoice_prefix: string;
  invoice_year: number;
  invoice_seq: number;
}

export interface DemoState {
  store: DemoStoreInfo;
  categories: DemoCategory[];
  products: Product[];
  customers: Customer[];
  sales: SaleRecord[];
  purchases: DemoPurchase[];
  stockMovements: DemoMovement[];
}

const STORE_ID = 'demo-store-1';

function product(
  id: string,
  category_id: string,
  name: string,
  selling_price: number,
  stock_quantity: number,
  extra: Partial<Product> = {},
): Product {
  const now = new Date().toISOString();
  return {
    id, store_id: STORE_ID, category_id, name,
    sku: null, barcode: null, description: null,
    cost_price: Math.round(selling_price * 0.8 * 100) / 100,
    selling_price, stock_quantity, unit: 'piece',
    low_stock_threshold: 5, is_active: true,
    created_at: now, updated_at: now, deleted_at: null,
    ...extra,
  };
}

export function seedDemo(): DemoState {
  const catStaples = uid('cat');
  const catDairy = uid('cat');
  const catSnacks = uid('cat');
  const catHome = uid('cat');
  const atta = product(uid('p'), catStaples, 'Aashirvaad Atta 5kg', 245, 22,
    { sku: 'ATT-5KG', barcode: '8901234500011', unit: 'bag', low_stock_threshold: 4 });
  const rice = product(uid('p'), catStaples, 'India Gate Basmati Rice 1kg', 132, 40, { sku: 'RICE-1KG', unit: 'packet' });
  const sugar = product(uid('p'), catStaples, 'Sugar 1kg', 46, 55, { unit: 'packet' });
  const oil = product(uid('p'), catStaples, 'Fortune Sunflower Oil 1L', 148, 18, { unit: 'bottle' });
  const milk = product(uid('p'), catDairy, 'Amul Taaza Milk 1L', 66, 25, { unit: 'liter' });
  const curd = product(uid('p'), catDairy, 'Amul Curd 400g', 35, 20, { unit: 'packet' });
  const biscuits = product(uid('p'), catSnacks, 'Parle-G Gold 200g', 25, 80, { unit: 'packet' });
  const tea = product(uid('p'), catSnacks, 'Tata Tea Gold 500g', 285, 14, { unit: 'packet' });
  const soap = product(uid('p'), catHome, 'Surf Excel Bar 200g', 32, 4, { unit: 'piece' });
  const salt = product(uid('p'), catStaples, 'Tata Salt 1kg', 28, 60, { unit: 'packet' });
  return {
    store: {
      id: STORE_ID, name: 'Sharma Kirana Store', phone: '98765 43210',
      city: 'Pune', invoice_prefix: 'INV',
      invoice_year: new Date().getFullYear(), invoice_seq: 3,
    },
    categories: [
      { id: catStaples, name: 'Staples', description: 'Atta, rice, dal and sugar' },
      { id: catDairy, name: 'Dairy', description: 'Milk, curd and paneer' },
      { id: catSnacks, name: 'Snacks & Beverages', description: 'Biscuits, tea and namkeen' },
      { id: catHome, name: 'Home Care', description: 'Soap and cleaning' },
    ],
    products: [atta, rice, sugar, oil, milk, curd, biscuits, tea, soap, salt],
    customers: [
      { id: uid('c'), store_id: STORE_ID, name: 'Rahul Verma', phone: '98111 22334', email: null, address: 'Lane 4, Koregaon Park', credit_limit: 5000, current_balance: 70, is_active: true },
      { id: uid('c'), store_id: STORE_ID, name: 'Priya Nair', phone: '98220 44556', email: null, address: 'Plot 12, Kothrud', credit_limit: 2000, current_balance: 0, is_active: true },
    ],
    sales: [],
    purchases: [],
    stockMovements: [],
  };
}

export function seedDemoWithHistory(): DemoState {
  const s = seedDemo();
  const now = new Date().toISOString();
  const atta = s.products[0];
  const sugar = s.products[2];
  const salt = s.products[9];
  const milk = s.products[4];
  s.sales = [
    {
      id: uid('s'), invoice_number: 'INV-2026-000001', total_amount: 568,
      subtotal: 568, discount_amount: 0, tax_amount: 0, payment_method: 'upi',
      payment_status: 'paid', customer_id: null, sold_at: now, amount_paid: 568,
      lines: [
        { product_id: atta.id, quantity: 2, product_name: atta.name, unit_price: 245, line_total: 490 },
        { product_id: sugar.id, quantity: 1, product_name: sugar.name, unit_price: 46, line_total: 46 },
        { product_id: salt.id, quantity: 1, product_name: salt.name, unit_price: 28, line_total: 28 },
      ],
    },
    {
      id: uid('s'), invoice_number: 'INV-2026-000002', total_amount: 330,
      subtotal: 330, discount_amount: 0, tax_amount: 0, payment_method: 'credit',
      payment_status: 'pending', customer_id: s.customers[0].id, sold_at: now, amount_paid: 0,
      lines: [{ product_id: milk.id, quantity: 5, product_name: milk.name, unit_price: 66, line_total: 330 }],
    },
  ];
  s.purchases = [
    {
      id: uid('pu'), invoice_number: 'SUP-1001', supplier_id: null,
      supplier_name: 'Metro Wholesale', total_amount: 1000,
      payment_status: 'paid', purchased_at: now,
      lines: [{ product_name: atta.name, quantity: 10, unit_cost: 100, total_cost: 1000 }],
    },
  ];
  return s;
}
