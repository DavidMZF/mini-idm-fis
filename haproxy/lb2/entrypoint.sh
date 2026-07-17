#!/bin/bash
set -e

echo "=== Iniciando HAProxy ==="
haproxy -f /etc/haproxy/haproxy.cfg -db &

sleep 2

echo "=== Limpiando estado previo de Keepalived ==="
rm -f /var/run/keepalived.pid

echo "=== Iniciando Keepalived ==="
exec keepalived --dont-fork --log-console --vrrp
