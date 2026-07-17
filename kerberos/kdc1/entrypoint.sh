#!/bin/bash
set -e
echo "$(hostname -i) kdc1.fis.epn.ec kdc1" >> /etc/hosts
REALM=${REALM:-FIS.EPN.EC}
MASTER_PASS=${KRB5_MASTER_PASSWORD:-changeme}
ADMIN_PASS=${KADMIN_PASSWORD:-changeme}
FIRST_RUN_FLAG="/var/lib/krb5kdc/.configured"
mkdir -p /var/lib/krb5kdc /etc/krb5kdc /shared-keytabs
if [ ! -f "$FIRST_RUN_FLAG" ]; then
  echo "=== Primera ejecución: inicializando base de datos Kerberos ==="
  kdb5_util create -s -r "${REALM}" -P "${MASTER_PASS}"
  echo "=== Creando principals de usuario ==="
  kadmin.local -q "addprinc -pw Password2026! fmorales@${REALM}"
  kadmin.local -q "addprinc -pw Password2026! dnoboa@${REALM}"
  echo "=== Creando principal de administración ==="
  kadmin.local -q "addprinc -pw ${ADMIN_PASS} dnoboa/admin@${REALM}"
  echo "=== Creando principals de servicio ==="
  kadmin.local -q "addprinc -randkey ldap/ldap1.fis.epn.ec@${REALM}"
  kadmin.local -q "addprinc -randkey ldap/ldap2.fis.epn.ec@${REALM}"
  kadmin.local -q "addprinc -randkey http/web1.fis.epn.ec@${REALM}"
  kadmin.local -q "addprinc -randkey HTTP/web1.fis.epn.ec@${REALM}"
  kadmin.local -q "addprinc -randkey host/kdc1.fis.epn.ec@${REALM}"
  kadmin.local -q "addprinc -randkey host/kdc2.fis.epn.ec@${REALM}"
  echo "=== Exportando keytabs directamente al volumen compartido ==="
  kadmin.local -q "ktadd -k /shared-keytabs/ldap1.keytab ldap/ldap1.fis.epn.ec@${REALM}"
  kadmin.local -q "ktadd -k /shared-keytabs/ldap2.keytab ldap/ldap2.fis.epn.ec@${REALM}"
  kadmin.local -q "ktadd -k /shared-keytabs/web1.keytab http/web1.fis.epn.ec@${REALM}"
  kadmin.local -q "ktadd -k /shared-keytabs/web1.keytab HTTP/web1.fis.epn.ec@${REALM}"
  kadmin.local -q "ktadd -k /etc/krb5kdc/kdc1.keytab host/kdc1.fis.epn.ec@${REALM}"
  kadmin.local -q "ktadd -k /etc/krb5kdc/kdc2.keytab host/kdc2.fis.epn.ec@${REALM}"
  cp /etc/krb5kdc/kdc2.keytab /shared-keytabs/kdc2.keytab
  echo "Keytab de kdc2 copiado a volumen compartido."
  touch "$FIRST_RUN_FLAG"
  echo "=== Configuración inicial completa ==="
else
  echo "=== Ya configurado previamente, iniciando directamente ==="
fi
echo "=== Iniciando krb5kdc y kadmind ==="
mkdir -p /var/log/krb5kdc
krb5kdc
kadmind -nofork &
wait
