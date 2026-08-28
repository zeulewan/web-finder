'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  parseAutoPublishState,
  parseTailscaleServeStatusJSON,
  planServeReconciliation,
} = require('../serve-state');

const status = JSON.stringify({
  TCP: { 3000: { HTTPS: true }, 9321: { HTTPS: true } },
  Web: {
    'host.example.ts.net:3000': { Handlers: { '/': { Proxy: 'http://127.0.0.1:4000' } } },
    'host.example.ts.net:9321': { Handlers: { '/': { Proxy: 'http://127.0.0.1:9321' } } },
  },
});

test('parses Tailscale Serve JSON without depending on display text', () => {
  assert.deepEqual(parseTailscaleServeStatusJSON(status), [
    {
      externalPort: 3000,
      externalScheme: 'https',
      path: '/',
      target: 'http://127.0.0.1:4000',
      backendHost: '127.0.0.1',
      backendPort: 4000,
    },
    {
      externalPort: 9321,
      externalScheme: 'https',
      path: '/',
      target: 'http://127.0.0.1:9321',
      backendHost: '127.0.0.1',
      backendPort: 9321,
    },
  ]);
});

test('migrates legacy port state only when the exact standard route still exists', () => {
  const existingRoutes = parseTailscaleServeStatusJSON(status);
  const plan = planServeReconciliation({
    existingRoutes,
    desiredServices: [{ port: 3000, url: 'http://127.0.0.1:3000' }],
    state: parseAutoPublishState('3000\n'),
    now: 1000,
  });
  assert.equal(plan.conflicts.length, 1);
  assert.equal(plan.create.length, 0);
  assert.equal(plan.remove.length, 0);
  assert.deepEqual(plan.nextState.routes, []);
});

test('never overwrites an unowned route on the desired external port', () => {
  const existingRoutes = parseTailscaleServeStatusJSON(status);
  const plan = planServeReconciliation({
    existingRoutes,
    desiredServices: [{ port: 3000, url: 'http://127.0.0.1:3000' }],
    state: parseAutoPublishState(''),
  });
  assert.equal(plan.conflicts.length, 1);
  assert.equal(plan.create.length, 0);
});

test('retains missing owned routes during grace then removes the exact owned route', () => {
  const route = {
    externalPort: 3000,
    externalScheme: 'https',
    path: '/',
    target: 'http://127.0.0.1:3000',
    backendHost: '127.0.0.1',
    backendPort: 3000,
  };
  const first = planServeReconciliation({
    existingRoutes: [route],
    desiredServices: [],
    state: { version: 2, routes: [{ ...route, missingSince: null }] },
    now: 1000,
    graceMs: 5000,
  });
  assert.equal(first.remove.length, 0);
  assert.equal(first.nextState.routes[0].missingSince, 1000);

  const second = planServeReconciliation({
    existingRoutes: [route],
    desiredServices: [],
    state: first.nextState,
    now: 6000,
    graceMs: 5000,
  });
  assert.equal(second.remove.length, 1);
  assert.deepEqual(second.nextState.routes, []);
});

test('does not remove a route the user changed after WebFinder created it', () => {
  const owned = {
    externalPort: 3000,
    externalScheme: 'https',
    path: '/',
    target: 'http://127.0.0.1:3000',
  };
  const current = {
    ...owned,
    target: 'http://127.0.0.1:4000',
    backendHost: '127.0.0.1',
    backendPort: 4000,
  };
  const plan = planServeReconciliation({
    existingRoutes: [current],
    desiredServices: [],
    state: { version: 2, routes: [owned] },
    now: 999999,
    graceMs: 1,
  });
  assert.equal(plan.remove.length, 0);
  assert.deepEqual(plan.nextState.routes, []);
});

test('does not clear an entire listener when an owned route shares it with another path', () => {
  const owned = {
    externalPort: 3000,
    externalScheme: 'https',
    path: '/',
    target: 'http://127.0.0.1:3000',
  };
  const sibling = {
    externalPort: 3000,
    externalScheme: 'https',
    path: '/admin',
    target: 'http://127.0.0.1:4000',
  };
  const plan = planServeReconciliation({
    existingRoutes: [owned, sibling],
    desiredServices: [],
    state: { version: 2, routes: [owned] },
    now: 10000,
    graceMs: 0,
  });
  assert.equal(plan.remove.length, 0);
  assert.equal(plan.conflicts.length, 1);
  assert.deepEqual(plan.nextState.routes, [{ ...owned, missingSince: null }]);
});
