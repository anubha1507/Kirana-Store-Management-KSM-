import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { IndianRupee, ReceiptText, Package, Users, AlertTriangle } from 'lucide-react';
import { useApp } from '../app/store';
import { inr, fmtDateTime } from '../lib/format';
import { apiGet } from '../lib/api';

interface SummaryData {
  today: { total_bills: number; total_sales: number; total_discount: number; total_tax: number };
  all_time: { total_bills: number; total_sales: number };
  store: { active_products: number; low_stock_count: number; customers: number; udhaar_total: number; movements: number };
}

interface SaleRow {
  id: string;
  invoice_number: string;
  sold_at: string;
  payment_method: string;
  total_amount: number;
}

interface ProductRow {
  id: string;
  name: string;
  stock_quantity: number;
  low_stock_threshold: number;
  unit: string;
  deleted_at: string | null;
}

interface CustomerRow {
  id: string;
  current_balance: number;
}

interface Stats {
  revenue: number;
  bills: number;
  totalBills: number;
  products: number;
  low: ProductRow[];
  udhaar: number;
  customers: number;
  recent: SaleRow[];
}

export function DashboardPage() {
  const { engine, mode, version } = useApp();
  void version;
  const [remote, setRemote] = useState<{
    summary: SummaryData;
    sales: SaleRow[];
    products: ProductRow[];
    customers: CustomerRow[];
  } | null>(null);
  const [err, setErr] = useState('');

  // Backend mode: one parallel batch — reports/summary + the three lists.
  useEffect(() => {
    if (mode !== 'backend') return;
    let alive = true;
    Promise.all([
      apiGet('reports/summary'),
      apiGet('sales'),
      apiGet('products'),
      apiGet('customers'),
    ])
      .then(([summary, sales, products, customers]) => {
        if (alive) setRemote({ summary, sales, products, customers });
      })
      .catch((e) => { if (alive) setErr((e as Error).message); });
    return () => { alive = false; };
  }, [mode, version]);

  const stats = useMemo<Stats | null>(() => {
    if (mode === 'backend') {
      if (!remote) return null;
      const { summary, sales, products, customers } = remote;
      return {
        revenue: summary.today.total_sales,
        bills: summary.today.total_bills,
        totalBills: summary.all_time.total_bills,
        products: products.filter((p) => !p.deleted_at).length,
        low: products.filter((p) => !p.deleted_at && p.stock_quantity <= p.low_stock_threshold),
        udhaar: customers.reduce((a, c) => a + Number(c.current_balance), 0),
        customers: customers.length,
        recent: sales.slice(0, 6),
      };
    }
    if (!engine) return null;
    const s = engine.state;
    const today = new Date().toISOString().slice(0, 10);
    const todays = s.sales.filter((x) => x.sold_at.slice(0, 10) === today && !(x as { cancelled_at?: string }).cancelled_at);
    return {
      revenue: todays.reduce((a, x) => a + x.total_amount, 0),
      bills: todays.length,
      totalBills: s.sales.length,
      products: s.products.filter((p) => !p.deleted_at).length,
      low: s.products.filter((p) => !p.deleted_at && p.stock_quantity <= p.low_stock_threshold),
      udhaar: s.customers.reduce((a, c) => a + c.current_balance, 0),
      customers: s.customers.length,
      recent: [...s.sales].slice(0, 6),
    };
  }, [mode, remote, engine]);

  if (!stats) {
    return (
      <p className="muted">
        {err || (mode === 'backend' ? 'Loading live data…' : 'Connect the backend to see live data.')}
      </p>
    );
  }

  const storeName = engine?.state.store.name ?? 'your store';

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h2>Namaste, here's today's dhandha</h2>
          <p className="muted">Live view of sales, stock and udhaar for {storeName}.</p>
        </div>
        <Link className="btn primary" to="/billing">New bill</Link>
      </div>

      <div className="stat-grid">
        <div className="card stat">
          <span className="stat-icon"><IndianRupee size={18} /></span>
          <div><small>Today's revenue</small><strong>{inr(stats.revenue)}</strong><span className="muted">{stats.bills} bills</span></div>
        </div>
        <div className="card stat">
          <span className="stat-icon"><ReceiptText size={18} /></span>
          <div><small>Total bills</small><strong>{stats.totalBills}</strong><span className="muted">this store</span></div>
        </div>
        <div className="card stat">
          <span className="stat-icon"><Package size={18} /></span>
          <div><small>Active products</small><strong>{stats.products}</strong><span className="muted">{stats.low.length} low stock</span></div>
        </div>
        <div className="card stat">
          <span className="stat-icon"><Users size={18} /></span>
          <div><small>Udhaar outstanding</small><strong>{inr(stats.udhaar)}</strong><span className="muted">{stats.customers} customers</span></div>
        </div>
      </div>

      <div className="grid-2">
        <div className="card">
          <div className="card-head"><h3>Recent bills</h3><Link to="/sales">View all</Link></div>
          {stats.recent.length === 0 && <p className="muted">No bills yet. Create the first one from Billing.</p>}
          <ul className="rows">
            {stats.recent.map((s) => (
              <li key={s.id}>
                <span><strong>{s.invoice_number}</strong><small> · {fmtDateTime(s.sold_at)} · {s.payment_method}</small></span>
                <strong>{inr(s.total_amount)}</strong>
              </li>
            ))}
          </ul>
        </div>
        <div className="card">
          <div className="card-head"><h3><AlertTriangle size={15} /> Low stock alerts</h3><Link to="/products">Manage</Link></div>
          {stats.low.length === 0 && <p className="muted">All stocked up. Nothing below threshold.</p>}
          <ul className="rows">
            {stats.low.map((p) => (
              <li key={p.id}>
                <span><strong>{p.name}</strong><small> · {p.stock_quantity} {p.unit} left (min {p.low_stock_threshold})</small></span>
                <span className="pill warn">reorder</span>
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  );
}