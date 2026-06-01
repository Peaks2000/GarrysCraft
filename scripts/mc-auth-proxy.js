#!/usr/bin/env node
"use strict";

const crypto = require("crypto");
const fs = require("fs");
const net = require("net");
const path = require("path");

const ROOT = path.resolve(__dirname, "..");
const CONFIG_PATH = path.join(ROOT, "lua", "mcgm", "config.lua");

function readLuaConfig() {
  const text = fs.readFileSync(CONFIG_PATH, "utf8");
  const out = {};

  for (const key of [
    "bind_host",
    "port",
    "auth_proxy_host",
    "auth_proxy_port",
    "motd",
    "max_players",
    "protocol_version",
    "minecraft_version",
    "minecraft_auth_session_server",
  ]) {
    const stringMatch = text.match(new RegExp(`${key}\\s*=\\s*"([^"]*)"`));
    if (stringMatch) {
      out[key] = stringMatch[1];
      continue;
    }

    const numberMatch = text.match(new RegExp(`${key}\\s*=\\s*([0-9]+)`));
    if (numberMatch) {
      out[key] = Number(numberMatch[1]);
    }
  }

  return out;
}

const cfg = readLuaConfig();
const FRONT_HOST = process.env.MCGM_AUTH_HOST || cfg.auth_proxy_host || "0.0.0.0";
const FRONT_PORT = Number(process.env.MCGM_AUTH_PORT || cfg.auth_proxy_port || 25565);
const BACKEND_HOST = process.env.MCGM_BACKEND_HOST || cfg.bind_host || "127.0.0.1";
const BACKEND_PORT = Number(process.env.MCGM_BACKEND_PORT || cfg.port || 25566);
const PROTOCOL = Number(cfg.protocol_version || 340);
const MC_VERSION = cfg.minecraft_version || "1.12.2";
const MOTD = cfg.motd || "GMod cross-play bridge";
const MAX_PLAYERS = Number(cfg.max_players || 32);
const SESSION_URL = cfg.minecraft_auth_session_server || "https://sessionserver.mojang.com/session/minecraft/hasJoined";

const { publicKey, privateKey } = crypto.generateKeyPairSync("rsa", {
  modulusLength: 1024,
  publicExponent: 0x10001,
});
const publicKeyDer = publicKey.export({ type: "spki", format: "der" });

function readVarInt(buffer, offset = 0) {
  let value = 0;
  let shift = 0;

  for (let i = 0; i < 5; i += 1) {
    if (offset + i >= buffer.length) return null;
    const byte = buffer[offset + i];
    value |= (byte & 0x7f) << shift;
    if ((byte & 0x80) === 0) {
      return { value, size: i + 1 };
    }
    shift += 7;
  }

  throw new Error("VarInt too large");
}

function writeVarInt(value) {
  const out = [];
  let next = Number(value) >>> 0;

  do {
    let temp = next & 0x7f;
    next >>>= 7;
    if (next !== 0) temp |= 0x80;
    out.push(temp);
  } while (next !== 0);

  return Buffer.from(out);
}

function readString(buffer, offset) {
  const len = readVarInt(buffer, offset);
  if (!len) return null;
  const start = offset + len.size;
  const end = start + len.value;
  if (end > buffer.length) return null;
  return { value: buffer.subarray(start, end).toString("utf8"), offset: end };
}

function writeString(value) {
  const body = Buffer.from(String(value || ""), "utf8");
  return Buffer.concat([writeVarInt(body.length), body]);
}

function readByteArray(buffer, offset) {
  const len = readVarInt(buffer, offset);
  if (!len) return null;
  const start = offset + len.size;
  const end = start + len.value;
  if (end > buffer.length) return null;
  return { value: buffer.subarray(start, end), offset: end };
}

function writeByteArray(value) {
  return Buffer.concat([writeVarInt(value.length), value]);
}

function packet(id, payload = Buffer.alloc(0)) {
  const body = Buffer.concat([writeVarInt(id), payload]);
  return Buffer.concat([writeVarInt(body.length), body]);
}

function nextPacket(buffer) {
  const len = readVarInt(buffer, 0);
  if (!len) return null;
  const start = len.size;
  const end = start + len.value;
  if (end > buffer.length) return null;

  const body = buffer.subarray(start, end);
  const id = readVarInt(body, 0);
  if (!id) return null;

  return {
    id: id.value,
    payload: body.subarray(id.size),
    raw: buffer.subarray(0, end),
    rest: buffer.subarray(end),
  };
}

function minecraftSha1Hex(buffers) {
  const digest = crypto.createHash("sha1").update(Buffer.concat(buffers)).digest();
  let value = BigInt(`0x${digest.toString("hex")}`);

  if ((digest[0] & 0x80) !== 0) {
    value -= 1n << 160n;
  }

  return value.toString(16);
}

function dashedUuid(id) {
  const hex = String(id || "").replace(/[^0-9a-f]/gi, "").toLowerCase();
  if (hex.length !== 32) return "00000000-0000-0000-0000-000000000000";
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function loginDisconnect(socket, message, cipher) {
  const payload = writeString(JSON.stringify({ text: message }));
  const bytes = packet(0x00, payload);
  socket.write(cipher ? cipher.update(bytes) : bytes);
  socket.end();
}

async function verifyWithMojang(username, serverHash) {
  const url = new URL(SESSION_URL);
  url.searchParams.set("username", username);
  url.searchParams.set("serverId", serverHash);

  const response = await fetch(url, {
    headers: { "User-Agent": "mcgm-auth-proxy/1.0" },
  });

  if (response.status === 204 || response.status === 404) return null;
  if (!response.ok) {
    throw new Error(`Mojang session server returned HTTP ${response.status}`);
  }

  const profile = await response.json();
  return profile && profile.id && profile.name ? profile : null;
}

function offlineHandshake(host, port, username) {
  const hostBuf = writeString(host);
  const portBuf = Buffer.alloc(2);
  portBuf.writeUInt16BE(port & 0xffff, 0);
  const handshake = packet(0x00, Buffer.concat([
    writeVarInt(PROTOCOL),
    hostBuf,
    portBuf,
    writeVarInt(2),
  ]));
  const login = packet(0x00, writeString(username));
  return Buffer.concat([handshake, login]);
}

function parseHandshake(payload) {
  let offset = 0;
  const protocol = readVarInt(payload, offset);
  if (!protocol) return null;
  offset += protocol.size;

  const host = readString(payload, offset);
  if (!host) return null;
  offset = host.offset;

  if (offset + 2 > payload.length) return null;
  const port = payload.readUInt16BE(offset);
  offset += 2;

  const nextState = readVarInt(payload, offset);
  if (!nextState) return null;

  return {
    protocol: protocol.value,
    host: host.value,
    port,
    nextState: nextState.value,
  };
}

function statusResponsePayload() {
  return writeString(JSON.stringify({
    version: { name: MC_VERSION, protocol: PROTOCOL },
    players: { max: MAX_PLAYERS, online: 0 },
    description: { text: `${MOTD} (online-mode proxy)` },
  }));
}

function connectBackend(clientSocket, clientCipher, clientDecipher, username, pendingClientEncrypted) {
  const backend = net.connect(BACKEND_PORT, BACKEND_HOST);

  backend.on("connect", () => {
    backend.write(offlineHandshake(BACKEND_HOST, BACKEND_PORT, username));
    if (pendingClientEncrypted.length > 0) {
      backend.write(clientDecipher.update(pendingClientEncrypted));
    }
  });

  backend.on("data", (chunk) => {
    clientSocket.write(clientCipher.update(chunk));
  });

  backend.on("error", (err) => {
    console.error(`[MCGM auth] backend error for ${username}: ${err.message}`);
    loginDisconnect(clientSocket, "The authenticated bridge backend is not running.", clientCipher);
  });

  backend.on("close", () => {
    clientSocket.end();
  });

  clientSocket.on("data", (chunk) => {
    backend.write(clientDecipher.update(chunk));
  });

  clientSocket.on("close", () => {
    backend.end();
  });

  clientSocket.on("error", () => {
    backend.destroy();
  });
}

function handleClient(socket) {
  let state = "handshake";
  let buffer = Buffer.alloc(0);
  let username = null;
  let verifyToken = null;
  let clientCipher = null;
  let clientDecipher = null;
  let handedToBackend = false;

  socket.on("data", async (chunk) => {
    if (handedToBackend) return;

    buffer = Buffer.concat([buffer, chunk]);

    try {
      while (!handedToBackend) {
        const parsed = nextPacket(buffer);
        if (!parsed) return;
        buffer = parsed.rest;

        if (state === "handshake") {
          if (parsed.id !== 0x00) {
            socket.end();
            return;
          }

          const handshake = parseHandshake(parsed.payload);
          if (!handshake) {
            socket.end();
            return;
          }

          state = handshake.nextState === 1 ? "status" : "login";
          continue;
        }

        if (state === "status") {
          if (parsed.id === 0x00) {
            socket.write(packet(0x00, statusResponsePayload()));
          } else if (parsed.id === 0x01) {
            socket.write(packet(0x01, parsed.payload));
            socket.end();
          }
          continue;
        }

        if (state === "login_start") {
          // unused marker; kept for readability below
        }

        if (state === "login") {
          if (parsed.id !== 0x00) {
            loginDisconnect(socket, "Expected Login Start.");
            return;
          }

          const name = readString(parsed.payload, 0);
          username = name && name.value ? name.value.replace(/[^\w]/g, "").slice(0, 16) : "";
          if (!username) {
            loginDisconnect(socket, "Invalid Minecraft username.");
            return;
          }

          verifyToken = crypto.randomBytes(4);
          socket.write(packet(0x01, Buffer.concat([
            writeString(""),
            writeByteArray(publicKeyDer),
            writeByteArray(verifyToken),
          ])));
          state = "encryption_response";
          continue;
        }

        if (state === "encryption_response") {
          if (parsed.id !== 0x01) {
            loginDisconnect(socket, "Expected Encryption Response.");
            return;
          }

          const secretPacket = readByteArray(parsed.payload, 0);
          const tokenPacket = secretPacket && readByteArray(parsed.payload, secretPacket.offset);
          if (!secretPacket || !tokenPacket) {
            loginDisconnect(socket, "Invalid encryption response.");
            return;
          }

          let sharedSecret;
          let token;
          try {
            sharedSecret = crypto.privateDecrypt({
              key: privateKey,
              padding: crypto.constants.RSA_PKCS1_PADDING,
            }, secretPacket.value);
            token = crypto.privateDecrypt({
              key: privateKey,
              padding: crypto.constants.RSA_PKCS1_PADDING,
            }, tokenPacket.value);
          } catch (err) {
            loginDisconnect(socket, "Could not decrypt encryption response.");
            return;
          }

          if (!crypto.timingSafeEqual(token, verifyToken)) {
            loginDisconnect(socket, "Invalid encryption verify token.");
            return;
          }

          const serverHash = minecraftSha1Hex([
            Buffer.from("", "ascii"),
            sharedSecret,
            publicKeyDer,
          ]);
          clientCipher = crypto.createCipheriv("aes-128-cfb8", sharedSecret, sharedSecret);
          clientDecipher = crypto.createDecipheriv("aes-128-cfb8", sharedSecret, sharedSecret);

          let profile;
          try {
            profile = await verifyWithMojang(username, serverHash);
          } catch (err) {
            console.error(`[MCGM auth] Mojang auth error for ${username}: ${err.message}`);
            loginDisconnect(socket, "Minecraft authentication servers are unavailable.", clientCipher);
            return;
          }

          if (!profile) {
            console.log(`[MCGM auth] rejected ${username}: Mojang hasJoined failed`);
            loginDisconnect(socket, "Failed to verify username with Mojang.", clientCipher);
            return;
          }

          console.log(`[MCGM auth] verified ${profile.name} (${dashedUuid(profile.id)})`);
          handedToBackend = true;
          const pending = buffer;
          buffer = Buffer.alloc(0);
          socket.removeAllListeners("data");
          connectBackend(socket, clientCipher, clientDecipher, profile.name, pending);
          return;
        }
      }
    } catch (err) {
      console.error(`[MCGM auth] client error: ${err.stack || err.message}`);
      socket.destroy();
    }
  });

  socket.on("error", (err) => {
    console.error(`[MCGM auth] socket error: ${err.message}`);
  });
}

const server = net.createServer(handleClient);
server.on("error", (err) => {
  console.error(`[MCGM auth] failed to listen: ${err.message}`);
  process.exit(1);
});

server.listen(FRONT_PORT, FRONT_HOST, () => {
  console.log(`[MCGM auth] online-mode proxy listening on ${FRONT_HOST}:${FRONT_PORT}`);
  console.log(`[MCGM auth] forwarding verified clients to ${BACKEND_HOST}:${BACKEND_PORT}`);
});
