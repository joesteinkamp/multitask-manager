#!/usr/bin/env bash
# Reports a Claude Code session's state to MultiTask Manager.
#
# One script, every event: Claude Code passes the hook payload on stdin as JSON
# and the event name as $1, and this maps it to a status file the app reads.
#
# The point of this file is that the app stops *guessing*. Without it, status
# comes from how long a transcript has gone unmodified — which cannot tell a
# session waiting for you from one thinking hard, and reports both as needing
# attention. These events say which.
#
# Writes ~/.multitaskmanager/status/<session>.json. Never blocks, never fails a
# tool call: every path exits 0.

set -u

event="${1:-unknown}"
matcher="${2:-}"
payload="$(cat 2>/dev/null || true)"

dir="${MTM_HOME:-$HOME/.multitaskmanager}/status"
mkdir -p "$dir" 2>/dev/null || exit 0

field() {
  printf '%s' "$payload" | sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

session="$(field session_id)"
cwd="$(field cwd)"
[ -n "$session" ] || session="unknown-$$"
[ -n "$cwd" ] || cwd="$PWD"

case "$event" in
  SessionStart)            status=idle;           waiting=""; reason="Session started" ;;
  UserPromptSubmit)        status=working;        waiting=""; reason="Working" ;;
  PreToolUse|PostToolUse|PostToolBatch)
                           status=working;        waiting=""; reason="${matcher:-Running a tool}" ;;
  # The event this whole file exists for. `agent_needs_input` and
  # `permission_prompt` are the harness stating outright that it is blocked on a
  # person — no timeout, no inference.
  Notification)
    case "$matcher" in
      permission_prompt)   status=needs_attention; waiting=approval; reason="Waiting for permission" ;;
      agent_needs_input)   status=needs_attention; waiting=question; reason="Asked you something" ;;
      idle_prompt)         status=needs_attention; waiting=question; reason="Waiting for your reply" ;;
      agent_completed)     status=done;            waiting=done;     reason="Finished" ;;
      *)                   status=needs_attention; waiting=question; reason="${matcher:-Notification}" ;;
    esac ;;
  Stop)                    status=done;           waiting=done; reason="Finished responding" ;;
  StopFailure)             status=needs_attention; waiting=error; reason="Turn ended with an error" ;;
  SubagentStop)            status=working;        waiting=""; reason="Subagent finished" ;;
  SessionEnd)              status=done;           waiting=done; reason="Session ended" ;;
  *)                       exit 0 ;;
esac

escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

cat > "$dir/$session.json" <<JSON
{
  "schemaVersion": 2,
  "sessionId": "$(escape "$session")",
  "projectPath": "$(escape "$cwd")",
  "project": "$(escape "$(basename "$cwd")")",
  "status": "$status",
  "waiting": "$waiting",
  "reason": "$(escape "$reason")",
  "tool": "claude",
  "updatedAt": $(date +%s)
}
JSON

exit 0
