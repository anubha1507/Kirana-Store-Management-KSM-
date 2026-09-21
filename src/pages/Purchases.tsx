import { useState } from 'react';
import { useApp } from '../app/store';
import { inr, fmtDateTime } from '../lib/format';
import { demoSupplierNames } from '../lib/mutations';
import { uid } from '../lib/format';

export function PurchasesPage() {
  const { engine, refresh, version } = useApp();
  const [productId, setProductId] = useState('');
  const [qty, setQty] = useState(10);
  const [cost, setCost] = useState(100);
  const [msg, setMsg] = useState('');
  void version;

  function receive() {
    if (!engine || !productId) return;
    const p = engine.addStock(productId, qty);
    engine.state.purchases.unshift({
      id: uid('pu'), invoice_number: `SUP-${engine.state.purchases.length + 1002}`,
      supplier_id: null, supplier_name: demoSupplierNames()[0],
      total_amount: qty * cost, payment_status: 'paid',
      purchased_at: new Date().toISOString(),
      lines: [{ product_name: p.name, quantity: qty, unit_cost: cost, total_cost: qty * cost }],
    });
    setMsg(`Received ${qty} x ${p.name}. Stock now ${p.stock_quantity}.`);
    refresh();
  }

  if (!engine) return <p className="muted">Supabase mode.</p>;
  return (
    <div className="page">
      <div className="page-head"><div><h2>Purchases</h2>
      <p className="muted">Goods-in writes a purchase movement per product.</p></div></div>
      {msg && <div className="alert ok">{msg}</div>}
      <div className="card"><div className="inline-form">
        <select value={productId} onChange={(e) => setProductId(e.target.value)}>
          <option value="">Choose product…</option>
          {engine.state.products.filter((p) => !p.deleted_at).map((p) => (
            <option key={p.id} value={p.id}>{p.name} ({p.stock_quantity})</option>))}
        </select>
        <input type="number" value={qty} onChange={(e) => setQty(Number(e.target.value))} placeholder="Qty" />
        <input type="number" value={cost} onChange={(e) => setCost(Number(e.target.value))} placeholder="Unit cost" />
        <button className="btn primary sm" onClick={receive} disabled={!productId}>Receive stock</button>
      </div></div>
      <div className="card"><div className="card-head"><h3>History</h3></div>
        <ul className="rows">{engine.state.purchases.map((pu) => (
          <li key={pu.id}><span><strong>{pu.invoice_number}</strong>
          <small> · {pu.supplier_name} · {fmtDateTime(pu.purchased_at)}</small></span>
          <strong>{inr(pu.total_amount)}</strong></li>))}</ul></div>
    </div>
  );
}
