// TLS-terminating TCP proxy for the wss:// Godot test.
//
// Terminates TLS with the self-signed test cert on `port` and forwards the
// decrypted byte stream to the plain example-server on `target`. Because it's a
// transparent TCP pipe, it carries both the HTTPS matchmaking requests and the
// WSS upgrade over the same port — letting the Godot client reach a normal
// Colyseus server over wss:// without the server itself doing TLS.
//
// Usage: node tls-proxy.mjs [--port 2568] [--target 2567] [--cert p] [--key p]
import tls from "node:tls";
import net from "node:net";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}

const port = parseInt(arg("port", "2568"), 10);
const target = parseInt(arg("target", "2567"), 10);
const certPath = arg("cert", path.join(here, "tls", "server.pem"));
const keyPath = arg("key", path.join(here, "tls", "server.key"));

const server = tls.createServer(
  { cert: fs.readFileSync(certPath), key: fs.readFileSync(keyPath) },
  (client) => {
    const upstream = net.connect(target, "127.0.0.1");
    client.pipe(upstream);
    upstream.pipe(client);
    const close = () => {
      client.destroy();
      upstream.destroy();
    };
    client.on("error", close);
    upstream.on("error", close);
    client.on("close", () => upstream.destroy());
    upstream.on("close", () => client.destroy());
  },
);

// Listen dual-stack (no host) so `localhost` works whether it resolves to
// 127.0.0.1 or ::1 — the client must use the hostname (not the IP) because
// std.http only verifies DNS-name SANs, not IP-address SANs.
server.listen(port, () => {
  console.log(`[tls-proxy] listening on wss://localhost:${port} -> 127.0.0.1:${target}`);
});
