const Fastify = require('fastify');
const fastifyMetrics = require('fastify-metrics').default;
const { performance } = require('node:perf_hooks');

const blockLimitMs = 250;

function buildApp() {
  const app = Fastify({ logger: false, connectionTimeout: 5000, keepAliveTimeout: 5000 });
  app.server.maxConnections = 64;
  app.register(fastifyMetrics, {
    endpoint: '/metrics',
    clearRegisterOnInit: true,
    routeMetrics: { registeredRoutesOnly: false },
  });

  app.get('/livez', async (_request, reply) => {
    reply.type('text/plain; charset=utf-8').send('ok\n');
  });

  app.get('/work', async (request, reply) => {
    const rawDuration = request.query.duration;
    const durationMs = rawDuration === undefined ? 100 : Number(rawDuration);
    if (!Number.isInteger(durationMs) || durationMs < 0 || durationMs > blockLimitMs) {
      reply.code(400).type('text/plain; charset=utf-8').send('duration must be an integer between 0 and 250 milliseconds\n');
      return;
    }

    const deadline = performance.now() + durationMs;
    while (performance.now() < deadline) {
      // Deliberately block this single event loop for a short, bounded interval.
    }
    reply.type('text/plain; charset=utf-8').send(`blocked the event loop for ${durationMs}ms\n`);
  });

  return app;
}

async function start() {
  const app = buildApp();
  const port = Number(process.env.PORT || 8080);
  try {
    await app.listen({ port, host: '0.0.0.0' });
  } catch (error) {
    app.log.error(error);
    process.exit(1);
  }
  console.log(`event-loop-lag lab listening on :${port}`);

  const shutdown = async () => {
    const timeout = setTimeout(() => process.exit(1), 5000);
    timeout.unref();
    try {
      await app.close();
      clearTimeout(timeout);
      process.exit(0);
    } catch (error) {
      app.log.error(error);
      process.exit(1);
    }
  };
  process.once('SIGTERM', shutdown);
  process.once('SIGINT', shutdown);
}

if (require.main === module) {
  start();
}

module.exports = { buildApp };