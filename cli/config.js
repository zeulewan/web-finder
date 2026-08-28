'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

function configPath() {
  return process.env.WEB_FINDER_CONFIG || path.join(os.homedir(), '.config', 'web-finder', 'config.json');
}

function normalizeConfig(value) {
  const services = {};
  for (const [key, entry] of Object.entries(value?.services || {})) {
    const port = parseInt(key);
    if (!Number.isInteger(port) || port <= 0 || port > 65535 || typeof entry !== 'object') continue;
    services[port] = {
      ...(typeof entry.name === 'string' && entry.name.trim() ? { name: entry.name.trim().slice(0, 200) } : {}),
      ...(typeof entry.publish === 'boolean' ? { publish: entry.publish } : {}),
    };
  }
  return { version: 1, services };
}

function loadConfig() {
  const file = configPath();
  try {
    return { file, config: normalizeConfig(JSON.parse(fs.readFileSync(file, 'utf8'))), error: null };
  } catch (error) {
    if (error.code === 'ENOENT') return { file, config: normalizeConfig({}), error: null };
    return { file, config: normalizeConfig({}), error: error.message };
  }
}

function applyServiceConfig(services, config, { forPublish = false } = {}) {
  return services.flatMap(service => {
    const entry = config?.services?.[service.port];
    if (forPublish && entry?.publish === false) return [];
    return [{ ...service, ...(entry?.name ? { title: entry.name, name: entry.name } : {}) }];
  });
}

module.exports = { applyServiceConfig, configPath, loadConfig, normalizeConfig };
