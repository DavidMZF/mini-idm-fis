#!/bin/bash
#
# 04-expired-certificate.sh <ldap1|ldap2>
#
# Experimento: Expiracion de certificados TLS
# Simula: reemplazar el certificado valido del nodo indicado por uno ya
# vencido, verifica que las conexiones TLS son rechazadas (midiendo el
# tiempo de deteccion), y restaura el certificado valido al finalizar.
#
# Requiere: proyecto levantado (docker compose up -d).
#
# Uso:
#   ./04-expired-certificate.sh ldap1
#   ./04-expired-certificate.sh ldap2

set -uo pipefail

cd "$(dirname "$0")/../.."

NODE="${1:-}"
if [ "$NODE" != "ldap1" ] && [ "$NODE" != "ldap2" ]; then
  echo "Uso: $0 <ldap1|ldap2>"
  exit 1
fi

# El "cliente externo real" que verifica el rechazo es siempre el otro nodo
# (ldap1 <-> ldap2), igual que en las corridas manuales ya validadas.
if [ "$NODE" = "ldap1" ]; then
  PEER="ldap2"
else
  PEER="ldap1"
fi

FQDN="${NODE}.fis.epn.ec"

BASE_DN="dc=fis,dc=epn,dc=ec"
ADMIN_DN="cn=admin,${BASE_DN}"
ADMIN_PASS="${LDAP_ADMIN_PASSWORD:-Password2026!}"
RESULTS_FILE="tests/fault-injection/results-04-expired-cert-${NODE}.log"

mkdir -p "$(dirname "$RESULTS_FILE")"

log() {
  echo "$*" | tee -a "$RESULTS_FILE"
}

log "=========================================="
log "EXPERIMENTO: Certificado expirado en ${NODE}"
log "Inicio: $(date '+%Y-%m-%d %H:%M:%S')"
log "=========================================="

# ---------------------------------------------------------------------------
# [1] Verificar que el nodo funciona normalmente ANTES de tocar nada
# ---------------------------------------------------------------------------
log ""
log "[1] Verificando que ${NODE} funciona normalmente con su certificado valido..."
if docker exec "$NODE" ldapsearch -x -H "ldaps://${FQDN}:636" \
  -D "$ADMIN_DN" -w "$ADMIN_PASS" -b "$BASE_DN" -s base > /dev/null 2>&1; then
  log "OK: certificado valido funciona correctamente."
else
  log "ERROR: ${NODE} no responde correctamente ANTES de iniciar el experimento."
  log "Abortando -- no tiene sentido inyectar un fallo sobre un sistema que ya esta roto."
  exit 1
fi

# ---------------------------------------------------------------------------
# [2] Respaldar el certificado y la key validos actuales (informativo,
#     la fuente real que importa es pki-certs, ver paso 4).
# ---------------------------------------------------------------------------
log ""
log "[2] Respaldando certificado valido actual..."
docker exec "$NODE" cp "/etc/ldap/certs/${NODE}.crt" "/etc/ldap/certs/${NODE}.crt.valido"
docker exec "$NODE" cp "/etc/ldap/certs/${NODE}.key" "/etc/ldap/certs/${NODE}.key.valido"
log "Backup creado dentro de ${NODE}: ${NODE}.crt.valido / ${NODE}.key.valido"

# ---------------------------------------------------------------------------
# [3] Generar certificado VENCIDO para el nodo, dentro de un contenedor
#     temporal que monta el mismo volumen pki-certs (no depende de que
#     ca-init este corriendo).
# ---------------------------------------------------------------------------
log ""
log "[3] Generando certificado VENCIDO para ${NODE}..."

# Sello de tiempo unico para que el CN del cert de prueba nunca choque con
# una corrida anterior en el indice del CA (openssl ca rechaza CNs duplicados).
RUN_TAG=$(date +%s)
EXPIRED_CN="${NODE}-expired-test-${RUN_TAG}.fis.epn.ec"

STARTDATE=$(date -u -d '60 days ago' +%y%m%d%H%M%SZ)
ENDDATE=$(date -u -d '30 days ago' +%y%m%d%H%M%SZ)

docker run --rm \
  -v mini-idm-fis_pki-certs:/certs \
  -v "$(pwd)/pki/openssl.cnf:/pki/openssl.cnf:ro" \
  alpine sh -c "
    set -e
    apk add --no-cache openssl -q

    openssl ecparam -name prime256v1 -genkey -noout -out /tmp/expired.key

    openssl req -new -key /tmp/expired.key -out /tmp/expired.csr -sha256 \
      -subj '/C=EC/ST=Pichincha/L=Quito/O=FIS-EPN/OU=IdM/CN=${EXPIRED_CN}'

    cat > /tmp/san_expired.cnf <<CNFEOF
[v3_server]
basicConstraints = CA:FALSE
keyUsage         = critical, digitalSignature, keyEncipherment
extendedKeyUsage  = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${FQDN}
CNFEOF

    openssl ca -batch -config /pki/openssl.cnf -extensions v3_server \
      -extfile /tmp/san_expired.cnf \
      -startdate ${STARTDATE} -enddate ${ENDDATE} \
      -in /tmp/expired.csr -out /tmp/expired.crt

    cp /tmp/expired.crt /certs/${NODE}-expired.crt
    cp /tmp/expired.key /certs/${NODE}-expired.key
  "

if [ $? -ne 0 ]; then
  log "ERROR: fallo la generacion del certificado vencido. Abortando sin tocar ${NODE}."
  exit 1
fi

# Verificacion explicita de que el certificado generado SI esta vencido.
EXPIRY_CHECK=$(docker run --rm -v mini-idm-fis_pki-certs:/certs alpine sh -c "
  apk add --no-cache openssl -q
  openssl x509 -in /certs/${NODE}-expired.crt -checkend 0 -noout
  echo \$?
")
if echo "$EXPIRY_CHECK" | tail -1 | grep -q "^1$"; then
  log "OK: certificado generado confirmado como VENCIDO (openssl -checkend)."
else
  log "ERROR: el certificado generado NO esta vencido. Abortando -- no se toca ${NODE}."
  exit 1
fi

# ---------------------------------------------------------------------------
# [4] Instalar el certificado vencido, sobrescribiendo la FUENTE en pki-certs
#     (no solo /etc/ldap/certs/, porque el entrypoint la vuelve a copiar en
#     cada arranque).
# ---------------------------------------------------------------------------
log ""
log "[4] Instalando certificado vencido..."
log "NOTA: el entrypoint.sh de ${NODE} copia /certs/${NODE}.{crt,key} -> /etc/ldap/certs/ en"
log "CADA arranque. Para que el cert vencido sobreviva a un restart, hay que"
log "sobrescribir tambien la fuente en el volumen pki-certs (no solo el destino)."

docker run --rm -v mini-idm-fis_pki-certs:/certs alpine sh -c "
  cp /certs/${NODE}.crt /certs/${NODE}.crt.pkibak
  cp /certs/${NODE}.key /certs/${NODE}.key.pkibak
  cp /certs/${NODE}-expired.crt /certs/${NODE}.crt
  cp /certs/${NODE}-expired.key /certs/${NODE}.key
"
log "Certificado vencido copiado a pki-certs (fuente) y respaldo del original guardado como *.pkibak"

log "Reiniciando ${NODE} (docker restart, para no matar el PID 1 desde un exec externo)..."
docker restart "$NODE" > /dev/null
sleep 5

# ---------------------------------------------------------------------------
# [5] Verificar que la conexion TLS es RECHAZADA, midiendo el tiempo
#     de deteccion. Se conecta desde el nodo par (cliente externo real).
# ---------------------------------------------------------------------------
log ""
log "[5] Verificando que la conexion TLS es RECHAZADA por certificado vencido..."

START_MS=$(date +%s%3N)
OUTPUT=$(docker exec "$PEER" ldapsearch -x -H "ldaps://${FQDN}:636" \
  -D "$ADMIN_DN" -w "$ADMIN_PASS" -b "$BASE_DN" -s base 2>&1)
EXIT_CODE=$?
END_MS=$(date +%s%3N)
ELAPSED_MS=$((END_MS - START_MS))

echo "$OUTPUT" >> "$RESULTS_FILE"

if [ $EXIT_CODE -ne 0 ]; then
  log "OK: conexion rechazada correctamente (exit code ${EXIT_CODE})."
  log "Tiempo de deteccion del rechazo TLS: ${ELAPSED_MS} ms"
  echo "$OUTPUT" | grep -i "expired\|certificate\|verify" | tee -a "$RESULTS_FILE" || \
    log "(el mensaje de error no incluyo las palabras esperadas -- ver diagnostico [5b] abajo)"
else
  log "ADVERTENCIA CRITICA: la conexion tuvo EXITO. El certificado vencido NO fue detectado."
  log "Esto puede indicar que el cliente no esta validando fechas (revisar TLS_REQCERT / TLS_CACERT)."
fi

log ""
log "[5b] Diagnostico adicional con openssl s_client (mensaje TLS detallado)..."
S_CLIENT_OUTPUT=$(docker run --rm --network "${NETWORK_NAME:-fis-net}" \
  -v mini-idm-fis_pki-certs:/certs:ro \
  alpine sh -c "
    apk add --no-cache openssl -q
    echo | openssl s_client -connect ${FQDN}:636 -CAfile /certs/ca.crt 2>&1
  ")
echo "$S_CLIENT_OUTPUT" | grep -i "verify\|expired\|error\|return code" | tee -a "$RESULTS_FILE"

# ---------------------------------------------------------------------------
# [6] Restaurar el certificado valido
# ---------------------------------------------------------------------------
log ""
log "[6] Restaurando certificado valido en pki-certs (fuente real)..."
docker run --rm -v mini-idm-fis_pki-certs:/certs alpine sh -c "
  cp /certs/${NODE}.crt.pkibak /certs/${NODE}.crt
  cp /certs/${NODE}.key.pkibak /certs/${NODE}.key
"
log "Certificado valido restaurado en pki-certs."

log "Reiniciando ${NODE} con certificado valido restaurado..."
docker restart "$NODE" > /dev/null
sleep 5
log ""
log "[7] Verificando que ${NODE} volvio a funcionar con certificado valido..."
if docker exec "$PEER" ldapsearch -x -H "ldaps://${FQDN}:636" \
  -D "$ADMIN_DN" -w "$ADMIN_PASS" -b "$BASE_DN" -s base > /dev/null 2>&1; then
  log "OK: ${NODE} restaurado y funcionando normalmente."
else
  log "ERROR: ${NODE} NO volvio a funcionar tras restaurar el certificado."
  log "Revisar manualmente -- el backup sigue en ${NODE}.crt.valido/${NODE}.key.valido"
  exit 1
fi

log ""
log "=========================================="
log "RESULTADO: Experimento de certificado expirado completado (${NODE})"
log "Fin: $(date '+%Y-%m-%d %H:%M:%S')"
log "Tiempo de deteccion del rechazo TLS: ${ELAPSED_MS} ms"
log "Resultados completos en: ${RESULTS_FILE}"
log "=========================================="
