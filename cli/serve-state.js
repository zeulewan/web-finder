'use strict';

const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '::1']);

function normalizePath(value) {
  const path = String(value || '/');
  return path.startsWith('/') ? path : `/${path}`;
}

function parseProxyTarget(target) {
  const raw = String(target || '');
  const match = raw.match(/^https?(?:\+insecure)?:\/\/(\[[^\]]+\]|[^/:]+)(?::(\d+))?/);
  if (!match) return { backendHost: null, backendPort: null };
  const backendHost = match[1].replace(/^\[|\]$/g, '');
  const backendPort = parseInt(match[2]) || (raw.startsWith('https') ? 443 : 80);
  return { backendHost, backendPort };
}

function parseTailscaleServeStatusJSON(raw) {
  let config;
  try {
    config = typeof raw === 'string' ? JSON.parse(raw) : raw;
  } catch {
    return [];
  }
  if (!config || typeof config !== 'object' || !config.Web) return [];

  const entries = [];
  for (const [hostPort, web] of Object.entries(config.Web)) {
    let externalPort;
    try {
      externalPort = parseInt(new URL(`https://${hostPort}`).port) || 443;
    } catch {
      continue;
    }
    const tcp = config.TCP?.[String(externalPort)] || {};
    const externalScheme = tcp.HTTPS ? 'https' : 'http';
    for (const [path, handler] of Object.entries(web?.Handlers || {})) {
      if (!handler?.Proxy) continue;
      const target = String(handler.Proxy);
      entries.push({
        externalPort,
        externalScheme,
        path: normalizePath(path),
        target,
        ...parseProxyTarget(target),
      });
    }
  }
  return entries.sort((a, b) => a.externalPort - b.externalPort || a.path.localeCompare(b.path));
}

function parseLegacyPortState(raw) {
  return String(raw || '')
    .split('\n')
    .map(line => parseInt(line.trim()))
    .filter(port => Number.isInteger(port) && port > 0 && port <= 65535);
}

function parseAutoPublishState(raw) {
  const text = String(raw || '').trim();
  if (!text) return { version: 2, routes: [], legacyPorts: [] };
  try {
    const parsed = JSON.parse(text);
    if (parsed?.version === 2 && Array.isArray(parsed.routes)) {
      return {
        version: 2,
        routes: parsed.routes.filter(validOwnedRoute).map(normalizeOwnedRoute),
        legacyPorts: [],
      };
    }
  } catch {}
  return { version: 2, routes: [], legacyPorts: parseLegacyPortState(text) };
}

function validOwnedRoute(route) {
  return Number.isInteger(route?.externalPort) && route.externalPort > 0 && route.externalPort <= 65535 &&
    typeof route?.target === 'string' && route.target.length > 0;
}

function normalizeOwnedRoute(route) {
  return {
    externalPort: route.externalPort,
    externalScheme: route.externalScheme === 'http' ? 'http' : 'https',
    path: normalizePath(route.path),
    target: route.target,
    missingSince: Number.isFinite(route.missingSince) ? route.missingSince : null,
  };
}

function routeKey(route) {
  return `${route.externalPort}|${normalizePath(route.path)}`;
}

function sameRoute(left, right) {
  return Boolean(left && right) &&
    left.externalPort === right.externalPort &&
    normalizePath(left.path) === normalizePath(right.path) &&
    left.target === right.target;
}

function desiredRouteForService(service) {
  const port = Number(service?.port);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) return null;
  let backendScheme = 'http';
  try {
    if (new URL(service.url).protocol === 'https:') backendScheme = 'https+insecure';
  } catch {}
  return {
    externalPort: port,
    externalScheme: 'https',
    path: '/',
    target: `${backendScheme}://127.0.0.1:${port}`,
    missingSince: null,
  };
}

function planServeReconciliation({ existingRoutes = [], desiredServices = [], state, now = Date.now(), graceMs = 300000 }) {
  const currentByKey = new Map(existingRoutes.map(route => [routeKey(route), route]));
  const currentByPort = new Map();
  for (const route of existingRoutes) {
    const routes = currentByPort.get(route.externalPort) || [];
    routes.push(route);
    currentByPort.set(route.externalPort, routes);
  }
  const desiredRoutes = desiredServices.map(desiredRouteForService).filter(Boolean);
  const desiredByKey = new Map(desiredRoutes.map(route => [routeKey(route), route]));
  const ownedByKey = new Map();

  for (const route of state?.routes || []) {
    if (!validOwnedRoute(route)) continue;
    ownedByKey.set(routeKey(route), normalizeOwnedRoute(route));
  }
  for (const port of state?.legacyPorts || []) {
    const key = `${port}|/`;
    const current = currentByKey.get(key);
    if (current && current.backendPort === port && LOOPBACK_HOSTS.has(current.backendHost)) {
      ownedByKey.set(key, normalizeOwnedRoute(current));
    }
  }

  const create = [];
  const remove = [];
  const conflicts = [];
  const preserved = [];
  const nextRoutes = [];

  for (const [key, desired] of desiredByKey) {
    const current = currentByKey.get(key);
    const owned = ownedByKey.get(key);
    if (!current) {
      const siblings = currentByPort.get(desired.externalPort) || [];
      if (siblings.length > 0) {
        conflicts.push({ desired, current: siblings[0], reason: 'port has other paths' });
        continue;
      }
      create.push(desired);
      nextRoutes.push(desired);
      continue;
    }
    if (sameRoute(current, desired)) {
      if (owned && sameRoute(current, owned)) nextRoutes.push(desired);
      else preserved.push(current);
      continue;
    }
    if (owned && sameRoute(current, owned)) {
      if ((currentByPort.get(current.externalPort) || []).length > 1) {
        conflicts.push({ desired, current, reason: 'owned path shares a port with other routes' });
        nextRoutes.push(owned);
        continue;
      }
      create.push(desired);
      nextRoutes.push(desired);
      continue;
    }
    conflicts.push({ desired, current });
  }

  for (const [key, owned] of ownedByKey) {
    if (desiredByKey.has(key)) continue;
    const current = currentByKey.get(key);
    if (!sameRoute(current, owned)) continue;
    if ((currentByPort.get(current.externalPort) || []).length > 1) {
      conflicts.push({ desired: null, current, reason: 'owned path shares a port with other routes' });
      nextRoutes.push(owned);
      continue;
    }
    const missingSince = owned.missingSince || now;
    if (now - missingSince >= graceMs) {
      remove.push(owned);
    } else {
      nextRoutes.push({ ...owned, missingSince });
    }
  }

  nextRoutes.sort((a, b) => a.externalPort - b.externalPort || a.path.localeCompare(b.path));
  return {
    create,
    remove,
    conflicts,
    preserved,
    nextState: { version: 2, routes: nextRoutes },
  };
}

module.exports = {
  desiredRouteForService,
  parseAutoPublishState,
  parseProxyTarget,
  parseTailscaleServeStatusJSON,
  planServeReconciliation,
  routeKey,
  sameRoute,
};
