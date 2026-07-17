FROM python:3.12-slim

WORKDIR /app
COPY exporter.py /app/exporter.py

EXPOSE 9100
ENV KDC_LOG_PATH=/var/log/krb5kdc/krb5kdc.log
ENV EXPORTER_PORT=9100

ENTRYPOINT ["python3", "/app/exporter.py"]
