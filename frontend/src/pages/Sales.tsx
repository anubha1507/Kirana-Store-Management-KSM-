import { useEffect, useState } from 'react';
import { useApp } from '../app/store';
import { inr, fmtDateTime } from '../lib/format';
import { apiGet } from '../lib/api';

interface SaleRow {
  id: string;
  invoice_number: string;
  sold_at: string;
  payment_method: string;
  payment_status: string;
  total_amount: number;
}

export function SalesPage() {
  const { engine, mode, version } = useApp();
  void version;
  const [rows, setRows] = useState<SaleRow[] | null>(null);
  const [err, setErr] = useState('');

  // Backend mode: GET /api/sales on mount and after any refresh().
  useEffect(() => {
    if (mode !== 'backend') return;
    let alive = true;
    setErr('');
    apiGet('sales')
      .then((d: SaleRow[]) => { if (alive) setRows(d); })
      .catch((e) => { if (alive) setErr((e as Error).message); });
    return () => { alive = false; };
  }, [mode, version]);

  if (mode === 'backend') {
    return (
      <div className="page">
        <div className="page-head"><div><h2>Sales history</h2>
        <p className="muted">{rows ? rows.length : '—'} bills · loaded live from GET /api/sales.</p></div></div>
        {err && <div className="alert err">{err}</div>}
        <div className="card"><ul className="rows">
          {rows?.map((s) => (
            <li key={s.id}><span><strong>{s.invoice_number}</strong>
            <small> · {fmtDateTime(s.sold_at)} · {s.payment_method} · {s.payment_status}</small></span>
            <strong>{inr(s.total_amount)}</strong></li>))}
          {rows && !rows.length && <p className="muted">No bills yet.</p>}
          {!rows && !err && <p className="muted">Loading…</p>}
        </ul></div>
      </div>
    );
  }

  if (!engine) return <p className="muted">Local demo engine unavailable.</p>;
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