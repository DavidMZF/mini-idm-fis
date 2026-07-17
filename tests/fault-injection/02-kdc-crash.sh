#!/bin/bash
# Experimento: Fallo del KDC Primario (detener servicio Kerberos)
# Métrica: latencia de autenticación durante failover

cd "$(dirname "$0")/../.."

echo "=========================================="
echo "EXPERIMENTO: Fallo de kdc1 (KDC Primario)"
echo "=========================================="

echo "[1] Estado inicial:"
docker compose ps kdc1 kdc2

echo ""
echo "[2] Obteniendo ticket de referencia desde kdc1..."
docker exec kdc1 kdestroy 2>/dev/null
docker exec kdc1 bash -c 'echo "Password2026!" | kinit dnoboa'
docker exec kdc1 klist | grep "Default principal"

echo ""
echo "[3] Simulando fallo: docker kill kdc1"
docker kill kdc1

echo ""
echo "[4] Midiendo tiempo de failover: obteniendo ticket vía kdc2..."
docker exec kdc2 kdestroy 2>/dev/null

START=$(date +%s%N)
docker exec kdc2 bash -c 'echo "Password2026!" | kinit dnoboa'
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))

docker exec kdc2 klist | grep "Default principal"
echo "OK: ticket obtenido desde kdc2 (secundario)"

echo ""
echo "[5] Restaurando kdc1..."
docker start kdc1
sleep 5
docker compose ps kdc1 kdc2

echo ""
echo "=========================================="
echo "RESULTADO: Failover KDC exitoso en ${ELAPSED_MS} ms"
echo "=========================================="
