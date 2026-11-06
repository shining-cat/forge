#!/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
TMP="$(mktemp -d "$ROOT/.template-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export FORGE_CONF_OVERRIDE="$TMP/forge.conf"
mkdir -p "$TMP/vault/PERSO/_shared/Templates/_skeleton"
printf 'VAULT_PATH=%s\n' "$TMP/vault" | python3 -c 'import sys; open(sys.argv[1], "w").write(sys.stdin.read())' "$FORGE_CONF_OVERRIDE"
LIB="$TMP/vault/PERSO/_shared/Templates"
cp "$ROOT/core/vault-templates/shared-template.md" "$LIB/_skeleton/README.md"
run() { /bin/bash "$HERE/../forge-template.sh" "$@"; }
reject() {
  if run "$@"; then echo "FAIL: accepted $*"; exit 1; fi
}
run new helpers/demo
reject new helpers/demo
reject add helpers/demo "$FORGE_CONF_OVERRIDE"
reject index
reject check
python3 - "$LIB" "$TMP" <<'PY'
import pathlib, sys
lib, tmp = map(pathlib.Path, sys.argv[1:])
readme = lib / "helpers/demo/README.md"
readme.write_text("---\nname: demo\nsummary: Safe helper\nwhen-to-use: Suspending work\nlanguage: Kotlin\ntags: [coroutines, helper]\n---\n# Demo\n")
(lib / "README.md").write_text("Library introduction without metadata\n")
(tmp / "Source.kt").write_bytes(b"package old.pkg\n")
(tmp / "image.png").write_bytes(b"\x89PNG\x00old.pkg\xff")
PY
run add helpers/demo "$TMP/Source.kt" "$TMP/image.png" --replace old.pkg=com.example
cmp "$TMP/image.png" "$LIB/helpers/demo/image.png"
grep -q 'package com.example' "$LIB/helpers/demo/Source.kt"
reject add helpers/demo "$TMP/Source.kt"
reject add helpers/demo "$TMP/Source.kt" --replace =bad
run index
grep -q 'demo.*helpers/demo/README.md.*Safe helper' "$LIB/INDEX.md"
test "$(grep -c '^- ' "$LIB/INDEX.md")" -eq 1
run check
cp "$LIB/helpers/demo/README.md" "$TMP/metadata"
for invalid in 'tags: []' 'language:' 'summary: TODO' 'name: duplicate' 'summary: null' 'summary: "unclosed'; do
  printf '%s\n' "$invalid" | python3 -c 'import re,sys; p=sys.argv[1]; s=open(p).read(); v=sys.stdin.read(); k=v.split(":")[0]; open(p,"w").write(s.replace("---\n# Demo",v+"---\n# Demo") if k=="name" else re.sub("^"+k+":.*\n",v,s,flags=re.M))' "$LIB/helpers/demo/README.md"
  reject index
  cp "$TMP/metadata" "$LIB/helpers/demo/README.md"
done
cp "$LIB/INDEX.md" "$TMP/previous"
run new helpers/incomplete
reject index
cmp "$TMP/previous" "$LIB/INDEX.md"
reject check
rm -rf "$LIB/helpers/incomplete"
reject new ../escape
reject new /absolute/path
ln -s "$TMP" "$LIB/escape"
reject new escape/demo
reject index
cmp "$TMP/previous" "$LIB/INDEX.md"
rm "$LIB/escape"
mkdir -p "$LIB/helpers/no-readme"
reject check
rm -r "$LIB/helpers/no-readme"
mkdir "$TMP/bin"
# Force the atomic rename to fail, including when the tests run as root.
printf '#!/bin/sh\ncase "$3" in */metadata) exec /bin/mv "$@";; *) exit 1;; esac\n' | python3 -c 'import sys; open(sys.argv[1], "w").write(sys.stdin.read())' "$TMP/bin/mv"
chmod +x "$TMP/bin/mv"
if PATH="$TMP/bin:$PATH" run index; then echo "FAIL: rename failure accepted"; exit 1; fi
cmp "$TMP/previous" "$LIB/INDEX.md"
if PATH="$TMP/bin:$PATH" run new atomic/failure; then exit 1; fi
test ! -e "$LIB/atomic"
if PATH="$TMP/bin:$PATH" run add helpers/demo "$TMP/metadata" "$FORGE_CONF_OVERRIDE"; then exit 1; fi
test ! -e "$LIB/helpers/demo/forge.conf" && test ! -e "$LIB/helpers/demo/metadata"
run check
cmp "$TMP/previous" "$LIB/INDEX.md"
echo "PASS: scaffold, metadata, add, replacement, binary, containment and atomic index"
