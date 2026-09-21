import { useMemo } from 'react';
import { Link } from 'react-router-dom';
import { IndianRupee, ReceiptText, Package, Users, AlertTriangle } from 'lucide-react';
import { useApp } from '../app/store';
import { inr, fmtDateTime } from '../lib/format';

export function DashboardPage() {
  const { engine, version } = useApp();
  void version;

  const stats = useMemo(() => {
    if (!engine) return null;
    const s = engine.state;
    const today = new Date().toISOString().slice(0, 10);
    const todays = s.sales.filter((x) => x.sold_at.slice(0, 10) === today && !(x as { cancelled_at?: string }).cancelled_at);
    const revenue = todays.reduce((a, x) => a + x.total_amount, 0);
    const low = s.products.filter((p) => !p.deleted_at && p.stock_quantity <= p.low_stock_threshold);
    const udhaar = s.customers.reduce((a, c) => a + c.current_balance, 0);
    return {
      revenue,
      bills: todays.length,
      products: s.products.filter((p) => !p.deleted_at).length,
      low,
      udhaar,
      recent: [...s.sales].slice(0, 6),
    };
  }, [engine]);

  if (!engine || !stats) return <p className="muted">Connect Supabase to see live data.</p>;

  return (
    <div className="page">
      <div className="page-head">
        <div>
          <h2>Namaste, here's today's dhandha</h2>
          <p className="muted">Live view of sales, stock and udhaar for {engine.state.store.name}.</p>
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
          <div><small>Total bills</small><strong>{engine.state.sales.length}</strong><span className="muted">this store</span></div>
        </div>
        <div className="card stat">
          <span className="stat-icon"><Package size={18} /></span>
          <div><small>Active products</small><strong>{stats.products}</strong><span className="muted">{stats.low.length} low stock</span></div>
        </div>
        <div className="card stat">
          <span className="stat-icon"><Users size={18} /></span>
          <div><small>Udhaar outstanding</small><strong>{inr(stats.udhaar)}</strong><span className="muted">{engine.state.customers.length} customers</span></div>
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
