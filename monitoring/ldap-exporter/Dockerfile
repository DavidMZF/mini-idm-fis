FROM python:3.12-slim

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y ldap-utils && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY ops_exporter.py /app/ops_exporter.py

EXPOSE 9330
ENV EXPORTER_PORT=9330

ENTRYPOINT ["python3", "/app/ops_exporter.py"]
