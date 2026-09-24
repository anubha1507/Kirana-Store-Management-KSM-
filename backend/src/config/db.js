import pg from 'pg';
import { env } from './env.js';

const pool = new pg.Pool({
  connectionString: env.databaseUrl,
  max: env.nodeEnv === 'production' ? 10 : 5,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  console.error('Unexpected PostgreSQL pool error:', err);
});

export const db = {
  pool,
  query: (text, params) => pool.query(text, params),
  connect: () => pool.connect(),
};

/**
 * Runs `fn(client)` on a dedicated connection inside a transaction with
 * `request.jwt.claims` set to the given user, so auth.uid()/auth.role() inside
 * SECURITY DEFINER RPCs (create_sale, create_purchase, record_customer_payment,
 * create_store, ...) resolve the caller exactly like Supabase's PostgREST
 * would. All statements in `fn` must go through `client`, not the pool.
 */
export async function withAuth(user, fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const claims = JSON.stringify({
      sub: user.id,
      role: 'authenticated',
      email: user.email || null,
      store_id: user.storeId || null,
      aud: env.jwtAudience,
      iss: env.jwtIssuer,
    });
    await client.query(`SELECT set_config('request.jwt.claims', $1, true)`, [claims]);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    try {
      await client.query('ROLLBACK');
    } catch { /* connection may already be broken */ }
    throw error;
  } finally {
    client.release();
  }
}

export async function healthCheckDb() {
  const result = await db.query('SELECT 1 AS ok');
  return result.rowCount === 1;
}

export { pool };
