FROM ubuntu:24.04

ENV TZ=America/Guayaquil
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    slapd ldap-utils iproute2 procps tzdata krb5-user libsasl2-modules-gssapi-mit netbase curl && \
    rm -rf /var/lib/apt/lists/*

COPY krb5.conf /etc/krb5.conf
COPY entrypoint.sh /entrypoint.sh
COPY bootstrap/ /bootstrap/
RUN chmod +x /entrypoint.sh

EXPOSE 389 636

ENTRYPOINT ["/entrypoint.sh"]
