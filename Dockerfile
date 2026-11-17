# Image unique de l'API Sama360 : même image pour l'API (défaut) et le worker
#   API    : node dist/main.js
#   worker : node dist/worker.js
#   migrations seules : node dist/shared/db/migrate.js
# Construction : docker build -t sama360-api .

FROM node:22-bookworm-slim AS build
WORKDIR /repo
RUN corepack enable
# Dépendances d'abord (cache Docker tant que le lockfile ne change pas)
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml tsconfig.base.json ./
COPY packages/contracts/package.json packages/contracts/
COPY apps/api/package.json apps/api/
RUN pnpm install --frozen-lockfile --filter "@sama360/api..."
# Code, compilation, puis dossier autonome avec les seules dépendances de production
COPY packages/contracts packages/contracts
COPY apps/api apps/api
RUN pnpm --filter @sama360/api build \
 && pnpm --filter @sama360/api deploy --prod --legacy /out \
 && rm -rf /out/src /out/test /out/jest.config.js /out/tsconfig*.json

FROM node:22-bookworm-slim
ENV NODE_ENV=production \
    PORT=3000
WORKDIR /app
COPY --from=build --chown=node:node /out ./
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/main.js"]
