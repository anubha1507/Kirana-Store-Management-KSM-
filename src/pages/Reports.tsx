import { useMemo } from 'react';
import { useApp } from '../app/store';
import { inr } from '../lib/format';

export function ReportsPage() {
  const { engine, version } = useApp();
  void version;
  const rows = useMemo(() => {
    if (!engine) return [];
    const map = new Map<string, { name: string; qty: number; rev: number }>();
    for (const s of engine.state.sales) {
      for (const l of s.lines) {
        const e = map.get(l.product_id) ?? { name: l.product_name, qty: 0, rev: 0 };
        e.qty += l.quantity; e.rev += l.line_total; map.set(l.product_id, e);
      }
    }
    return [...map.values()].sort((a, b) => b.rev - a.rev);
  }, [engine]);

  if (!engine) return <p className="muted">Supabase mode.</p>;
  const revenue = engine.state.sales.reduce((a, s) => a + s.total_amount, 0);
  const udhaar = engine.state.customers.reduce((a, c) => a + c.current_balance, 0);
  return (
    <div className="page">
      <div className="page-head"><div><h2>Reports</h2>
      <p className="muted">Same shape as the SQL views: daily takings, product sales, udhaar.</p></div></div>
      <div className="stat-grid">
        <div className="card stat"><div><small>Total revenue</small><strong>{inr(revenue)}</strong></div></div>
        <div className="card stat"><div><small>Bills</small><strong>{engine.state.sales.length}</strong></div></div>
        <div className="card stat"><div><small>Udhaar</small><strong>{inr(udhaar)}</strong></div></div>
        <div className="card stat"><div><small>Movements</small><strong>{engine.state.stockMovements.length}</strong></div></div>
      </div>
      <div className="card"><div className="card-head"><h3>Product sales</h3></div>
        <table className="tbl"><thead><tr><th>Product</th><th>Qty</th><th>Revenue</th></tr></thead>
        <tbody>{rows.map((r) => <tr key={r.name}><td>{r.name}</td><td>{r.qty}</td><td>{inr(r.rev)}</td></tr>)}</tbody>
        </table></div>
      <div className="card"><div className="card-head"><h3>Stock ledger</h3></div>
        <ul className="rows">{engine.state.stockMovements.slice(0, 20).map((m) => (
          <li key={m.id}><span><strong>{m.product_name}</strong><small> · {m.movement_type} {m.quantity}</small></span>
          <span className="muted">{m.previous_quantity} → {m.new_quantity}</span></li>))}
          {!engine.state.stockMovements.length && <p className="muted">Movements appear after billing or receiving stock.</p>}
        </ul></div>
    </div>
  );
}
