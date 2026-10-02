"""API de télémétrie (lab mube) : mesures d'humidité, clés d'accès et quotas."""
import hashlib
import os
import re
from datetime import datetime
from functools import wraps

import psycopg
from flask import Flask, g, jsonify, request
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from werkzeug.exceptions import HTTPException

app = Flask(__name__)
app.json.ensure_ascii = False
DATABASE_URL = os.environ["DATABASE_URL"]
RATE_LIMIT = os.environ.get("RATE_LIMIT", "60 per minute")

ID_PATTERN = re.compile(r"^[A-Za-z0-9_-]{1,64}$")   # device_id et sensor_id


def db_connect():
    return psycopg.connect(DATABASE_URL, connect_timeout=3)


def hash_key(key):
    return hashlib.sha256(key.encode()).hexdigest()


def error(status, code, message):
    """Format d'erreur unique pour toute l'API."""
    return jsonify(code=code, message=message), status


def invalid_device_id():
    return error(400, "invalid_device_id", "device_id : 1 à 64 caractères parmi A-Z a-z 0-9 _ -.")


# ---------- Quotas : 60 requêtes / minute par clé (par IP à défaut de clé) ----------

def rate_limit_key():
    key = request.headers.get("X-API-Key")
    return "key:" + hash_key(key) if key else "ip:" + get_remote_address()


limiter = Limiter(rate_limit_key, app=app, default_limits=[RATE_LIMIT],
                  headers_enabled=True, storage_uri="memory://")


# ---------- Authentification par clé ----------

def require_api_key(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        key = request.headers.get("X-API-Key")
        if not key:
            return error(401, "missing_api_key", "En-tête X-API-Key absent.")
        with db_connect() as conn:
            row = conn.execute(
                "SELECT client FROM api_keys WHERE key_hash = %s AND active",
                (hash_key(key),)).fetchone()
        if row is None:
            return error(401, "invalid_api_key", "Clé API invalide ou révoquée.")
        g.client = row[0]
        return view(*args, **kwargs)
    return wrapper


# ---------- Routes ----------

@app.get("/health")
@limiter.exempt
def health():
    """200 si l'API et PostgreSQL répondent, 503 sinon (sonde Uptime Kuma)."""
    try:
        with db_connect() as conn:
            conn.execute("SELECT 1")
    except psycopg.Error:
        return jsonify(status="error", database="unreachable"), 503
    return jsonify(status="ok", database="ok")


@app.post("/api/v1/devices/<device_id>/telemetry")
@require_api_key
def add_measurement(device_id):
    if not ID_PATTERN.match(device_id):
        return invalid_device_id()

    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        return error(400, "invalid_json", "Le corps doit être un objet JSON.")

    humidity = body.get("humidity")
    if isinstance(humidity, bool) or not isinstance(humidity, (int, float)):
        return error(400, "invalid_humidity", "humidity est obligatoire et doit être un nombre.")
    if not 0 <= humidity <= 100:
        return error(400, "invalid_humidity", "humidity doit être comprise entre 0 et 100.")

    sensor_id = body.get("sensor_id", "humidity-1")
    if not isinstance(sensor_id, str) or not ID_PATTERN.match(sensor_id):
        return error(400, "invalid_sensor_id", "sensor_id : 1 à 64 caractères parmi A-Z a-z 0-9 _ -.")

    measured_at = body.get("measured_at")
    if measured_at is not None:
        try:
            measured_at = datetime.fromisoformat(measured_at)
        except (TypeError, ValueError):
            measured_at = None
        if measured_at is None or measured_at.tzinfo is None:
            return error(400, "invalid_measured_at",
                         "measured_at doit être une date ISO 8601 avec fuseau, ex. 2026-10-02T12:00:00Z.")

    with db_connect() as conn:
        row = conn.execute(
            """INSERT INTO telemetry (device_id, sensor_id, humidity, measured_at)
               VALUES (%s, %s, %s, COALESCE(%s, now()))
               RETURNING sensor_id, humidity, measured_at""",
            (device_id, sensor_id, humidity, measured_at)).fetchone()
    return jsonify(device_id=device_id, sensor_id=row[0], humidity=float(row[1]),
                   measured_at=row[2].isoformat()), 201


@app.get("/api/v1/devices/<device_id>/telemetry")
@require_api_key
def list_measurements(device_id):
    if not ID_PATTERN.match(device_id):
        return invalid_device_id()
    limit = request.args.get("limit", "100")
    if not limit.isdigit() or not 1 <= int(limit) <= 1000:
        return error(400, "invalid_limit", "limit doit être un entier entre 1 et 1000.")

    with db_connect() as conn:
        rows = conn.execute(
            """SELECT sensor_id, humidity, measured_at FROM telemetry
               WHERE device_id = %s ORDER BY measured_at DESC LIMIT %s""",
            (device_id, int(limit))).fetchall()
    if not rows:
        return error(404, "device_not_found", f"Aucune mesure pour l'équipement « {device_id} ».")
    return jsonify([{"sensor_id": s, "humidity": float(h), "measured_at": t.isoformat()}
                    for s, h, t in rows])


# ---------- Erreurs JSON homogènes ----------

@app.errorhandler(429)
def rate_limited(e):
    return error(429, "rate_limited",
                 f"Quota dépassé ({RATE_LIMIT}). Réessayez après le délai indiqué par l'en-tête Retry-After.")


@app.errorhandler(HTTPException)
def http_error(e):
    known = {404: ("not_found", "Ressource introuvable. Vérifiez l'URL (préfixe /api/v1)."),
             405: ("method_not_allowed", "Méthode HTTP non autorisée sur cette ressource.")}
    code, message = known.get(e.code, ("http_error", e.description))
    return error(e.code, code, message)


@app.errorhandler(psycopg.OperationalError)
def database_unavailable(e):
    app.logger.error("Base de données injoignable : %s", e)
    return error(503, "service_unavailable", "Service momentanément indisponible, réessayez dans quelques instants.")


@app.errorhandler(Exception)
def internal_error(e):
    app.logger.exception("Erreur non gérée")
    return error(500, "internal_error", "Erreur interne. Si elle persiste, contactez le support.")
