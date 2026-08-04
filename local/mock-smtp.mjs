import { createServer } from "node:net";
import { createWriteStream, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";

const PORT = Number(process.env.MOCK_SMTP_PORT ?? 2525);
const LOG_PATH = join(dirname(new URL(import.meta.url).pathname), "mock-smtp.log");
mkdirSync(dirname(LOG_PATH), { recursive: true });
const logStream = createWriteStream(LOG_PATH, { flags: "a" });

const CRLF = "\r\n";
let connectionCount = 0;

function emit(line) {
  logStream.write(line + "\n");
  console.log(line);
}

createServer((socket) => {
  const id = ++connectionCount;
  let buffer = "";
  let inData = false;
  let message = "";
  let authState = 0;
  emit(`[conn ${id}] open`);

  const send = (line) => socket.write(line + CRLF);

  socket.on("data", (chunk) => {
    buffer += chunk.toString("utf8");
    let idx;
    while ((idx = buffer.indexOf(CRLF)) !== -1) {
      const line = buffer.slice(0, idx);
      buffer = buffer.slice(idx + CRLF.length);
      if (inData) {
        if (line === ".") {
          inData = false;
          emit(`[conn ${id}] delivered message (${message.length} chars)`);
          logStream.write(message + "\n---END MESSAGE---\n");
          message = "";
          send("250 2.0.0 message accepted for delivery");
        } else {
          message += (message ? "\n" : "") + (line.startsWith("..") ? line.slice(1) : line);
        }
        continue;
      }
      const upper = line.toUpperCase();
      if (upper.startsWith("EHLO") || upper.startsWith("HELO")) {
        send("250-localhost");
        send("250-AUTH PLAIN LOGIN");
        send("250-SIZE 10485760");
        send("250 OK");
      } else if (upper === "AUTH PLAIN" || upper.startsWith("AUTH PLAIN ")) {
        send("235 2.7.0 authentication successful");
      } else if (upper === "AUTH LOGIN") {
        authState = 1;
        send("334 VXNlcm5hbWU6");
      } else if (authState === 1) {
        authState = 2;
        send("334 UGFzc3dvcmQ6");
      } else if (authState === 2) {
        authState = 0;
        send("235 2.7.0 authentication successful");
      } else if (upper === "DATA") {
        inData = true;
        send("354 End data with <CR><LF>.<CR><LF>");
      } else if (upper === "QUIT") {
        send("221 2.0.0 bye");
        socket.end();
      } else if (upper === "RSET" || upper === "NOOP") {
        authState = 0;
        send("250 2.0.0 OK");
      } else if (upper.startsWith("MAIL FROM")) {
        send("250 2.1.0 OK");
      } else if (upper.startsWith("RCPT TO")) {
        send("250 2.1.5 OK");
      } else if (upper.startsWith("STARTTLS")) {
        send("454 4.7.0 TLS not available");
      } else {
        send("250 2.0.0 OK");
      }
    }
  });

  socket.on("error", (e) => emit(`[conn ${id}] error: ${e.message}`));
  socket.on("close", () => emit(`[conn ${id}] close`));

  send("220 qm-mock-smtp ESMTP ready");
}).listen(PORT, "127.0.0.1", () => {
  console.log(`mock SMTP on 127.0.0.1:${PORT}, logging to ${LOG_PATH}`);
});
