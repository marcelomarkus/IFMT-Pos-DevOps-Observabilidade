"""API ShopFlow - microsservico de e-commerce instrumentado com OpenTelemetry.

Emite os tres pilares da observabilidade para o OpenTelemetry Collector:
  - Metricas  -> OTLP/gRPC (export periodico)
  - Logs      -> OTLP/gRPC (JSON, com trace_id para correlacao)
  - Traces    -> OTLP/gRPC (span do FastAPI + span de negocio "payment.authorize")

A configuracao de destino vem de variaveis de ambiente OTEL_* (ver main.tf).
"""

import json
import logging
import os
import random
import sys
import time
import uuid
from datetime import datetime, timezone

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.metrics import Observation
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import Status, StatusCode

SERVICE_NAME = os.getenv("OTEL_SERVICE_NAME", "shopflow-api")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "1.4.0")
ENVIRONMENT = os.getenv("DEPLOYMENT_ENV", "lab")

RESOURCE = Resource.create(
    {
        "service.name": SERVICE_NAME,
        "service.version": SERVICE_VERSION,
        "deployment.environment": ENVIRONMENT,
        "service.namespace": "shopflow",
    }
)

_STARTED_AT = time.time()
# Estado interno usado pelas metricas observaveis e pela injecao de falhas.
_state = {"available": 1.0, "queue": 0.0}


# Atributos padrao de LogRecord que nao devem ir para o corpo do log JSON.
_RESERVED_ATTRS = {
    "name", "msg", "args", "levelname", "levelno", "pathname", "filename", "module",
    "exc_info", "exc_text", "stack_info", "lineno", "funcName", "created", "msecs",
    "relativeCreated", "thread", "threadName", "processName", "process", "taskName",
    "message", "asctime",
}


class JsonFormatter(logging.Formatter):
    """Serializa o log em JSON e injeta trace_id/span_id para correlacao no Grafana."""

    def format(self, record: logging.LogRecord) -> str:
        span = trace.get_current_span().get_span_context()
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "level": record.levelname,
            "service": SERVICE_NAME,
            "message": record.getMessage(),
            "trace_id": format(span.trace_id, "032x") if span.trace_id else "",
            "span_id": format(span.span_id, "016x") if span.span_id else "",
        }
        # Campos de negocio passados via logging extra={...} (apenas tipos primitivos).
        for key, value in record.__dict__.items():
            if key not in _RESERVED_ATTRS:
                payload[key] = value
        return json.dumps(payload, ensure_ascii=False)


def _setup_telemetry() -> TracerProvider:
    """Configura os providers OTLP. Endpoint/via env: OTEL_EXPORTER_OTLP_ENDPOINT."""
    tracer_provider = TracerProvider(resource=RESOURCE)
    tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(tracer_provider)

    interval = int(os.getenv("OTEL_METRIC_EXPORT_INTERVAL", "5000"))
    reader = PeriodicExportingMetricReader(OTLPMetricExporter(), export_interval_millis=interval)
    metrics.set_meter_provider(MeterProvider(resource=RESOURCE, metric_readers=[reader]))

    logger_provider = LoggerProvider(resource=RESOURCE)
    logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
    otlp_handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
    otlp_handler.setFormatter(JsonFormatter())

    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(JsonFormatter())

    root = logging.getLogger()
    root.handlers = [otlp_handler, stream_handler]
    root.setLevel(logging.INFO)
    return tracer_provider


_setup_telemetry()
meter = metrics.get_meter("shopflow.instrumentation")
tracer = trace.get_tracer("shopflow.instrumentation")
log = logging.getLogger("shopflow")

orders_completed = meter.create_counter("shopflow.orders.completed", unit="1", description="Pedidos concluidos com sucesso")
orders_failed = meter.create_counter("shopflow.orders.failed", unit="1", description="Pedidos rejeitados pelo gateway de pagamento")
auth_failures = meter.create_counter("shopflow.auth.failures", unit="1", description="Falhas de autenticacao")
checkout_duration = meter.create_histogram("shopflow.checkout.duration", unit="ms", description="Duracao total do checkout")
payment_duration = meter.create_histogram("shopflow.payment.duration", unit="ms", description="Latencia do gateway de pagamento")
search_duration = meter.create_histogram("shopflow.search.duration", unit="ms", description="Latencia da busca de produtos")
cart_value = meter.create_histogram("shopflow.cart.value", unit="BRL", description="Valor do carrinho no momento do checkout")


def _availability_callback(options):
    yield Observation(_state["available"], {"check": "synthetic-http"})


def _queue_callback(options):
    yield Observation(_state["queue"], {"queue": "payment"})


meter.create_observable_gauge("shopflow.availability", callbacks=[_availability_callback], unit="1", description="Disponibilidade sintetica (0 = indisponivel)")
meter.create_observable_gauge("shopflow.payment.queue.size", callbacks=[_queue_callback], unit="1", description="Itens na fila de pagamento")

PRODUCTS = [
    {"id": "SKU-1001", "name": "Notebook Ultra 14", "price": 4299.90, "stock": 12},
    {"id": "SKU-1002", "name": "Smartphone Edge 5G", "price": 3199.00, "stock": 34},
    {"id": "SKU-1003", "name": "Fone Bluetooth Pro", "price": 499.90, "stock": 120},
    {"id": "SKU-1004", "name": "Monitor 27 4K", "price": 1899.00, "stock": 18},
    {"id": "SKU-1005", "name": "Teclado Mecanico RGB", "price": 349.90, "stock": 77},
    {"id": "SKU-1006", "name": "Cadeira Ergonomica", "price": 1299.00, "stock": 9},
]
PAYMENT_METHODS = ["credit_card", "pix", "boleto"]

app = FastAPI(title="ShopFlow API", version=SERVICE_VERSION, description="Microsservico instrumentado para o laboratorio de observabilidade")


@app.middleware("http")
async def indisponibilidade(request: Request, call_next):
    """Com a falha injetada, todas as rotas respondem 503 (exceto /chaos, para poder recuperar)."""
    if _state["available"] < 1 and not request.url.path.startswith("/chaos"):
        log.error("Requisicao rejeitada: servico indisponivel", extra={"http.target": request.url.path})
        return JSONResponse(status_code=503, content={"detail": "simulated outage"})
    return await call_next(request)


@app.get("/")
def index():
    return {
        "service": SERVICE_NAME,
        "version": SERVICE_VERSION,
        "environment": ENVIRONMENT,
        "endpoints": ["/healthz", "/catalog", "/catalog/{id}", "/search?q=", "/checkout", "/auth/login", "/chaos/{up|down}"],
    }


@app.get("/healthz")
def healthz():
    if _state["available"] < 1:
        raise HTTPException(status_code=503, detail="simulated outage")
    _state["queue"] = max(0.0, _state["queue"] + random.randint(-3, 4))
    return {"status": "ok", "uptime_s": round(time.time() - _STARTED_AT, 1)}


@app.get("/catalog")
def catalog():
    return {"items": PRODUCTS, "count": len(PRODUCTS)}


@app.get("/catalog/{product_id}")
def product(product_id: str):
    for item in PRODUCTS:
        if item["id"] == product_id:
            return item
    log.warning("Produto nao encontrado", extra={"product.id": product_id})
    raise HTTPException(status_code=404, detail="product not found")


@app.get("/search")
def search(q: str = ""):
    start = time.perf_counter()
    time.sleep(random.uniform(0.02, 0.25))
    elapsed = (time.perf_counter() - start) * 1000
    search_duration.record(elapsed, {"routing.endpoint": "/search"})
    results = [p for p in PRODUCTS if q.lower() in p["name"].lower()] if q else PRODUCTS
    return {"query": q, "results": len(results), "items": results}


@app.post("/auth/login")
def login():
    if random.random() < 0.18:
        auth_failures.add(1, {"reason": "invalid_credentials"})
        log.warning("Falha de autenticacao", extra={"auth.reason": "invalid_credentials"})
        raise HTTPException(status_code=401, detail="invalid credentials")
    return {"token": uuid.uuid4().hex, "expires_in": 3600}


@app.post("/checkout")
def checkout(cart: dict | None = None):
    cart = cart or {}
    items = int(cart.get("items", random.randint(1, 4)))
    method = cart.get("payment_method", random.choice(PAYMENT_METHODS))
    order_id = f"ORD-{uuid.uuid4().hex[:8].upper()}"
    value = round(sum(random.uniform(49.9, 899.9) for _ in range(items)), 2)
    started = time.perf_counter()

    with tracer.start_as_current_span("payment.authorize") as span:
        span.set_attribute("order.id", order_id)
        span.set_attribute("payment.method", method)
        span.set_attribute("cart.items", items)
        span.set_attribute("cart.value", value)
        latency = random.uniform(60, 700)
        time.sleep(latency / 1000)
        payment_duration.record(latency, {"payment.method": method})

        if random.random() < 0.07:
            span.set_status(Status(StatusCode.ERROR, "payment gateway timeout"))
            span.set_attribute("payment.gateway.status", "timeout")
            orders_failed.add(1, {"reason": "gateway_timeout", "payment.method": method})
            checkout_duration.record((time.perf_counter() - started) * 1000, {"status": "error"})
            log.error(
                "Gateway de pagamento nao respondeu no tempo esperado",
                extra={"order.id": order_id, "payment.method": method, "cart.value": value},
            )
            raise HTTPException(status_code=502, detail="payment gateway timeout")

        span.set_attribute("payment.gateway.status", "approved")

    total = (time.perf_counter() - started) * 1000
    checkout_duration.record(total, {"status": "success"})
    cart_value.record(value, {"payment.method": method})
    orders_completed.add(1, {"payment.method": method})
    log.info(
        "Pedido finalizado com sucesso",
        extra={"order.id": order_id, "payment.method": method, "cart.items": items, "cart.value": value},
    )
    return {"order_id": order_id, "status": "approved", "items": items, "value": value, "payment_method": method}


@app.post("/chaos/{action}")
def chaos(action: str):
    """Injecao de falha para demonstrar alertas: /chaos/down e /chaos/up."""
    if action not in ("up", "down"):
        raise HTTPException(status_code=400, detail="acao invalida, use up ou down")
    _state["available"] = 1.0 if action == "up" else 0.0
    if action == "down":
        log.error("Disponibilidade sintetica desativada (injecao de falha)", extra={"chaos.action": "down"})
    else:
        log.info("Servico restabelecido", extra={"chaos.action": "up"})
    return {"availability": _state["available"]}


FastAPIInstrumentor.instrument_app(app)
