"""Gestion des clés API.

  docker compose exec api python -m app.manage create-key "Client A"
  docker compose exec api python -m app.manage list-keys
  docker compose exec api python -m app.manage revoke-key <id>
"""
import secrets
import sys

from app.main import db_connect, hash_key


def create_key(client):
    key = "lab_" + secrets.token_urlsafe(32)
    with db_connect() as conn:
        key_id = conn.execute(
            "INSERT INTO api_keys (client, key_hash) VALUES (%s, %s) RETURNING id",
            (client, hash_key(key))).fetchone()[0]
    print(f"Clé n° {key_id} créée pour « {client} ».")
    print(f"  {key}")
    print("Transmettez-la au client maintenant : elle ne sera plus jamais affichée (seule son empreinte est stockée).")


def list_keys():
    with db_connect() as conn:
        rows = conn.execute(
            "SELECT id, client, active, created_at, left(key_hash, 12) FROM api_keys ORDER BY id").fetchall()
    print(f"{'id':>3}  {'client':<20} {'statut':<8} {'créée le':<17} empreinte")
    for key_id, client, active, created, prefix in rows:
        print(f"{key_id:>3}  {client:<20} {'active' if active else 'révoquée':<8} "
              f"{created:%Y-%m-%d %H:%M} {prefix}…")


def revoke_key(key_id):
    with db_connect() as conn:
        updated = conn.execute("UPDATE api_keys SET active = false WHERE id = %s", (key_id,)).rowcount
    print(f"Clé n° {key_id} révoquée." if updated else f"Aucune clé n° {key_id}.")


if __name__ == "__main__":
    commands = {"create-key": create_key, "list-keys": list_keys, "revoke-key": revoke_key}
    if len(sys.argv) < 2 or sys.argv[1] not in commands:
        sys.exit(__doc__)
    commands[sys.argv[1]](*sys.argv[2:])
