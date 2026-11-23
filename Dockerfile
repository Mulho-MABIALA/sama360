# Image unique de Sama360 : l'API (avec le worker intégré) et la version web de l'app sur /app
#   API    : node dist/main.js
#   worker : node dist/worker.js
#   migrations seules : node dist/shared/db/migrate.js
# Construction : docker build -t sama360-api .
# Images de base : miroir officiel Docker sur Amazon ECR Public (évite la limite de téléchargements de Docker Hub)

# ---------- Version web de l'app (Flutter) ----------
FROM public.ecr.aws/docker/library/debian:bookworm-slim AS web
ARG FLUTTER_VERSION=3.50.0
RUN apt-get update && apt-get install -y --no-install-recommends git curl unzip xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /flutter
ENV PATH="/flutter/bin:${PATH}" \
    FLUTTER_SUPPRESS_ANALYTICS=true
RUN flutter config --no-analytics --enable-web && flutter precache --web
WORKDIR /mobile
COPY apps/mobile/pubspec.yaml apps/mobile/pubspec.lock ./
RUN flutter pub get
COPY apps/mobile ./
# STORE : pas de réglage « serveur » ; l'app web parle à l'adresse d'où elle est servie
RUN flutter build web --release --base-href /app/ --no-web-resources-cdn --dart-define=STORE=true \
 && find build/web -name '*.map' -delete

# ---------- API ----------
FROM public.ecr.aws/docker/library/node:22-bookworm-slim AS build
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

FROM public.ecr.aws/docker/library/node:22-bookworm-slim
ENV NODE_ENV=production \
    PORT=3000 \
    WEB_APP_DIR=/app/web
WORKDIR /app
COPY --from=build --chown=node:node /out ./
COPY --from=web --chown=node:node /mobile/build/web ./web
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/main.js"]
