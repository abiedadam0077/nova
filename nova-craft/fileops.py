#!/usr/bin/env python3
"""NOVA CRAFT server file operations.

Runs on the GitHub runner, inside/below the server data folder ONLY.
Every path is resolved and checked against the data root; anything that
escapes it is rejected (no traversal, no symlink escape).

Modes
  manifest <root> <out.json>
  request  <root> <request.json> <response.json>
  addons   <data_root> <addons_dir> <state.json> <out.json>
  import   <data_root> <zip> <world_name> <out.json>
"""
import base64
import json
import os
import re
import shutil
import sys
import tempfile
import time
import zipfile

MAX_READ = 700 * 1024
MAX_MANIFEST_ENTRIES = 4000
SKIP_DIRS = {"libraries", "versions", ".fabric", "cache", ".cache", "tmp", "crash-reports"}


def safe_data_root(root):
    root_abs = os.path.abspath(root)
    if os.path.islink(root_abs) or not os.path.isdir(root_abs):
        raise ValueError("unsafe data root")
    root_real = os.path.realpath(root_abs)
    if not os.path.isdir(root_real):
        raise ValueError("unsafe data root")
    return root_real


def safe_path(root, rel):
    root_real = safe_data_root(root)
    if rel is None or rel == "":
        return root_real
    if not isinstance(rel, str) or rel != rel.strip():
        raise ValueError("path-outside-root")
    normalized = rel.replace("\\", "/")
    if normalized == ".":
        return root_real
    parts = normalized.split("/")
    if (normalized.startswith("/") or any(part in ("", ".", "..") for part in parts)
            or re.match(r"^[A-Za-z]:", parts[0])):
        raise ValueError("path-outside-root")
    candidate = os.path.realpath(os.path.join(root_real, *parts))
    if candidate != root_real and not candidate.startswith(root_real + os.sep):
        raise ValueError("path-outside-root")
    return candidate


def manifest(root):
    root_real = safe_data_root(root)
    files = []
    dirs = []
    truncated = False
    for dirpath, dirnames, filenames in os.walk(root_real, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not os.path.islink(os.path.join(dirpath, d))]
        rel_dir = os.path.relpath(dirpath, root_real).replace(os.sep, "/")
        if rel_dir != ".":
            dirs.append(rel_dir)
        for name in filenames:
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            try:
                st = os.stat(full)
            except OSError:
                continue
            rel = os.path.relpath(full, root_real).replace(os.sep, "/")
            files.append({"path": rel, "size": st.st_size, "modified": int(st.st_mtime)})
            if len(files) >= MAX_MANIFEST_ENTRIES:
                truncated = True
                break
        if truncated:
            break
    files.sort(key=lambda f: f["path"])
    dirs.sort()
    return {
        "schema": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "files": files,
        "dirs": dirs,
        "truncated": truncated,
    }


def _ok(**kwargs):
    out = {"ok": True}
    out.update(kwargs)
    return out


def _fail(code):
    return {"ok": False, "error": code}


def atomic_write_bytes(path, data):
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".nova-craft-", dir=parent)
    try:
        with os.fdopen(fd, "wb") as handle_file:
            handle_file.write(data)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def atomic_write_json(path, payload):
    data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    atomic_write_bytes(path, data)


def handle(root, request):
    op = (request.get("op") or "").lower()
    if op == "list":
        target = safe_path(root, request.get("path") or ".")
        if not os.path.isdir(target):
            return _fail("not-a-directory")
        rel_base = os.path.relpath(target, os.path.realpath(root)).replace(os.sep, "/")
        if rel_base == ".":
            rel_base = ""
        entries = []
        for name in sorted(os.listdir(target)):
            full = os.path.join(target, name)
            if os.path.islink(full):
                continue
            st = os.stat(full)
            entries.append({
                "name": name,
                "path": (rel_base + "/" + name).lstrip("/"),
                "dir": os.path.isdir(full),
                "size": 0 if os.path.isdir(full) else st.st_size,
                "modified": int(st.st_mtime),
            })
        return _ok(path=rel_base, files=entries)
    if op == "read":
        target = safe_path(root, request.get("path") or "")
        if not os.path.isfile(target):
            return _fail("not-a-file")
        size = os.path.getsize(target)
        with open(target, "rb") as handle_file:
            data = handle_file.read(MAX_READ)
        return _ok(
            path=os.path.relpath(target, os.path.realpath(root)).replace(os.sep, "/"),
            size=size,
            truncated=size > len(data),
            content=base64.b64encode(data).decode(),
        )
    if op == "write":
        target = safe_path(root, request.get("path") or "")
        if not request.get("path"):
            return _fail("missing-path")
        data = base64.b64decode(request.get("content") or "")
        if len(data) > 2 * 1024 * 1024:
            return _fail("too-large")
        os.makedirs(os.path.dirname(target) or os.path.realpath(root), exist_ok=True)
        # A fixed sibling temporary name could be pre-created as a symlink to
        # a file outside the server data root. mkstemp uses O_EXCL and a random
        # name, then replace atomically installs the new file.
        atomic_write_bytes(target, data)
        return _ok(path=os.path.relpath(target, os.path.realpath(root)).replace(os.sep, "/"), size=len(data))
    if op == "mkdir":
        target = safe_path(root, request.get("path") or "")
        if not request.get("path"):
            return _fail("missing-path")
        os.makedirs(target, exist_ok=True)
        return _ok(path=request.get("path"))
    if op == "rename":
        src = safe_path(root, request.get("path") or "")
        dest = safe_path(root, request.get("dest") or "")
        if not request.get("path") or not request.get("dest"):
            return _fail("missing-path")
        if not os.path.exists(src):
            return _fail("not-found")
        if os.path.exists(dest):
            return _fail("destination-exists")
        os.makedirs(os.path.dirname(dest) or root, exist_ok=True)
        os.replace(src, dest)
        return _ok(path=request.get("dest"))
    if op == "delete":
        target = safe_path(root, request.get("path") or "")
        if not request.get("path"):
            return _fail("missing-path")
        if os.path.isdir(target):
            shutil.rmtree(target)
        elif os.path.exists(target):
            os.remove(target)
        else:
            return _fail("not-found")
        return _ok(path=request.get("path"))
    return _fail("unknown-op")


def _zip_safe(zf, base):
    for member in zf.namelist():
        normalized = os.path.normpath(member).replace("\\", "/")
        if normalized.startswith("..") or normalized.startswith("/") or ":" in normalized.split("/")[0]:
            raise ValueError("unsafe-archive-entry")
    zf.extractall(base)


def _read_pack_manifest(path):
    if os.path.isdir(path):
        manifest_path = os.path.join(path, "manifest.json")
        with open(manifest_path, "r", encoding="utf-8") as handle_file:
            data = json.load(handle_file)
        return _pack_info(data, path)
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        manifest_name = None
        for candidate in names:
            normalized = candidate.replace("\\", "/")
            if normalized.endswith("manifest.json") and normalized.count("/") <= 1:
                manifest_name = candidate
                break
        if manifest_name is None:
            raise ValueError("missing-manifest")
        raw = zf.read(manifest_name).decode("utf-8", "replace")
        return _pack_info(json.loads(raw), path)


def _pack_info(data, path):
    header = data.get("header") or {}
    modules = data.get("modules") or []
    kinds = {m.get("type") for m in modules if isinstance(m, dict)}
    if "data" in kinds:
        kind = "behavior"
    elif "resources" in kinds:
        kind = "resource"
    elif "script" in kinds:
        kind = "behavior"
    else:
        raise ValueError("unknown-pack-type")
    version = header.get("version") or [1, 0, 0]
    if isinstance(version, str):
        version = [int(x) for x in version.split(".") if x.isdigit()] or [1, 0, 0]
    return {
        "uuid": str(header.get("uuid") or ""),
        "name": str(header.get("name") or os.path.basename(path)),
        "version": version,
        "kind": kind,
    }


def apply_addons(data_root, addons_dir, state_path):
    """Install enabled packs and register them on the world.

    Toggles in the app write `enabled`, and this function is what makes that
    change real: it extracts the pack and rewrites world_behavior_packs.json /
    world_resource_packs.json for the selected world. `.mcaddon` bundles are
    expanded into their individual packs first.
    """
    result = {"ok": True, "installed": [], "skipped": []}
    try:
        with open(state_path, "r", encoding="utf-8") as handle_file:
            state = json.load(handle_file)
    except (OSError, ValueError):
        return {"ok": True, "installed": [], "skipped": [], "note": "no-addon-state"}
    world = state.get("world") or "Bedrock level"
    if "/" in world or "\\" in world or world in (".", ".."):
        world = "Bedrock level"
    level = safe_path(data_root, os.path.join("worlds", world))
    active = {"behavior": [], "resource": []}
    staging = os.path.join(addons_dir, ".staging")
    shutil.rmtree(staging, ignore_errors=True)
    for pack in state.get("packs") or []:
        if not isinstance(pack, dict):
            continue
        rel = pack.get("file") or ""
        src = os.path.join(addons_dir, os.path.basename(rel))
        if not os.path.isfile(src):
            result["skipped"].append({"file": rel, "reason": "missing-file"})
            continue
        enabled = bool(pack.get("enabled", True))
        sources = []
        if src.lower().endswith(".mcaddon"):
            bundle_dir = os.path.join(staging, os.path.splitext(os.path.basename(src))[0])
            try:
                with zipfile.ZipFile(src) as zf:
                    _zip_safe(zf, bundle_dir)
            except (ValueError, zipfile.BadZipFile) as error:
                result["skipped"].append({"file": rel, "reason": str(error)})
                continue
            for dirpath, _dirnames, filenames in os.walk(bundle_dir):
                if "manifest.json" in filenames:
                    sources.append(dirpath)
        else:
            sources.append(src)
        if not sources:
            result["skipped"].append({"file": rel, "reason": "no-pack-inside"})
            continue
        for source in sources:
            try:
                info = _read_pack_manifest(source)
            except (ValueError, zipfile.BadZipFile, json.JSONDecodeError) as error:
                result["skipped"].append({"file": rel, "reason": str(error)})
                continue
            folder = info["kind"] + "_packs"
            stem = os.path.splitext(os.path.basename(src))[0]
            if len(sources) > 1:
                stem = "%s-%s" % (stem, info["uuid"][:8])
            dest = safe_path(data_root, os.path.join(folder, stem))
            if enabled:
                shutil.rmtree(dest, ignore_errors=True)
                os.makedirs(dest, exist_ok=True)
                try:
                    if os.path.isdir(source):
                        if os.path.exists(dest):
                            shutil.rmtree(dest)
                        shutil.copytree(source, dest)
                    else:
                        with zipfile.ZipFile(source) as zf:
                            _zip_safe(zf, dest)
                except (ValueError, zipfile.BadZipFile, OSError) as error:
                    result["skipped"].append({"file": rel, "reason": str(error)})
                    continue
                active[info["kind"]].append({"pack_id": info["uuid"], "version": info["version"]})
                result["installed"].append({"file": rel, "kind": info["kind"], "uuid": info["uuid"], "name": info["name"]})
            else:
                shutil.rmtree(dest, ignore_errors=True)
                result["installed"].append({"file": rel, "kind": info["kind"], "uuid": info["uuid"], "name": info["name"], "disabled": True})
    shutil.rmtree(staging, ignore_errors=True)
    if os.path.isdir(level):
        for kind, entries in active.items():
            path = os.path.join(level, "world_%s_packs.json" % kind)
            with open(path, "w", encoding="utf-8") as handle_file:
                json.dump(entries, handle_file, indent=2)
    else:
        result["note"] = "world-not-generated-yet"
    result["world"] = world
    result["enabledCount"] = len(active["behavior"]) + len(active["resource"])
    return result


def import_world(data_root, archive, name):
    if not zipfile.is_zipfile(archive):
        return {"ok": False, "error": "not-a-zip"}
    with zipfile.ZipFile(archive) as zf:
        names = zf.namelist()
        has_level = any(n.replace("\\", "/").endswith("level.dat") for n in names)
        has_db = any(n.replace("\\", "/").split("/")[0] == "db" or "/db/" in n.replace("\\", "/") for n in names)
    if not has_level:
        return {"ok": False, "error": "missing-level-dat"}
    if not has_db:
        return {"ok": False, "error": "missing-world-db"}
    target = safe_path(data_root, os.path.join("worlds", name))
    if os.path.isdir(target):
        return {"ok": False, "error": "world-already-exists"}
    os.makedirs(target, exist_ok=True)
    try:
        with zipfile.ZipFile(archive) as zf:
            _zip_safe(zf, target)
    except ValueError as error:
        shutil.rmtree(target, ignore_errors=True)
        return {"ok": False, "error": str(error)}
    return {"ok": True, "world": name, "path": "worlds/" + name}


TEXT_EXT = {
    ".txt", ".properties", ".json", ".yml", ".yaml", ".toml", ".cfg", ".conf", ".ini",
    ".log", ".md", ".sh", ".bat", ".xml", ".csv", ".mcmeta", ".snbt", ".list",
}
SNAPSHOT_LIMIT = 64 * 1024
SNAPSHOT_MAX_FILES = 150
SNAPSHOT_MAX_BYTES = 3 * 1024 * 1024


def snapshot(root, out_path):
    """Publish small, editable text files as one JSON document.

    This is what makes "edit while the server is stopped" honest: the runner
    publishes the current contents, the app edits the JSON, and the runner
    re-applies it on top of the restored cache before the next start.
    """
    root_real = safe_data_root(root)
    files = {}
    total = 0
    truncated = False
    for dirpath, dirnames, filenames in os.walk(root_real, followlinks=False):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not os.path.islink(os.path.join(dirpath, d))]
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            if os.path.islink(full):
                continue
            ext = os.path.splitext(name)[1].lower()
            if ext not in TEXT_EXT:
                continue
            try:
                size = os.path.getsize(full)
            except OSError:
                continue
            if size > SNAPSHOT_LIMIT or size == 0:
                continue
            if total + size > SNAPSHOT_MAX_BYTES or len(files) >= SNAPSHOT_MAX_FILES:
                truncated = True
                break
            rel = os.path.relpath(full, root_real).replace(os.sep, "/")
            try:
                with open(full, "rb") as handle_file:
                    files[rel] = base64.b64encode(handle_file.read()).decode()
            except OSError:
                continue
            total += size
        if truncated:
            break
    payload = {
        "schema": 1,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "truncated": truncated,
        "files": files,
    }
    atomic_write_json(out_path, payload)
    return payload


def apply_snapshot(root, snap_path):
    """Apply repository-side edits on top of the restored cache."""
    try:
        with open(snap_path, "r", encoding="utf-8") as handle_file:
            payload = json.load(handle_file)
    except (OSError, ValueError):
        return {"ok": True, "applied": 0}
    applied = 0
    for rel, encoded in (payload.get("files") or {}).items():
        dest = safe_path(root, rel)
        os.makedirs(os.path.dirname(dest) or os.path.realpath(root), exist_ok=True)
        atomic_write_bytes(dest, base64.b64decode(encoded))
        applied += 1
    return {"ok": True, "applied": applied}


def main(argv):
    if len(argv) < 3:
        print("usage: fileops.py <mode> ...", file=sys.stderr)
        return 2
    mode = argv[1]
    if mode == "manifest":
        root, out = argv[2], argv[3]
        root = safe_data_root(root)
        data = manifest(root)
        atomic_write_json(out, data)
        print("manifest %d files" % len(data["files"]))
        return 0
    if mode == "request":
        root, request_path, response_path = argv[2], argv[3], argv[4]
        root = safe_data_root(root)
        try:
            with open(request_path, "r", encoding="utf-8") as handle_file:
                request = json.load(handle_file)
        except (OSError, ValueError):
            request = {}
        request_id = request.get("id")
        try:
            response = handle(root, request)
        except ValueError as error:
            response = _fail(str(error))
        except OSError as error:
            response = _fail("os-error: %s" % error.strerror)
        response["id"] = request_id
        with open(response_path, "w", encoding="utf-8") as handle_file:
            json.dump(response, handle_file, separators=(",", ":"))
        print("request %s -> ok=%s" % (request.get("op"), response.get("ok")))
        return 0
    if mode == "addons":
        data_root, addons_dir, state_path, out = argv[2], argv[3], argv[4], argv[5]
        result = apply_addons(data_root, addons_dir, state_path)
        with open(out, "w", encoding="utf-8") as handle_file:
            json.dump(result, handle_file, separators=(",", ":"))
        print("addons installed=%d skipped=%d" % (len(result["installed"]), len(result["skipped"])))
        return 0
    if mode == "snapshot":
        root, out_path = argv[2], argv[3]
        result = snapshot(root, out_path)
        print("snapshot %d files" % len(result["files"]))
        return 0
    if mode == "apply-snapshot":
        root, snap_path = argv[2], argv[3]
        print("apply-snapshot", apply_snapshot(root, snap_path))
        return 0
    if mode == "import":
        data_root, archive, name, out = argv[2], argv[3], argv[4], argv[5]
        result = import_world(data_root, archive, name)
        with open(out, "w", encoding="utf-8") as handle_file:
            json.dump(result, handle_file, separators=(",", ":"))
        print("import -> %s" % result)
        return 0
    print("unknown mode", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
