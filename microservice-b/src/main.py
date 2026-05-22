# ============================================================
# microservice-b/src/main.py
# Python FastAPI microservice — asyncpg for PostgreSQL
# ============================================================

import asyncio
import asyncpg
import httpx
import os
import time
import logging

from contextlib import asynccontextmanager
from fastapi import FastAPI, HTTPException, Depends
from fastapi.middleware.cors import CORSMiddleware
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
from starlette.requests import Request
from starlette.responses import Response
from pydantic import BaseModel, EmailStr
from typing import Optional, List

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(name)s %(message)s'
)
logger = logging.getLogger(__name__)

# ── Config ────────────────────────────────────────────────────
class Config:
    DB_HOST     = os.environ["DB_HOST"]
    DB_PORT     = int(os.getenv("DB_PORT", "5432"))
    DB_NAME     = os.environ["DB_NAME"]
    DB_USER     = os.environ["DB_USER"]
    DB_PASSWORD = os.environ["DB_PASSWORD"]
    DB_SSL_MODE = os.getenv("DB_SSL_MODE", "require")
    DB_POOL_SIZE = int(os.getenv("DB_POOL_SIZE", "5"))
    SERVICE_A_URL = os.getenv("SERVICE_A_URL", "http://microservice-a.microservice-a.svc.cluster.local")
    PORT        = int(os.getenv("PORT", "8000"))

cfg = Config()

# ── Prometheus metrics ────────────────────────────────────────
REQUEST_COUNT = Counter(
    'http_requests_total',
    'Total HTTP requests',
    ['method', 'endpoint', 'status']
)
REQUEST_LATENCY = Histogram(
    'http_request_duration_seconds',
    'HTTP request latency',
    ['method', 'endpoint'],
    buckets=[.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5]
)
DB_QUERY_LATENCY = Histogram(
    'db_query_duration_seconds',
    'PostgreSQL query latency',
    ['query_name']
)

# ── Database pool ─────────────────────────────────────────────
db_pool: Optional[asyncpg.Pool] = None

async def get_db_pool() -> asyncpg.Pool:
    return db_pool

async def init_db():
    global db_pool
    dsn = (
        f"postgresql://{cfg.DB_USER}:{cfg.DB_PASSWORD}"
        f"@{cfg.DB_HOST}:{cfg.DB_PORT}/{cfg.DB_NAME}"
        f"?sslmode={cfg.DB_SSL_MODE}"
    )
    db_pool = await asyncpg.create_pool(
        dsn=dsn,
        min_size=2,
        max_size=cfg.DB_POOL_SIZE,
        command_timeout=30,
        max_inactive_connection_lifetime=300,
    )
    # Init schema
    async with db_pool.acquire() as conn:
        await conn.execute("""
            CREATE TABLE IF NOT EXISTS orders (
                id         SERIAL PRIMARY KEY,
                user_id    INTEGER NOT NULL,
                product    VARCHAR(255) NOT NULL,
                quantity   INTEGER NOT NULL DEFAULT 1,
                status     VARCHAR(50) NOT NULL DEFAULT 'pending',
                created_at TIMESTAMPTZ DEFAULT NOW(),
                updated_at TIMESTAMPTZ DEFAULT NOW()
            );
            CREATE INDEX IF NOT EXISTS idx_orders_user_id ON orders(user_id);
            CREATE INDEX IF NOT EXISTS idx_orders_status ON orders(status);
        """)
    logger.info("Database pool initialized and schema ready")

async def close_db():
    if db_pool:
        await db_pool.close()
    logger.info("Database pool closed")

# ── Lifespan (replaces @app.on_event deprecated) ─────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield
    await close_db()

# ── FastAPI app ───────────────────────────────────────────────
app = FastAPI(
    title="Microservice B",
    version="1.0.0",
    lifespan=lifespan,
    docs_url=None,    # disable in production
    redoc_url=None,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["https://api.example.com"],
    allow_methods=["GET", "POST", "PUT"],
    allow_headers=["*"],
)

# ── Middleware: metrics ───────────────────────────────────────
@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.time()
    response = await call_next(request)
    duration = time.time() - start
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.url.path,
        status=response.status_code
    ).inc()
    REQUEST_LATENCY.labels(
        method=request.method,
        endpoint=request.url.path
    ).observe(duration)
    return response

# ── Pydantic models ───────────────────────────────────────────
class OrderCreate(BaseModel):
    user_id:  int
    product:  str
    quantity: int = 1

class OrderResponse(BaseModel):
    id:         int
    user_id:    int
    product:    str
    quantity:   int
    status:     str
    created_at: str

# ── Health endpoints ──────────────────────────────────────────
@app.get("/health", tags=["health"])
async def health():
    return {"status": "alive", "service": "microservice-b"}

@app.get("/ready", tags=["health"])
async def ready(pool: asyncpg.Pool = Depends(get_db_pool)):
    try:
        await pool.fetchval("SELECT 1")
        return {"status": "ready", "db": "connected"}
    except Exception as e:
        raise HTTPException(status_code=503, detail=f"DB not ready: {e}")

@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

# ── Business logic ────────────────────────────────────────────
@app.get("/api/v2/orders", response_model=List[OrderResponse])
async def list_orders(
    status: Optional[str] = None,
    limit: int = 20,
    pool: asyncpg.Pool = Depends(get_db_pool)
):
    start = time.time()
    try:
        if status:
            rows = await pool.fetch(
                "SELECT * FROM orders WHERE status=$1 ORDER BY created_at DESC LIMIT $2",
                status, limit
            )
        else:
            rows = await pool.fetch(
                "SELECT * FROM orders ORDER BY created_at DESC LIMIT $1",
                limit
            )
        DB_QUERY_LATENCY.labels(query_name="list_orders").observe(time.time() - start)
        return [dict(r) | {"created_at": str(r["created_at"])} for r in rows]
    except Exception as e:
        logger.error(f"Error listing orders: {e}")
        raise HTTPException(status_code=500, detail="Internal server error")

@app.post("/api/v2/orders", response_model=OrderResponse, status_code=201)
async def create_order(
    order: OrderCreate,
    pool: asyncpg.Pool = Depends(get_db_pool)
):
    # Cross-service call: validate user exists in Microservice A
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            resp = await client.get(f"{cfg.SERVICE_A_URL}/api/v1/users/{order.user_id}")
            if resp.status_code == 404:
                raise HTTPException(status_code=404, detail=f"User {order.user_id} not found")
            resp.raise_for_status()
        except httpx.TimeoutException:
            logger.warning(f"Timeout checking user {order.user_id} in service-a")
            raise HTTPException(status_code=503, detail="User service unavailable")

    start = time.time()
    async with pool.acquire() as conn:
        async with conn.transaction():
            row = await conn.fetchrow(
                """INSERT INTO orders (user_id, product, quantity, status)
                   VALUES ($1, $2, $3, 'pending')
                   RETURNING *""",
                order.user_id, order.product, order.quantity
            )
    DB_QUERY_LATENCY.labels(query_name="create_order").observe(time.time() - start)
    return dict(row) | {"created_at": str(row["created_at"])}

@app.put("/api/v2/orders/{order_id}/status")
async def update_order_status(
    order_id: int,
    status: str,
    pool: asyncpg.Pool = Depends(get_db_pool)
):
    valid_statuses = {"pending", "processing", "completed", "cancelled"}
    if status not in valid_statuses:
        raise HTTPException(status_code=400, detail=f"Status must be one of {valid_statuses}")

    row = await pool.fetchrow(
        "UPDATE orders SET status=$1, updated_at=NOW() WHERE id=$2 RETURNING *",
        status, order_id
    )
    if not row:
        raise HTTPException(status_code=404, detail="Order not found")
    return dict(row) | {"created_at": str(row["created_at"])}
