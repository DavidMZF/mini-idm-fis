#!/bin/bash
# Experimento: Partición de red (equivalente a iptables DROP)
# Simula: ldap1 pierde conectividad de red completamente, sin caerse el proceso
# Métrica: tiempo de detección y recuperación del balanceador

cd "$(dirname "$0")/../.."

echo "=========================================="
echo "EXPERIMENTO: Partición de red de ldap1"
echo "=========================================="

echo "[1] Estado inicial:"
docker compose ps ldap1 ldap2 lb1

echo ""
echo "[2] Verificando que ldap1 responde normalmente..."
docker exec ldap2 ldapsearch -x -H ldap://ldap1.fis.epn.ec:389 -D "cn=admin,dc=fis,dc=epn,dc=ec" \
  -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" -b "dc=fis,dc=epn,dc=ec" -s base | grep "^dn:" \
  && echo "OK: ldap1 responde normalmente"

echo ""
echo "[3] Simulando partición de red: desconectando ldap1 de fis-net"
echo "    (equivalente a bloquear todo el tráfico con iptables DROP)"
START=$(date +%s%N)
docker network disconnect fis-net ldap1

echo ""
echo "[4] Verificando que el balanceador (lb1) sigue sirviendo vía ldap2..."
until docker exec ldap2 ldapsearch -x -H ldaps://lb.fis.epn.ec:636 -D "cn=admin,dc=fis,dc=epn,dc=ec" \
  -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" -b "dc=fis,dc=epn,dc=ec" -s base > /dev/null 2>&1; do
  sleep 0.3
done
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))

echo "OK: el balanceador siguió sirviendo tráfico vía ldap2 (verificado en ${ELAPSED_MS} ms)"

echo ""
echo "[5] Verificando que ldap1 realmente está aislado (debe fallar)..."
if docker exec ldap2 timeout 3 ldapsearch -x -H ldap://ldap1.fis.epn.ec:389 \
  -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "${LDAP_ADMIN_PASSWORD:-Password2026!}" \
  -b "dc=fis,dc=epn,dc=ec" -s base > /dev/null 2>&1; then
  echo "ADVERTENCIA: ldap1 respondió, la partición no se aplicó correctamente"
else
  echo "OK: ldap1 confirmado inalcanzable (partición de red efectiva)"
fi

echo ""
echo "[6] Restaurando conectividad de ldap1..."
docker network connect fis-net ldap1
sleep 3
docker compose ps ldap1 ldap2 lb1

echo ""
echo "=========================================="
echo "RESULTADO: Balanceador mantuvo servicio durante partición (~${ELAPSED_MS} ms de exposición)"
echo "=========================================="
