import { useEffect, useState } from 'react';
import { useApp } from '../app/store';
import { inr, fmtDateTime } from '../lib/format';
import { uid } from '../lib/format';
import { demoSupplierNames } from '../lib/mutations';
import { apiGet, apiPost } from '../lib/api';

interface ProductOption {
  id: string;
  name: string;
  stock_quantity: number;
  deleted_at: string | null;
}

interface PurchaseRow {
  id: string;
  invoice_number: string;
  supplier_name?: string | null;
  total_amount: number;
  payment_status?: string;
  purchased_at: string;
}

export function PurchasesPage() {
  const { engine, mode, refresh, version } = useApp();
  const [productId, setProductId] = useState('');
  const [qty, setQty] = useState(10);
  const [cost, setCost] = useState(100);
  const [msg, setMsg] = useState('');
  const [err, setErr] = useState('');
  const [products, setProducts] = useState<ProductOption[] | null>(null);
  const [purchases, setPurchases] = useState<PurchaseRow[] | null>(null);
  void version;

  // Backend mode: GET /api/products + GET /api/purchases on mount/refresh.
  useEffect(() => {
    if (mode !== 'backend') return;
    let alive = true;
    Promise.all([apiGet('products'), apiGet('purchases')])
      .then(([p, pu]) => {
        if (alive) {
          setProducts(p as ProductOption[]);
          setPurchases(pu as PurchaseRow[]);
        }
      })
      .catch((e) => { if (alive) setErr((e as Error).message); });
    return () => { alive = false; };
  }, [mode, version]);

  const productOptions: ProductOption[] = mode === 'backend'
    ? (products ?? [])
    : (engine?.state.products ?? []);
  const history: PurchaseRow[] = mode === 'backend'
    ? (purchases ?? [])
    : (engine?.state.purchases ?? []);

  async function receive() {
    if (!productId) return;
    setErr('');
    if (mode === 'backend') {
      try {
        // POST /api/purchases → create_purchase RPC (stock ledger + WAC).
        const created = await apiPost('purchases', {
          items: [{ product_id: productId, quantity: qty, unit_cost: cost }],
          payment_status: 'paid',
        });
        const p = productOptions.find((x) => x.id === productId);
        setMsg(`Received ${qty} x ${p?.name ?? 'item'}${created?.invoice_number ? ` · ${created.invoice_number}` : ''}. Stock updated.`);
        refresh();
      } catch (e) {
        setErr((e as Error).message);
      }
      return;
    }
    if (!engine) return;
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

  return (
    <div className="page">
      <div className="page-head"><div><h2>Purchases</h2>
      <p className="muted">Goods-in writes a purchase movement per product.</p></div></div>
      {msg && <div className="alert ok">{msg}</div>}
      {err && <div className="alert err">{err}</div>}
      {mode === 'backend' && (products === null || purchases === null) && !err && (
        <p className="muted">Loading purchases…</p>
      )}
      <div className="card"><div className="inline-form">
        <select value={productId} onChange={(e) => setProductId(e.target.value)}>
          <option value="">Choose product…</option>
          {productOptions.filter((p) => !p.deleted_at).map((p) => (
            <option key={p.id} value={p.id}>{p.name} ({p.stock_quantity})</option>))}
        </select>
        <input type="number" value={qty} onChange={(e) => setQty(Number(e.target.value))} placeholder="Qty" />
        <input type="number" value={cost} onChange={(e) => setCost(Number(e.target.value))} placeholder="Unit cost" />
        <button className="btn primary sm" onClick={receive} disabled={!productId}>Receive stock</button>
      </div></div>
      <div className="card"><div className="card-head"><h3>History</h3></div>
        <ul className="rows">{history.map((pu) => (
          <li key={pu.id}><span><strong>{pu.invoice_number}</strong>
          <small> · {pu.supplier_name ?? 'Supplier'} · {fmtDateTime(pu.purchased_at)}</small></span>
          <strong>{inr(pu.total_amount)}</strong></li>))}</ul></div>
    </div>
  );
}