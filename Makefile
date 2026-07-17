.PHONY: up down build clean logs status test-fault-injection test-ldap-crash test-kdc-crash test-network-partition test-expired-cert kinit-demo propagate-kerberos help

DC := docker compose

## Levanta todo el stack completo, en el orden correcto, con monitoreo habilitado
up:
	@echo "=== 1/5: Generando PKI ==="
	$(DC) up -d ca-init
	@echo "=== 2/5: Levantando LDAP, Kerberos y balanceadores ==="
	$(DC) up -d ldap1 ldap2 kdc1 kdc2 lb1 lb2
	@echo "=== Esperando 15s a que LDAP/Kerberos terminen de inicializar ==="
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

## Propaga la base de datos de principals desde kdc1 (primario) hacia kdc2 (secundario)
propagate-kerberos:
	@docker exec kdc1 cp /etc/krb5kdc/kdc1.keytab /etc/krb5.keytab
	@docker exec kdc1 kdb5_util dump /var/lib/krb5kdc/replica_dump
	@docker exec kdc1 kprop -f /var/lib/krb5kdc/replica_dump kdc2.fis.epn.ec

## Apaga todo, conservando los volúmenes (datos persisten)
down:
	$(DC) down

## Apaga todo y borra TODOS los volúmenes (reinicio completo desde cero)
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

## Corre los 4 experimentos de inyección de fallos en secuencia
test-fault-injection: test-ldap-crash test-kdc-crash test-network-partition test-expired-cert

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

## Demo rápida: obtiene un ticket y prueba el flujo SPNEGO completo contra web1
kinit-demo:
	@echo "Obteniendo ticket Kerberos para dnoboa..."
	@docker exec ldap1 kdestroy 2>/dev/null || true
	@docker exec ldap1 bash -c 'echo "Password2026!" | kinit dnoboa'
	@echo ""
	@echo "Accediendo a web1 con el ticket (SPNEGO)..."
	@docker exec ldap1 curl -sk --negotiate -u : https://web1.fis.epn.ec:443/whoami

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
	@echo "  make test-fault-injection    - Corre los 4 experimentos de fallos"
	@echo "  make kinit-demo             - Demo rapida: kinit + acceso a web1 via SPNEGO"
