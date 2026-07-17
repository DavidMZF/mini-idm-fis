FROM ubuntu:24.04

ENV TZ=America/Guayaquil
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apache2 libapache2-mod-auth-gssapi \
    krb5-user tzdata iproute2 procps curl && \
    rm -rf /var/lib/apt/lists/*

RUN a2enmod ssl auth_gssapi ldap authnz_ldap headers rewrite include

COPY config/ports.conf /etc/apache2/ports.conf
COPY config/web1-ssl.conf /etc/apache2/sites-available/web1-ssl.conf
COPY config/krb5.conf /etc/krb5.conf
COPY app/ /var/www/html/
COPY scripts/entrypoint.sh /entrypoint.sh

RUN a2ensite web1-ssl && a2dissite 000-default && \
    chmod +x /entrypoint.sh

EXPOSE 443

ENTRYPOINT ["/entrypoint.sh"]
