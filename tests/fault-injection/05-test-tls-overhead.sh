#!/bin/bash
set -e
cd "$(dirname "$0")/../.."

N=${1:-30}

echo "=========================================="
echo "EXPERIMENTO: Overhead de TLS en latencia de solicitudes"
echo "=========================================="

echo ""
echo "[1] Estado inicial:"
docker compose ps ldap1

echo ""
echo "[2] Midiendo $N busquedas LDAP en texto plano (puerto 389)..."
TOTAL_PLAIN_MS=0
for i in $(seq 1 $N); do
  T0=$(date +%s%N)
  docker exec ldap1 ldapsearch -x -H ldap:/// -b "dc=fis,dc=epn,dc=ec" \
    -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" \
    "(uid=fmorales)" > /dev/null 2>&1
  T1=$(date +%s%N)
  MS=$(( (T1 - T0) / 1000000 ))
  TOTAL_PLAIN_MS=$(( TOTAL_PLAIN_MS + MS ))
done
AVG_PLAIN_MS=$(( TOTAL_PLAIN_MS / N ))
echo "OK: latencia promedio sin TLS = ${AVG_PLAIN_MS} ms (sobre $N solicitudes)"

echo ""
echo "[3] Midiendo $N busquedas LDAP sobre TLS (puerto 636, LDAPS)..."
TOTAL_TLS_MS=0
for i in $(seq 1 $N); do
  T0=$(date +%s%N)
  docker exec ldap1 ldapsearch -x -H ldaps://ldap1.fis.epn.ec:636 -b "dc=fis,dc=epn,dc=ec" \
    -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" \
    "(uid=fmorales)" > /dev/null 2>&1
  T1=$(date +%s%N)
  MS=$(( (T1 - T0) / 1000000 ))
  TOTAL_TLS_MS=$(( TOTAL_TLS_MS + MS ))
done
AVG_TLS_MS=$(( TOTAL_TLS_MS / N ))
echo "OK: latencia promedio con TLS = ${AVG_TLS_MS} ms (sobre $N solicitudes)"

echo ""
echo "[4] Midiendo $N busquedas LDAP a traves del balanceador (lb1, LDAPS 636)..."
TOTAL_LB_MS=0
for i in $(seq 1 $N); do
  T0=$(date +%s%N)
  docker exec ldap1 ldapsearch -x -H ldaps://lb.fis.epn.ec:636 -b "dc=fis,dc=epn,dc=ec" \
    -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" \
    "(uid=fmorales)" > /dev/null 2>&1
  T1=$(date +%s%N)
  MS=$(( (T1 - T0) / 1000000 ))
  TOTAL_LB_MS=$(( TOTAL_LB_MS + MS ))
done
AVG_LB_MS=$(( TOTAL_LB_MS / N ))
echo "OK: latencia promedio con TLS via balanceador = ${AVG_LB_MS} ms (sobre $N solicitudes)"

OVERHEAD_MS=$(( AVG_TLS_MS - AVG_PLAIN_MS ))
OVERHEAD_PCT=0
if [ "$AVG_PLAIN_MS" -gt 0 ]; then
  OVERHEAD_PCT=$(( (OVERHEAD_MS * 100) / AVG_PLAIN_MS ))
fi

echo ""
echo "=========================================="
echo "RESULTADO: Overhead de TLS"
echo "  Latencia sin TLS (389):          ${AVG_PLAIN_MS} ms"
echo "  Latencia con TLS (636):          ${AVG_TLS_MS} ms"
echo "  Latencia con TLS via balanceador: ${AVG_LB_MS} ms"
echo "  Overhead TLS directo:            ${OVERHEAD_MS} ms (${OVERHEAD_PCT}%)"
echo "=========================================="
