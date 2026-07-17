#!/bin/bash
# enable-monitor.sh
# Habilita el backend cn=monitor de OpenLDAP en ldap1 y ldap2 SIN
# reiniciar los contenedores ni afectar los datos ya cargados.
# Uso: ./enable-monitor.sh
set -e

BASE_DN=${LDAP_BASE_DN:-dc=fis,dc=epn,dc=ec}

apply_to() {
  local container="$1"
  echo "=== Habilitando cn=monitor en ${container} ==="

  docker exec -i "$container" bash -c "cat > /tmp/monitor_module.ldif" <<EOF
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: back_monitor
EOF

  docker exec -i "$container" bash -c "cat > /tmp/monitor_db.ldif" <<EOF
dn: olcDatabase=Monitor,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMonitorConfig
olcDatabase: Monitor
olcAccess: to * by dn.exact="cn=admin,${BASE_DN}" read by * none
EOF

  echo "--- cargando modulo back_monitor ---"
  docker exec "$container" ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/monitor_module.ldif \
    || echo "  (back_monitor ya cargado o modulo ya presente, continuando)"

  echo "--- creando base Monitor ---"
  docker exec "$container" ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/monitor_db.ldif \
    || echo "  (base Monitor ya existente, continuando)"

  echo "--- verificando ---"
  docker exec "$container" ldapsearch -x -LLL -D "cn=admin,${BASE_DN}" -w "${LDAP_ADMIN_PASSWORD:-changeme}" \
    -H ldapi:/// -b "cn=Monitor" -s base dn \
    && echo "OK: cn=Monitor accesible en ${container}" \
    || echo "AVISO: no se pudo verificar cn=Monitor en ${container} via bind simple (revisar ACL/password)"

  echo
}

apply_to ldap1
apply_to ldap2

echo "=== Listo. cn=monitor habilitado en ambos nodos sin reiniciar contenedores. ==="
