#!/bin/bash
# Keeper-owned template maintenance, only on explicit request.
# Usage: new <area>/<name> | add <area>/<name> <file>... [--replace old=new]...
#        index | check
# Requires python3; flat scalar front matter and inline [tags] (no YAML dependency).
set -euo pipefail
CONF="${FORGE_CONF_OVERRIDE:-$HOME/.claude/forge.conf}"
exec python3 - "$CONF" "$@" <<'PY'
import json, os, pathlib, re, shlex, subprocess, sys, tempfile
def fail(message):
    raise ValueError(message)
def contained(path):
    if not path.resolve().is_relative_to(vault):
        fail("path escapes VAULT_PATH: " + str(path))
    if path != vault and any(p.is_symlink() for p in [path, *path.parents] if p != vault):
        fail("symlink path refused: " + str(path))
    return path
def target(slug):
    if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*/[A-Za-z0-9_-][A-Za-z0-9_.-]*", slug):
        fail("expected contained <area>/<name>: " + slug)
    if ".." in slug.split("/") or slug.split("/")[0] == "_skeleton":
        fail("reserved or traversal path: " + slug)
    return contained(library / slug)
def metadata(path):
    lines = contained(path).read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "---" or "---" not in lines[1:]:
        fail("missing or unclosed front matter: " + str(path))
    values = {}
    for line in lines[1:lines[1:].index("---") + 1]:
        match = re.fullmatch(r"([a-z-]+):\s*(.+)", line)
        if not match or match[1] in values:
            fail("invalid or duplicate metadata: " + str(path))
        key, value = match.groups()
        value = value.strip()
        if value.startswith('"'): value = json.loads(value)
        elif value.startswith("'"):
            if not re.fullmatch(r"'(?:[^']|'')*'", value): fail("invalid quoted metadata: " + str(path))
            value = value[1:-1].replace("''", "'")
        elif key != "tags" and (value.lower() in ("null", "~", "true", "false") or value.startswith(("[", "{", "|", ">"))): fail("expected scalar metadata: " + str(path))
        if any(c in value for c in "\r\n\t"): fail("metadata must be single-line: " + str(path))
        if re.search(r"\{\{|[<>]|\b(?:TODO|TBD|CHANGE_ME|placeholder)\b", value, re.I):
            fail("placeholder metadata: " + str(path))
        values[key] = value
    for key in ("name", "summary", "when-to-use", "language", "tags"):
        if not values.get(key):
            fail("missing " + key + ": " + str(path))
    if not re.fullmatch(r"\[\s*[A-Za-z0-9_-]+(?:\s*,\s*[A-Za-z0-9_-]+)*\s*\]", values["tags"]):
        fail("tags must be a nonempty inline list: " + str(path))
    return values
def atomic(path, data):
    contained(path)
    if path.exists() and not path.is_file():
        fail("destination is not a file: " + str(path))
    fd, temporary = tempfile.mkstemp(prefix=".forge-template-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
        subprocess.run(["mv", "-f", temporary, str(path)], check=True, capture_output=True)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
def render():
    rows, problems = [], []
    for base, dirs, files in os.walk(library, followlinks=False, onerror=lambda error: problems.append(str(error))):
        dirs[:] = sorted(d for d in dirs if d != "_skeleton")
        for item in dirs + files:
            try:
                contained(pathlib.Path(base) / item)
            except ValueError as error:
                problems.append(str(error))
        if len(pathlib.Path(base).relative_to(library).parts) == 2 and "README.md" not in files:
            problems.append("template README.md missing: " + base)
        if "README.md" not in files or pathlib.Path(base) == library:
            continue
        path = pathlib.Path(base) / "README.md"
        slug = str(path.parent.relative_to(library))
        try:
            target(slug)
            info = metadata(path)
            rows.append("- [%s](%s/README.md) — %s; when: %s; language: %s; tags: %s" %
                        (info["name"], slug, info["summary"], info["when-to-use"], info["language"], info["tags"]))
        except (ValueError, OSError, UnicodeError) as error:
            problems.append(str(error))
    return ("# Shared templates\n\n" + "\n".join(sorted(rows)) + "\n").encode(), problems
try:
    config = pathlib.Path(sys.argv[1]).read_text()
    settings = re.findall(r"^VAULT_PATH=(.+)$", config, re.M)
    if len(settings) != 1: fail("forge.conf must define one VAULT_PATH")
    setting = shlex.split(settings[0])
    if len(setting) != 1: fail("invalid VAULT_PATH")
    vault = pathlib.Path(os.path.expandvars(os.path.expanduser(setting[0]))).resolve(strict=True)
    library = contained(vault / "PERSO/_shared/Templates")
    if not library.is_dir(): fail("template library missing: " + str(library))
    args = sys.argv[2:]
    if not args: fail("use new, add, index or check")
    command = args.pop(0)
    if command == "new" and len(args) == 1:
        destination = target(args[0])
        if destination.exists(): fail("template already exists")
        scaffold = contained(library / "_skeleton/README.md").read_bytes()
        parent_existed = destination.parent.exists()
        destination.mkdir(parents=True)
        try:
            atomic(destination / "README.md", scaffold)
        except Exception:
            destination.rmdir()
            if not parent_existed:
                destination.parent.rmdir()
            raise
    elif command == "add" and len(args) >= 2:
        destination = target(args.pop(0))
        metadata(destination / "README.md")
        replacements, sources, planned = [], [], []
        while args:
            item = args.pop(0)
            if item == "--replace":
                if not args or "=" not in args[0] or not args[0].split("=", 1)[0]:
                    fail("--replace requires nonempty old=new")
                replacements.append(args.pop(0).split("=", 1))
            else:
                sources.append(pathlib.Path(item))
        if not sources: fail("add requires source files")
        for source in sources:
            path = contained(destination / source.name)
            if not source.is_file() or path.exists() or path in [p for p, _ in planned]:
                fail("source missing, duplicate destination or overwrite: " + str(source))
            data = source.read_bytes()
            try:
                text = data.decode("utf-8")
                if "\0" not in text:
                    for old, new in replacements:
                        text = text.replace(old, new)
                    data = text.encode("utf-8")
            except UnicodeError:
                pass  # Binary files are copied byte-for-byte, never neutralised.
            planned.append((path, data))
        written = []
        try:
            for path, data in planned:
                atomic(path, data)
                written.append(path)
        except Exception:
            for path in written:
                path.unlink()
            raise
    elif command in ("index", "check") and not args:
        data, problems = render()
        index = contained(library / "INDEX.md")
        if command == "check" and (not index.is_file() or index.read_bytes() != data):
            problems.append("INDEX.md missing or stale; templates not indexed")
        if problems:
            fail("\n".join(problems))
        if command == "index":
            atomic(index, data)
    else:
        fail("invalid arguments; use new <area>/<name>, add <area>/<name> <files> [--replace old=new], index, check")
except (ValueError, OSError, UnicodeError, subprocess.SubprocessError) as error:
    print("[forge-template] ERROR: " + str(error), file=sys.stderr)
    sys.exit(1)
PY
