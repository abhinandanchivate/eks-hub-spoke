// ============================================================
// microservice-a/src/app.js
// Node.js / Express microservice — connects to PostgreSQL via SSL
// ============================================================

const express = require('express');
const { Pool } = require('pg');
const promClient = require('prom-client');

const app = express();
app.use(express.json());

// ── Prometheus metrics ────────────────────────────────────────
const register = new promClient.Registry();
promClient.collectDefaultMetrics({ register });

const httpRequestDuration = new promClient.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.01, 0.05, 0.1, 0.3, 0.5, 1, 2, 5],
  registers: [register],
});

const dbQueryDuration = new promClient.Histogram({
  name: 'db_query_duration_seconds',
  help: 'Duration of PostgreSQL queries',
  labelNames: ['query_name'],
  registers: [register],
});

// ── PostgreSQL connection pool ────────────────────────────────
const pool = new Pool({
  host:     process.env.DB_HOST,
  port:     parseInt(process.env.DB_PORT || '5432'),
  database: process.env.DB_NAME,
  user:     process.env.DB_USER,
  password: process.env.DB_PASSWORD,
  ssl: {
    rejectUnauthorized: true,   // enforce SSL certificate validation
    ca: process.env.DB_CA_CERT, // RDS CA bundle (optional, set in env)
  },
  min:                    parseInt(process.env.DB_POOL_MIN || '2'),
  max:                    parseInt(process.env.DB_POOL_MAX || '10'),
  idleTimeoutMillis:      30000,
  connectionTimeoutMillis: 5000,
  statement_timeout:       30000,
});

pool.on('error', (err) => {
  console.error('Unexpected DB pool error:', err);
});

// ── Middleware: metrics + request logging ─────────────────────
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const duration = (Date.now() - start) / 1000;
    httpRequestDuration.observe(
      { method: req.method, route: req.route?.path || req.path, status_code: res.statusCode },
      duration
    );
  });
  next();
});

// ── Health endpoints ──────────────────────────────────────────
let isReady = false;

app.get('/health/live',    (req, res) => res.json({ status: 'alive' }));
app.get('/health/startup', (req, res) => res.json({ status: isReady ? 'ready' : 'starting' }));
app.get('/health/ready', async (req, res) => {
  try {
    const client = await pool.connect();
    await client.query('SELECT 1');
    client.release();
    res.json({ status: 'ready', db: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'not ready', error: err.message });
  }
});

app.get('/metrics', async (req, res) => {
  res.set('Content-Type', register.contentType);
  res.send(await register.metrics());
});

// ── Business logic endpoints ──────────────────────────────────
app.get('/api/v1/users', async (req, res) => {
  const end = dbQueryDuration.startTimer({ query_name: 'list_users' });
  try {
    const { rows } = await pool.query(
      'SELECT id, name, email, created_at FROM users ORDER BY created_at DESC LIMIT $1',
      [parseInt(req.query.limit) || 20]
    );
    end();
    res.json({ data: rows, count: rows.length });
  } catch (err) {
    end();
    console.error('Error fetching users:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.post('/api/v1/users', async (req, res) => {
  const { name, email } = req.body;
  if (!name || !email) {
    return res.status(400).json({ error: 'name and email are required' });
  }

  const end = dbQueryDuration.startTimer({ query_name: 'create_user' });
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const { rows } = await client.query(
      'INSERT INTO users (name, email, created_at) VALUES ($1, $2, NOW()) RETURNING id, name, email, created_at',
      [name, email]
    );
    await client.query('COMMIT');
    end();
    res.status(201).json({ data: rows[0] });
  } catch (err) {
    await client.query('ROLLBACK');
    end();
    if (err.code === '23505') {
      return res.status(409).json({ error: 'Email already exists' });
    }
    console.error('Error creating user:', err);
    res.status(500).json({ error: 'Internal server error' });
  } finally {
    client.release();
  }
});

app.get('/api/v1/users/:id', async (req, res) => {
  const end = dbQueryDuration.startTimer({ query_name: 'get_user' });
  try {
    const { rows } = await pool.query(
      'SELECT id, name, email, created_at FROM users WHERE id = $1',
      [req.params.id]
    );
    end();
    if (rows.length === 0) return res.status(404).json({ error: 'User not found' });
    res.json({ data: rows[0] });
  } catch (err) {
    end();
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ── Startup ───────────────────────────────────────────────────
async function start() {
  // DB migration / table check
  const client = await pool.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS users (
        id         SERIAL PRIMARY KEY,
        name       VARCHAR(255) NOT NULL,
        email      VARCHAR(255) UNIQUE NOT NULL,
        created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
      );
      CREATE INDEX IF NOT EXISTS idx_users_email ON users(email);
    `);
    console.log('DB schema ready');
  } finally {
    client.release();
  }

  const PORT = parseInt(process.env.PORT || '3000');
  app.listen(PORT, () => {
    isReady = true;
    console.log(`Microservice A running on port ${PORT}`);
  });
}

start().catch((err) => {
  console.error('Startup failed:', err);
  process.exit(1);
});

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('SIGTERM received — closing DB pool');
  await pool.end();
  process.exit(0);
});
