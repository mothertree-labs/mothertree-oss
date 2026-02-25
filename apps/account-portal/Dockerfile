# Simple Node.js Express app
FROM node:25-alpine

WORKDIR /app

# Install all dependencies (including devDeps for Tailwind build)
COPY package.json ./
RUN npm install

# Copy app source
COPY . .

# Build Tailwind CSS
RUN npm run build:css

# Remove devDependencies for smaller production image
RUN npm prune --production

# Create non-root user
RUN addgroup -g 1001 -S nodejs && \
    adduser -S nodejs -u 1001 && \
    chown -R nodejs:nodejs /app

USER nodejs

EXPOSE 3000

ENV NODE_ENV=production
ENV PORT=3000

CMD ["node", "server.js"]
