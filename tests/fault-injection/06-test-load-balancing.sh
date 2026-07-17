#!/bin/bash
set -e
cd "$(dirname "$0")/../.."

DURATION=${1:-15}
CONCURRENCY=${2:-5}

echo "=========================================="
echo "EXPERIMENTO: Balanceo de carga - throughput (lb1)"
echo "=========================================="

echo ""
echo "[1] Estado inicial:"
docker compose ps ldap1 ldap2 lb1

echo ""
echo "[2] Verificando que el balanceador responde..."
docker exec ldap1 ldapsearch -x -H ldaps://lb.fis.epn.ec:636 -b "dc=fis,dc=epn,dc=ec" \
  -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" \
  -s base > /dev/null 2>&1 && echo "OK: lb1 responde normalmente"

RESULTS_DIR=$(mktemp -d)

worker() {
  local id=$1
  local end_ts=$2
  local count=0
  while [ "$(date +%s)" -lt "$end_ts" ]; do
    if docker exec ldap1 ldapsearch -x -H ldaps://lb.fis.epn.ec:636 \
      -b "dc=fis,dc=epn,dc=ec" -D "cn=admin,dc=fis,dc=epn,dc=ec" \
      -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" "(uid=fmorales)" > /dev/null 2>&1; then
      count=$((count + 1))
    fi
  done
  echo "$count" > "$RESULTS_DIR/worker_$id.count"
}

echo ""
echo "[3] Lanzando $CONCURRENCY workers concurrentes durante ${DURATION}s contra lb1..."
END_TS=$(( $(date +%s) + DURATION ))
START=$(date +%s%N)
for i in $(seq 1 $CONCURRENCY); do
  worker "$i" "$END_TS" &
done
wait
END=$(date +%s%N)
ELAPSED_S=$(echo "scale=2; ($END - $START) / 1000000000" | bc)

TOTAL=0
for f in "$RESULTS_DIR"/worker_*.count; do
  C=$(cat "$f")
  TOTAL=$(( TOTAL + C ))
done

THROUGHPUT=$(echo "scale=2; $TOTAL / $ELAPSED_S" | bc)

echo ""
echo "[4] Resultados por worker:"
for i in $(seq 1 $CONCURRENCY); do
  echo "  worker $i: $(cat "$RESULTS_DIR/worker_$i.count") solicitudes"
done

rm -rf "$RESULTS_DIR"

echo ""
echo "=========================================="
echo "RESULTADO: Balanceo de carga (lb1)"
echo "  Duracion:               ${ELAPSED_S} s"
echo "  Workers concurrentes:   ${CONCURRENCY}"
echo "  Solicitudes totales:    ${TOTAL}"
echo "  Throughput:             ${THROUGHPUT} req/s"
echo "=========================================="

echo ""
echo "=========================================="
echo "EXPERIMENTO: Balanceo de carga - distribucion entre ldap1/ldap2"
echo "=========================================="

echo ""
echo "=========================================="
echo "EXPERIMENTO: Balanceo de carga - distribucion entre ldap1/ldap2"
echo "=========================================="

get_search_counts() {
  curl -s -G 'http://localhost:9090/api/v1/query' \
    --data-urlencode 'query=ldap_operations_total{op="search"}' | \
  python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    counts = {}
    for r in data['data']['result']:
        counts[r['metric']['node']] = int(float(r['value'][1]))
    print(f\"{counts.get('ldap1', 0)} {counts.get('ldap2', 0)}\")
except Exception:
    print('0 0')
"
}

echo ""
echo "[5] Capturando contador de busquedas antes de la carga (via Prometheus)..."
read BEFORE_LDAP1 BEFORE_LDAP2 <<< "$(get_search_counts)"
echo "  ldap1 (antes): ${BEFORE_LDAP1} busquedas acumuladas"
echo "  ldap2 (antes): ${BEFORE_LDAP2} busquedas acumuladas"

echo ""
echo "[6] Generando 40 solicitudes secuenciales via lb1..."
for i in $(seq 1 40); do
  docker exec ldap1 ldapsearch -x -H ldaps://lb.fis.epn.ec:636 -b "dc=fis,dc=epn,dc=ec" \
    -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" \
    -s base > /dev/null 2>&1 || true
done
echo "OK: 40 solicitudes enviadas a traves de lb1"

echo ""
echo "[7] Esperando 3s para que Prometheus haga scrape del estado final..."
sleep 3

echo ""
echo "[8] Capturando contador de busquedas despues de la carga..."
read AFTER_LDAP1 AFTER_LDAP2 <<< "$(get_search_counts)"

DELTA_LDAP1=$(( AFTER_LDAP1 - BEFORE_LDAP1 ))
DELTA_LDAP2=$(( AFTER_LDAP2 - BEFORE_LDAP2 ))
DELTA_TOTAL=$(( DELTA_LDAP1 + DELTA_LDAP2 ))

PCT_LDAP1=0
PCT_LDAP2=0
if [ "$DELTA_TOTAL" -gt 0 ]; then
  PCT_LDAP1=$(( (DELTA_LDAP1 * 100) / DELTA_TOTAL ))
  PCT_LDAP2=$(( (DELTA_LDAP2 * 100) / DELTA_TOTAL ))
fi

echo ""
echo "=========================================="
echo "RESULTADO: Distribucion de carga entre ldap1/ldap2 (fuente: Prometheus)"
echo "=========================================="
echo "  ldap1:  +${DELTA_LDAP1} busquedas  (${PCT_LDAP1}%)"
echo "  ldap2:  +${DELTA_LDAP2} busquedas  (${PCT_LDAP2}%)"
echo "  Total observado en el periodo: ${DELTA_TOTAL} busquedas"
echo "=========================================="
