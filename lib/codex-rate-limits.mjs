#!/usr/bin/env node

import { spawn } from "node:child_process";
import readline from "node:readline";

const timeoutSeconds = Number.parseInt(process.argv[2] ?? "30", 10);
const child = spawn("codex", ["app-server", "--stdio"], {
  env: process.env,
  stdio: ["pipe", "pipe", "pipe"],
});

let stderr = "";
let completed = false;

const finish = (code, payload) => {
  if (completed) return;
  completed = true;
  clearTimeout(timer);
  if (payload) process.stdout.write(`${JSON.stringify(payload)}\n`);
  if (code !== 0 && stderr.trim()) process.stderr.write(`${stderr.trim()}\n`);
  child.kill("SIGTERM");
  process.exitCode = code;
};

child.stderr.on("data", (chunk) => {
  stderr += chunk.toString();
});

child.on("error", (error) => {
  stderr += error.message;
  finish(1);
});

child.on("exit", (code) => {
  if (!completed) finish(code || 1);
});

const lines = readline.createInterface({ input: child.stdout });
lines.on("line", (line) => {
  let message;
  try {
    message = JSON.parse(line);
  } catch {
    return;
  }

  if (message.id === 1 && message.result) {
    child.stdin.write(`${JSON.stringify({ method: "initialized" })}\n`);
    child.stdin.write(
      `${JSON.stringify({
        id: 2,
        method: "account/rateLimits/read",
        params: null,
      })}\n`,
    );
    return;
  }

  if (message.id === 2) {
    if (message.result) {
      finish(0, message.result);
    } else {
      finish(1, { error: message.error ?? { message: "Unknown app-server error" } });
    }
  }
});

const timer = setTimeout(() => {
  stderr += `Codex rate-limit request timed out after ${timeoutSeconds}s.`;
  finish(1);
}, timeoutSeconds * 1000);

child.stdin.write(
  `${JSON.stringify({
    id: 1,
    method: "initialize",
    params: {
      clientInfo: { name: "ai-account-center", version: "0.2.1" },
      capabilities: { experimentalApi: true },
    },
  })}\n`,
);
