#!/usr/bin/env python3
"""
Exporter que consulta el backend cn=monitor de OpenLDAP (ldap1 y ldap2)
y expone contadores de operaciones (bind, search, etc), conexiones, y
el retraso de replicacion (contextCSN provider vs consumer) en formato
Prometheus. Se apoya en ldapsearch via subprocess para no depender de
librerias LDAP de terceros.

Metricas expuestas:
  - ldap_operations_total{node, op}   (contador acumulado que reporta el propio slapd)
  - ldap_connections_current{node}
  - ldap_monitor_up{node}
  - ldap_replication_lag_seconds      (provider ldap1 vs consumer ldap2, via contextCSN)
"""

import os
import re
import subprocess
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

BASE_DN = os.environ.get("LDAP_BASE_DN", "dc=fis,dc=epn,dc=ec")
ADMIN_DN = f"cn=admin,{BASE_DN}"
ADMIN_PASS = os.environ.get("LDAP_ADMIN_PASSWORD", "changeme")
NODES = {
    "ldap1": os.environ.get("LDAP1_HOST", "ldap1.fis.epn.ec"),
    "ldap2": os.environ.get("LDAP2_HOST", "ldap2.fis.epn.ec"),
}
PROVIDER_NODE = "ldap1"
CONSUMER_NODE = "ldap2"
POLL_INTERVAL = int(os.environ.get("POLL_INTERVAL_SECONDS", "10"))
EXPORTER_PORT = int(os.environ.get("EXPORTER_PORT", "9330"))
CSN_RE = re.compile(r"(\d{14})\.\d+Z")

OP_MONITOR_COUNTERS = {
    "bind": "cn=Bind,cn=Operations,cn=Monitor",
    "search": "cn=Search,cn=Operations,cn=Monitor",
    "add": "cn=Add,cn=Operations,cn=Monitor",
    "modify": "cn=Modify,cn=Operations,cn=Monitor",
    "delete": "cn=Delete,cn=Operations,cn=Monitor",
}

lock = threading.Lock()
state = {}  # node -> {"up": 0/1, "ops": {op: count}, "connections": int}


def ldapsearch_attr(host: str, base: str, attr: str) -> "str | None":
    try:
        result = subprocess.run(
            [
                "ldapsearch", "-x", "-LLL",
                "-H", f"ldaps://{host}:636",
                "-D", ADMIN_DN,
                "-w", ADMIN_PASS,
                "-b", base,
                "-s", "base",
                attr,
            ],
            capture_output=True, text=True, timeout=10,
        )
        m = re.search(rf"{attr}:\s*(\S+)", result.stdout)
        return m.group(1) if m else None
    except Exception:
        return None


def fetch_context_csn(host: str) -> "datetime | None":
    val = ldapsearch_attr(host, BASE_DN, "contextCSN")
    if not val:
        return None
    m = CSN_RE.search(val)
    if not m:
        return None
    try:
        return datetime.strptime(m.group(1), "%Y%m%d%H%M%S").replace(
            tzinfo=timezone.utc
        )
    except ValueError:
        return None


def poll_node(node: str, host: str) -> None:
    ops = {}
    ok = True
    for op_name, dn in OP_MONITOR_COUNTERS.items():
        val = ldapsearch_attr(host, dn, "monitorOpCompleted")
        if val is None:
            ok = False
            continue
        try:
            ops[op_name] = int(val)
        except ValueError:
            ok = False

    conns = ldapsearch_attr(host, "cn=Current,cn=Connections,cn=Monitor", "monitorCounter")
    conns_val = int(conns) if conns and conns.isdigit() else None

    with lock:
        state[node] = {"up": 1 if ok else 0, "ops": ops, "connections": conns_val}


def poll_forever() -> None:
    while True:
        for node, host in NODES.items():
            poll_node(node, host)

        provider_csn = fetch_context_csn(NODES[PROVIDER_NODE])
        consumer_csn = fetch_context_csn(NODES[CONSUMER_NODE])
        with lock:
            if provider_csn and consumer_csn:
                state["_replication_lag_seconds"] = max(
                    (provider_csn - consumer_csn).total_seconds(), 0
                )
            else:
                state["_replication_lag_seconds"] = None

        time.sleep(POLL_INTERVAL)


def render_metrics() -> str:
    lines = [
        "# HELP ldap_monitor_up Si se pudo consultar cn=monitor en este nodo",
        "# TYPE ldap_monitor_up gauge",
        "# HELP ldap_operations_total Operaciones completadas acumuladas, por tipo (contador nativo de slapd)",
        "# TYPE ldap_operations_total counter",
        "# HELP ldap_connections_current Conexiones abiertas actuales",
        "# TYPE ldap_connections_current gauge",
    ]
    with lock:
        for node, data in sorted(state.items()):
            if node == "_replication_lag_seconds":
                continue
            lines.append(f'ldap_monitor_up{{node="{node}"}} {data["up"]}')
            for op_name, count in sorted(data["ops"].items()):
                lines.append(
                    f'ldap_operations_total{{node="{node}",op="{op_name}"}} {count}'
                )
            if data["connections"] is not None:
                lines.append(
                    f'ldap_connections_current{{node="{node}"}} {data["connections"]}'
                )
        lag = state.get("_replication_lag_seconds")
    if lag is not None:
        lines += [
            "# HELP ldap_replication_lag_seconds Retraso de replicacion estimado entre ldap1 (provider) y ldap2 (consumer), via contextCSN",
            "# TYPE ldap_replication_lag_seconds gauge",
            f"ldap_replication_lag_seconds {lag}",
        ]
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
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
        pass


def main() -> None:
    threading.Thread(target=poll_forever, daemon=True).start()
    server = HTTPServer(("0.0.0.0", EXPORTER_PORT), Handler)
    print(f"ldap-ops-exporter escuchando en :{EXPORTER_PORT}")
    server.serve_forever()


if __name__ == "__main__":
    main()
