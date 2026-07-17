#!/bin/bash
set -e

echo "=== Copiando certificados TLS ==="
mkdir -p /etc/web1/certs
cp /certs/web1.key /certs/web1.crt /certs/ca.crt /etc/web1/certs/
chmod 600 /etc/web1/certs/web1.key
chmod 644 /etc/web1/certs/web1.crt /etc/web1/certs/ca.crt

echo "=== Copiando keytab Kerberos ==="
mkdir -p /etc/apache2
if [ -f /shared-keytabs/web1.keytab ]; then
  cp /shared-keytabs/web1.keytab /etc/krb5.keytab
  chmod 644 /etc/krb5.keytab
  echo "Keytab copiado correctamente."
else
  echo "ADVERTENCIA: /shared-keytabs/web1.keytab no encontrado."
fi

echo "=== Verificando configuracion de Apache ==="
apache2ctl configtest

echo "=== Iniciando Apache en primer plano ==="
exec apache2ctl -D FOREGROUND
