FROM nginxinc/nginx-unprivileged:1.28-alpine@sha256:7377697a821c131a924a7105fafbe7414db4e9fcc77a6f08f776f33f141ec3f8
ENV NGINX_ENVSUBST_FILTER=^VAULT_DNS_RESOLVERS$
COPY web/nginx.conf /etc/nginx/templates/default.conf.template
COPY --chmod=755 web/15-vault-dns.envsh /docker-entrypoint.d/15-vault-dns.envsh
COPY web/public/ /usr/share/nginx/html/
COPY web/prepare-assets.sh /tmp/prepare-assets.sh
USER root
RUN sh /tmp/prepare-assets.sh /usr/share/nginx/html && rm /tmp/prepare-assets.sh
USER nginx
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1:8080/health || exit 1
