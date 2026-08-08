// Firstmate primary turn-end guard for prime-agent.
//
// This is the prime-agent sibling of `.pi/extensions/fm-primary-turnend-guard.ts`.
// It is a separate file rather than a shared one because the two harnesses
// differ on exactly the event this guard is built on: Pi fires `agent_settled`
// once per logical agent run, and prime-agent has no such event at all. Its
// extension API stops at `agent_start` / `agent_end` / `turn_end` (verified
// against its own `dist/core/extensions/types.d.ts`, prime-agent 0.7.1), and
// registering `agent_settled` is silently accepted and never fires. A shared
// arm that guessed wrong for one of them would be worse than two honest ones.
//
// The settle is therefore RECONSTRUCTED from `agent_end`, following the shape
// prime-agent's own built-in Herdr reporter uses
// (`dist/core/extensions/builtin/herdr-agent-state.js`) - which is the only
// description of that behaviour that exists, because prime-agent ships no
// documentation of its Herdr integration at all:
//   - an `agent_end` whose last assistant message has `stopReason === "error"`
//     may be followed by an auto-retry that starts AFTER this event, so the
//     settle is held for a grace window and cancelled if a retry begins;
//   - an `agent_end` with queued messages is not a settle at all, because a
//     follow-up or steer starts the next run immediately;
//   - anything else settles now.
// `ctx.isIdle()` is deliberately not used as the gate: it was measured false
// throughout a live prime-agent run, so gating on it would never settle.
//
// The operational-input encoder is imported from the Pi extension tree on
// purpose. It is one owner for the whole fleet, and a second copy under
// `.prime/` would drift the moment only one was edited.
import { spawn, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import {
  classifyFirstmateCurrentOperationalText,
  encodeFirstmateOperationalInput,
} from "../../../.pi/extensions/lib/fm-operational-input.ts";

let guardFollowupActive = false;

type LockOwnership = "owned" | "missing" | "other";

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../../..");
const fmHome = process.env.FM_HOME || process.env.FM_ROOT_OVERRIDE || root;
const state = process.env.FM_STATE_OVERRIDE || `${fmHome}/state`;
const marker = `${state}/.prime-turnend-extension-loaded`;
const extensionVersion = `sha256:${createHash("sha256").update(readFileSync(extensionFile)).digest("hex")}`;

function positiveInteger(name: string, fallback: number): number {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value <= 0) return fallback;
  return Math.floor(value);
}

// prime-agent's own reporter defaults, kept under the same env names it reads
// so an operator tuning one tunes both.
const retryGraceMs = positiveInteger("HERDR_PI_RETRY_GRACE_MS", 2500);

function parentPid(pid: string): string {
  const result = spawnSync("ps", ["-o", "ppid=", "-p", pid], { encoding: "utf8" });
  if (result.status !== 0) return "";
  return result.stdout.trim();
}

function pidAlive(pid: string): boolean {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function lockOwnership(): LockOwnership {
  let lockPid = "";
  try {
    lockPid = readFileSync(`${state}/.lock`, "utf8").trim();
  } catch {
    return "missing";
  }
  if (!/^[0-9]+$/.test(lockPid) || lockPid === "1") return "other";
  let pid = String(process.pid);
  for (let i = 0; i < 8; i += 1) {
    if (pid === lockPid) return "owned";
    pid = parentPid(pid);
    if (!pid || pid === "1") break;
  }
  return pidAlive(lockPid) ? "other" : "missing";
}

function markLoaded(): void {
  if (!existsSync(state) || lockOwnership() === "other") return;
  writeFileSync(marker, `${extensionVersion}\n${process.pid}\n`);
}

const sessionstartDeliveryBytes = 512 * 1024;
const sessionstartTruncatedMarker =
  "\n\nPRIME-AGENT SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. " +
  "Treat omitted context as unread and inspect the named files directly before acting on it.";

function runSessionstartHook(source: string): Promise<string> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-sessionstart-run.sh`, ["--source", source], {
      stdio: ["ignore", "pipe", "ignore"],
    });
    const chunks: Buffer[] = [];
    let retainedBytes = 0;
    let truncated = false;
    child.stdout.on("data", (chunk: Buffer) => {
      if (retainedBytes >= sessionstartDeliveryBytes) {
        truncated = true;
        return;
      }
      const remaining = sessionstartDeliveryBytes - retainedBytes;
      const retained = chunk.length <= remaining ? chunk : chunk.subarray(0, remaining);
      chunks.push(retained);
      retainedBytes += retained.length;
      if (retained.length !== chunk.length) truncated = true;
    });
    child.on("error", () => resolveResult(""));
    child.on("close", (code) => {
      if (code !== 0) {
        resolveResult("");
        return;
      }
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      resolveResult(truncated ? `${raw}${sessionstartTruncatedMarker}` : raw);
    });
  });
}

async function injectSessionstart(pi: ExtensionAPI, source: string): Promise<void> {
  const raw = await runSessionstartHook(source);
  if (!raw) return;
  try {
    // Same reason as the Pi adapter: this injects a MESSAGE rather than hook
    // stdout, so it must carry operational provenance or Ahoy would have to
    // guess whether it was captain-authored.
    const content = classifyFirstmateCurrentOperationalText(raw)
      ? raw
      : encodeFirstmateOperationalInput("session-start", raw);
    pi.sendMessage({
      customType: "firstmate-sessionstart-nudge",
      content,
      display: false,
      details: { kind: "session-start" },
    });
  } catch {
  }
}

function runGuard(): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/fm-turnend-guard.sh`, {
      stdio: ["pipe", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
    child.stdin.end('{"stop_hook_active":false}');
  });
}

// PreToolUse seatbelts, piggybacked on this same file exactly as the Pi
// adapter does, so no extra launch flag is needed. Each owner script owns its
// own decision and is inert outside the real primary checkout.
function runChecker(script: string, command: string): Promise<{ code: number; stderr: string }> {
  return new Promise((resolveResult) => {
    const child = spawn(`${root}/bin/${script}`, ["--command", command], {
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });
    child.on("error", () => resolveResult({ code: 0, stderr: "" }));
    child.on("close", (code) => resolveResult({ code: code ?? 0, stderr }));
  });
}

function lastAssistantStoppedOnError(event: unknown): boolean {
  const messages = (event as { messages?: unknown })?.messages;
  if (!Array.isArray(messages)) return false;
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const message = messages[i] as { role?: unknown; stopReason?: unknown } | undefined;
    if (message?.role === "assistant") return message.stopReason === "error";
  }
  return false;
}

export default function (pi: ExtensionAPI) {
  let agentActive = false;
  let boundSessionManager: unknown;
  let settleTimer: ReturnType<typeof setTimeout> | undefined;

  const isBoundSession = (ctx: unknown): boolean => {
    if (boundSessionManager === undefined) return true;
    return (ctx as { sessionManager?: unknown } | undefined)?.sessionManager === boundSessionManager;
  };

  const bindSession = (ctx: unknown): boolean => {
    const sessionManager = (ctx as { sessionManager?: unknown } | undefined)?.sessionManager;
    if (boundSessionManager === undefined && sessionManager !== undefined) boundSessionManager = sessionManager;
    return isBoundSession(ctx);
  };

  const clearSettleTimer = (): void => {
    if (settleTimer) clearTimeout(settleTimer);
    settleTimer = undefined;
  };

  async function runSettleGuard(): Promise<void> {
    if (guardFollowupActive) {
      guardFollowupActive = false;
      return;
    }
    const result = await runGuard();
    if (result.code !== 2) return;
    guardFollowupActive = true;
    try {
      const content = encodeFirstmateOperationalInput(
        "turn-end-guard",
        "TURN WOULD END BLIND - supervision is off. " +
          "The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n" +
          result.stderr,
      );
      await pi.sendUserMessage(content, { deliverAs: "followUp" });
    } catch {
      guardFollowupActive = false;
    }
  }

  pi.on?.("session_start", async (event, ctx) => {
    if (!bindSession(ctx)) return;
    const reason = String((event as { reason?: unknown }).reason ?? "");
    const source = { startup: "startup", new: "clear", resume: "resume", fork: "fork" }[reason];
    markLoaded();
    if (!source) return;
    await injectSessionstart(pi, source);
  });

  pi.on?.("session_compact", async (_event, ctx) => {
    if (!isBoundSession(ctx)) return;
    await injectSessionstart(pi, "compact");
  });

  pi.on("tool_call", async (event, ctx) => {
    if (!isBoundSession(ctx)) return {};
    if (event.type !== "tool_call" || event.toolName !== "bash") return {};
    const command = String((event.input as { command?: unknown })?.command ?? "");
    if (!command) return {};
    const cdResult = await runChecker("fm-cd-pretool-check.sh", command);
    if (cdResult.code === 2) {
      return { block: true, reason: cdResult.stderr.trim() || "denied by the cd-guard PreToolUse seatbelt" };
    }
    const result = await runChecker("fm-arm-pretool-check.sh", command);
    if (result.code !== 2) return {};
    return { block: true, reason: result.stderr.trim() || "denied by the watcher-arm PreToolUse seatbelt" };
  });

  pi.on("agent_start", (_event, ctx) => {
    if (!isBoundSession(ctx)) return;
    // A retry that starts inside the grace window cancels the held settle, which
    // is the whole reason the hold exists.
    clearSettleTimer();
    agentActive = true;
  });

  pi.on("agent_end", (event, ctx) => {
    if (!isBoundSession(ctx)) return;
    // A duplicate or late end must not settle a run this instance never saw
    // start, or it would fire the guard against an agent that is still working.
    if (!agentActive) return;
    agentActive = false;
    if (lastAssistantStoppedOnError(event)) {
      clearSettleTimer();
      settleTimer = setTimeout(() => {
        settleTimer = undefined;
        void runSettleGuard();
      }, retryGraceMs);
      settleTimer.unref?.();
      return;
    }
    // Queued messages mean the next run starts immediately; that run's own end
    // is the settle, so this one is not.
    const pending = ctx as { hasPendingMessages?: () => boolean } | undefined;
    if (typeof pending?.hasPendingMessages === "function" && pending.hasPendingMessages()) return;
    clearSettleTimer();
    return runSettleGuard();
  });

  markLoaded();
}
