// Minimal self-signed wss:// echo server for the TLS transport tests.
//
// Zero dependencies (Node built-ins only): terminates TLS with the test server
// cert, completes the WebSocket upgrade, and echoes data frames back. Its only
// job is to let the client complete a *verified* TLS handshake — so the tests
// can assert that cert verification passes with a trusted CA and fails without.
//
// Usage: node wss-echo-server.mjs [--port N] [--cert path] [--key path]
import https from "node:https";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback;
}

const port = parseInt(arg("port", process.env.WSS_PORT || "2569"), 10);
const certPath = arg("cert", path.join(here, "server.pem"));
const keyPath = arg("key", path.join(here, "server.key"));

const WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

const server = https.createServer({
  cert: fs.readFileSync(certPath),
  key: fs.readFileSync(keyPath),
});

// Complete the RFC 6455 opening handshake.
server.on("upgrade", (req, socket) => {
  const key = req.headers["sec-websocket-key"];
  if (!key) {
    socket.destroy();
    return;
  }
  const accept = crypto.createHash("sha1").update(key + WS_GUID).digest("base64");
  socket.write(
    "HTTP/1.1 101 Switching Protocols\r\n" +
      "Upgrade: websocket\r\n" +
      "Connection: Upgrade\r\n" +
      `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
  );
  pump(socket);
});

// Minimal frame loop: unmask client frames, echo data frames, answer ping/close.
function pump(socket) {
  let buf = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    for (;;) {
      const frame = readFrame(buf);
      if (!frame) break;
      buf = buf.subarray(frame.size);
      const op = frame.opcode;
      if (op === 0x8) {
        socket.end(encodeFrame(0x8, frame.payload));
        return;
      } else if (op === 0x9) {
        socket.write(encodeFrame(0xa, frame.payload)); // pong
      } else if (op === 0x1 || op === 0x2) {
        socket.write(encodeFrame(op, frame.payload)); // echo
      }
    }
  });
  socket.on("error", () => socket.destroy());
}

function readFrame(buf) {
  if (buf.length < 2) return null;
  const opcode = buf[0] & 0x0f;
  const masked = (buf[1] & 0x80) !== 0;
  let len = buf[1] & 0x7f;
  let offset = 2;
  if (len === 126) {
    if (buf.length < 4) return null;
    len = buf.readUInt16BE(2);
    offset = 4;
  } else if (len === 127) {
    if (buf.length < 10) return null;
    len = Number(buf.readBigUInt64BE(2));
    offset = 10;
  }
  const maskLen = masked ? 4 : 0;
  if (buf.length < offset + maskLen + len) return null;
  let payload = buf.subarray(offset + maskLen, offset + maskLen + len);
  if (masked) {
    const mask = buf.subarray(offset, offset + 4);
    payload = Buffer.from(payload);
    for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
  }
  return { opcode, payload, size: offset + maskLen + len };
}

function encodeFrame(opcode, payload) {
  const len = payload.length;
  let header;
  if (len < 126) {
    header = Buffer.from([0x80 | opcode, len]);
  } else if (len < 65536) {
    header = Buffer.alloc(4);
    header[0] = 0x80 | opcode;
    header[1] = 126;
    header.writeUInt16BE(len, 2);
  } else {
    header = Buffer.alloc(10);
    header[0] = 0x80 | opcode;
    header[1] = 127;
    header.writeBigUInt64BE(BigInt(len), 2);
  }
  return Buffer.concat([header, payload]);
}

server.listen(port, "127.0.0.1", () => {
  console.log(`[wss-echo] listening on wss://127.0.0.1:${port}`);
});
