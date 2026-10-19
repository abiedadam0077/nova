#!/usr/bin/env bash
# NOVA CRAFT server runner (GitHub-hosted Ubuntu).
# Responsibilities: restore, download+verify server build, start Playit, run the
# server, publish status/live log, accept queued commands, back up safely, stop.
set -uo pipefail

CFG=nova-craft/server.json
REPO="${GITHUB_REPOSITORY:?}"
ACTION="${NOVA_ACTION:-start}"
REF="${GITHUB_REF_NAME:-main}"
SID="$(python3 -c 'import json;print(json.load(open("nova-craft/server.json"))["id"])')"
DATA="$(python3 -c 'import json;print(json.load(open("nova-craft/server.json")).get("dataPath") or "server")')"
EDITION="$(python3 -c 'import json;print(json.load(open("nova-craft/server.json")).get("edition","JAVA"))')"
SOFTWARE="$(python3 -c 'import json;print(json.load(open("nova-craft/server.json")).get("software","VANILLA").upper())')"
MCV="$(python3 -c 'import json;print(json.load(open("nova-craft/server.json")).get("mcVersion",""))')"
MEMORY="$(python3 -c 'import json;print(int(json.load(open("nova-craft/server.json")).get("memoryMb",4096)))')"
JAVAMAJOR="$(python3 -c 'import json;print(int(json.load(open("nova-craft/server.json")).get("javaMajor",21)))')"
DLURL="$(python3 -c 'import json;print(json.load(open("nova-craft/server.json")).get("downloadUrl",""))')"
DLSHA="$(python3 -c 'import json;print(json.load(open("nova-craft/server.json")).get("downloadSha",""))')"
EULA="$(python3 -c 'import json;print("true" if json.load(open("nova-craft/server.json")).get("eulaAccepted") else "false")')"
PLAYIT_TUNNEL_ID="$(python3 -c 'import json;print(json.load(open("nova-craft/server.json")).get("playitTunnelId",""))')"
AUTORESTART="$(python3 -c 'import json;print("true" if json.load(open("nova-craft/server.json")).get("autoRestart",True) else "false")')"
ALLOW_COMMANDS="$(python3 -c 'import json;print("true" if json.load(open("nova-craft/server.json")).get("allowCommands",True) else "false")')"
BACKUP_RETENTION="$(python3 -c 'import json;print(max(2,min(30,int(json.load(open("nova-craft/server.json")).get("backupRetention",10)))))')"
MAXSEC=18000
JOB_STARTED=$(date +%s)
PHASE=unknown
STATUS_LAST=""
LIVE_LAST=""
PLAYIT_PID=""
PLAYIT_LOG_PATH=""
PLAYIT_SECRET_FILE=""
PLAYIT_CURL_CONFIG=""
PLAYIT_TEMP_DIR=""
PLAYIT_AGENT_STATUS="not_started"
PLAYIT_AGENT_DIAGNOSTIC="agent_not_started"
PLAYIT_AGENT_EXIT_CODE="not_started"
PLAYIT_AGENT_EXIT_CAPTURED=false
PLAYIT_SECRET_STATUS="missing"
SERVER_PORT_STATUS="unknown"
TUNNEL_DIAGNOSTIC="not_started"
FILES_MANIFEST_STATUS="unknown"
FILES_SNAPSHOT_STATUS="unknown"
TUNNEL_LOCAL_IP=""
TUNNEL_LOCAL_PORT=""
GAME_PORT=25565
[ "$EDITION" = "BEDROCK" ] && GAME_PORT=19132
SRV_PID=""
export PLAYIT_AGENT_EXIT_CODE TUNNEL_DIAGNOSTIC FILES_MANIFEST_STATUS FILES_SNAPSHOT_STATUS

cleanup_playit() {
  if [ -n "$PLAYIT_PID" ] && kill -0 "$PLAYIT_PID" 2>/dev/null; then
    kill "$PLAYIT_PID" 2>/dev/null || true
    wait "$PLAYIT_PID" 2>/dev/null || true
  fi
  if [ -n "$PLAYIT_TEMP_DIR" ]; then
    rm -rf -- "$PLAYIT_TEMP_DIR"
  fi
}
trap cleanup_playit EXIT

WORKSPACE_ABS="$(pwd -P)"
if ! python3 - "$DATA" <<'PYDATAPATH'
import re, sys
value = sys.argv[1]
parts = value.split("/")
if not value or value.startswith("/") or any(part in ("", ".", "..") or not re.fullmatch(r"[A-Za-z0-9._-]+", part) for part in parts) or parts[0] in (".git", ".github", "nova-craft"):
    sys.exit(1)
PYDATAPATH
then
  echo "[nova] ERROR server dataPath must be a safe relative path"
  exit 1
fi
DATA_CURSOR="$WORKSPACE_ABS"
IFS='/' read -r -a DATA_PARTS <<< "$DATA"
for segment in "${DATA_PARTS[@]}"; do
  DATA_CURSOR="$DATA_CURSOR/$segment"
  if [ -L "$DATA_CURSOR" ]; then
    echo "[nova] ERROR server dataPath cannot traverse a symbolic link"
    exit 1
  fi
done
mkdir -p -- "$DATA" || { echo "[nova] ERROR could not create server dataPath"; exit 1; }
DATA_ABS="$(cd -- "$DATA" && pwd -P)" || exit 1
if [ "$DATA_ABS" != "$WORKSPACE_ABS/$DATA" ] || [ "$DATA_ABS" = "$WORKSPACE_ABS" ]; then
  echo "[nova] ERROR resolved server dataPath is outside the repository checkout"
  exit 1
fi
cd "$WORKSPACE_ABS" || exit 1

log() { echo "[nova] $*"; }
if [ -n "${PLAYIT_SECRET_KEY:-}" ]; then
  printf '::add-mask::%s\n' "$PLAYIT_SECRET_KEY"
  PLAYIT_SECRET_STATUS=saved
else
  PLAYIT_SECRET_STATUS=missing
fi
export PLAYIT_SECRET_STATUS

# ---------------------------------------------------------------- utilities --

api_content_sha() {
  gh api "repos/$REPO/contents/$1?ref=$REF" --jq .sha 2>/dev/null || echo ""
}

api_content_text() {
  gh api "repos/$REPO/contents/$1?ref=$REF" --jq .content 2>/dev/null | base64 -d 2>/dev/null || true
}

# put_file <path> <text> <message>  — skips the commit when content is unchanged.
put_file() {
  local path="$1" text="$2" message="$3"
  local current sha payload
  current="$(api_content_text "$path")"
  if [ "$current" = "$text" ]; then return 0; fi
  sha="$(api_content_sha "$path")"
  payload="$(mktemp)"
  python3 - "$text" "$message" "$REF" "$sha" > "$payload" <<'PYJSON'
import base64, json, sys
text, message, ref, sha = sys.argv[1:5]
body = {
    "message": message or "nova: update",
    "content": base64.b64encode(text.encode()).decode(),
    "branch": ref or "main",
}
if sha and sha != "null":
    body["sha"] = sha
print(json.dumps(body))
PYJSON
  local api_error detail
  api_error="$(mktemp)"
  if ! gh api -X PUT "repos/$REPO/contents/$path" --input "$payload" > /dev/null 2>"$api_error"; then
    detail="$(tail -n 3 "$api_error" 2>/dev/null | tr '\n' ' ' | sed -E 's/(Authorization:[[:space:]]*Bearer[[:space:]]+)[^[:space:]]+/\1[REDACTED]/Ig; s/(Agent-Key[[:space:]]+)[^[:space:]]+/\1[REDACTED]/Ig; s/[[:xdigit:]]{32,}/[REDACTED]/g' | cut -c1-240)"
    log "WARN GitHub API could not publish $path${detail:+: $detail}"
    rm -f "$api_error" "$payload"
    return 1
  fi
  rm -f "$api_error"
  rm -f "$payload"
  return 0
}

publish_status() {
  local phase="$1" ready="$2" reason="${3:-}" players="${4:-}" pmax="${5:-}" tunnel="${6:-unknown}" tunnel_msg="${7:-}" latency="${8:-}"
  local json
  json="$(python3 - "$phase" "$ready" "$reason" "$players" "$pmax" "$tunnel" "$tunnel_msg" "$latency" "$SRV_PID" "$MCV" "$JOB_STARTED" <<'PY'
import json, os, re, sys, time
phase, ready, reason, players, pmax, tunnel, tmsg, latency, pid, mcv, started = sys.argv[1:12]
def num(v):
    try:
        return int(v)
    except Exception:
        return None
def safe_agent_log_tail():
    path = os.environ.get("PLAYIT_LOG_PATH", "")
    if not path or not os.path.isfile(path):
        return ""
    try:
        with open(path, "rb") as handle:
            handle.seek(max(0, os.fstat(handle.fileno()).st_size - 6000))
            text = handle.read(6000).decode("utf-8", "replace")
    except OSError:
        return ""
    secret = os.environ.get("PLAYIT_SECRET_KEY", "")
    secret_path = os.environ.get("PLAYIT_SECRET_FILE", "")
    if not secret and secret_path:
        try:
            with open(secret_path, "r", encoding="utf-8") as secret_handle:
                secret = secret_handle.read()
        except OSError:
            secret = ""
    if secret:
        text = text.replace(secret, "[REDACTED]")
    text = re.sub(r"(?i)(authorization:\s*agent-key\s+)[^\s\"']+", r"\1[REDACTED]", text)
    text = re.sub(r"(?i)(secret(?:_key)?\s*[:=]\s*)[\"']?[0-9a-f]{16,}[\"']?", r"\1[REDACTED]", text)
    return text
print(json.dumps({
    "schema": 2,
    "serverId": json.load(open("nova-craft/server.json"))["id"],
    "phase": phase,
    "ready": ready == "true",
    "reason": reason,
    "playersOnline": num(players),
    "playersMax": num(pmax),
    "version": mcv,
    "serverPid": num(pid),
    "tunnelStatus": tunnel,
    "tunnelMessage": tmsg,
    "tunnelDiagnostic": os.environ.get("TUNNEL_DIAGNOSTIC", ""),
    "tunnelAddress": os.environ.get("TUNNEL_ADDR", ""),
    "tunnelName": os.environ.get("TUNNEL_NAME", ""),
    "tunnelId": os.environ.get("TUNNEL_ID", ""),
    "tunnelProtocol": os.environ.get("TUNNEL_PROTO", ""),
    "tunnelLocalIp": os.environ.get("TUNNEL_LOCAL_IP", ""),
    "tunnelLocalPort": num(os.environ.get("TUNNEL_LOCAL_PORT", "")),
    "tunnelOfflineReasons": [x for x in [os.environ.get("TUNNEL_ISSUE", "")] if x],
    "agentId": os.environ.get("AGENT_ID", ""),
    "agentStatus": os.environ.get("PLAYIT_AGENT_STATUS", "unknown"),
    "agentDiagnostic": os.environ.get("PLAYIT_AGENT_DIAGNOSTIC", ""),
    "agentExitCode": os.environ.get("PLAYIT_AGENT_EXIT_CODE", "not_started"),
    "playitSecretStatus": os.environ.get("PLAYIT_SECRET_STATUS", "unknown"),
    "serverPortStatus": os.environ.get("SERVER_PORT_STATUS", "unknown"),
    "gamePort": num(os.environ.get("GAME_PORT", "")),
    "agentLogTail": safe_agent_log_tail(),
    "fileManifestStatus": os.environ.get("FILES_MANIFEST_STATUS", "unknown"),
    "fileSnapshotStatus": os.environ.get("FILES_SNAPSHOT_STATUS", "unknown"),
    "latencyMs": num(latency),
    "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "cycleStartedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(started))),
    "conclusion": "",
}, ensure_ascii=False, indent=2))
PY
)"
  if [ "$json" != "$STATUS_LAST" ]; then
    STATUS_LAST="$json"
    put_file "nova-craft/status.json" "$json" "nova: status $phase" || true
  fi
}

publish_live() {
  local file="$1"
  [ -f "$file" ] || return 0
  local tail_text
  tail_text="$(tail -n 260 "$file" | tail -c 45000)"
  if [ "$tail_text" != "$LIVE_LAST" ]; then
    LIVE_LAST="$tail_text"
    put_file "nova-craft/live.log" "$tail_text" "nova: live log" || true
  fi
}

publish_files() {
  # The manifest and snapshot are GitHub repository files. The server data used
  # to generate them lives only on this runner while the Actions job is active.
  local files_dir="$WORKSPACE_ABS/nova-craft/files"
  local manifest_path="$files_dir/manifest.json"
  local snapshot_path="$WORKSPACE_ABS/nova-craft/snapshot.json"
  local error_file="$(mktemp)"
  FILES_MANIFEST_STATUS=generation_failed
  FILES_SNAPSHOT_STATUS=generation_failed
  mkdir -p -- "$files_dir" || {
    log "WARN could not create the manifest output directory"
    rm -f "$error_file"
    return 0
  }

  if python3 "$WORKSPACE_ABS/nova-craft/fileops.py" manifest "$DATA_ABS" "$manifest_path" > /dev/null 2>"$error_file"; then
    if put_file "nova-craft/files/manifest.json" "$(cat "$manifest_path")" "nova: file manifest"; then
      FILES_MANIFEST_STATUS=published
    else
      FILES_MANIFEST_STATUS=publish_failed
      log "WARN generated file manifest could not be published to GitHub Contents"
    fi
  else
    local detail
    detail="$(tail -n 4 "$error_file" 2>/dev/null | tr '\n' ' ' | cut -c1-320)"
    log "WARN manifest generation failed${detail:+: $detail}"
  fi

  : > "$error_file"
  if python3 "$WORKSPACE_ABS/nova-craft/fileops.py" snapshot "$DATA_ABS" "$snapshot_path" > /dev/null 2>"$error_file"; then
    if put_file "nova-craft/snapshot.json" "$(cat "$snapshot_path")" "nova: config snapshot"; then
      FILES_SNAPSHOT_STATUS=published
    else
      FILES_SNAPSHOT_STATUS=publish_failed
      log "WARN generated editable snapshot could not be published to GitHub Contents"
    fi
  else
    local detail
    detail="$(tail -n 4 "$error_file" 2>/dev/null | tr '\n' ' ' | cut -c1-320)"
    log "WARN config snapshot generation failed${detail:+: $detail}"
  fi
  rm -f "$error_file"
}

# File operations requested from the app. Applied immediately while a cycle is
# running, so the Files tab is not limited to "next start".
apply_file_request() {
  local sha payload_text
  sha="$(api_content_sha "nova-craft/files/request.json")"
  [ -n "$sha" ] || return 0
  payload_text="$(gh api "repos/$REPO/contents/nova-craft/files/request.json?ref=$REF" --jq .content 2>/dev/null | base64 -d 2>/dev/null)"
  [ -n "$payload_text" ] || return 0
  local req_id
  printf '%s' "$payload_text" > /tmp/nova-req.json
  req_id="$(python3 -c 'import json;print(json.load(open("/tmp/nova-req.json")).get("id",""))' 2>/dev/null || echo "")"
  [ -n "$req_id" ] || { echo "WARN: file request without id"; return 0; }
  if [ "$req_id" = "$LAST_FILE_REQ" ]; then return 0; fi
  LAST_FILE_REQ="$req_id"
  log "file request $req_id"
  python3 nova-craft/fileops.py request "$DATA_ABS" /tmp/nova-req.json /tmp/nova-res.json > /dev/null 2>&1 || true
  if [ -f /tmp/nova-res.json ]; then
    put_file "nova-craft/files/response.json" "$(cat /tmp/nova-res.json)" "nova: file response" || true
  fi
  gh api -X DELETE "repos/$REPO/contents/nova-craft/files/request.json" \
    -f message="nova: file request consumed" -f sha="$sha" -f branch="$REF" > /dev/null 2>&1 || true
  publish_files
}

publish_cycle_end() {
  local conclusion="$1" reason="$2"
  local json
  json="$(python3 - "$conclusion" "$reason" "$MCV" "$JOB_STARTED" <<'PY'
import json, os, re, sys, time
conclusion, reason, mcv, started = sys.argv[1:5]
def safe_agent_log_tail():
    path = os.environ.get("PLAYIT_LOG_PATH", "")
    if not path or not os.path.isfile(path):
        return ""
    try:
        with open(path, "rb") as handle:
            handle.seek(max(0, os.fstat(handle.fileno()).st_size - 6000))
            text = handle.read(6000).decode("utf-8", "replace")
    except OSError:
        return ""
    secret = os.environ.get("PLAYIT_SECRET_KEY", "")
    secret_path = os.environ.get("PLAYIT_SECRET_FILE", "")
    if not secret and secret_path:
        try:
            with open(secret_path, "r", encoding="utf-8") as secret_handle:
                secret = secret_handle.read()
        except OSError:
            secret = ""
    if secret:
        text = text.replace(secret, "[REDACTED]")
    text = re.sub(r"(?i)(authorization:\s*agent-key\s+)[^\s\"']+", r"\1[REDACTED]", text)
    text = re.sub(r"(?i)(secret(?:_key)?\s*[:=]\s*)[\"']?[0-9a-f]{16,}[\"']?", r"\1[REDACTED]", text)
    return text
print(json.dumps({
    "schema": 2,
    "serverId": json.load(open("nova-craft/server.json"))["id"],
    "phase": "stopped" if conclusion == "success" else "failed",
    "ready": False,
    "reason": reason,
    "conclusion": conclusion,
    "version": mcv,
    "tunnelStatus": os.environ.get("TUNNEL_STATE", "unknown"),
    "tunnelMessage": os.environ.get("TUNNEL_MSG", ""),
    "tunnelDiagnostic": os.environ.get("TUNNEL_DIAGNOSTIC", ""),
    "tunnelAddress": os.environ.get("TUNNEL_ADDR", ""),
    "tunnelName": os.environ.get("TUNNEL_NAME", ""),
    "tunnelId": os.environ.get("TUNNEL_ID", ""),
    "tunnelProtocol": os.environ.get("TUNNEL_PROTO", ""),
    "tunnelLocalIp": os.environ.get("TUNNEL_LOCAL_IP", ""),
    "tunnelLocalPort": int(os.environ.get("TUNNEL_LOCAL_PORT", "0") or 0) or None,
    "agentId": os.environ.get("AGENT_ID", ""),
    "agentStatus": os.environ.get("PLAYIT_AGENT_STATUS", "unknown"),
    "agentDiagnostic": os.environ.get("PLAYIT_AGENT_DIAGNOSTIC", ""),
    "agentExitCode": os.environ.get("PLAYIT_AGENT_EXIT_CODE", "not_started"),
    "playitSecretStatus": os.environ.get("PLAYIT_SECRET_STATUS", "unknown"),
    "serverPortStatus": os.environ.get("SERVER_PORT_STATUS", "unknown"),
    "gamePort": int(os.environ.get("GAME_PORT", "0") or 0) or None,
    "agentLogTail": safe_agent_log_tail(),
    "fileManifestStatus": os.environ.get("FILES_MANIFEST_STATUS", "unknown"),
    "fileSnapshotStatus": os.environ.get("FILES_SNAPSHOT_STATUS", "unknown"),
    "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "cycleStartedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(float(started))),
}, ensure_ascii=False, indent=2))
PY
)"
  put_file "nova-craft/status.json" "$json" "nova: cycle $conclusion" || true
}

verify_hash() {
  local file="$1" hash="$2"
  if [ -z "$hash" ]; then log "no checksum published for $file (skipping verification)"; return 0; fi
  local len=${#hash}
  if [ "$len" -eq 64 ]; then echo "$hash  $file" | sha256sum -c - || return 1
  elif [ "$len" -eq 40 ]; then echo "$hash  $file" | sha1sum -c - || return 1
  elif [ "$len" -eq 32 ]; then echo "$hash  $file" | md5sum -c - || return 1
  else log "unknown checksum length ($len); skipping verification"; ci=false; return 0
  fi
}

download() {
  local url="$1" out="$2" hash="$3"
  local tmp="${out}.part"
  rm -f "$tmp"
  log "downloading $url"
  curl -fL --retry 4 --retry-all-errors --connect-timeout 20 -o "$tmp" "$url" || return 1
  [ -s "$tmp" ] || { log "ERROR empty download"; rm -f "$tmp"; return 1; }
  if ! verify_hash "$tmp" "$hash"; then
    log "ERROR checksum mismatch for $out"
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$out"
}

wait_for_port() {
  local host="$1" port="$2" timeout="$3"
  python3 - "$host" "$port" "$timeout" <<'PY'
import socket, sys, time
host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
deadline = time.time() + timeout
while time.time() < deadline:
    try:
        with socket.create_connection((host, port), timeout=2):
            sys.exit(0)
    except OSError:
        time.sleep(1)
sys.exit(1)
PY
}

probe_tunnel() {
  # The helper requires an actual Java SLP/TCP or Bedrock RakNet/UDP reply.
  # External probes also require the one running official Playit Agent.
  local address="$1" require_agent="${2:-true}"
  [ -n "$address" ] || return 1
  if [ "$require_agent" = "true" ]; then
    [ -n "$PLAYIT_PID" ] || return 1
    kill -0 "$PLAYIT_PID" 2>/dev/null || return 1
  fi
  python3 "$WORKSPACE_ABS/nova-craft/playit.py" probe "$address" "$EDITION"
}

# -------------------------------------------------------------- validation --

if [ "$EDITION" = "JAVA" ] && [ "$ACTION" = "start" ] && [ "$EULA" != "true" ]; then
  log "ERROR Minecraft EULA was not accepted in the app; refusing to start."
  publish_cycle_end failure "eula-not-accepted"
  exit 1
fi

if [ "$EDITION" = "JAVA" ] && [ -z "$DLURL" ]; then
  log "ERROR server.json has no download URL; re-save the server in the app."
  publish_cycle_end failure "missing-download-url"
  exit 1
fi

# ---------------------------------------------------------------- restore --

mkdir -p nova-craft
INCOMING=nova-craft/import
REQUESTED_RESTORE_TAG="${NOVA_RESTORE_TAG:-}"
RESTORE_TAG=""
if [ "$ACTION" = "snapshot" ]; then
  if [ -n "$REQUESTED_RESTORE_TAG" ]; then
    log "ERROR snapshot actions cannot include a restore tag"
    publish_cycle_end failure "invalid-restore-tag"
    exit 1
  fi
else
  if [ -n "$REQUESTED_RESTORE_TAG" ]; then
    case "$REQUESTED_RESTORE_TAG" in
      "backup-$SID-"[A-Za-z0-9_-][A-Za-z0-9_-]*) ;;
      *)
        log "ERROR the requested backup tag does not belong to this server"
        publish_cycle_end failure "invalid-restore-tag"
        exit 1
        ;;
    esac
  else
    RELEASE_LIST="/tmp/nova-backup-releases.json"
    if gh api "repos/$REPO/releases?per_page=100" > "$RELEASE_LIST" 2>/dev/null; then
      REQUESTED_RESTORE_TAG="$(python3 - "$RELEASE_LIST" "$SID" <<'PYLATEST'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    releases = json.load(handle)
prefix = "backup-%s-" % sys.argv[2]
backups = []
for release in releases:
    if not isinstance(release, dict) or release.get("draft"):
        continue
    if not str(release.get("tag_name", "")).startswith(prefix):
        continue
    if "NOVA_CRAFT_BACKUP_VERIFIED" not in str(release.get("body", "")):
        continue
    assets = {asset.get("name") for asset in (release.get("assets") or []) if isinstance(asset, dict)}
    if {"world-backup.zip", "world-backup.sha256"} <= assets:
        backups.append(release)
backups.sort(key=lambda release: str(release.get("created_at", "")), reverse=True)
if backups:
    print(backups[0].get("tag_name", ""))
PYLATEST
      )"
    else
      log "WARN could not list verified backups; using the cached world"
    fi
  fi
fi

restore_backup_archive() {
  python3 - "$1" "$DATA_ABS" "$EDITION" <<'PYRESTORE'
import os, shutil, stat, sys, zipfile
archive_path, root, edition = sys.argv[1:]
world_roots = {"worlds"} if edition == "BEDROCK" else {"world", "world_nether", "world_the_end"}
shared = ({"server.properties", "allowlist.json", "permissions.json"} if edition == "BEDROCK" else
          {"server.properties", "whitelist.json", "banned-players.json", "banned-ips.json", "ops.json"})
stage = os.path.join(root, ".nova-restore-stage")
if os.path.exists(stage):
    if os.path.islink(stage):
        raise SystemExit("restore staging path is a symlink")
    shutil.rmtree(stage)
os.makedirs(stage)
try:
    with zipfile.ZipFile(archive_path, "r") as archive:
        infos = archive.infolist()
        if not infos or len(infos) > 100000:
            raise ValueError("empty or oversized backup manifest")
        accepted = []
        seen = set()
        expanded_size = 0
        max_total_size = 8 * 1024 * 1024 * 1024
        max_file_size = 4 * 1024 * 1024 * 1024
        for info in infos:
            name = info.filename.replace("\\", "/")
            clean_name = name.rstrip("/")
            if clean_name in seen:
                raise ValueError("duplicate archive path")
            seen.add(clean_name)
            if info.file_size < 0 or info.file_size > max_file_size:
                raise ValueError("backup file exceeds the restore size limit")
            expanded_size += info.file_size
            if expanded_size > max_total_size:
                raise ValueError("backup exceeds the restore size limit")
            parts = clean_name.split("/")
            if name.startswith("/") or not clean_name or any(part in ("", ".", "..") for part in parts):
                raise ValueError("unsafe archive path")
            first = parts[0]
            if first not in world_roots and not (len(parts) == 1 and first in shared):
                raise ValueError("unexpected path in backup")
            mode = (info.external_attr >> 16) & 0xffff
            if stat.S_ISLNK(mode):
                raise ValueError("symlink in backup")
            if info.is_dir():
                continue
            if mode and not stat.S_ISREG(mode):
                raise ValueError("non-regular file in backup")
            accepted.append((info, name))
        if not accepted:
            raise ValueError("backup has no files")
        if archive.testzip() is not None:
            raise ValueError("backup CRC verification failed")
        for info, name in accepted:
            target = os.path.realpath(os.path.join(stage, *name.rstrip("/").split("/")))
            if os.path.commonpath((os.path.realpath(stage), target)) != os.path.realpath(stage):
                raise ValueError("archive path escaped staging root")
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with archive.open(info, "r") as source, open(target, "wb") as destination:
                shutil.copyfileobj(source, destination)
        # Only after the complete archive is checked and staged do we replace
        # the existing world folders and shared files.
        world_data_found = False
        for world_root in world_roots:
            staged_world = os.path.join(stage, world_root)
            if os.path.isdir(staged_world):
                for _, _, files in os.walk(staged_world):
                    if files:
                        world_data_found = True
                        break
            if world_data_found:
                break
        if not world_data_found:
            raise ValueError("backup contains no world data")
        previous_root = os.path.join(stage, ".previous")
        os.makedirs(previous_root)
        moved_old = []
        installed_new = []
        try:
            for rel in world_roots:
                target = os.path.join(root, rel)
                staged = os.path.join(stage, rel)
                if not os.path.isdir(staged):
                    continue
                if os.path.lexists(target):
                    if os.path.islink(target) or not os.path.isdir(target):
                        raise ValueError("unsafe existing world path")
                    previous = os.path.join(previous_root, rel)
                    os.makedirs(os.path.dirname(previous), exist_ok=True)
                    os.replace(target, previous)
                    moved_old.append((target, previous))
                os.replace(staged, target)
                installed_new.append(target)
            for rel in shared:
                staged = os.path.join(stage, rel)
                if not os.path.isfile(staged):
                    continue
                target = os.path.join(root, rel)
                if os.path.lexists(target):
                    if os.path.isdir(target) and not os.path.islink(target):
                        raise ValueError("unsafe existing shared path")
                    previous = os.path.join(previous_root, rel)
                    os.makedirs(os.path.dirname(previous), exist_ok=True)
                    os.replace(target, previous)
                    moved_old.append((target, previous))
                os.replace(staged, target)
                installed_new.append(target)
        except Exception:
            for target in reversed(installed_new):
                if not os.path.lexists(target):
                    continue
                if os.path.isdir(target) and not os.path.islink(target):
                    shutil.rmtree(target)
                else:
                    os.unlink(target)
            for target, previous in reversed(moved_old):
                if os.path.lexists(previous):
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    os.replace(previous, target)
            raise
finally:
    if os.path.isdir(stage) and not os.path.islink(stage):
        shutil.rmtree(stage, ignore_errors=True)
print("verified backup extracted safely")
PYRESTORE
}

if [ -n "$REQUESTED_RESTORE_TAG" ]; then
  log "checking backup release $REQUESTED_RESTORE_TAG"
  TMPD="$(mktemp -d)"
  if gh release download "$REQUESTED_RESTORE_TAG" --repo "$REPO" --pattern "world-backup.zip" --dir "$TMPD" 2>/dev/null \
      && gh release download "$REQUESTED_RESTORE_TAG" --repo "$REPO" --pattern "world-backup.sha256" --dir "$TMPD" 2>/dev/null \
      && (cd "$TMPD" && sha256sum -c world-backup.sha256) \
      && restore_backup_archive "$TMPD/world-backup.zip"; then
    RESTORE_TAG="$REQUESTED_RESTORE_TAG"
    log "restored verified backup $RESTORE_TAG"
  else
    rm -rf "$TMPD"
    log "ERROR backup could not be verified/restored; refusing to start from an older cached world"
    publish_cycle_end failure "backup-restore-failed"
    exit 1
  fi
  rm -rf "$TMPD"
fi

# Settings from the app always win over the cached copy.
python3 nova-craft/config.py --write-props || log "WARN could not rewrite server.properties"

# Small config edits made in the app while the server was stopped live in the
# repository snapshot; they must win over the restored cache too.
if [ -f nova-craft/snapshot.json ]; then
  python3 nova-craft/fileops.py apply-snapshot "$DATA_ABS" nova-craft/snapshot.json \
    || log "WARN could not apply the repository snapshot"
fi

# Packages uploaded from the phone (worlds, jars, add-ons) are copied in here.
if [ -d nova-craft/uploads ]; then
  for f in nova-craft/uploads/*; do
    [ -f "$f" ] || continue
    case "$f" in
      *.gitkeep|*.json) continue ;;
    esac
    log "applying upload $(basename "$f")"
    cp -f "$f" "$DATA_ABS/$(basename "$f")" || log "WARN upload copy failed"
  done
fi

# Add-on packages are installed before the server starts so toggles are real.
if [ -f nova-craft/addons/state.json ]; then
  python3 nova-craft/fileops.py addons "$DATA_ABS" nova-craft/addons nova-craft/addons/state.json /tmp/nova-addons.json \
    && cp /tmp/nova-addons.json nova-craft/addons/result.json || log "WARN add-on install failed"
fi

if [ -f "$INCOMING/world.zip" ]; then
  log "applying imported world"
  WORLD_NAME="$(python3 -c 'import json;d=json.load(open("nova-craft/import/world.json"));print(d.get("name") or "Imported world")' 2>/dev/null || echo "Imported world")"
  if python3 nova-craft/fileops.py import "$DATA_ABS" "$INCOMING/world.zip" "$WORLD_NAME" /tmp/nova-import.json; then
    cp /tmp/nova-import.json nova-craft/import/result.json || true
    SHA="$(api_content_sha "$INCOMING/world.zip")"
    if [ -n "$SHA" ]; then
      gh api -X DELETE "repos/$REPO/contents/$INCOMING/world.zip" -f message="nova: import applied" -f sha="$SHA" -f branch="$REF" > /dev/null 2>&1 || true
    fi
  else
    cp /tmp/nova-import.json nova-craft/import/result.json || true
    log "WARN imported world was rejected (see nova-craft/import/result.json)"
  fi
fi

# ------------------------------------------------------------------- EULA --

if [ "$EDITION" = "JAVA" ]; then
  if [ "$EULA" = "true" ]; then echo "eula=true" > "$DATA_ABS/eula.txt"; fi
fi

# ---------------------------------------------------------------- snapshot --

prune_backups() {
  local listing="/tmp/nova-backup-releases.json"
  local obsolete="/tmp/nova-backup-prune.txt"
  gh api "repos/$REPO/releases?per_page=100" > "$listing" 2>/dev/null || {
    log "WARN could not list releases for backup retention"
    return 0
  }
  if ! python3 - "$listing" "$SID" "$BACKUP_RETENTION" > "$obsolete" <<'PYPRUNE'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    releases = json.load(handle)
prefix = "backup-%s-" % sys.argv[2]
keep = max(2, min(30, int(sys.argv[3])))
verified = []
for release in releases:
    if not isinstance(release, dict) or release.get("draft"):
        continue
    if not str(release.get("tag_name", "")).startswith(prefix):
        continue
    if "NOVA_CRAFT_BACKUP_VERIFIED" not in str(release.get("body", "")):
        continue
    assets = {asset.get("name") for asset in (release.get("assets") or []) if isinstance(asset, dict)}
    if {"world-backup.zip", "world-backup.sha256"} <= assets:
        verified.append(release)
verified.sort(key=lambda release: str(release.get("created_at", "")), reverse=True)
for release in verified[keep:]:
    print(release.get("tag_name", ""))
PYPRUNE
  then
    log "WARN could not evaluate backup retention safely"
    return 0
  fi
  while IFS= read -r old_tag; do
    [ -n "$old_tag" ] || continue
    if gh release delete "$old_tag" --repo "$REPO" --yes --cleanup-tag; then
      log "pruned old verified backup $old_tag"
    else
      log "WARN failed to prune old backup $old_tag"
    fi
  done < "$obsolete"
}

backup_now() {
  local phase_label="$1"
  local ts tag verify_dir work_dir archive_size
  ts="$(date -u +%Y%m%dT%H%M%S%NZ)"
  tag="backup-$SID-$ts"
  # Old versions placed the archive in the cached server directory, doubling
  # cache size on every cycle. Keep archives only in ephemeral runner storage.
  rm -f "$DATA_ABS/world-backup.zip" "$DATA_ABS/world-backup.sha256"
  work_dir="$(mktemp -d)"
  if ! python3 - "$DATA_ABS" "$EDITION" "$work_dir/world-backup.zip" "$work_dir/world-backup.sha256" <<'PYBACKUP'
import hashlib, os, sys, zipfile
root, edition, archive_path, checksum_path = sys.argv[1:]
paths = (["worlds", "server.properties", "allowlist.json", "permissions.json"]
         if edition == "BEDROCK" else
         ["world", "world_nether", "world_the_end", "server.properties",
          "whitelist.json", "banned-players.json", "banned-ips.json", "ops.json"])
world_paths = ["worlds"] if edition == "BEDROCK" else ["world", "world_nether", "world_the_end"]
world_files = []
for rel in world_paths:
    full = os.path.join(root, rel)
    if os.path.isdir(full) and not os.path.islink(full):
        for current, dirs, files in os.walk(full, followlinks=False):
            if any(os.path.islink(os.path.join(current, name)) for name in dirs + files):
                raise SystemExit("refusing to archive a symlink in world data")
            world_files.extend(os.path.join(current, name) for name in files)
if not world_files:
    raise SystemExit("no world data found; refusing to publish an empty backup")
count = 0
with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as archive:
    for rel in paths:
        full = os.path.join(root, rel)
        if not os.path.exists(full):
            continue
        if os.path.islink(full):
            raise SystemExit("refusing to archive a symlink")
        if os.path.isdir(full):
            for current, dirs, files in os.walk(full, followlinks=False):
                dirs.sort(); files.sort()
                if any(os.path.islink(os.path.join(current, name)) for name in dirs + files):
                    raise SystemExit("refusing to archive a symlink")
                for name in files:
                    source = os.path.join(current, name)
                    archive.write(source, os.path.relpath(source, root))
                    count += 1
        else:
            archive.write(full, rel)
            count += 1
if count == 0:
    raise SystemExit("backup archive contains no files")
with zipfile.ZipFile(archive_path, "r") as archive:
    corrupt = archive.testzip()
    if corrupt is not None:
        raise SystemExit("archive verification failed at %s" % corrupt)
digest = hashlib.sha256()
with open(archive_path, "rb") as handle:
    for block in iter(lambda: handle.read(1024 * 1024), b""):
        digest.update(block)
with open(checksum_path, "w", encoding="ascii") as handle:
    handle.write("%s  world-backup.zip\n" % digest.hexdigest())
print("verified %d files (%d bytes)" % (count, os.path.getsize(archive_path)))
PYBACKUP
  then
    rm -rf "$work_dir"
    log "ERROR world backup creation or local verification failed"
    return 1
  fi
  archive_size="$(stat -c '%s' "$work_dir/world-backup.zip" 2>/dev/null || echo 0)"
  if [ "$archive_size" -gt 2147483648 ]; then
    rm -rf "$work_dir"
    log "ERROR backup exceeds GitHub's 2 GiB release-asset limit; old backups were preserved"
    return 1
  fi
  if ! gh release create "$tag" "$work_dir/world-backup.zip" "$work_dir/world-backup.sha256" \
        --repo "$REPO" --title "Backup $ts" \
        --notes "NOVA CRAFT $phase_label backup (restored: ${RESTORE_TAG:-cache})"; then
    log "WARN release create failed; attempting upload to an existing tag"
    if ! gh release upload "$tag" "$work_dir/world-backup.zip" "$work_dir/world-backup.sha256" \
        --repo "$REPO" --clobber; then
      rm -rf "$work_dir"
      return 1
    fi
  fi
  verify_dir="$(mktemp -d)"
  if ! gh release download "$tag" --repo "$REPO" --pattern "world-backup.zip" --pattern "world-backup.sha256" --dir "$verify_dir"; then
    rm -rf "$work_dir" "$verify_dir"
    log "ERROR could not download the published backup for verification"
    return 1
  fi
  if ! (cd "$verify_dir" && sha256sum -c world-backup.sha256 && python3 - <<'PYVERIFY'
import sys, zipfile
with zipfile.ZipFile("world-backup.zip", "r") as archive:
    sys.exit(0 if archive.testzip() is None and archive.namelist() else 1)
PYVERIFY
  ); then
    rm -rf "$work_dir" "$verify_dir"
    log "ERROR published backup failed checksum or archive verification"
    return 1
  fi
  if ! gh release edit "$tag" --repo "$REPO" \
      --notes "NOVA_CRAFT_BACKUP_VERIFIED — NOVA CRAFT re-downloaded this backup and verified its SHA-256 and ZIP CRC."; then
    log "WARN backup bytes verified, but could not write the verification marker to the release notes"
  fi
  rm -rf "$work_dir" "$verify_dir"
  log "backup published and verified $tag"
  prune_backups
  return 0
}

if [ "$ACTION" = "snapshot" ]; then
  if backup_now "snapshot"; then
    publish_cycle_end success "snapshot"
    exit 0
  fi
  publish_cycle_end failure "snapshot-failed"
  exit 1
fi

# ------------------------------------------------------------- Downloads ---

cd "$DATA_ABS" || exit 1
if [ "$EDITION" = "JAVA" ]; then
  # Fabric launchers are re-downloaded per loader, so only cache immutable jars.
  if [ -f server.jar ] && [ -n "$DLSHA" ]; then
    if verify_hash server.jar "$DLSHA" 2>/dev/null; then
      log "server.jar already present and verified"
    else
      log "cached server.jar does not match the pinned checksum; re-downloading"
      rm -f server.jar
      download "$DLURL" server.jar "$DLSHA" || { publish_cycle_end failure "download-failed"; exit 1; }
    fi
  else
    download "$DLURL" server.jar "$DLSHA" || { publish_cycle_end failure "download-failed"; exit 1; }
  fi
else
  # Bedrock updates are mandatory for clients, so the installed build is tied
  # to the resolved URL. A new URL replaces the old server instead of keeping a
  # stale bedrock_server forever.
  BURL="$DLURL"
  if [ -z "$BURL" ] || [ "$BURL" = "https://www.minecraft.net/en-us/download/server/bedrock" ]; then
    BURL="$(curl -sL -A "Mozilla/5.0" https://www.minecraft.net/en-us/download/server/bedrock \
      | grep -oE "https://www\.minecraft\.net/bedrockdedicatedserver/bin-linux/[^\"']+\.zip" | head -1)"
  fi
  if [ -z "$BURL" ]; then
    if [ -f bedrock_server ]; then
      log "WARN could not resolve a new Bedrock build; using the cached server"
    else
      log "ERROR could not resolve the Bedrock download URL"
      publish_cycle_end failure "bedrock-download-url"
      exit 1
    fi
  else
    PREV=""
    [ -f bedrock.url ] && PREV="$(cat bedrock.url 2>/dev/null || true)"
    if [ ! -f bedrock_server ] || [ "$PREV" != "$BURL" ]; then
      download "$BURL" bedrock.zip "" || { publish_cycle_end failure "download-failed"; exit 1; }
      unzip -o -q bedrock.zip || { publish_cycle_end failure "bedrock-unzip"; exit 1; }
      chmod +x bedrock_server
      rm -f bedrock.zip
      printf '%s' "$BURL" > bedrock.url
      log "bedrock build installed from $BURL"
    else
      log "bedrock build already current"
    fi
  fi
fi
cd "$WORKSPACE_ABS" || exit 1

# ------------------------------------------------------------ Playit agent --

playit_api() {
  local endpoint="$1" payload="$2" error_path="$PLAYIT_TEMP_DIR/api.err"
  PLAYIT_API_HTTP_STATUS=""
  PLAYIT_API_EXIT_CODE=0
  PLAYIT_API_ERROR=""
  if PLAYIT_API_HTTP_STATUS="$(curl -sS --connect-timeout 10 --max-time 25 \
      --config "$PLAYIT_CURL_CONFIG" -X POST "https://api.playit.gg$endpoint" \
      -H "Content-Type: application/json" -d "$payload" \
      -o "$PLAYIT_TEMP_DIR/rundata.json" -w '%{http_code}' 2>"$error_path")"; then
    return 0
  else
    PLAYIT_API_EXIT_CODE=$?
  fi
  PLAYIT_API_ERROR="$(python3 - "$error_path" "$PLAYIT_SECRET_FILE" <<'PYAPIERR'
import re, sys
try:
    text = open(sys.argv[1], encoding="utf-8", errors="replace").read()[-1200:].replace("\n", " ").replace("\r", " ").strip()
except OSError:
    text = ""
try:
    secret = open(sys.argv[2], encoding="utf-8").read()
except OSError:
    secret = ""
if secret:
    text = text.replace(secret, "[REDACTED]")
text = re.sub(r"(?i)(authorization:\s*agent-key\s+)[^\s\"']+", r"\1[REDACTED]", text)
print(text[:320])
PYAPIERR
  )"
  log "PLAYIT_API_TRANSPORT_ERROR exit=$PLAYIT_API_EXIT_CODE${PLAYIT_API_ERROR:+ detail=$PLAYIT_API_ERROR}"
  return 1
}

refresh_tunnel() {
  rm -f "$PLAYIT_TEMP_DIR/rundata.json" "$PLAYIT_TEMP_DIR/tunnel.env"
  if ! playit_api /v1/agents/rundata '{}'; then
    TUNNEL_STATE=error
    TUNNEL_DIAGNOSTIC=rundata_network_error
    TUNNEL_MSG="Playit rundata transport failed (curl exit $PLAYIT_API_EXIT_CODE)${PLAYIT_API_ERROR:+: $PLAYIT_API_ERROR}"
    return 1
  fi
  case "$PLAYIT_API_HTTP_STATUS" in
    2??) ;;
    401)
      TUNNEL_STATE=error
      TUNNEL_DIAGNOSTIC=rundata_unauthorized
      TUNNEL_MSG="Playit rundata rejected the Agent key (HTTP 401)."
      playit_agent_failure invalid_secret "$TUNNEL_MSG" rundata_unauthorized
      return 1
      ;;
    403)
      TUNNEL_STATE=error
      TUNNEL_DIAGNOSTIC=rundata_forbidden
      TUNNEL_MSG="Playit rundata returned HTTP 403 (forbidden); this is not enough to identify the key as invalid."
      return 1
      ;;
    *)
      TUNNEL_STATE=error
      TUNNEL_DIAGNOSTIC=rundata_http_error
      TUNNEL_MSG="Playit rundata returned HTTP ${PLAYIT_API_HTTP_STATUS:-unknown}."
      log "PLAYIT_API_HTTP_ERROR status=${PLAYIT_API_HTTP_STATUS:-unknown}"
      return 1
      ;;
  esac
  [ -s "$PLAYIT_TEMP_DIR/rundata.json" ] || {
    TUNNEL_STATE=error
    TUNNEL_DIAGNOSTIC=rundata_empty
    TUNNEL_MSG="Playit returned HTTP ${PLAYIT_API_HTTP_STATUS:-2xx} with an empty rundata body."
    return 1
  }
  python3 nova-craft/playit.py parse "$PLAYIT_TEMP_DIR/rundata.json" "$PLAYIT_TEMP_DIR/tunnel.env" "$EDITION" "$PLAYIT_TUNNEL_ID" > /dev/null || {
    TUNNEL_STATE=error
    TUNNEL_DIAGNOSTIC=rundata_parse_error
    TUNNEL_MSG="The successful Playit rundata response could not be parsed as Tunnel data."
    return 1
  }
  . "$PLAYIT_TEMP_DIR/tunnel.env"
  TUNNEL_DIAGNOSTIC="${TUNNEL_DIAGNOSTIC:-$TUNNEL_STATE}"
  TUNNEL_MSG="${TUNNEL_Q_MSG:-}"
  return 0
}

record_playit_agent_exit() {
  [ -n "$PLAYIT_PID" ] || return 0
  [ "$PLAYIT_AGENT_EXIT_CAPTURED" = "true" ] && return 0
  local exit_code
  if wait "$PLAYIT_PID"; then exit_code=0; else exit_code=$?; fi
  PLAYIT_AGENT_EXIT_CODE="$exit_code"
  PLAYIT_AGENT_EXIT_CAPTURED=true
}

stop_failed_playit_agent() {
  [ -n "$PLAYIT_PID" ] || return 0
  if kill -0 "$PLAYIT_PID" 2>/dev/null; then
    kill -TERM "$PLAYIT_PID" 2>/dev/null || true
    for _ in $(seq 1 5); do
      kill -0 "$PLAYIT_PID" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$PLAYIT_PID" 2>/dev/null || true
  fi
  if [ "$PLAYIT_AGENT_EXIT_CAPTURED" != "true" ]; then
    wait "$PLAYIT_PID" 2>/dev/null || true
    PLAYIT_AGENT_EXIT_CAPTURED=true
  fi
  PLAYIT_AGENT_EXIT_CODE=stopped_after_failure
}

playit_agent_failure() {
  local diagnostic="$1" message="$2" tunnel_diagnostic="${3:-agent_$1}"
  case "$diagnostic" in
    process_exited|ipc_socket_failed) record_playit_agent_exit ;;
    *) stop_failed_playit_agent ;;
  esac
  PLAYIT_AGENT_STATUS=failed
  PLAYIT_AGENT_DIAGNOSTIC="$diagnostic"
  TUNNEL_STATE=error
  TUNNEL_DIAGNOSTIC="$tunnel_diagnostic"
  TUNNEL_MSG="$message"
  export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
  export TUNNEL_STATE TUNNEL_MSG TUNNEL_DIAGNOSTIC TUNNEL_ADDR TUNNEL_NAME TUNNEL_ID TUNNEL_PROTO TUNNEL_ISSUE TUNNEL_LOCAL_IP TUNNEL_LOCAL_PORT AGENT_ID
  log "PLAYIT_AGENT_FAILED diagnostic=$PLAYIT_AGENT_DIAGNOSTIC exit_code=$PLAYIT_AGENT_EXIT_CODE"
  publish_status starting false "playit-agent-failed" "" "" "$TUNNEL_STATE" "$TUNNEL_MSG"
}

start_playit() {
  TUNNEL_STATE=unknown
  TUNNEL_DIAGNOSTIC=secret_missing
  TUNNEL_MSG="Playit Agent has not started; save PLAYIT_SECRET_KEY and start the server cycle."
  TUNNEL_ADDR=""
  TUNNEL_NAME=""
  TUNNEL_ID=""
  TUNNEL_PROTO=""
  TUNNEL_ISSUE=""
  TUNNEL_LOCAL_IP=""
  TUNNEL_LOCAL_PORT=""
  AGENT_ID=""
  PLAYIT_AGENT_EXIT_CODE=not_started
  PLAYIT_AGENT_EXIT_CAPTURED=false
  PLAYIT_AGENT_STATUS=not_started
  PLAYIT_AGENT_DIAGNOSTIC=secret_missing
  if [ -z "${PLAYIT_SECRET_KEY:-}" ]; then
    PLAYIT_SECRET_STATUS=missing
    export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_AGENT_EXIT_CODE PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
    export TUNNEL_STATE TUNNEL_MSG TUNNEL_DIAGNOSTIC TUNNEL_ADDR TUNNEL_NAME TUNNEL_ID TUNNEL_PROTO TUNNEL_ISSUE TUNNEL_LOCAL_IP TUNNEL_LOCAL_PORT AGENT_ID
    log "PLAYIT_SECRET_INJECTED=false; Agent was not started"
    return 0
  fi

  # Move the injected key into an unexported local and immediately remove the
  # workflow environment variable; it was already registered for log masking.
  local secret_value="$PLAYIT_SECRET_KEY"
  unset PLAYIT_SECRET_KEY
  PLAYIT_SECRET_STATUS=saved
  if [[ ! "$secret_value" =~ ^([[:xdigit:]]{2})+$ ]]; then
    unset secret_value
    playit_agent_failure invalid_secret_format "The supplied Playit Agent key has an invalid format. Save the official Agent SECRET_KEY again."
    return 0
  fi

  local run_tag="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
  local runner_temp="${RUNNER_TEMP:-/tmp}"
  mkdir -p -- "$runner_temp" || {
    unset secret_value
    playit_agent_failure temp_directory_unavailable "The private runner temporary directory could not be created."
    return 0
  }
  PLAYIT_TEMP_DIR="$(mktemp -d "$runner_temp/nova-playit-${run_tag}.XXXXXX")" || {
    unset secret_value
    playit_agent_failure temp_directory_unavailable "The private runner temporary directory could not be created."
    return 0
  }
  if ! chmod 700 "$PLAYIT_TEMP_DIR"; then
    unset secret_value
    playit_agent_failure secure_temp_directory_failed "Could not secure the temporary directory for the Playit Agent key."
    return 0
  fi
  PLAYIT_SECRET_FILE="$PLAYIT_TEMP_DIR/agent.secret"
  PLAYIT_CURL_CONFIG="$PLAYIT_TEMP_DIR/api.curl"
  PLAYIT_LOG_PATH="$PLAYIT_TEMP_DIR/agent.log"
  local previous_umask secret_file_error=""
  previous_umask="$(umask)"
  umask 077
  if ! printf '%s' "$secret_value" > "$PLAYIT_SECRET_FILE"; then
    secret_file_error=write_secret_failed
  elif ! printf 'header = "Authorization: Agent-Key %s"\n' "$secret_value" > "$PLAYIT_CURL_CONFIG"; then
    secret_file_error=write_api_config_failed
  elif ! : > "$PLAYIT_LOG_PATH"; then
    secret_file_error=create_log_failed
  elif ! chmod 600 "$PLAYIT_SECRET_FILE" "$PLAYIT_CURL_CONFIG" "$PLAYIT_LOG_PATH"; then
    secret_file_error=secure_temp_files_failed
  fi
  umask "$previous_umask"
  unset secret_value
  if [ -n "$secret_file_error" ]; then
    playit_agent_failure "$secret_file_error" "Could not create or secure the temporary Playit Agent files."
    return 0
  fi
  export PLAYIT_SECRET_FILE PLAYIT_LOG_PATH
  PLAYIT_AGENT_STATUS=starting
  PLAYIT_AGENT_DIAGNOSTIC=starting
  PLAYIT_AGENT_EXIT_CODE=not_started
  TUNNEL_STATE=unknown
  TUNNEL_DIAGNOSTIC=agent_starting
  TUNNEL_MSG="Official Playit Agent is starting; connection is not confirmed yet."
  export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_AGENT_EXIT_CODE PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
  export TUNNEL_STATE TUNNEL_MSG TUNNEL_DIAGNOSTIC TUNNEL_ADDR TUNNEL_NAME TUNNEL_ID TUNNEL_PROTO TUNNEL_ISSUE TUNNEL_LOCAL_IP TUNNEL_LOCAL_PORT AGENT_ID
  log "PLAYIT_SECRET_INJECTED=true (secret value redacted)"
  publish_status starting false "playit-agent-starting" "" "" "$TUNNEL_STATE" "$TUNNEL_MSG"

  local url="https://github.com/playit-cloud/playit-agent/releases/download/v1.0.10/playit-linux-amd64"
  local expected_sha="2df7d9f10227ab312b1ad341853db4e8a8243df5cfcdbae58713a4271711c339"
  if [ -x "$WORKSPACE_ABS/playitd" ] && ! printf '%s  %s\n' "$expected_sha" "$WORKSPACE_ABS/playitd" | sha256sum -c --status; then
    log "cached Playit daemon checksum mismatch; discarding binary"
    rm -f "$WORKSPACE_ABS/playitd"
  fi
  if [ ! -x "$WORKSPACE_ABS/playitd" ]; then
    if ! curl -fsSL --retry 3 --connect-timeout 20 -o "$WORKSPACE_ABS/playitd.tmp" "$url"; then
      rm -f "$WORKSPACE_ABS/playitd.tmp"
      playit_agent_failure agent_download_failed "The official Playit daemon download failed."
      return 0
    fi
    if [ ! -s "$WORKSPACE_ABS/playitd.tmp" ]; then
      rm -f "$WORKSPACE_ABS/playitd.tmp"
      playit_agent_failure agent_download_failed "The official Playit daemon download was empty."
      return 0
    fi
    if ! printf '%s  %s\n' "$expected_sha" "$WORKSPACE_ABS/playitd.tmp" | sha256sum -c --status; then
      rm -f "$WORKSPACE_ABS/playitd.tmp"
      playit_agent_failure agent_checksum_failed "The official Playit daemon checksum did not match; the binary was rejected."
      return 0
    fi
    chmod 700 "$WORKSPACE_ABS/playitd.tmp"
    mv "$WORKSPACE_ABS/playitd.tmp" "$WORKSPACE_ABS/playitd"
  fi

  # One official daemon process for this server cycle. It consumes the raw key
  # through a 0600 file; SECRET_KEY is never placed on argv or in its env.
  # GitHub-hosted runners may not have Playit's default IPC parent directory.
  # Keep its socket inside this run's already-created private temp directory.
  nohup "$WORKSPACE_ABS/playitd" --secret-path "$PLAYIT_SECRET_FILE" \
    --socket-path "$PLAYIT_TEMP_DIR/playit.sock" --platform-docker \
    > "$PLAYIT_LOG_PATH" 2>&1 </dev/null &
  PLAYIT_PID=$!
  PLAYIT_AGENT_EXIT_CODE=running
  PLAYIT_AGENT_EXIT_CAPTURED=false
  local attempt="" failure_diagnostic="startup_timeout"
  for attempt in $(seq 1 45); do
    if ! kill -0 "$PLAYIT_PID" 2>/dev/null; then
      record_playit_agent_exit
      if grep -Eiq 'IPC error: Failed to bind to socket|failed to bind.*socket' "$PLAYIT_LOG_PATH"; then
        failure_diagnostic=ipc_socket_failed
      else
        failure_diagnostic=process_exited
      fi
      break
    fi
    if grep -Fiq 'playit connected; tunnels loaded' "$PLAYIT_LOG_PATH"; then
      PLAYIT_AGENT_STATUS=connected
      PLAYIT_AGENT_DIAGNOSTIC=connected
      break
    fi
    if grep -Eiq 'InvalidAgentKey|invalid agent key|invalid secret|unauthori[sz]ed|no longer valid' "$PLAYIT_LOG_PATH"; then
      failure_diagnostic=invalid_secret
      break
    fi
    if grep -Eiq 'AgentDisabledOverLimit|agent limit|over the agent limit' "$PLAYIT_LOG_PATH"; then
      failure_diagnostic=account_agent_limit
      break
    fi
    if grep -Eiq 'Could not connect|Could not reach|failed to connect|timed out while connecting|connection refused|network is unreachable|temporary failure in name resolution|Name or service not known' "$PLAYIT_LOG_PATH"; then
      failure_diagnostic=network_unreachable
      break
    fi
    if [ $((attempt % 5)) -eq 0 ]; then
      export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
      publish_status starting false "playit-agent-starting" "" "" "$TUNNEL_STATE" "$TUNNEL_MSG"
    fi
    sleep 2
  done
  if [ "$PLAYIT_AGENT_STATUS" != "connected" ]; then
    case "$failure_diagnostic" in
      invalid_secret)
        playit_agent_failure invalid_secret "Playit rejected the Agent SECRET_KEY. Save the official key again."
        ;;
      account_agent_limit)
        playit_agent_failure account_agent_limit "The Playit account has reached its Agent limit."
        ;;
      process_exited)
        playit_agent_failure process_exited "The official Playit Agent exited before connecting (exit code ${PLAYIT_AGENT_EXIT_CODE})."
        ;;
      ipc_socket_failed)
        playit_agent_failure ipc_socket_failed "The Playit Agent could not bind its local IPC socket; check the runner's temporary socket path."
        ;;
      *)
        PLAYIT_AGENT_STATUS=starting
        PLAYIT_AGENT_DIAGNOSTIC="$failure_diagnostic"
        TUNNEL_STATE=unknown
        TUNNEL_DIAGNOSTIC="agent_$failure_diagnostic"
        TUNNEL_MSG="Playit has not confirmed Agent connectivity; the daemon is still running and will retry."
        export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_AGENT_EXIT_CODE PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
        export TUNNEL_STATE TUNNEL_MSG TUNNEL_DIAGNOSTIC TUNNEL_ADDR TUNNEL_NAME TUNNEL_ID TUNNEL_PROTO TUNNEL_ISSUE TUNNEL_LOCAL_IP TUNNEL_LOCAL_PORT AGENT_ID
        log "PLAYIT_AGENT_STILL_STARTING diagnostic=$PLAYIT_AGENT_DIAGNOSTIC exit_code=$PLAYIT_AGENT_EXIT_CODE"
        publish_status starting false "playit-agent-starting" "" "" "$TUNNEL_STATE" "$TUNNEL_MSG"
        ;;
    esac
    return 0
  fi

  PLAYIT_AGENT_STATUS=connected
  PLAYIT_AGENT_DIAGNOSTIC=connected
  PLAYIT_AGENT_EXIT_CODE=running
  TUNNEL_DIAGNOSTIC=agent_connected
  TUNNEL_MSG="Official Playit Agent confirmed connected; tunnels loaded."
  export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_AGENT_EXIT_CODE PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
  log "PLAYIT_AGENT_CONNECTED: official daemon log confirmed 'playit connected; tunnels loaded'"
  if refresh_tunnel; then
    case "$TUNNEL_STATE" in
      allocated) TUNNEL_MSG="Playit reports $TUNNEL_ADDR; the local game port and external game-protocol ping are still being checked." ;;
      disabled) TUNNEL_MSG="Playit reports this Tunnel as disabled (${TUNNEL_ISSUE:-no reason given})." ;;
      not_created) TUNNEL_MSG="No matching Playit Tunnel was reported. Create one manually in the Playit dashboard; NOVA CRAFT does not create it." ;;
      unsupported) TUNNEL_MSG="The reported Tunnel type or transport is unsupported for this Minecraft edition." ;;
      address_unavailable) TUNNEL_MSG="The matching Playit Tunnel exists, but its public address is unavailable." ;;
      selection_required) TUNNEL_MSG="Several matching Playit Tunnels exist or the saved selection is unavailable; select one in NOVA CRAFT." ;;
      error) [ -n "$TUNNEL_MSG" ] || TUNNEL_MSG="The official Agent is connected, but Playit did not return usable Tunnel data." ;;
    esac
  else
    [ "$PLAYIT_AGENT_STATUS" = "failed" ] || TUNNEL_STATE=error
    [ -n "$TUNNEL_MSG" ] || TUNNEL_MSG="The Playit rundata request failed after Agent startup."
  fi
  export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
  export TUNNEL_STATE TUNNEL_MSG TUNNEL_ADDR TUNNEL_NAME TUNNEL_ID TUNNEL_PROTO TUNNEL_ISSUE TUNNEL_LOCAL_IP TUNNEL_LOCAL_PORT AGENT_ID
  publish_status starting false "playit-agent-checked" "" "" "$TUNNEL_STATE" "$TUNNEL_MSG"
}

TUNNEL_STATE=unknown
TUNNEL_DIAGNOSTIC=minecraft_starting
TUNNEL_MSG="Minecraft is starting. The Playit Agent will start only after the local game protocol responds."
TUNNEL_ADDR=""
TUNNEL_NAME=""
TUNNEL_ID=""
TUNNEL_PROTO=""
TUNNEL_LOCAL_IP=""
TUNNEL_LOCAL_PORT=""
TUNNEL_ISSUE=""
AGENT_ID=""
PLAYIT_PID=""
PLAYIT_CURL_CONFIG=""
export TUNNEL_STATE TUNNEL_MSG TUNNEL_DIAGNOSTIC TUNNEL_ADDR TUNNEL_NAME TUNNEL_ID TUNNEL_PROTO TUNNEL_ISSUE TUNNEL_LOCAL_IP TUNNEL_LOCAL_PORT AGENT_ID
export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_AGENT_EXIT_CODE PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
publish_status starting false "minecraft-starting" "" "" "$TUNNEL_STATE" "$TUNNEL_MSG"

# ---------------------------------------------------------------- runtime ---

cd "$DATA_ABS" || exit 1
FIFO=/tmp/nova-stdin
rm -f "$FIFO"; mkfifo "$FIFO"
exec 7<>"$FIFO"

if [ "$EDITION" = "JAVA" ]; then
  java -Xms512M -Xmx${MEMORY}M -XX:+UseG1GC -jar server.jar nogui < "$FIFO" > server.log 2>&1 &
else
  LD_LIBRARY_PATH=. ./bedrock_server < "$FIFO" > server.log 2>&1 &
fi
SRV_PID=$!
cd "$WORKSPACE_ABS" || exit 1
log "server pid $SRV_PID"

send_cmd() { printf '%s\n' "$1" >&7 2>/dev/null || true; }

wait_for_save() {
  local start_offset="$1" log_file="$DATA_ABS/server.log" pattern
  if [ "$EDITION" = "BEDROCK" ]; then
    pattern='Data saved\. Files are now ready to be copied'
  else
    pattern='Saved the game|All chunks are saved'
  fi
  for _ in $(seq 1 150); do
    if [ -f "$log_file" ] && tail -c +$((start_offset + 1)) "$log_file" 2>/dev/null | grep -qiE "$pattern"; then
      return 0
    fi
    kill -0 "$SRV_PID" 2>/dev/null || return 1
    sleep 2
  done
  return 1
}

SERVER_READY=false
READY_DEADLINE=$(( $(date +%s) + 900 ))
while kill -0 "$SRV_PID" 2>/dev/null; do
  if grep -qE "Done \([0-9.]+s\)!|Server started\." "$DATA_ABS/server.log" 2>/dev/null; then SERVER_READY=true; break; fi
  if [ "$(date +%s)" -gt "$READY_DEADLINE" ]; then break; fi
  sleep 3
done

# The first status is published only after the process check below, so a
# crashed server is never reported as ready.
if ! kill -0 "$SRV_PID" 2>/dev/null && [ "$SERVER_READY" != "true" ]; then
  log "ERROR the server exited before it became ready"
  tail -n 80 "$DATA_ABS/server.log" || true
  if [ -n "$PLAYIT_PID" ]; then
    if kill -0 "$PLAYIT_PID" 2>/dev/null; then
      [ "$PLAYIT_AGENT_STATUS" = "failed" ] || { PLAYIT_AGENT_STATUS=stopped; PLAYIT_AGENT_DIAGNOSTIC=cycle_ended; }
      kill "$PLAYIT_PID" 2>/dev/null || true
    elif [ "$PLAYIT_AGENT_STATUS" != "failed" ]; then
      PLAYIT_AGENT_STATUS=failed
      PLAYIT_AGENT_DIAGNOSTIC=process_exited
    fi
  fi
  if [ "$PLAYIT_AGENT_STATUS" = "stopped" ]; then
    TUNNEL_STATE=unknown
    TUNNEL_ADDR=""
    TUNNEL_MSG="The Minecraft process failed before the cycle was ready; the Playit Agent has stopped."
  fi
  export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
  export TUNNEL_STATE TUNNEL_MSG TUNNEL_ADDR TUNNEL_NAME TUNNEL_ID TUNNEL_PROTO TUNNEL_ISSUE TUNNEL_LOCAL_IP TUNNEL_LOCAL_PORT AGENT_ID
  publish_live "$DATA_ABS/server.log"
  publish_cycle_end failure "server-crashed"
  exit 1
fi
if [ "$SERVER_READY" != "true" ]; then
  log "ERROR Minecraft did not report ready within 900 seconds; Playit Agent was not started"
  tail -n 80 "$DATA_ABS/server.log" || true
  send_cmd "stop"
  kill "$SRV_PID" 2>/dev/null || true
  SERVER_PORT_STATUS=not_listening
  TUNNEL_STATE=server_port_not_listening
  TUNNEL_DIAGNOSTIC=minecraft_start_timeout
  TUNNEL_MSG="Minecraft did not become ready within 900 seconds; Playit Agent was not started."
  export SERVER_PORT_STATUS GAME_PORT TUNNEL_STATE TUNNEL_MSG TUNNEL_DIAGNOSTIC
  publish_live "$DATA_ABS/server.log"
  publish_cycle_end failure "server-start-timeout"
  exit 1
fi

players_count() {
  local line
  # Java: "There are 0 of a max of 20 players online"
  # Bedrock: "There are 0/10 players online"
  line="$(grep -oE "There are [0-9]+ of a max of [0-9]+ players online" "$DATA_ABS/server.log" 2>/dev/null | tail -1)"
  if [ -z "$line" ]; then
    line="$(grep -oE "There are [0-9]+/[0-9]+ players online" "$DATA_ABS/server.log" 2>/dev/null | tail -1 | sed -E 's|There are ([0-9]+)/([0-9]+) players online|There are \1 of a max of \2 players online|')"
  fi
  if [ -n "$line" ]; then echo "$line"; fi
}
parse_players() { echo "$1" | grep -oE "[0-9]+" | head -1; }
parse_max() { echo "$1" | grep -oE "[0-9]+" | sed -n 2p; }

# Confirm the local Minecraft endpoint with an actual game-protocol ping; a
# startup log line alone is not evidence that port 25565/19132 is reachable.
if [ "$EDITION" = "JAVA" ] && ! wait_for_port 127.0.0.1 "$GAME_PORT" 60; then
  log "WARN local Java TCP port $GAME_PORT did not accept a socket within 60 seconds"
fi
if probe_tunnel "127.0.0.1:$GAME_PORT" false; then
  SERVER_PORT_STATUS=listening
else
  SERVER_PORT_STATUS=not_listening
fi
if [ "$SERVER_PORT_STATUS" = "listening" ]; then
  # Start the official daemon only after Minecraft answered its local game
  # protocol. This keeps an Agent failure independent from server readiness.
  start_playit
  LAST_TUNNEL_REFRESH=$(date +%s)
else
  PLAYIT_AGENT_STATUS=not_started
  PLAYIT_AGENT_DIAGNOSTIC=minecraft_port_not_listening
  PLAYIT_AGENT_EXIT_CODE=not_started
  TUNNEL_STATE=server_port_not_listening
  TUNNEL_DIAGNOSTIC=server_port_not_listening
  TUNNEL_ADDR=""
  TUNNEL_MSG="Minecraft did not answer its local game protocol on port $GAME_PORT; Playit Agent was not started."
  log "PLAYIT_AGENT_NOT_STARTED reason=minecraft_port_not_listening game_port=$GAME_PORT"
fi
export SERVER_PORT_STATUS GAME_PORT PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_AGENT_EXIT_CODE PLAYIT_SECRET_STATUS
export TUNNEL_STATE TUNNEL_MSG TUNNEL_DIAGNOSTIC TUNNEL_ADDR TUNNEL_NAME TUNNEL_ID TUNNEL_PROTO TUNNEL_ISSUE TUNNEL_LOCAL_IP TUNNEL_LOCAL_PORT AGENT_ID

# Start the five-hour runtime budget only after local Minecraft readiness and
# the Agent/Tunnel checks have completed (or their failure has been diagnosed).
JOB_STARTED=$(date +%s)
publish_live "$DATA_ABS/server.log"
publish_files
publish_status ready true "server-ready" "$(parse_players "$(players_count)")" "$(parse_max "$(players_count)")" "$TUNNEL_STATE" "$TUNNEL_MSG"

STOP_FLAG=/tmp/nova-stop
BACKUP_REQUEST_FLAG=/tmp/nova-backup-request
rm -f "$STOP_FLAG" "$BACKUP_REQUEST_FLAG"
BACKUP_DONE=false
LAST_FILE_REQ=""
LAST_FILES_PUBLISH=$(date +%s)

poll_commands() {
  while kill -0 "$SRV_PID" 2>/dev/null; do
    sleep 12
    apply_file_request
    local files
    files="$(gh api "repos/$REPO/contents/nova-craft/commands" --jq '[.[] | select(.type=="file" and (.name | endswith(".txt")))] | sort_by(.name) | .[].name' 2>/dev/null || true)"
    for f in $files; do
      local cmd sha
      cmd="$(gh api "repos/$REPO/contents/nova-craft/commands/$f" --jq .content 2>/dev/null | base64 -d 2>/dev/null | tr -d '\r\n')"
      sha="$(gh api "repos/$REPO/contents/nova-craft/commands/$f" --jq .sha 2>/dev/null)"
      case "$cmd" in
        "nova:stop") touch "$STOP_FLAG"; send_cmd "say NOVA CRAFT is stopping";;
        "nova:backup") touch "$BACKUP_REQUEST_FLAG"; log "backup requested from the app";;
        "") : ;;
        *)
          if [ "$ALLOW_COMMANDS" = "true" ]; then
            log "manual command accepted"
            send_cmd "$cmd"
          else
            log "manual command rejected: console commands are disabled"
          fi
          ;;
      esac
      [ -n "$sha" ] && gh api -X DELETE "repos/$REPO/contents/nova-craft/commands/$f" \
        -f message="nova: command consumed" -f sha="$sha" > /dev/null 2>&1 || true
      sleep 1
    done
  done
}

heartbeat() {
  while kill -0 "$SRV_PID" 2>/dev/null; do
    sleep 30
    local players line latency now
    line="$(players_count)"
    players="$(parse_players "$line")"

    # The local game endpoint is checked independently of the Agent and Tunnel.
    if probe_tunnel "127.0.0.1:$GAME_PORT" false; then
      SERVER_PORT_STATUS=listening
    else
      SERVER_PORT_STATUS=not_listening
    fi

    if [ -n "$PLAYIT_PID" ]; then
      if ! kill -0 "$PLAYIT_PID" 2>/dev/null; then
        if [ "$PLAYIT_AGENT_STATUS" != "failed" ]; then
          record_playit_agent_exit
          PLAYIT_AGENT_STATUS=failed
          PLAYIT_AGENT_DIAGNOSTIC=process_exited
          TUNNEL_STATE=error
          TUNNEL_DIAGNOSTIC=agent_process_exited
          TUNNEL_MSG="The Playit Agent exited while Minecraft was running (exit code ${PLAYIT_AGENT_EXIT_CODE})."
          log "PLAYIT_AGENT_FAILED diagnostic=process_exited exit_code=$PLAYIT_AGENT_EXIT_CODE"
        fi
      elif grep -Fiq 'playit connected; tunnels loaded' "$PLAYIT_LOG_PATH"; then
        if [ "$PLAYIT_AGENT_STATUS" != "connected" ]; then
          PLAYIT_AGENT_STATUS=connected
          PLAYIT_AGENT_DIAGNOSTIC=connected
          log "PLAYIT_AGENT_CONNECTED: official daemon log confirmed connection after startup retry"
          LAST_TUNNEL_REFRESH=0
        fi
      fi
    fi

    # Read late-created Tunnels once per minute, and only after the official
    # daemon confirms that it is connected. The runner never creates Tunnels.
    now=$(date +%s)
    if [ "$PLAYIT_AGENT_STATUS" = "connected" ] && [ $((now - LAST_TUNNEL_REFRESH)) -ge 60 ]; then
      LAST_TUNNEL_REFRESH=$now
      if refresh_tunnel; then
        case "$TUNNEL_STATE" in
          allocated) TUNNEL_MSG="Playit reports $TUNNEL_ADDR; waiting for local and external Minecraft protocol checks." ;;
          disabled) TUNNEL_MSG="Playit reports this Tunnel as disabled (${TUNNEL_ISSUE:-no reason given})." ;;
          not_created) TUNNEL_MSG="No matching Playit Tunnel was reported. Create one manually in the Playit dashboard." ;;
          unsupported) TUNNEL_MSG="The reported Tunnel type or transport is unsupported for this Minecraft edition." ;;
          address_unavailable) TUNNEL_MSG="The matching Playit Tunnel exists, but its public address is unavailable." ;;
          selection_required) TUNNEL_MSG="Select one matching Playit Tunnel in NOVA CRAFT." ;;
          error) [ -n "$TUNNEL_MSG" ] || TUNNEL_MSG="The official Agent is connected, but Playit did not return usable Tunnel data." ;;
        esac
      else
        TUNNEL_STATE=error
        [ -n "$TUNNEL_DIAGNOSTIC" ] || TUNNEL_DIAGNOSTIC=rundata_network_error
        [ -n "$TUNNEL_MSG" ] || TUNNEL_MSG="The Playit rundata refresh failed; inspect the sanitized API diagnostic."
      fi
    fi

    # Only an allocated, supported Tunnel can progress to Connection ready.
    # Java is probed using the Minecraft Server List Ping over TCP; Bedrock
    # uses RakNet's unconnected UDP ping. A raw socket connect is never enough.
    case "$TUNNEL_STATE" in
      allocated|connecting|connected|server_port_not_listening|origin_mismatch)
        if [ "$SERVER_PORT_STATUS" != "listening" ]; then
          TUNNEL_STATE=server_port_not_listening
          TUNNEL_DIAGNOSTIC=server_port_not_listening
          TUNNEL_MSG="The local Minecraft game port $GAME_PORT did not answer its protocol ping."
        elif [ "$PLAYIT_AGENT_STATUS" = "failed" ]; then
          TUNNEL_STATE=error
          TUNNEL_DIAGNOSTIC="agent_$PLAYIT_AGENT_DIAGNOSTIC"
          TUNNEL_MSG="The Playit Agent failed while Minecraft was running."
        elif [ "$PLAYIT_AGENT_STATUS" != "connected" ]; then
          TUNNEL_STATE=unknown
          TUNNEL_DIAGNOSTIC=agent_not_connected
          TUNNEL_MSG="Waiting for the official Playit Agent connection."
        elif [ -n "$TUNNEL_LOCAL_PORT" ] && [ "$TUNNEL_LOCAL_PORT" != "$GAME_PORT" ]; then
          TUNNEL_STATE=origin_mismatch
          TUNNEL_DIAGNOSTIC=origin_mismatch
          TUNNEL_MSG="The Playit Tunnel targets local port $TUNNEL_LOCAL_PORT; Minecraft is configured for port $GAME_PORT."
        elif [ -n "$TUNNEL_ADDR" ] && probe_tunnel "$TUNNEL_ADDR" true; then
          TUNNEL_STATE=connected
          TUNNEL_DIAGNOSTIC=connected
          if [ "$EDITION" = "BEDROCK" ]; then
            TUNNEL_MSG="Playit's reported address answered a Bedrock RakNet ping."
          else
            TUNNEL_MSG="Playit's reported address answered a Java Server List Ping."
          fi
        else
          TUNNEL_STATE=connecting
          TUNNEL_DIAGNOSTIC=connecting
          TUNNEL_MSG="The local game port is ready; waiting for Playit's public address to answer the Minecraft protocol ping."
        fi
        ;;
    esac

    export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_AGENT_EXIT_CODE PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
    export TUNNEL_STATE TUNNEL_MSG TUNNEL_DIAGNOSTIC TUNNEL_ADDR TUNNEL_NAME TUNNEL_ID TUNNEL_PROTO TUNNEL_ISSUE TUNNEL_LOCAL_IP TUNNEL_LOCAL_PORT AGENT_ID
    latency=""
    publish_live "$DATA_ABS/server.log"
    if [ $(( $(date +%s) - LAST_FILES_PUBLISH )) -ge 300 ]; then
      LAST_FILES_PUBLISH=$(date +%s)
      publish_files
    fi
    publish_status ready true "server-ready" "$players" "$(parse_max "$line")" "$TUNNEL_STATE" "$TUNNEL_MSG" "$latency"
  done
}

poll_commands & POLL_PID=$!
heartbeat & HB_PID=$!

perform_manual_backup() {
  local save_log_offset
  rm -f "$BACKUP_REQUEST_FLAG"
  log "starting an on-demand, consistency-protected backup"
  save_log_offset="$(wc -c < "$DATA_ABS/server.log" 2>/dev/null || echo 0)"
  if [ "$EDITION" = "BEDROCK" ]; then
    send_cmd "save hold"
    send_cmd "save query"
  else
    send_cmd "save-off"
    send_cmd "save-all flush"
  fi
  if wait_for_save "$save_log_offset"; then
    if backup_now "manual"; then
      log "on-demand backup completed and verified"
    else
      log "ERROR on-demand backup did not complete"
    fi
  else
    log "ERROR save acknowledgement timed out; refusing to archive a possibly changing world"
  fi
  if [ "$EDITION" = "BEDROCK" ]; then
    send_cmd "save resume"
  else
    send_cmd "save-on"
  fi
}

while kill -0 "$SRV_PID" 2>/dev/null; do
  if [ -f "$STOP_FLAG" ]; then log "stop requested from the app"; break; fi
  if [ $(( $(date +%s) - JOB_STARTED )) -ge "$MAXSEC" ]; then log "cycle time limit reached"; break; fi
  if [ -f "$BACKUP_REQUEST_FLAG" ]; then perform_manual_backup; fi
  sleep 10
done

kill "$POLL_PID" "$HB_PID" 2>/dev/null || true
wait "$POLL_PID" "$HB_PID" 2>/dev/null || true

# Safe shutdown: flush and hold writes using edition-appropriate commands,
# verify the release backup, resume saves, then stop the server process.
publish_status stopping false "stopping"
SAVE_LOG_OFFSET="$(wc -c < "$DATA_ABS/server.log" 2>/dev/null || echo 0)"
if [ "$EDITION" = "BEDROCK" ]; then
  send_cmd "save hold"
  send_cmd "save query"
else
  send_cmd "save-off"
  send_cmd "save-all flush"
fi
if wait_for_save "$SAVE_LOG_OFFSET"; then
  if backup_now "cycle"; then BACKUP_DONE=true; fi
else
  log "ERROR save acknowledgement timed out; refusing to archive a possibly changing world"
fi
if [ "$EDITION" = "BEDROCK" ]; then
  send_cmd "save resume"
else
  send_cmd "save-on"
fi
send_cmd "stop"
for _ in $(seq 1 45); do kill -0 "$SRV_PID" 2>/dev/null || break; sleep 2; done
if kill -0 "$SRV_PID" 2>/dev/null; then log "server did not stop in time; killing"; kill -9 "$SRV_PID" 2>/dev/null || true; fi

exec 7>&- 2>/dev/null || true
if [ -n "$PLAYIT_PID" ]; then
  if kill -0 "$PLAYIT_PID" 2>/dev/null; then
    if [ "$PLAYIT_AGENT_STATUS" = "connected" ] || [ "$PLAYIT_AGENT_STATUS" = "starting" ]; then
      PLAYIT_AGENT_STATUS=stopped
      PLAYIT_AGENT_DIAGNOSTIC=cycle_ended
    fi
    kill "$PLAYIT_PID" 2>/dev/null || true
    wait "$PLAYIT_PID" 2>/dev/null || true
    PLAYIT_AGENT_EXIT_CODE=cycle_ended
    PLAYIT_AGENT_EXIT_CAPTURED=true
  elif [ "$PLAYIT_AGENT_STATUS" != "failed" ] && [ "$PLAYIT_AGENT_STATUS" != "not_started" ]; then
    record_playit_agent_exit
    PLAYIT_AGENT_STATUS=failed
    PLAYIT_AGENT_DIAGNOSTIC=process_exited
    TUNNEL_STATE=error
    TUNNEL_DIAGNOSTIC=agent_process_exited
    TUNNEL_MSG="The Playit Agent exited before the cycle ended (exit code ${PLAYIT_AGENT_EXIT_CODE})."
  fi
fi
if [ "$PLAYIT_AGENT_STATUS" = "stopped" ]; then
  TUNNEL_STATE=unknown
  TUNNEL_DIAGNOSTIC=cycle_ended
  TUNNEL_ADDR=""
  TUNNEL_MSG="The GitHub Actions server cycle ended; the Agent and live Tunnel are no longer running."
fi
SERVER_PORT_STATUS=unknown
export PLAYIT_AGENT_STATUS PLAYIT_AGENT_DIAGNOSTIC PLAYIT_AGENT_EXIT_CODE PLAYIT_SECRET_STATUS SERVER_PORT_STATUS GAME_PORT
export TUNNEL_STATE TUNNEL_MSG TUNNEL_DIAGNOSTIC TUNNEL_ADDR TUNNEL_NAME TUNNEL_ID TUNNEL_PROTO TUNNEL_ISSUE TUNNEL_LOCAL_IP TUNNEL_LOCAL_PORT AGENT_ID

publish_live "$DATA_ABS/server.log"
publish_files
tail -n 120 "$DATA_ABS/server.log" || true

if [ "$BACKUP_DONE" != "true" ]; then
  log "WARN no backup could be uploaded this cycle"
  publish_cycle_end failure "backup-failed"
  exit 1
fi

publish_cycle_end success "cycle-finished"

if [ ! -f "$STOP_FLAG" ] && [ "$AUTORESTART" = "true" ]; then
  log "dispatching the next cycle"
  gh workflow run novacraft-server.yml --repo "$REPO" --ref "$REF" -f action=start || \
    log "WARN could not dispatch the next cycle (time limit reached?)"
fi
