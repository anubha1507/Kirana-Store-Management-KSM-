import { useApp } from '../app/store';
import { inr, fmtDateTime } from '../lib/format';

export function SalesPage() {
  const { engine, version } = useApp();
  void version;
  if (!engine) return <p className="muted">Supabase mode.</p>;
  return (
    <div className="page">
      <div className="page-head"><div><h2>Sales history</h2>
      <p className="muted">{engine.state.sales.length} bills · invoices preserved with snapshots.</p></div></div>
      <div className="card"><ul className="rows">
        {engine.state.sales.map((s) => (
          <li key={s.id}><span><strong>{s.invoice_number}</strong>
          <small> · {fmtDateTime(s.sold_at)} · {s.payment_method} · {s.payment_status}</small>
          <br /><small>{s.lines.map((l) => `${l.product_name} x${l.quantity}`).join(', ')}</small></span>
          <strong>{inr(s.total_amount)}</strong></li>))}
        {!engine.state.sales.length && <p className="muted">No bills yet.</p>}
      </ul></div>
    </div>
  );
}
