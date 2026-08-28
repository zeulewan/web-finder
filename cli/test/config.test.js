'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { applyServiceConfig, normalizeConfig } = require('../config');

test('service config aliases and excludes only from publishing', () => {
  const config = normalizeConfig({
    services: {
      3000: { name: 'Grafana' },
      5000: { name: 'Private admin', publish: false },
      nope: { name: 'ignored' },
    },
  });
  const services = [
    { title: 'Port 3000', port: 3000 },
    { title: 'Admin', port: 5000 },
  ];
  assert.deepEqual(applyServiceConfig(services, config), [
    { title: 'Grafana', name: 'Grafana', port: 3000 },
    { title: 'Private admin', name: 'Private admin', port: 5000 },
  ]);
  assert.deepEqual(applyServiceConfig(services, config, { forPublish: true }), [
    { title: 'Grafana', name: 'Grafana', port: 3000 },
  ]);
});
