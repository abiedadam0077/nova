#!/usr/bin/env python3
"""Expose nova-craft/server.json values as GitHub step outputs."""
import json
import os
import re
import sys

with open("nova-craft/server.json", "r", encoding="utf-8") as handle:
    cfg = json.load(handle)

data_path = cfg.get("dataPath") or "server"
if not isinstance(data_path, str):
    raise SystemExit("unsafe server dataPath")
path_parts = data_path.split("/")
if (data_path.startswith("/") or any(part in ("", ".", "..") or not re.fullmatch(r"[A-Za-z0-9._-]+", part) for part in path_parts)
        or path_parts[0] in (".git", ".github", "nova-craft")):
    raise SystemExit("unsafe server dataPath")
workspace = os.path.realpath(os.getcwd())
resolved_data_path = os.path.realpath(os.path.join(workspace, data_path))
if resolved_data_path != os.path.join(workspace, data_path):
    raise SystemExit("server dataPath cannot traverse a symbolic link")

sid = cfg.get("id")
if not isinstance(sid, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,80}", sid):
    raise SystemExit("unsafe server id")
edition = cfg.get("edition", "JAVA")
software = cfg.get("software", "VANILLA")
if not isinstance(edition, str) or edition.upper() not in ("JAVA", "BEDROCK"):
    raise SystemExit("unsupported server edition")
if not isinstance(software, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", software):
    raise SystemExit("unsafe server software")
edition = edition.upper()
software = software.upper()
try:
    java_major = int(cfg.get("javaMajor", 21))
    memory_mb = int(cfg.get("memoryMb", 4096))
except (TypeError, ValueError):
    raise SystemExit("invalid server runtime settings")
if not 8 <= java_major <= 99 or not 512 <= memory_mb <= 65536:
    raise SystemExit("server runtime settings are outside safe bounds")


def truthy(value):
    return "true" if value else "false"


def write_properties():
    """Regenerate server.properties (and eula.txt) from server.json.

    The Actions cache restores the whole data folder, so values committed in the
    repository could otherwise be overwritten by an older cached copy. Writing
    them again after the restore makes the app's settings authoritative.
    """
    root = data_path
    os.makedirs(root, exist_ok=True)
    bedrock = edition == "BEDROCK"
    if bedrock:
        lines = [
            "server-name=%s" % cfg.get("name", "NOVA CRAFT"),
            "gamemode=%s" % cfg.get("gamemode", "survival"),
            "force-gamemode=false",
            "difficulty=%s" % cfg.get("difficulty", "normal"),
            "allow-cheats=false",
            "max-players=%s" % cfg.get("maxPlayers", 20),
            "online-mode=%s" % truthy(cfg.get("onlineMode", True)),
            "allow-list=%s" % truthy(cfg.get("whiteList", False)),
            "server-port=19132",
            "server-portv6=19133",
            "enable-lan-visibility=false",
            "view-distance=%s" % cfg.get("viewDistance", 10),
            "level-name=Bedrock level",
            "level-seed=%s" % cfg.get("seed", ""),
        ]
    else:
        lines = [
            "#Minecraft server properties (managed by NOVA CRAFT)",
            "level-seed=%s" % cfg.get("seed", ""),
            "gamemode=%s" % cfg.get("gamemode", "survival"),
            "level-name=world",
            "motd=%s" % cfg.get("motd", "A NOVA CRAFT Server"),
            "pvp=%s" % truthy(cfg.get("pvp", True)),
            "difficulty=%s" % cfg.get("difficulty", "normal"),
            "max-players=%s" % cfg.get("maxPlayers", 20),
            "online-mode=%s" % truthy(cfg.get("onlineMode", True)),
            "view-distance=%s" % cfg.get("viewDistance", 10),
            "simulation-distance=%s" % cfg.get("simulationDistance", 10),
            "server-port=25565",
            "white-list=%s" % truthy(cfg.get("whiteList", False)),
            "enforce-whitelist=%s" % truthy(cfg.get("whiteList", False)),
            "allow-nether=true",
            "spawn-animals=true",
            "spawn-monsters=true",
            "spawn-npcs=true",
        ]
    with open(os.path.join(root, "server.properties"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")
    if not bedrock:
        eula_path = os.path.join(root, "eula.txt")
        if cfg.get("eulaAccepted"):
            with open(eula_path, "w", encoding="utf-8") as handle:
                handle.write("eula=true\n")
        elif os.path.exists(eula_path):
            os.remove(eula_path)


if "--write-props" in sys.argv:
    write_properties()
    sys.exit(0)

out = os.environ["GITHUB_OUTPUT"]
values = {
    "sid": sid,
    "edition": edition,
    "javamajor": str(java_major),
    "data": data_path,
    "software": software,
    "memory": str(memory_mb),
    "eula": "true" if cfg.get("eulaAccepted") else "false",
    "allowcommands": "true" if cfg.get("allowCommands", True) else "false",
    "backupretention": str(max(2, min(30, int(cfg.get("backupRetention", 10))))),
}
with open(out, "a", encoding="utf-8") as handle:
    for key, value in values.items():
        handle.write(f"{key}={value}\n")
print("config:", {k: v for k, v in values.items() if k != "sid"})
