import { useMemo, useState } from 'react';
import { useApp, can } from '../app/store';
import { inr } from '../lib/format';
import { applyProductCreate } from '../lib/mutations';

export function ProductsPage() {
  const { engine, role, refresh, version } = useApp();
  const [q, setQ] = useState('');
  const [name, setName] = useState('');
  const [price, setPrice] = useState(100);
  const [stock, setStock] = useState(10);
  const [err, setErr] = useState('');
  void version;

  const list = useMemo(() => {
    if (!engine) return [];
    const s = q.trim().toLowerCase();
    return engine.state.products.filter((p) => !p.deleted_at && (!s || p.name.toLowerCase().includes(s)));
  }, [engine, q]);

  function create() {
    if (!engine) return;
    setErr('');
    try {
      applyProductCreate(engine.state, {
        store_id: engine.state.store.id, name, selling_price: price, stock_quantity: stock,
      });
      setName(''); refresh();
    } catch (e) { setErr((e as Error).message); }
  }

  if (!engine) return <p className="muted">Supabase mode.</p>;
  const editable = can(role, 'products-read') && role !== 'cashier';
  return (
    <div className="page">
      <div className="page-head"><div><h2>Products</h2>
      <p className="muted">{list.length} active · low-stock flagged at threshold.</p></div></div>
      {err && <div className="alert err">{err}</div>}
      {editable && (
        <div className="card"><div className="inline-form">
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder="New product name" />
          <input type="number" value={price} onChange={(e) => setPrice(Number(e.target.value))} placeholder="Price" />
          <input type="number" value={stock} onChange={(e) => setStock(Number(e.target.value))} placeholder="Stock" />
          <button className="btn primary sm" onClick={create} disabled={!name.trim()}>Add product</button>
        </div></div>
      )}
      <div className="card"><div className="card-head"><h3>Catalogue</h3>
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search…" /></div>
        <table className="tbl"><thead><tr><th>Product</th><th>Price</th><th>Stock</th><th>Status</th></tr></thead>
        <tbody>{list.map((p) => (
          <tr key={p.id}><td>{p.name}</td><td>{inr(p.selling_price)}</td>
          <td>{p.stock_quantity} {p.unit}</td>
          <td>{p.stock_quantity <= p.low_stock_threshold ? 'reorder' : 'ok'}</td></tr>))}
        </tbody></table></div>
    </div>
  );
}
