"""Vendor-neutral capability catalog; stdlib only and fail-closed."""
import datetime as dt
import json
import os
import shutil
import tempfile

SCHEMA_VERSION = 1
FRESHNESS_SECONDS = 24 * 60 * 60
TIERS = ("economy", "standard", "premium")
EVIDENCE_KINDS = ("declared", "public_benchmark", "passive")
EXIT_CODES = {"resolved": 0, "inherit": 1, "no_match": 2, "invalid": 3}

class CatalogError(ValueError):
    pass
class SnapshotError(CatalogError):
    pass

def _now():
    return dt.datetime.now(dt.timezone.utc)

def _timestamp(value, field="timestamp"):
    if not isinstance(value, str):
        raise SnapshotError(f"{field} must be RFC3339 text")
    try:
        parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise SnapshotError(f"{field} is not RFC3339") from exc
    if parsed.tzinfo is None:
        raise SnapshotError(f"{field} must include timezone")
    return parsed.astimezone(dt.timezone.utc)

def snapshot_path(vault_path=None):
    return os.path.join(vault_path or os.environ.get("VAULT_PATH", ""), "_shared", "capability-snapshot.json")

def _text(value, field):
    if not isinstance(value, str) or not value.strip():
        raise SnapshotError(f"{field} must be non-empty text")
    return value

def _validate_record(record, index):
    prefix = f"records[{index}]"
    if not isinstance(record, dict):
        raise SnapshotError(f"{prefix} must be an object")
    identity = record.get("identity")
    if not isinstance(identity, dict):
        raise SnapshotError(f"{prefix}.identity must be an object")
    _text(identity.get("id"), f"{prefix}.identity.id")
    _text(identity.get("vendor"), f"{prefix}.identity.vendor")
    if record.get("tier") not in TIERS:
        raise SnapshotError(f"{prefix}.tier is invalid")
    capabilities = record.get("capabilities")
    if not isinstance(capabilities, list) or any(not isinstance(x, str) or not x for x in capabilities):
        raise SnapshotError(f"{prefix}.capabilities is invalid")
    evidence = record.get("evidence")
    if not isinstance(evidence, list):
        raise SnapshotError(f"{prefix}.evidence must be a list")
    for j, item in enumerate(evidence):
        if not isinstance(item, dict) or item.get("kind") not in EVIDENCE_KINDS:
            raise SnapshotError(f"{prefix}.evidence[{j}] is invalid")
        if "captured_at" in item:
            _timestamp(item["captured_at"], f"{prefix}.evidence[{j}].captured_at")
        if "source" in item and not isinstance(item["source"], str):
            raise SnapshotError(f"{prefix}.evidence[{j}].source is invalid")
    bindings = record.get("bindings")
    if not isinstance(bindings, list):
        raise SnapshotError(f"{prefix}.bindings must be a list")
    for j, binding in enumerate(bindings):
        bp = f"{prefix}.bindings[{j}]"
        if not isinstance(binding, dict):
            raise SnapshotError(f"{bp} must be an object")
        _text(binding.get("runtime"), f"{bp}.runtime")
        if not isinstance(binding.get("active"), bool):
            raise SnapshotError(f"{bp}.active must be boolean")
        if binding.get("active"):
            _text(binding.get("dispatch_id"), f"{bp}.dispatch_id")
        if "captured_at" in binding:
            _timestamp(binding["captured_at"], f"{bp}.captured_at")

def validate_snapshot(data, now=None):
    if not isinstance(data, dict) or data.get("schema_version") != SCHEMA_VERSION:
        raise SnapshotError("missing or incompatible schema_version")
    captured = _timestamp(data.get("captured_at"), "captured_at")
    clock = data.get("clock")
    if not isinstance(clock, dict) or clock.get("source") not in ("system", "manual"):
        raise SnapshotError("explicit clock metadata is required")
    if not isinstance(clock.get("timezone", "UTC"), str):
        raise SnapshotError("clock.timezone is invalid")
    if not isinstance(data.get("records"), list) or not isinstance(data.get("outcomes"), list):
        raise SnapshotError("records and outcomes must be lists")
    for i, outcome in enumerate(data["outcomes"]):
        prefix = f"outcomes[{i}]"
        if not isinstance(outcome, dict):
            raise SnapshotError(f"{prefix} must be an object")
        _text(outcome.get("status"), f"{prefix}.status")
        if outcome["status"] not in ("available", "unavailable", "error", "skipped"):
            raise SnapshotError(f"{prefix}.status is invalid")
        if "record_id" in outcome:
            _text(outcome["record_id"], f"{prefix}.record_id")
        if "kind" in outcome and outcome["kind"] not in ("catalog", "refresh", "probe"):
            raise SnapshotError(f"{prefix}.kind is invalid")
        if "captured_at" in outcome:
            _timestamp(outcome["captured_at"], f"{prefix}.captured_at")
        if "error" in outcome and not isinstance(outcome["error"], str):
            raise SnapshotError(f"{prefix}.error is invalid")
    migration = data.get("migration")
    if not isinstance(migration, dict):
        raise SnapshotError("migration metadata is required")
    _text(migration.get("status"), "migration.status")
    if migration["status"] not in ("none", "manual", "complete", "pending"):
        raise SnapshotError("migration.status is invalid")
    for field in ("backup", "source"):
        if field in migration and not isinstance(migration[field], str):
            raise SnapshotError(f"migration.{field} is invalid")
    for field in ("roles", "pending"):
        if field in migration:
            values = migration[field]
            if not isinstance(values, dict):
                raise SnapshotError(f"migration.{field} must be an object")
            for role, value in values.items():
                _text(role, f"migration.{field} role")
                if isinstance(value, str):
                    # Compact role entries may use only a neutral tier (or the
                    # explicit pending marker). Pending entries themselves are
                    # structured records so arbitrary legacy-model strings can
                    # never masquerade as migration metadata.
                    if field != "roles" or value not in TIERS + ("inherit", "pending"):
                        raise SnapshotError(f"migration.{field}.{role} is invalid")
                    continue
                if not isinstance(value, dict):
                    raise SnapshotError(f"migration.{field}.{role} is invalid")
                if isinstance(value, dict):
                    allowed = {"tier", "status", "legacy_model"}
                    if set(value) - allowed:
                        raise SnapshotError(f"migration.{field}.{role} has unknown fields")
                    if "tier" in value and value["tier"] not in TIERS + ("inherit", "pending"):
                        raise SnapshotError(f"migration.{field}.{role}.tier is invalid")
                    if "status" in value and value["status"] not in ("pending", "migrated", "inherit"):
                        raise SnapshotError(f"migration.{field}.{role}.status is invalid")
                    if "legacy_model" in value and not isinstance(value["legacy_model"], str):
                        raise SnapshotError(f"migration.{field}.{role}.legacy_model is invalid")
    reference = now or _now()
    if reference.tzinfo is None:
        reference = reference.replace(tzinfo=dt.timezone.utc)
    age = (reference.astimezone(dt.timezone.utc) - captured).total_seconds()
    if age < 0 or age > FRESHNESS_SECONDS:
        raise SnapshotError("snapshot is stale or from the future")
    for i, record in enumerate(data["records"]):
        _validate_record(record, i)
    return data

def load_snapshot(path=None, now=None):
    try:
        with open(path or snapshot_path(), encoding="utf-8") as stream:
            data = json.load(stream)
    except (OSError, ValueError) as exc:
        raise SnapshotError("snapshot unavailable or malformed") from exc
    return validate_snapshot(data, now)

def write_snapshot(data, path=None):
    validate_snapshot(data)
    path = path or snapshot_path()
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".capability-snapshot.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        dfd = os.open(directory, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def publish_manual(input_path, output_path=None):
    with open(input_path, encoding="utf-8") as stream:
        data = json.load(stream)
    if not isinstance(data, dict):
        raise SnapshotError("manual catalog input must be an object")
    data.setdefault("schema_version", SCHEMA_VERSION)
    data.setdefault("captured_at", _now().isoformat().replace("+00:00", "Z"))
    data.setdefault("clock", {"source": "manual", "timezone": "UTC"})
    data.setdefault("records", [])
    data.setdefault("outcomes", [])
    data.setdefault("migration", {"status": "manual"})
    write_snapshot(data, output_path)
    return data

def resolve(snapshot, tier="inherit", required_capabilities=(), role=None, active_binding=None):
    if tier == "inherit":
        return {"status": "inherit", "tier": "inherit", "record": None}
    if tier not in TIERS:
        return {"status": "no_match", "tier": tier, "record": None, "reason": "invalid tier"}
    candidates = []
    for record in snapshot.get("records", []):
        if record["tier"] != tier or not set(required_capabilities).issubset(record["capabilities"]):
            continue
        for binding in record["bindings"]:
            if active_binding is not None and binding["runtime"] != active_binding:
                continue
            if binding["active"]:
                candidates.append((record, binding))
    if not candidates:
        return {"status": "no_match", "tier": tier, "record": None}
    candidates.sort(key=lambda x: (x[0]["identity"]["vendor"], x[0]["identity"]["id"], x[1]["runtime"], x[1]["dispatch_id"]))
    record, binding = candidates[0]
    return {"status": "resolved", "tier": tier, "record": record, "dispatch_id": binding["dispatch_id"], "binding": binding}

def tier_from_config(config_path, role):
    """Read one neutral tier without sourcing shell configuration."""
    role_key = "MODEL_TIER_" + _text(role, "role").upper()
    for key, value in _read_config(config_path):
        if key == role_key:
            if value not in TIERS + ("inherit", "pending"):
                raise SnapshotError(f"{role_key} is invalid")
            return value
    return "inherit"

def _read_config(path):
    entries = []
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            stripped = line.rstrip("\n")
            if not stripped or stripped.lstrip().startswith("#") or "=" not in stripped:
                entries.append((None, stripped))
                continue
            key, value = stripped.split("=", 1)
            entries.append((key, value))
    return entries

def migrate_config(config_path, metadata_path=None):
    """Safely migrate MODEL_* without sourcing, overwriting, or deleting keys."""
    entries = _read_config(config_path)
    keys = {key for key, _ in entries if key}
    roles = {}
    pending = {}
    for key, value in entries:
        if not key or not key.startswith("MODEL_") or key.startswith("MODEL_TIER_"):
            continue
        role = key[6:].lower()
        if value == "":
            tier = "inherit"
        elif value in TIERS:
            tier = value
        else:
            tier = "pending"
            pending[role] = {"legacy_model": value, "status": "pending"}
        roles[role] = tier
    backup = config_path + ".pre-model-catalog"
    if not os.path.exists(backup):
        shutil.copy2(config_path, backup)
    additions = []
    for role, tier in sorted(roles.items()):
        key = "MODEL_TIER_" + role.upper()
        if key not in keys:
            additions.append(f"{key}={tier}")
    if additions:
        with open(config_path, "a", encoding="utf-8") as stream:
            stream.write("\n" + "\n".join(additions) + "\n")
    metadata_path = metadata_path or os.path.join(os.path.dirname(config_path), "forge-model-migration.json")
    metadata = {"schema_version": 1, "status": "complete", "backup": backup, "roles": roles, "pending": pending}
    fd, temporary = tempfile.mkstemp(prefix=".forge-model-migration.", dir=os.path.dirname(os.path.abspath(metadata_path)))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(metadata, stream, sort_keys=True, indent=2); stream.write("\n"); stream.flush(); os.fsync(stream.fileno())
        os.replace(temporary, metadata_path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    return metadata
