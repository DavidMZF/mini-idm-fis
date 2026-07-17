# mini-idm-fis

Este proyecto implementa un laboratorio de gestión de identidad (IdM) de alta disponibilidad en entornos de contenedores (Docker). Diseñado como un banco de pruebas académico para la Escuela Politécnica Nacional (EPN), el stack simula una infraestructura corporativa robusta orientada a evaluar la tolerancia a fallos, la replicación de directorios y la autenticación federada bajo escenarios de estrés e inyección de fallos.

## Arquitectura del stack

El entorno se compone de múltiples capas interconectadas sobre una red aislada de Docker:

- **Servicio de Directorio (LDAP):** instancia replicada bajo esquema proveedor/consumidor (`ldap1` y `ldap2`).
- **Autenticación Centralizada (Kerberos):** arquitectura KDC replicada (`kdc1` primario y `kdc2` secundario) con propagación de base de datos de principals.
- **Balanceo de Carga (HAProxy):** dos balanceadores activos (`lb1` y `lb2`) encargados de distribuir las peticiones LDAP y gestionar la redirección en caso de caída de nodos.
- **Seguridad y PKI:** autoridad certificadora (CA) interna que emite certificados TLS para asegurar los canales de comunicación (LDAPS).
- **Aplicación de prueba (Webapp):** servicio web protegido mediante el protocolo SPNEGO/Kerberos para validar el ciclo de autenticación completo de un cliente real.
- **Observabilidad:** stack compuesto por Prometheus, cAdvisor y exporters personalizados para LDAP y Kerberos, permitiendo monitorear métricas críticas en tiempo real.
- **Inyección de fallas:** scripts automatizados para simular particiones de red, latencias, caída de servicios y expiración de certificados, registrando los tiempos de recuperación del sistema.

## Estructura del proyecto

```
mini-idm-fis/
├── Makefile                  Automatización del ciclo de vida y pruebas
├── docker-compose.yml         Orquestación de servicios y redes de Docker
├── .env                       Parámetros de configuración del dominio y credenciales
├── pki/                       Scripts y configuración de la CA local
├── ldap/                      Configuraciones de réplica proveedor-consumidor
├── kerberos/                  Configuración de KDC primario y secundario
├── haproxy/                   Configuración de balanceadores de carga
├── webapp/                    Aplicación protegida con autenticación SPNEGO
├── monitoring/                Configuración de Prometheus, cAdvisor y exporters locales
└── tests/                     Suite de pruebas y simulación de fallas
```

## Prerrequisitos y configuración

### Requisitos de sistema

- **Motor de ejecución:** Docker Engine v24 o superior y Docker Compose v2 (integrado como plugin, `docker compose`).
- **Herramientas:** GNU Make, Git.
- **Recursos:** mínimo 4 GB de RAM y 2 GB de espacio libre en disco.
- **Soporte de red:** Linux nativo o WSL2 (Windows Subsystem for Linux), requerido debido al uso de capacidades de red avanzadas (`NET_ADMIN`, `NET_RAW`) para la simulación de particiones.
- **Puertos libres en el host:** 389, 636, 3389, 6636, 88 (UDP/TCP), 464, 749, 8088, 8754, 1389, 1636, 2389, 2636, 8443, 8081 y 9090.

### Preparación en Windows usando WSL

1. Verificar si WSL ya está instalado, desde PowerShell:

   ```powershell
   wsl --status
   ```

2. Si no está instalado, instalarlo (esto instala WSL2 junto con una distribución Ubuntu por defecto):

   ```powershell
   wsl --install
   ```

   Reiniciar el equipo si el instalador lo solicita.

3. Verificar que la distribución esté usando la versión 2 del subsistema:

   ```powershell
   wsl -l -v
   ```

   Si alguna distribución aparece como versión 1, convertirla con:

   ```powershell
   wsl --set-version <nombre-distro> 2
   ```

4. Instalar Docker Desktop para Windows y, en Settings > General, confirmar que la opción "Use the WSL 2 based engine" esté activada.

5. En Settings > Resources > WSL Integration, habilitar la integración con la distribución de Linux que se vaya a usar (por ejemplo, Ubuntu).

6. Abrir la distribución WSL y verificar, desde esa terminal, que Docker responda correctamente:

   ```bash
   docker version
   docker compose version
   ```

   Si ambos comandos devuelven información sin errores, el proyecto puede clonarse y ejecutarse desde dentro de WSL sin instalar Docker por separado en Linux.

## Clonación del repositorio

```bash
git clone https://github.com/DavidMZF/mini-idm-fis
cd mini-idm-fis
```

El archivo `.env` ya se incluye en el repositorio con valores por defecto (dominio `fis.epn.ec`, realm `FIS.EPN.EC` y credenciales de prueba). Puede modificarse antes del primer arranque, pero no es obligatorio para un primer despliegue.

## Operación del proyecto

El ciclo de vida del laboratorio está completamente automatizado a través del `Makefile`.

### Comandos de ciclo de vida

```bash
# Levantar el stack completo (inicializa PKI, LDAP, Kerberos, Webapp y monitoreo)
make up

# Consultar el estado de los servicios
make status

# Ver logs en tiempo real
make logs

# Detener los contenedores preservando los datos de los volúmenes
make down

# Limpieza total (apaga contenedores y elimina volúmenes y certificados antiguos)
make clean

# Reconstruir todas las imágenes sin caché
make build

# Propagar manualmente la base de datos de Kerberos (kdc1 -> kdc2)
make propagate-kerberos

# Ver la lista completa de targets disponibles
make help
```

### Demo rápida de autenticación

```bash
make kinit-demo
```

Este comando obtiene un ticket Kerberos para el usuario de prueba `dnoboa` y lo usa para autenticarse contra la aplicación web mediante SPNEGO.

### Pruebas de resiliencia e inyección de fallos

Para evaluar el comportamiento de alta disponibilidad y capturar métricas de recuperación frente a caídas:

```bash
# Ejecutar toda la suite de pruebas consecutivamente
make test-fault-injection
```

También pueden ejecutarse de forma individual:

```bash
make test-ldap-crash          # Caída del nodo LDAP principal
make test-kdc-crash           # Caída del KDC de Kerberos
make test-network-partition   # Partición de red inducida por HAProxy
make test-expired-cert        # Comportamiento ante certificados expirados
```

Los resultados de las pruebas de certificado expirado quedan registrados como archivos de log dentro de `tests/fault-injection/`.

## Diagnóstico y pruebas manuales

Para interactuar directamente con los componentes o depurar fallas de manera manual, se pueden usar los siguientes comandos.

### Verificar contenedores activos

```bash
docker compose ps -a
```

### Consultar el directorio LDAP

```bash
# Consultar contra el nodo proveedor (ldap1)
docker exec ldap1 ldapsearch -x -H ldap:/// -b "dc=fis,dc=epn,dc=ec" \
  -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "Password2026!" "(uid=fmorales)"

# Consultar contra el nodo de réplica (ldap2)
docker exec ldap2 ldapsearch -x -H ldap:/// -b "dc=fis,dc=epn,dc=ec" \
  -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "Password2026!" "(uid=fmorales)"
```

### Consultar el estado interno de LDAP (cn=monitor)

El Makefile habilita automáticamente `cn=monitor` durante `make up`. Puede consultarse manualmente así:

```bash
docker exec ldap1 ldapsearch -x -H ldap:/// -b "cn=monitor" \
  -D "cn=admin,dc=fis,dc=epn,dc=ec" -w "Password2026!"
```

### Administración de Kerberos

```bash
# Listar los principals registrados en el KDC primario
docker exec kdc1 kadmin.local -q "listprincs"

# Revisar los logs del KDC
docker exec kdc1 tail -f /var/log/krb5kdc/kdc.log

# Simular la obtención de un ticket Kerberos (kinit) y listarlo (klist)
docker exec ldap1 kdestroy 2>/dev/null || true
docker exec ldap1 bash -c 'echo "Password2026!" | kinit dnoboa'
docker exec ldap1 klist
```

### Verificar los balanceadores de carga

```bash
docker compose ps lb1 lb2
```

### Prueba de acceso web (SPNEGO) por curl

La aplicación web (web1) expone un endpoint protegido por SPNEGO en el puerto 8443. La verificación debe hacerse por línea de comandos usando curl, no desde un navegador.

```bash
# Intento sin credenciales (retorna código 401 Unauthorized)
curl -sk -i https://localhost:8443/whoami

# Petición autenticada mediante negociación SPNEGO desde el contenedor cliente
docker exec ldap1 curl -sk --negotiate -u : https://web1.fis.epn.ec:443/whoami
```

Si se desea probar desde el host en lugar de desde un contenedor, es necesario contar con un ticket Kerberos válido en la máquina host y con resolución de nombre para `web1.fis.epn.ec`, o bien apuntar la petición directamente al puerto publicado:

```bash
curl -sk --negotiate -u : https://localhost:8443/whoami
```

## Monitoreo y observabilidad

Una vez inicializado el stack, se puede acceder a las siguientes direcciones locales para medir el impacto de la inyección de fallos:

- **Prometheus:** `http://localhost:9090`. Desde la pestaña "Graph" se pueden consultar métricas expuestas por los distintos targets, y desde "Status > Targets" verificar que los tres exporters (cAdvisor, kdc-exporter, ldap-exporter) estén siendo correctamente scrapeados (estado "UP").
- **cAdvisor:** `http://localhost:8081`. Expone el uso de CPU, memoria, red y disco por contenedor en tiempo real.

Este proyecto solo incorpora Prometheus como interfaz de consulta y no incluye Grafana. La pestaña "Graph" de Prometheus permite igualmente graficar la evolución de una métrica en el tiempo y es suficiente para observar el comportamiento del sistema durante los experimentos.

### Extracción de métricas crudas

Si se desea evaluar los datos crudos transmitidos por los recolectores de métricas dentro de la red del clúster:

```bash
# Obtener métricas del KDC (por ejemplo, AS_REQ, TGS_REQ)
docker exec prometheus wget -qO- http://kdc-exporter:9100/metrics

# Obtener métricas de LDAP (incluye retraso de sincronización de réplica)
docker exec prometheus wget -qO- http://ldap-exporter:9330/metrics
```

Estas métricas, junto con los logs generados por los propios scripts de `tests/fault-injection/` (que miden por línea de comandos el tiempo de recuperación de cada componente), se complementan para evaluar el comportamiento del sistema ante fallos.

## Notas de seguridad

Las credenciales (`Password2026!`) y configuraciones de dominio (`fis.epn.ec`) provistas en el archivo `.env` se entregan con propósitos puramente académicos e instrumentales para laboratorios locales. No deben ser expuestas en entornos productivos. Adicionalmente, si algún puerto del host listado en los prerrequisitos ya está en uso, `docker compose up` fallará al intentar publicarlo; en ese caso debe liberarse el puerto o modificarse el mapeo correspondiente en `docker-compose.yml`.
