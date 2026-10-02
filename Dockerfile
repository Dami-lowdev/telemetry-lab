FROM python:3.12-slim

WORKDIR /srv
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

# Ne pas tourner en root dans le conteneur
RUN useradd --system --no-create-home api
USER api

EXPOSE 8000
CMD ["gunicorn", "--bind", "0.0.0.0:8000", "--workers", "2", "app.main:app"]
