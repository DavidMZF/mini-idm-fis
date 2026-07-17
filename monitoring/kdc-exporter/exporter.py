#!/usr/bin/env python3
"""
kdc-exporter: exporter minimalista para Kerberos MIT (krb5kdc).

MIT Kerberos no expone metricas nativas en formato Prometheus, asi que
este exporter sigue en modo 'tail -f' el archivo de log del KDC
(configurado via [logging] en krb5.conf) y cuenta eventos por tipo
usando expresiones regulares sobre las lineas que krb5kdc ya escribe
de forma nativa, por ejemplo:

    ... AS_REQ (4 etypes ...) 172.18.0.5: ISSUE: authtime ...
    ... TGS_REQ (4 etypes ...) 172.18.0.5: ISSUE: authtime ...
    ... AS_REQ ... NEEDED_PREAUTH ...
    ... TGS_REQ ... UNKNOWN_SERVER ...

Metricas expuestas:
  - kdc_requests_total{type="AS_REQ|TGS_REQ", result="issue|error"}
  - kdc_log_lines_total
  - kdc_exporter_up

No requiere dependencias externas: usa http.server de la stdlib.
"""

import os
import re
import threading
import time
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG_PATH = os.environ.get("KDC_LOG_PATH", "/var/log/krb5kdc/krb5kdc.log")
LISTEN_PORT = int(os.environ.get("EXPORTER_PORT", "9100"))

# Contadores protegidos por lock (el hilo de tail escribe, el de HTTP lee)
lock = threading.Lock()
counters = defaultdict(int)
log_lines_total = 0
exporter_up = 1

# AS_REQ / TGS_REQ ... ISSUE  -> exito
# AS_REQ / TGS_REQ ... seguido de un texto de error conocido -> error
REQ_RE = re.compile(r"\b(AS_REQ|TGS_REQ)\b")
ISSUE_RE = re.compile(r"\bISSUE\b")
ERROR_HINTS = (
    "NEEDED_PREAUTH",
    "UNKNOWN_SERVER",
    "CLIENT_NOT_FOUND",
    "PREAUTH_FAILED",
    "KRB_AP_ERR",
    "expired",
)


def classify_and_count(line: str) -> None:
    global log_lines_total
    m = REQ_RE.search(line)
    if not m:
        with lock:
            log_lines_total += 1
        return

    req_type = m.group(1)
    if ISSUE_RE.search(line):
        result = "issue"
    elif any(hint in line for hint in ERROR_HINTS):
        result = "error"
    else:
        result = "other"

    with lock:
        counters[(req_type, result)] += 1
        log_lines_total += 1


def tail_forever(path: str) -> None:
    """Sigue el archivo de log como 'tail -F', tolerando que aun no exista
    o que sea rotado/truncado (se re-abre desde el principio en ese caso)."""
    global exporter_up
    while True:
        if not os.path.exists(path):
            with lock:
                exporter_up = 0
            time.sleep(2)
            continue
        try:
            with open(path, "r", errors="replace") as f:
                with lock:
                    exporter_up = 1
                f.seek(0, os.SEEK_END)
                inode = os.fstat(f.fileno()).st_ino
                while True:
                    line = f.readline()
                    if not line:
                        # Detectar rotacion/truncado del archivo
                        try:
                            if os.stat(path).st_ino != inode:
                                break
                        except FileNotFoundError:
                            break
                        time.sleep(0.5)
                        continue
                    classify_and_count(line)
        except OSError:
            with lock:
                exporter_up = 0
            time.sleep(2)


def render_metrics() -> str:
    with lock:
        lines = [
            "# HELP kdc_exporter_up Whether the exporter can currently read the KDC log file",
            "# TYPE kdc_exporter_up gauge",
            f"kdc_exporter_up {exporter_up}",
            "# HELP kdc_log_lines_total Total lines processed from the KDC log file",
            "# TYPE kdc_log_lines_total counter",
            f"kdc_log_lines_total {log_lines_total}",
            "# HELP kdc_requests_total Total Kerberos KDC requests by type and result",
            "# TYPE kdc_requests_total counter",
        ]
        if not counters:
            lines.append('kdc_requests_total{type="AS_REQ",result="issue"} 0')
            lines.append('kdc_requests_total{type="TGS_REQ",result="issue"} 0')
        for (req_type, result), value in sorted(counters.items()):
            lines.append(
                f'kdc_requests_total{{type="{req_type}",result="{result}"}} {value}'
            )
    return "\n".join(lines) + "\n"


class MetricsHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        body = render_metrics().encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        pass  # silenciar logging default de http.server


def main() -> None:
    t = threading.Thread(target=tail_forever, args=(LOG_PATH,), daemon=True)
    t.start()
    server = HTTPServer(("0.0.0.0", LISTEN_PORT), MetricsHandler)
    print(f"kdc-exporter escuchando en :{LISTEN_PORT}, leyendo {LOG_PATH}")
    server.serve_forever()


if __name__ == "__main__":
    main()
