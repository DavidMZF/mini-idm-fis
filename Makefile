.PHONY: up down build clean logs status test-fault-injection test-ldap-crash test-kdc-crash test-network-partition test-expired-cert test-tls-overhead test-load-balancing kinit-demo propagate-kerberos create-user help

include .env
export

DC := docker compose

## Levanta todo el stack completo, en el orden correcto, con monitoreo habilitado
up:
	@echo "=== 0/5: Deteniendo contenedores previos (si existen) ==="
	@$(DC) down
	@echo "=== 1/5: Generando PKI ==="
	$(DC) up -d ca-init
	@echo "=== 2/5: Levantando LDAP, Kerberos y balanceadores ==="
	$(DC) up -d ldap1 ldap2 kdc1 kdc2 lb1 lb2
	@echo "=== Esperando a que LDAP/Kerberos terminen de inicializar ==="
	@sleep 15
	@echo "=== 3/5: Propagando base de datos Kerberos (kdc1 -> kdc2) ==="
	@$(MAKE) propagate-kerberos
	@echo "=== 4/5: Habilitando cn=monitor en LDAP ==="
	@bash monitoring/enable-monitor.sh
	@echo "=== 5/5: Levantando web1 y monitoreo (Prometheus/exporters/cAdvisor) ==="
	$(DC) up -d web1 cadvisor kdc-exporter ldap-exporter prometheus
	@echo ""
	@echo "=== Stack completo levantado ==="
	@$(MAKE) status
	@echo ""
	@echo "=================================================="
	@echo " Interfaces disponibles:"
	@echo "=================================================="
	@echo "  Prometheus (metricas):           http://localhost:9090"
	@echo "  Prometheus - Targets:            http://localhost:9090/targets"
	@echo "  cAdvisor (metricas de sistema):  http://localhost:8081"
	@echo ""
	@echo "  Prueba rapida acceso web1:       make kinit-demo"
	@echo "  Pruebas de fallos:               make test-fault-injection"
	@echo "  Ver todos los comandos:          make help"
	@echo "=================================================="

## Propaga la base de datos
propagate-kerberos:
	@docker exec kdc1 cp /etc/krb5kdc/kdc1.keytab /etc/krb5.keytab
	@docker exec kdc1 kdb5_util dump /var/lib/krb5kdc/replica_dump
	@docker exec kdc1 kprop -f /var/lib/krb5kdc/replica_dump kdc2.fis.epn.ec

## Apaga todo, conservando los volúmenes
down:
	$(DC) down

## Apaga todo y borra los volúmenes
clean:
	$(DC) down -v

## Reconstruye todas las imágenes sin caché
build:
	$(DC) build --no-cache

## Muestra el estado de todos los contenedores
status:
	$(DC) ps -a

## Muestra logs en vivo de todo el stack
logs:
	$(DC) logs -f

## Corre los 6 experimentos de inyección de fallos
test-fault-injection: test-ldap-crash test-kdc-crash test-network-partition test-expired-cert test-tls-overhead test-load-balancing

test-ldap-crash:
	@bash tests/fault-injection/01-ldap-crash.sh

test-kdc-crash:
	@bash tests/fault-injection/02-kdc-crash.sh

test-network-partition:
	@bash tests/fault-injection/03-network-partition.sh

test-expired-cert:
	@echo "=== Certificado expirado: ldap1 ==="
	@bash tests/fault-injection/04-expired-certificate.sh ldap1
	@echo ""
	@echo "=== Certificado expirado: ldap2 ==="
	@bash tests/fault-injection/04-expired-certificate.sh ldap2

test-tls-overhead:
	@bash tests/fault-injection/05-test-tls-overhead.sh

test-load-balancing:
	@bash tests/fault-injection/06-test-load-balancing.sh

## Demo interactiva: pide usuario y contraseña, obtiene ticket y prueba SPNEGO contra web1
kinit-demo:
	@read -p "Usuario Kerberos EJ: (Usuario: dnoboa Password: Password2026!): " KUSER; \
	docker exec ldap1 kdestroy 2>/dev/null || true; \
	docker exec -it ldap1 kinit $$KUSER; \
	echo ""; \
	echo "Accediendo a web1 con el ticket obtenido (SPNEGO)..."; \
	docker exec ldap1 curl -sk --negotiate -u : https://web1.fis.epn.ec:443/whoami

## Crea un usuario nuevo en LDAP y Kerberos.
create-user:
	@if [ -z "$(UID_)" ] || [ -z "$(CN)" ] || [ -z "$(SN)" ] || [ -z "$(PASS)" ]; then \
		echo "Uso: make create-user UID_=jperez CN=\"Juan Perez\" SN=Perez PASS=Password2026!"; \
		exit 1; \
	fi
	@echo "=== Creando $(UID_) en LDAP ==="
	@UIDNUM=$$(shuf -i 10003-19999 -n1); \
	printf 'dn: uid=%s,ou=people,dc=fis,dc=epn,dc=ec\nobjectClass: inetOrgPerson\nobjectClass: posixAccount\nobjectClass: shadowAccount\nuid: %s\ncn: %s\nsn: %s\nmail: %s@fis.epn.ec\nuidNumber: %s\ngidNumber: 5000\nhomeDirectory: /home/%s\nloginShell: /bin/bash\n' \
		"$(UID_)" "$(UID_)" "$(CN)" "$(SN)" "$(UID_)" "$$UIDNUM" "$(UID_)" > /tmp/newuser_$(UID_).ldif
	@docker cp /tmp/newuser_$(UID_).ldif ldap1:/tmp/newuser.ldif
	@rm -f /tmp/newuser_$(UID_).ldif
	@docker exec ldap1 ldapadd -x -D "cn=admin,dc=fis,dc=epn,dc=ec" \
		-w "$(LDAP_ADMIN_PASSWORD)" -f /tmp/newuser.ldif
	@docker exec ldap1 ldappasswd -x -D "cn=admin,dc=fis,dc=epn,dc=ec" \
		-w "$(LDAP_ADMIN_PASSWORD)" -s "$(PASS)" "uid=$(UID_),ou=people,dc=fis,dc=epn,dc=ec"
	@echo "=== Creando $(UID_) en Kerberos ==="
	@docker exec kdc1 kadmin.local -q "addprinc -pw $(PASS) $(UID_)@$(REALM)"
	@echo "=== Usuario $(UID_) creado y sincronizado (LDAP + Kerberos) ==="

## Lista los targets disponibles
help:
	@echo "Targets disponibles:"
	@echo "  make up                     - Levanta todo el stack (PKI, LDAP, Kerberos, HA, web1, monitoreo)"
	@echo "  make down                   - Apaga el stack (conserva datos)"
	@echo "  make clean                  - Apaga el stack y borra TODOS los datos"
	@echo "  make build                  - Reconstruye todas las imagenes"
	@echo "  make status                 - Muestra el estado de los contenedores"
	@echo "  make logs                   - Muestra logs en vivo"
	@echo "  make propagate-kerberos     - Propaga manualmente la base de Kerberos (kdc1 -> kdc2)"
	@echo "  make test-fault-injection    - Corre los 6 experimentos de fallos"
	@echo "  make test-ldap-crash         - Fallo de nodo LDAP: tiempo de recuperacion"
	@echo "  make test-kdc-crash          - Failover del KDC: latencia de autenticacion"
	@echo "  make test-network-partition  - Particion de red entre nodos"
	@echo "  make test-expired-cert       - Certificado TLS expirado"
	@echo "  make test-tls-overhead       - Overhead de TLS en latencia de solicitudes"
	@echo "  make test-load-balancing     - Balanceo de carga y throughput"
	@echo "  make kinit-demo             - Demo rapida acceso a web1 ingreso de usuario y password"
	@echo "  make create-user UID_=... CN=\"...\" SN=... PASS=... - Crea un usuario en LDAP y Kerberos"
