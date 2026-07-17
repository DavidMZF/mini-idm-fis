FROM alpine:3.20

RUN apk add --no-cache openssl bash

WORKDIR /pki

COPY openssl.cnf /pki/openssl.cnf
COPY entrypoint.sh /pki/entrypoint.sh
RUN chmod +x /pki/entrypoint.sh

ENTRYPOINT ["/pki/entrypoint.sh"]
