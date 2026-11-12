FROM node:22.19-alpine
WORKDIR /app
COPY labs/event-loop-lag/package.json labs/event-loop-lag/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY --chown=node:node labs/event-loop-lag/server.js ./server.js
USER node
EXPOSE 8080
CMD ["node", "server.js"]