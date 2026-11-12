const assert = require('node:assert/strict');
const test = require('node:test');

const { buildApp } = require('./server');

test('Fastify serves bounded work and its runtime and route metrics', async (t) => {
  const app = buildApp();
  t.after(() => app.close());

  const valid = await app.inject({ method: 'GET', url: '/work?duration=0' });
  assert.equal(valid.statusCode, 200);
  assert.match(valid.body, /blocked the event loop for 0ms/);

  const invalid = await app.inject({ method: 'GET', url: '/work?duration=251' });
  assert.equal(invalid.statusCode, 400);

  const delayed = await app.inject({ method: 'GET', url: '/work?duration=60' });
  assert.equal(delayed.statusCode, 200);
  await new Promise((resolve) => setTimeout(resolve, 30));

  const metrics = await app.inject({ method: 'GET', url: '/metrics' });
  assert.equal(metrics.statusCode, 200);
  assert.match(metrics.body, /nodejs_eventloop_lag_max_seconds/);
  assert.match(metrics.body, /http_request_duration_seconds_count/);
  assert.match(metrics.body, /process_cpu_seconds_total/);
});

test('Fastify keeps liveness independent of the work route', async (t) => {
  const app = buildApp();
  t.after(() => app.close());

  const response = await app.inject({ method: 'GET', url: '/livez' });
  assert.equal(response.statusCode, 200);
  assert.equal(response.body, 'ok\n');
});