-- Schéma de la base télémétrie (exécuté une seule fois, à la création du volume)

CREATE TABLE telemetry (
  id          BIGSERIAL PRIMARY KEY,
  device_id   TEXT NOT NULL,
  sensor_id   TEXT NOT NULL DEFAULT 'humidity-1',   -- prêt pour un 2e capteur
  humidity    NUMERIC(5,2) NOT NULL CHECK (humidity BETWEEN 0 AND 100),
  measured_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX telemetry_device_time_idx ON telemetry (device_id, measured_at DESC);

CREATE TABLE api_keys (
  id         SERIAL PRIMARY KEY,
  client     TEXT NOT NULL,
  key_hash   TEXT NOT NULL UNIQUE,                  -- empreinte SHA-256, jamais la clé
  active     BOOLEAN NOT NULL DEFAULT true,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
