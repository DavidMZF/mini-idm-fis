#!/bin/bash
set -e

REALM=${REALM:-FIS.EPN.EC}
MASTER_PASS=${KRB5_MASTER_PASSWORD:-changeme}
FIRST_RUN_FLAG="/var/lib/krb5kdc/.configured"

mkdir -p /var/lib/krb5kdc /etc/krb5kdc

echo "=== Copiando keytab de kdc2 ==="
for i in $(seq 1 30); do
  if [ -f /shared-keytabs/kdc2.keytab ]; then
    echo "Keytab de kdc2 encontrado."
    break
  fi
  echo "Esperando keytab de kdc2... ($i/30)"
  sleep 2
done
cp /shared-keytabs/kdc2.keytab /etc/krb5.keytab

if [ ! -f "$FIRST_RUN_FLAG" ]; then
  echo "=== Primera ejecución: creando base de datos vacía ==="
  kdb5_util create -s -r "${REALM}" -P "${MASTER_PASS}"
  touch "$FIRST_RUN_FLAG"
  echo "=== Configuración inicial completa ==="
else
  echo "=== Ya configurado previamente, iniciando directamente ==="
fi

echo "=== Iniciando krb5kdc ==="
krb5kdc &

echo "=== Iniciando kpropd (esperando propagación desde kdc1) ==="
exec kpropd -S -a /etc/krb5kdc/kpropd.acl -d
