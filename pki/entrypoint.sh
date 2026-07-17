#!/bin/bash
set -e

echo "=== Iniciando generación de PKI para FIS ==="

mkdir -p /certs/private /certs/newcerts /certs/csr
chmod 700 /certs/private

# Evita regenerar si ya existe (útil si reinicias el contenedor)
if [ -f /certs/ca.crt ]; then
  echo "CA ya existe, omitiendo generación."
else
  touch /certs/index.txt
  echo 1000 > /certs/serial

  echo "--- Generando llave privada de la CA ---"
  openssl ecparam -name prime256v1 -genkey -noout -out /certs/private/ca.key
  chmod 400 /certs/private/ca.key

  echo "--- Generando certificado autofirmado de la CA (120 días) ---"
  openssl req -config /pki/openssl.cnf -key /certs/private/ca.key \
    -new -x509 -days 120 -sha256 -extensions v3_ca -out /certs/ca.crt
fi

# Función para generar y firmar el certificado de un nodo
issue_cert() {
  local NODE=$1
  local FQDN="${NODE}.fis.epn.ec"

  if [ -f "/certs/${NODE}.crt" ]; then
    echo "Certificado de ${NODE} ya existe, omitiendo."
    return
  fi

  echo "--- Generando certificado para ${NODE} (${FQDN}) ---"
  openssl ecparam -name prime256v1 -genkey -noout -out /certs/csr/${NODE}.key
  openssl req -new -key /certs/csr/${NODE}.key -out /certs/csr/${NODE}.csr -sha256 \
    -subj "/C=EC/ST=Pichincha/L=Quito/O=FIS-EPN/OU=IdM/CN=${FQDN}"

  openssl ca -batch -config /pki/openssl.cnf -extensions v3_server -days 30 \
    -in /certs/csr/${NODE}.csr -out /certs/${NODE}.crt

  cp /certs/csr/${NODE}.key /certs/${NODE}.key
}

issue_cert_ldap_san() {
  local NODE=$1
  local FQDN="${NODE}.fis.epn.ec"

  if [ -f "/certs/${NODE}.crt" ]; then
    echo "Certificado de ${NODE} ya existe, omitiendo."
    return
  fi

  echo "--- Generando certificado SAN para ${NODE} (incluye ldap1, ldap2, lb) ---"
  openssl ecparam -name prime256v1 -genkey -noout -out /certs/csr/${NODE}.key

  cat > /tmp/san_${NODE}.cnf <<EOF
[req]
default_bits = 256
prompt = no
distinguished_name = dn
req_extensions = v3_req

[dn]
C = EC
ST = Pichincha
L = Quito
O = FIS-EPN
OU = IdM
CN = ${FQDN}

[v3_req]
subjectAltName = @alt_names

[alt_names]
DNS.1 = ldap1.fis.epn.ec
DNS.2 = ldap2.fis.epn.ec
DNS.3 = lb.fis.epn.ec
EOF

  openssl req -new -key /certs/csr/${NODE}.key -out /certs/csr/${NODE}.csr -sha256 \
    -config /tmp/san_${NODE}.cnf

  openssl ca -batch -config /pki/openssl.cnf -extensions v3_server -days 30 \
    -in /certs/csr/${NODE}.csr -out /certs/${NODE}.crt \
    -extfile /tmp/san_${NODE}.cnf -extensions v3_req

  cp /certs/csr/${NODE}.key /certs/${NODE}.key
}

issue_cert_ldap_san ldap1
issue_cert_ldap_san ldap2
issue_cert kdc1
issue_cert kdc2
issue_cert web1

echo "=== PKI generada correctamente ==="
echo "Certificados disponibles en /certs:"
ls -la /certs/*.crt /certs/*.key 2>/dev/null

echo "=== ca-init finalizado ==="
