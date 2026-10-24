"""Servicio HTTP para Cloud Run, alimentado por una suscripción Pub/Sub push.

Códigos de respuesta pensados para Pub/Sub: 2xx confirma el mensaje, 5xx lo reintenta.
El servidor atiende de a una petición (dbt no es thread-safe), igual que la
concurrencia 1 configurada en el servicio.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, HTTPServer

from lakehouse import freshness
from lakehouse.config import load_settings
from lakehouse.events import dates_from_pubsub_push, is_freshness_check
from lakehouse.runner import run_dbt

log = logging.getLogger(__name__)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # health check
        self._reply(HTTPStatus.OK, {"status": "ok"})

    def do_POST(self) -> None:
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            if is_freshness_check(body):
                self._freshness()
                return
            dates = dates_from_pubsub_push(body)
        except (ValueError, KeyError) as exc:
            # Un mensaje malformado no mejora reintentando: se confirma y se registra.
            log.warning("mensaje inválido: %s", exc)
            self._reply(HTTPStatus.OK, {"skipped": True, "error": str(exc)})
            return

        if not dates:
            self._reply(HTTPStatus.OK, {"skipped": True})
            return

        settings = load_settings()
        runs = []
        for d in dates:
            try:
                result = run_dbt(settings, d)
            except Exception:
                log.exception("dbt lanzó una excepción para %s", d)
                self._reply(HTTPStatus.INTERNAL_SERVER_ERROR, {"run_date": d.isoformat()})
                return
            runs.append(result.as_dict())
            if not result.success:
                self._reply(HTTPStatus.INTERNAL_SERVER_ERROR, {"runs": runs})
                return
        self._reply(HTTPStatus.OK, {"skipped": False, "runs": runs})

    def _freshness(self) -> None:
        # Llamado por Cloud Scheduler. Un 5xx dispara la alerta de errores de Monitoring.
        d = freshness.expected_date()
        problems = freshness.check(load_settings(), d)
        if problems:
            log.error("frescura: %s", "; ".join(problems))
            self._reply(
                HTTPStatus.INTERNAL_SERVER_ERROR, {"date": d.isoformat(), "problems": problems}
            )
        else:
            self._reply(HTTPStatus.OK, {"freshness": "ok", "date": d.isoformat()})

    def _reply(self, status: HTTPStatus, payload: dict) -> None:
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, format: str, *args: object) -> None:
        log.info("%s - %s", self.address_string(), format % args)


def main() -> None:
    # force=True: importar dbt ya registra un handler en el logger raíz.
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s %(message)s", force=True)
    # Cloud Run manda SIGTERM antes de apagar la instancia (scale-to-zero).
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    port = int(os.environ.get("PORT", "8080"))
    log.info("escuchando en :%d", port)
    HTTPServer(("0.0.0.0", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
