FROM node:22-alpine@sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

COPY src ./src

ENV NODE_ENV=production
ENV PORT=8789
ENV PASSKEY_CREDENTIAL_STORE_FILE=/data/passkey-backup/credentials.json
ENV PASSKEY_RECOVERY_ENABLED=false

EXPOSE 8789

RUN mkdir -p /data/passkey-backup && chown -R node:node /data/passkey-backup && chown -R node:node /app

VOLUME ["/data/passkey-backup"]

USER node

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 8789) + '/api/passkey-backup/v1/health').then(async (r) => { const body = await r.json(); process.exit(r.ok && body.ok === true && body.service === 'fearless-passkey-backup' && body.rpId === 'fearlesswallet.io' && body.schemaVersion === 1 ? 0 : 1); }).catch(() => process.exit(1))"

CMD ["node", "src/server.js"]
