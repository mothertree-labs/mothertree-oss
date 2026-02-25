FROM node:22-alpine

LABEL org.opencontainers.image.source="https://github.com/mothertree-labs/mothertree-oss"
LABEL org.opencontainers.image.description="Calendar automation service for Mothertree"

# Run as non-root user
RUN addgroup -g 1001 -S appgroup && \
    adduser -u 1001 -S appuser -G appgroup

WORKDIR /app

# Install dependencies first (layer caching)
COPY package*.json ./
RUN npm ci --production && npm cache clean --force

# Copy application code
COPY server.js ./

# Switch to non-root user
USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD wget -qO- http://localhost:8080/healthz || exit 1

CMD ["node", "server.js"]
