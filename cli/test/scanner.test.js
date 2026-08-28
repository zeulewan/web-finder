'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { validateManifest } = require('../scanner');

test('manifest validation accepts bounded HTTP services', () => {
  assert.deepEqual(validateManifest({
    version: 1,
    hostname: 'server',
    services: [{ name: 'Dashboard', port: 3000, url: 'https://127.0.0.1:3000/' }],
  }), {
    version: 1,
    hostname: 'server',
    services: [{ name: 'Dashboard', port: 3000, url: 'https://127.0.0.1:3000/' }],
  });
});

test('manifest validation rejects unsupported URLs and invalid ports', () => {
  const manifest = validateManifest({
    version: 1,
    hostname: 'peer',
    services: [
      { name: 'Unsafe', port: 1234, url: 'file:///etc/passwd' },
      { name: 'Too high', port: 70000, url: 'http://127.0.0.1:70000' },
      { name: 'Good', port: 8080, url: 'http://127.0.0.1:8080' },
    ],
  });
  assert.deepEqual(manifest.services, [
    { name: 'Good', port: 8080, url: 'http://127.0.0.1:8080' },
  ]);
});

test('manifest validation rejects unknown versions and oversized lists', () => {
  assert.equal(validateManifest({ version: 2, services: [] }), null);
  assert.equal(validateManifest({ version: 1, services: Array(257).fill({}) }), null);
});
