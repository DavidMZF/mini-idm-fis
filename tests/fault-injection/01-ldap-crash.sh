#!/bin/bash
# Experimento: Crash del servidor LDAP Master (kill -9)
# Métrica: tiempo de recuperación, disponibilidad de lecturas

set -e
cd "$(dirname "$0")/../.."

echo "=========================================="
echo "EXPERIMENTO: Crash de ldap1 (kill -9)"
echo "=========================================="

echo "[1] Estado inicial:"
docker compose ps ldap1 ldap2

echo ""
echo "[2] Verificando lectura normal desde ldap1..."
docker exec ldap1 ldapsearch -x -H ldap:/// -b "dc=fis,dc=epn,dc=ec" \
  -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" \
  "(uid=fmorales)" | grep "^dn:" && echo "OK: lectura exitosa en ldap1"

echo ""
echo "[3] Simulando crash: docker kill ldap1 (SIGKILL, equivalente a kill -9)"
START=$(date +%s%N)
docker kill ldap1

echo ""
echo "[4] Verificando que ldap2 sigue sirviendo lecturas..."
until docker exec ldap2 ldapsearch -x -H ldap:/// -b "dc=fis,dc=epn,dc=ec" \
  -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" \
  "(uid=fmorales)" > /dev/null 2>&1; do
  sleep 0.2
done
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))

echo "OK: ldap2 respondió exitosamente en ${ELAPSED_MS} ms tras el crash de ldap1"

echo ""
echo "[5] Restaurando ldap1..."
docker start ldap1
sleep 3
docker compose ps ldap1 ldap2

echo ""
echo "=========================================="
echo "RESULTADO: Failover LDAP exitoso en ${ELAPSED_MS} ms"
echo "=========================================="
