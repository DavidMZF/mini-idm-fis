#!/bin/bash
set -e

DOMAIN=${DOMAIN:-fis.epn.ec}
BASE_DN=${LDAP_BASE_DN:-dc=fis,dc=epn,dc=ec}
ADMIN_PASS=${LDAP_ADMIN_PASSWORD:-changeme}
FIRST_RUN_FLAG="/var/lib/ldap/.configured"

echo "=== Copiando certificados TLS ==="
mkdir -p /etc/ldap/certs
cp /certs/ldap1.key /certs/ldap1.crt /certs/ca.crt /etc/ldap/certs/
chown openldap:openldap /etc/ldap/certs/*
chmod 640 /etc/ldap/certs/ldap1.key
chmod 644 /etc/ldap/certs/ldap1.crt /etc/ldap/certs/ca.crt

if ! grep -q "TLS_CACERT.*ca.crt" /etc/ldap/ldap.conf 2>/dev/null; then
  echo "TLS_CACERT /etc/ldap/certs/ca.crt" >> /etc/ldap/ldap.conf
fi

if [ ! -f "$FIRST_RUN_FLAG" ]; then
  echo "=== Primera ejecución: configurando slapd ==="

  debconf-set-selections <<EOF
slapd slapd/internal/generated_adminpw password ${ADMIN_PASS}
slapd slapd/internal/adminpw password ${ADMIN_PASS}
slapd slapd/password2 password ${ADMIN_PASS}
slapd slapd/password1 password ${ADMIN_PASS}
slapd slapd/domain string ${DOMAIN}
slapd shared/organization string FIS-EPN
slapd slapd/backend string MDB
slapd slapd/purge_database boolean false
slapd slapd/move_old_database boolean true
slapd slapd/allow_ldap_v2 boolean false
slapd slapd/no_configuration boolean false
EOF

  dpkg-reconfigure -f noninteractive slapd

  cat > /tmp/tls.ldif <<EOF
dn: cn=config
changetype: modify
replace: olcTLSCertificateFile
olcTLSCertificateFile: /etc/ldap/certs/ldap1.crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: /etc/ldap/certs/ldap1.key
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: /etc/ldap/certs/ca.crt
EOF

  slapd -h "ldapi:/// ldap:///" -u openldap -g openldap &
  SLAPD_PID=$!
  sleep 2

  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/tls.ldif

  echo "=== Cargando estructura base (OUs, grupo, usuarios) ==="
  for f in /bootstrap/*.ldif; do
    echo "Cargando $f..."
    ldapadd -x -D "cn=admin,${BASE_DN}" -w "${ADMIN_PASS}" -f "$f" || echo "  (posible entrada ya existente, continuando)"
  done

  echo "=== Habilitando syncprov (para replicación) ==="
  cat > /tmp/syncprov_mod.ldif <<EOF
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: syncprov
EOF
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/syncprov_mod.ldif

  cat > /tmp/syncprov_overlay.ldif <<EOF
dn: olcOverlay=syncprov,olcDatabase={1}mdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcSyncProvConfig
olcOverlay: syncprov
olcSpCheckpoint: 100 10
olcSpSessionLog: 100
EOF
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/syncprov_overlay.ldif

  cat > /tmp/syncprov_index.ldif <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: entryCSN eq
-
add: olcDbIndex
olcDbIndex: entryUUID eq
EOF
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/syncprov_index.ldif

  echo "=== Habilitando backend cn=monitor (metricas para Prometheus) ==="
  cat > /tmp/monitor_module.ldif <<EOF
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: back_monitor
EOF
  ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/monitor_module.ldif || echo "  (back_monitor ya cargado, continuando)"

  cat > /tmp/monitor_db.ldif <<EOF
dn: olcDatabase=Monitor,cn=config
objectClass: olcDatabaseConfig
objectClass: olcMonitorConfig
olcDatabase: Monitor
olcAccess: to * by dn.exact="cn=admin,${BASE_DN}" read by * none
EOF
  ldapadd -Y EXTERNAL -H ldapi:/// -f /tmp/monitor_db.ldif || echo "  (base Monitor ya existente, continuando)"

  echo "=== Deteniendo instancia temporal de slapd ==="
  pkill -TERM slapd 2>/dev/null || true

  # Espera activamente hasta que el proceso realmente muera
  for i in $(seq 1 10); do
    if ! pgrep slapd > /dev/null 2>&1; then
      echo "slapd detenido correctamente."
      break
    fi
    echo "Esperando que slapd termine... ($i/10)"
    sleep 1
  done

  # Si sigue vivo después de 10s, forzar
  pkill -KILL slapd 2>/dev/null || true
  sleep 1

  touch "$FIRST_RUN_FLAG"
  echo "=== Configuración inicial completa ==="
else
  echo "=== Ya configurado previamente, iniciando directamente ==="
fi

echo "=== Copiando keytab Kerberos ==="
if [ -f /shared-keytabs/ldap1.keytab ]; then
  cp /shared-keytabs/ldap1.keytab /etc/krb5.keytab
  chown openldap:openldap /etc/krb5.keytab
  chmod 600 /etc/krb5.keytab
  echo "Keytab copiado correctamente."
else
  echo "ADVERTENCIA: /shared-keytabs/ldap1.keytab no encontrado."
fi

echo "=== Iniciando slapd en primer plano ==="
exec slapd -d 1 -h "ldap:/// ldapi:/// ldaps:///" -u openldap -g openldap
