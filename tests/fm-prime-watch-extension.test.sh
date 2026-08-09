#!/usr/bin/env bash
# Behavior tests for the tracked prime-agent primary watcher extension.
#
# The prime-agent sibling of tests/fm-pi-watch-extension.test.sh, covering the
# three properties that decide whether watcher supervision survives a real
# session rather than only compiling: the extension owns re-arming (a manual
# call while it already owns a cycle changes nothing), a clean close that ends
# without an actionable reason is retried a bounded number of times and then
# surfaced, and one generation per session activation owns the arm child so a
# shut-down session can never rearm behind a live one.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-prime-watch-extension)
EXT="$ROOT/.prime/agent/extensions/fm-primary-prime-watch.ts"
export NODE_NO_WARNINGS=1

install_prime_watch_extension_fixture() {  # <repo>
  local repo=$1
  # The tracked layout is load-bearing: the extension imports the shared
  # operational-input encoder from the .pi tree three levels up, so the fixture
  # reproduces both trees rather than flattening them.
  mkdir -p \
    "$repo/.prime/agent/extensions" \
    "$repo/.pi/extensions/lib" \
    "$repo/bin" \
    "$repo/node_modules/typebox"
  cp "$EXT" "$repo/.prime/agent/extensions/fm-primary-prime-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

test_prime_redundant_tool_call_is_owned_noop() {
  local repo home plugin log stop out status
  repo="$TMP_ROOT/prime-redundant-root"
  home="$TMP_ROOT/prime-redundant-home"
  log="$TMP_ROOT/prime-redundant.log"
  stop="$TMP_ROOT/prime-redundant.stop"
  mkdir -p "$home/state" "$home/config"
  install_prime_watch_extension_fixture "$repo"
  plugin="$repo/.prime/agent/extensions/fm-primary-prime-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm\n' >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while [ ! -e "$FM_STOP_FILE" ]; do sleep 0.02; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_STOP_FILE="$stop" node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_prime") tool = candidate;
  },
  sendUserMessage: async () => {},
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("prime-agent watch tool was not registered");
const initial = await tool.execute("tool-call-first", {}, undefined, undefined, {});
if (!initial.content[0]?.text.includes("started prime-agent extension arm child")) {
  throw new Error(`initial call did not start the arm child: ${initial.content[0]?.text}`);
}
const redundant = await tool.execute("tool-call-redundant", {}, undefined, undefined, {});
if (!redundant.content[0]?.text.includes("already owns an arm child; no manual re-arm needed")) {
  throw new Error(`redundant call omitted ownership-based no-op guidance: ${redundant.content[0]?.text}`);
}
if (!redundant.content[0]?.text.includes("only after a later notification says the cycle is missing, failed, or unhealthy")) {
  throw new Error(`redundant call omitted the repair-only condition: ${redundant.content[0]?.text}`);
}
for (let i = 0; i < 100 && !existsSync(process.env.FM_ARM_LOG); i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
if (!existsSync(process.env.FM_ARM_LOG)) throw new Error("initial arm child did not start");
await new Promise((resolve) => setTimeout(resolve, 100));
const rows = readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n");
if (rows.length !== 1) throw new Error(`redundant call spawned ${rows.length} arm children`);
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
EOF
)
  status=$?
  expect_code 0 "$status" "prime-agent redundant tool call must remain an ownership-based no-op"
  [ -z "$out" ] || fail "prime-agent redundant-call test printed output: $out"
  pass "prime-agent redundant tool call returns ownership guidance and spawns no second child"
}

test_prime_established_empty_close_honors_retry_limit() {
  local repo home plugin log out status
  repo="$TMP_ROOT/prime-empty-close-root"
  home="$TMP_ROOT/prime-empty-close-home"
  log="$TMP_ROOT/prime-empty-close.log"
  mkdir -p "$home/state" "$home/config"
  install_prime_watch_extension_fixture "$repo"
  plugin="$repo/.prime/agent/extensions/fm-primary-prime-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
exit 0
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
let prompt = "";
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_prime") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompt += message;
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await tool.execute("tool-call-established-empty", {}, undefined, undefined, {});
for (let i = 0; i < 250 && !prompt; i += 1) {
  await new Promise((resolve) => setTimeout(resolve, 10));
}
const rows = existsSync(process.env.FM_ARM_LOG)
  ? readFileSync(process.env.FM_ARM_LOG, "utf8").trim().split("\n")
  : [];
if (rows.length !== 3) throw new Error(`retry limit launched ${rows.length} arm cycles: ${rows.join(" | ")}`);
if (!prompt.startsWith("⁣FIRSTMATE_OP: v1 watcher: ")) {
  throw new Error(`untyped operational follow-up: ${prompt}`);
}
if (!prompt.includes("after 2 retries")) throw new Error(`retry exhaustion was not surfaced: ${prompt}`);
EOF
)
  status=$?
  expect_code 0 "$status" "prime-agent clean closes must honor the continuity retry limit and surface a typed wake"
  [ -z "$out" ] || fail "prime-agent empty-close retry test printed output: $out"
  pass "prime-agent established clean closes stop at the configured retry limit"
}

test_prime_session_generation_owns_the_arm_child() {
  local repo home plugin log child out status
  repo="$TMP_ROOT/prime-generation-root"
  home="$TMP_ROOT/prime-generation-home"
  log="$TMP_ROOT/prime-generation.log"
  child="$TMP_ROOT/prime-generation-child.pid"
  mkdir -p "$home/state" "$home/config"
  install_prime_watch_extension_fixture "$repo"
  plugin="$repo/.prime/agent/extensions/fm-primary-prime-watch.ts"
  cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm pid=%s\n' "$$" >> "${FM_ARM_LOG:?}"
printf '%s\n' "$$" > "${FM_CHILD_PID_FILE:?}"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
trap 'exit 0' TERM INT
while :; do sleep 0.05; done
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  out=$(PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" FM_ARM_LOG="$log" FM_CHILD_PID_FILE="$child" FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=2 node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

function makePi() {
  const handlers = new Map();
  let tool = null;
  const pi = {
    on(event, handler) {
      handlers.set(event, handler);
    },
    registerCommand() {},
    registerTool(candidate) {
      if (candidate.name === "fm_watch_arm_prime") tool = candidate;
    },
    sendUserMessage: async () => {},
  };
  return { pi, handlers, getTool: () => tool };
}

function pidAlive(pid) {
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

async function waitFor(predicate, label) {
  for (let i = 0; i < 250; i += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
  throw new Error(`timeout waiting for ${label}`);
}

function armPids() {
  if (!existsSync(process.env.FM_ARM_LOG)) return [];
  return readFileSync(process.env.FM_ARM_LOG, "utf8")
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => /pid=(\d+)/.exec(line)?.[1] || "")
    .filter(Boolean);
}

writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);

const first = makePi();
const parentManager = {};
const childManager = {};
const parentCtx = { sessionManager: parentManager };
const childCtx = { sessionManager: childManager };
mod.default(first.pi);
await first.handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, parentCtx);
const armed = await first.getTool().execute("startup", {}, undefined, undefined, parentCtx);
if (!armed.details?.ok) throw new Error(`startup arm failed: ${JSON.stringify(armed.details)}`);
await waitFor(() => existsSync(process.env.FM_CHILD_PID_FILE), "startup arm child");
const startupChild = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();

await first.handlers.get("session_start")?.({ type: "session_start", reason: "startup" }, childCtx);
await first.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "quit" }, childCtx);
if (!pidAlive(startupChild)) throw new Error("an inline child session stopped the parent's arm child");
const childArm = await first.getTool().execute("child", {}, undefined, undefined, childCtx);
if (childArm.details?.ok !== false) throw new Error(`an inline child session controlled the parent watcher: ${JSON.stringify(childArm.details)}`);
if (armPids().length !== 1) throw new Error(`an inline child session spawned another arm: ${armPids().join(",")}`);

// The generation that owns the child is retired with the session, and its
// stale tool must not be able to start a competing cycle afterwards.
await first.handlers.get("session_shutdown")?.({ type: "session_shutdown", reason: "replace" }, parentCtx);
await waitFor(() => !pidAlive(startupChild), "startup arm child exit");
const stale = await first.getTool().execute("stale", {}, undefined, undefined, parentCtx);
if (stale.details?.ok !== false || !String(stale.details.message).includes("session is shutting down")) {
  throw new Error(`stale generation was allowed to rearm: ${JSON.stringify(stale.details)}`);
}
if (armPids().length !== 1) throw new Error(`stale generation spawned another arm: ${armPids().join(",")}`);

// A replacement session activates a new live generation that arms once.
const second = makePi();
const replacementCtx = { sessionManager: {} };
mod.default(second.pi);
await second.handlers.get("session_start")?.({ type: "session_start", reason: "replace" }, replacementCtx);
const rearmed = await second.getTool().execute("replacement", {}, undefined, undefined, replacementCtx);
if (!rearmed.details?.ok) throw new Error(`replacement arm failed: ${JSON.stringify(rearmed.details)}`);
if (String(rearmed.details.message).includes("shutting down")) {
  throw new Error("replacement session inherited the shutting-down latch");
}
await waitFor(() => {
  const current = readFileSync(process.env.FM_CHILD_PID_FILE, "utf8").trim();
  return current !== startupChild && pidAlive(current);
}, "replacement arm child");
const live = armPids().filter(pidAlive);
if (live.length !== 1) throw new Error(`expected exactly one live arm child, got ${live.join(",") || "(none)"}`);
process.kill(Number(live[0]), "SIGTERM");
EOF
)
  status=$?
  expect_code 0 "$status" "prime-agent generation ownership must retire with its session and rearm exactly once"
  [ -z "$out" ] || fail "prime-agent generation test printed output: $out"
  pass "prime-agent session generation owns the arm child across a replacement"
}

test_prime_redundant_tool_call_is_owned_noop
test_prime_established_empty_close_honors_retry_limit
test_prime_session_generation_owns_the_arm_child

echo "# all fm-prime-watch-extension tests passed"
