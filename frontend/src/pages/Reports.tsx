import { useEffect, useMemo, useState } from 'react';
import { useApp } from '../app/store';
import { inr } from '../lib/format';
import { apiGet } from '../lib/api';

interface ProductSaleRow {
  product_name: string;
  total_quantity_sold: number;
  total_revenue: number;
}

interface MovementRow {
  id: string;
  product_name: string;
  movement_type: string;
  quantity: number;
  previous_quantity: number;
  new_quantity: number;
}

interface ReportStats {
  revenue: number;
  bills: number;
  udhaar: number;
  movements: number;
  rows: { name: string; qty: number; rev: number }[];
  ledger: MovementRow[];
}

export function ReportsPage() {
  const { engine, mode, version } = useApp();
  void version;
  const [remote, setRemote] = useState<ReportStats | null>(null);
  const [err, setErr] = useState('');

  // Backend mode: summary + product_sales_summary view + stock ledger.
  useEffect(() => {
    if (mode !== 'backend') return;
    let alive = true;
    Promise.all([
      apiGet('reports/summary'),
      apiGet('reports/product-sales'),
      apiGet('reports/movements'),
    ])
      .then(([summary, productSales, ledger]) => {
        if (!alive) return;
        setRemote({
          revenue: summary.all_time.total_sales,
          bills: summary.all_time.total_bills,
          udhaar: summary.store.udhaar_total,
          movements: summary.store.movements,
          rows: (productSales as ProductSaleRow[]).map((r) => ({
            name: r.product_name,
            qty: Number(r.total_quantity_sold),
            rev: Number(r.total_revenue),
          })),
          ledger: ledger as MovementRow[],
        });
      })
      .catch((e) => { if (alive) setErr((e as Error).message); });
    return () => { alive = false; };
  }, [mode, version]);

  const stats = useMemo<ReportStats | null>(() => {
    if (mode === 'backend') return remote;
    if (!engine) return null;
    const map = new Map<string, { name: string; qty: number; rev: number }>();
    for (const s of engine.state.sales) {
      for (const l of s.lines) {
        const e = map.get(l.product_id) ?? { name: l.product_name, qty: 0, rev: 0 };
        e.qty += l.quantity; e.rev += l.line_total; map.set(l.product_id, e);
      }
    }
    const rows = [...map.values()].sort((a, b) => b.rev - a.rev);
    return {
      revenue: engine.state.sales.reduce((a, s) => a + s.total_amount, 0),
      bills: engine.state.sales.length,
      udhaar: engine.state.customers.reduce((a, c) => a + c.current_balance, 0),
      movements: engine.state.stockMovements.length,
      rows,
      ledger: engine.state.stockMovements.slice(0, 20),
    };
  }, [mode, remote, engine]);

  if (!stats) {
    return (
      <p className="muted">
        {err || (mode === 'backend' ? 'Loading reports…' : 'Connect the backend to see live data.')}
      </p>
    );
  }

  return (
    <div className="page">
      <div className="page-head"><div><h2>Reports</h2>
      <p className="muted">Same shape as the SQL views: daily takings, product sales, udhaar.</p></div></div>
      {err && <div className="alert err">{err}</div>}
      <div className="stat-grid">
        <div className="card stat"><div><small>Total revenue</small><strong>{inr(stats.revenue)}</strong></div></div>
        <div className="card stat"><div><small>Bills</small><strong>{stats.bills}</strong></div></div>
        <div className="card stat"><div><small>Udhaar</small><strong>{inr(stats.udhaar)}</strong></div></div>
        <div className="card stat"><div><small>Movements</small><strong>{stats.movements}</strong></div></div>
      </div>
      <div className="card"><div className="card-head"><h3>Product sales</h3></div>
        <table className="tbl"><thead><tr><th>Product</th><th>Qty</th><th>Revenue</th></tr></thead>
        <tbody>{stats.rows.map((r) => <tr key={r.name}><td>{r.name}</td><td>{r.qty}</td><td>{inr(r.rev)}</td></tr>)}</tbody>
        </table></div>
      <div className="card"><div className="card-head"><h3>Stock ledger</h3></div>
        <ul className="rows">{stats.ledger.slice(0, 20).map((m) => (
          <li key={m.id}><span><strong>{m.product_name}</strong><small> · {m.movement_type} {m.quantity}</small></span>
          <span className="muted">{m.previous_quantity} → {m.new_quantity}</span></li>))}
          {!stats.ledger.length && <p className="muted">Movements appear after billing or receiving stock.</p>}
        </ul></div>
    </div>
  );
}