"""API de télémétrie (lab mube) — sous-étape 1 : socle et route /health."""
import os

import psycopg
from flask import Flask, jsonify

app = Flask(__name__)
DATABASE_URL = os.environ["DATABASE_URL"]


def db_connect():
    return psycopg.connect(DATABASE_URL, connect_timeout=3)


@app.get("/health")
def health():
    """200 si l'API et PostgreSQL répondent, 503 sinon (sonde Uptime Kuma)."""
    try:
        with db_connect() as conn:
            conn.execute("SELECT 1")
    except psycopg.Error:
        return jsonify(status="error", database="unreachable"), 503
    return jsonify(status="ok", database="ok")
