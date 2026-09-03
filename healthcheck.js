// Readiness probe for the image's HEALTHCHECK. /api/v3/ping answers 200 with no
// auth and no database access; the probe only tests the status code.
//
// NodeBB mounts every route under the path of `url` (src/routes/index.js,
// `app.use(relativePath || '/', router)`), so a forum at
// https://example.com/forum answers /forum/api/v3/ping and 404s at /api/v3/ping.
// The path is read the same way the forum reads it: the `url` environment
// variable first, then config.json. The port is not read; the container always
// listens on 4567, and only the host side of a port mapping ever moves.
'use strict';

const fs = require('fs');
const http = require('http');
const path = require('path');

const configFile = process.env.CONFIG ||
	path.join(process.env.CONFIG_DIR || '/opt/config', 'config.json');

let url = process.env.url;
if (!url) {
	try {
		url = JSON.parse(fs.readFileSync(configFile, 'utf8')).url;
	} catch (e) {
		// No config yet (web installer) or unreadable: probe the root.
	}
}

let prefix = '';
if (url) {
	try {
		prefix = new URL(url).pathname.replace(/\/+$/, '');
	} catch (e) {
		// Malformed url: NodeBB itself would refuse to start on it.
	}
}

http.get(`http://127.0.0.1:4567${prefix}/api/v3/ping`, (res) => {
	process.exit(res.statusCode === 200 ? 0 : 1);
}).on('error', () => process.exit(1));
