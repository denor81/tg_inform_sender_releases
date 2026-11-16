#!/usr/bin/env bash
set -euo pipefail

REPOSITORY="denor81/tg_inform_sender_releases"
SIGNER_WORKFLOW="denor81/tg_inform_sender_releases/.github/workflows/attest-release.yml"
GH_VERSION="2.104.0"
GH_AMD64_SHA256="98cb101ad87dbbd3f6b2f2bfcbd43197ccd07643140121d8a9cfaa91eadbc24e"
MAX_METADATA_BYTES=2097152
MAX_ARTIFACT_BYTES=536870912
CHANNEL="stable"
REQUESTED_VERSION=""
LIST_ONLY=false

fail() { echo "Public installation blocked: $*" >&2; exit 1; }
usage() {
    cat <<'EOF'
Usage: install.sh [--channel stable|rc] [--version vX.Y.Z[-rc.N]] [--list]

With no arguments, installs the latest stable signed public release.
--channel rc allows release candidates; --version selects one exact release.
--list prints available signed release records without installing anything.
EOF
}

while (($#)); do
    case "$1" in
        --channel)
            (($# >= 2)) || fail "--channel requires stable or rc"
            CHANNEL="$2"; shift
            [[ "$CHANNEL" == stable || "$CHANNEL" == rc ]] || fail "invalid channel"
            ;;
        --version)
            (($# >= 2)) || fail "--version requires vX.Y.Z[-rc.N]"
            REQUESTED_VERSION="$2"; shift
            ;;
        --list) LIST_ONLY=true ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; fail "unknown argument: $1" ;;
    esac
    shift
done
[[ -z "$REQUESTED_VERSION" || "$REQUESTED_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$ ]] || \
    fail "--version must be strict SemVer prefixed with v"

for command in curl python3 sha256sum stat tar mktemp; do
    command -v "$command" >/dev/null 2>&1 || fail "required command '$command' is unavailable"
done
case "$(uname -m)" in
    x86_64|amd64) architecture=x86_64; gh_arch=amd64; gh_sha="$GH_AMD64_SHA256" ;;
    *) fail "public Sender releases currently support linux-x86_64 only" ;;
esac

tmp="$(mktemp -d)"
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT
releases="$tmp/releases.json"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --retry-delay 2 \
    --connect-timeout 10 --max-time 60 --max-filesize "$MAX_METADATA_BYTES" \
    -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
    -o "$releases" "https://api.github.com/repos/${REPOSITORY}/releases?per_page=30" || \
    fail "GitHub release metadata could not be downloaded (check network or API rate limit)"

selection="$tmp/selection"
python3 - "$releases" "$CHANNEL" "$REQUESTED_VERSION" "$architecture" "$LIST_ONLY" >"$selection" <<'PY'
import json, re, sys
from pathlib import Path

path, channel, requested, architecture, list_only = sys.argv[1:]
raw = Path(path).read_bytes()
if len(raw) > 2_097_152:
    raise SystemExit("release metadata is too large")
data = json.loads(raw)
if not isinstance(data, list) or len(data) > 30:
    raise SystemExit("invalid release metadata")
pattern = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-rc\.([1-9][0-9]*))?$")
valid = []
for item in data:
    if not isinstance(item, dict) or item.get("draft") is True:
        continue
    tag = item.get("tag_name")
    match = pattern.fullmatch(tag) if isinstance(tag, str) else None
    if match is None:
        continue
    rc = match.group(4)
    if bool(item.get("prerelease")) != (rc is not None):
        continue
    version = tag[1:]
    artifact = f"notification-sender-{version}-linux-{architecture}.tar.gz"
    names = {
        artifact,
        f"notification-sender-{version}-linux-{architecture}.manifest.json",
        f"{artifact}.bundle.jsonl",
    }
    assets = item.get("assets")
    if not isinstance(assets, list) or len(assets) > 20:
        continue
    found = {}
    for asset in assets:
        if not isinstance(asset, dict) or asset.get("name") not in names:
            continue
        name, url, size = asset.get("name"), asset.get("browser_download_url"), asset.get("size")
        prefix = f"https://github.com/denor81/tg_inform_sender_releases/releases/download/{tag}/"
        if name in found or not isinstance(url, str) or not url.startswith(prefix) or not isinstance(size, int):
            found = {}; break
        found[name] = (url, size)
    if set(found) != names:
        continue
    key = tuple(int(match.group(i)) for i in range(1, 4)) + ((-1, 0) if rc is None else (-2, int(rc)))
    if key < (0, 3, 1, -2, 1):
        continue
    valid.append((key, tag, artifact, found))
valid.sort(key=lambda value: value[0])
if list_only == "true":
    for _, tag, _, _ in valid:
        print(tag)
    raise SystemExit()
eligible = [entry for entry in valid if channel == "rc" or "-rc." not in entry[1]]
if requested:
    eligible = [entry for entry in valid if entry[1] == requested]
if not eligible:
    raise SystemExit("no matching signed release is available")
_, tag, artifact, found = eligible[-1]
manifest = artifact.removesuffix(".tar.gz") + ".manifest.json"
bundle = f"{artifact}.bundle.jsonl"
print(tag)
for name in (artifact, manifest, bundle):
    print(name, found[name][1], found[name][0], sep="\t")
PY

if [[ "$LIST_ONLY" == true ]]; then
    cat "$selection"
    exit 0
fi
mapfile -t selected <"$selection"
[[ ${#selected[@]} -eq 4 ]] || fail "release selection returned an invalid result"
tag="${selected[0]}"
IFS=$'\t' read -r artifact_name artifact_size artifact_url <<<"${selected[1]}"
IFS=$'\t' read -r manifest_name manifest_size manifest_url <<<"${selected[2]}"
IFS=$'\t' read -r bundle_name bundle_size bundle_url <<<"${selected[3]}"

download_asset() {
    local name="$1" declared_size="$2" url="$3" maximum="$4"
    [[ "$declared_size" =~ ^[0-9]+$ && "$declared_size" -gt 0 && "$declared_size" -le "$maximum" ]] || \
        fail "asset '$name' has an invalid declared size"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --retry 3 --retry-all-errors --retry-delay 2 \
        --connect-timeout 10 --max-time 300 --max-filesize "$maximum" -o "$tmp/$name" "$url" || \
        fail "asset '$name' could not be downloaded"
    [[ "$(stat -c %s "$tmp/$name")" == "$declared_size" ]] || fail "asset '$name' size changed"
}
download_asset "$manifest_name" "$manifest_size" "$manifest_url" "$MAX_METADATA_BYTES"
download_asset "$bundle_name" "$bundle_size" "$bundle_url" 4194304

gh_archive="$tmp/gh.tar.gz"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
    --retry 3 --retry-all-errors --retry-delay 2 \
    --connect-timeout 10 --max-time 120 --max-filesize 67108864 -o "$gh_archive" \
    "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${gh_arch}.tar.gz" || \
    fail "the pinned GitHub attestation verifier could not be downloaded"
printf '%s  %s\n' "$gh_sha" "$gh_archive" | sha256sum --check --status || \
    fail "the pinned GitHub attestation verifier digest is invalid"
gh_binary="$tmp/gh"
tar -xOf "$gh_archive" "gh_${GH_VERSION}_linux_${gh_arch}/bin/gh" >"$gh_binary" || \
    fail "the pinned verifier archive is invalid"
chmod 0755 "$gh_binary"

"$gh_binary" attestation verify "$tmp/$manifest_name" --bundle "$tmp/$bundle_name" \
    --repo "$REPOSITORY" --signer-workflow "$SIGNER_WORKFLOW" --source-ref "refs/tags/$tag" \
    --deny-self-hosted-runners >/dev/null || fail "release manifest attestation is invalid"

manifest_values="$tmp/manifest-values"
python3 - "$tmp/$manifest_name" "$tag" "$artifact_name" "$architecture" >"$manifest_values" <<'PY'
import json, re, sys
from pathlib import Path, PurePosixPath

path, tag, artifact_name, architecture = sys.argv[1:]
data = json.loads(Path(path).read_bytes())
expected = {"format", "application", "tag", "version", "channel", "built_at", "source", "platform", "database", "artifact", "files", "dependency_lock_sha256", "rollout_window_seconds"}
if not isinstance(data, dict) or set(data) != expected or data["format"] != 1 or data["application"] != "notification-sender":
    raise SystemExit("manifest identity is invalid")
if data["tag"] != tag or data["version"] != tag[1:]:
    raise SystemExit("manifest version is invalid")
if data.get("source", {}).get("repository") != "denor81/tg_inform_sender" or data["source"].get("build_workflow") != "denor81/tg_inform_sender/.github/workflows/release.yml":
    raise SystemExit("manifest source is invalid")
if data.get("platform", {}).get("architecture") != architecture:
    raise SystemExit("manifest platform is invalid")
if not isinstance(data["rollout_window_seconds"], int) or data["rollout_window_seconds"] < 0:
    raise SystemExit("manifest rollout window is invalid")
artifact = data.get("artifact")
if not isinstance(artifact, dict) or artifact.get("name") != artifact_name:
    raise SystemExit("manifest artifact is invalid")
digest, size = artifact.get("sha256"), artifact.get("size")
if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None or not isinstance(size, int) or size <= 0:
    raise SystemExit("manifest artifact digest is invalid")
files = data.get("files")
if not isinstance(files, list) or not files:
    raise SystemExit("manifest payload is invalid")
seen = set()
for item in files:
    name = item.get("path") if isinstance(item, dict) else None
    if not isinstance(name, str) or name in seen or PurePosixPath(name).is_absolute() or ".." in PurePosixPath(name).parts:
        raise SystemExit("manifest payload path is invalid")
    seen.add(name)
print(digest)
print(size)
PY
mapfile -t manifest_data <"$manifest_values"
[[ ${#manifest_data[@]} -eq 2 ]] || fail "release manifest is invalid"
[[ "${manifest_data[1]}" == "$artifact_size" ]] || fail "artifact size disagrees with manifest"
download_asset "$artifact_name" "$artifact_size" "$artifact_url" "$MAX_ARTIFACT_BYTES"
printf '%s  %s\n' "${manifest_data[0]}" "$tmp/$artifact_name" | sha256sum --check --status || \
    fail "release artifact digest is invalid"
"$gh_binary" attestation verify "$tmp/$artifact_name" --bundle "$tmp/$bundle_name" \
    --repo "$REPOSITORY" --signer-workflow "$SIGNER_WORKFLOW" --source-ref "refs/tags/$tag" \
    --deny-self-hosted-runners >/dev/null || fail "release artifact attestation is invalid"

extract_root="$tmp/release"
mkdir "$extract_root"
python3 - "$tmp/$artifact_name" "$tmp/$manifest_name" "$extract_root" <<'PY'
import hashlib, json, sys, tarfile
from pathlib import Path

archive, manifest_path, destination = map(Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_bytes())
expected = {item["path"]: item for item in manifest["files"]}
expected_directories = {
    str(parent)
    for name in expected
    for parent in Path(name).parents
    if str(parent) != "."
}
with tarfile.open(archive, "r:gz") as tar:
    members = tar.getmembers()
    member_names = [member.name.rstrip("/") for member in members]
    if len(member_names) != len(set(member_names)):
        raise SystemExit("archive contains a duplicate entry")
    if set(member_names) != set(expected) | expected_directories:
        raise SystemExit("archive payload does not match manifest")
    for member in members:
        name = member.name.rstrip("/")
        if member.isdir():
            if name not in expected_directories:
                raise SystemExit("archive contains an unexpected directory")
            continue
        if not member.isfile() or member.issym() or member.islnk():
            raise SystemExit("archive contains a non-regular entry")
        source = tar.extractfile(member)
        if source is None:
            raise SystemExit("archive entry cannot be read")
        data = source.read()
        item = expected[name]
        if len(data) != item["size"] or hashlib.sha256(data).hexdigest() != item["sha256"]:
            raise SystemExit("archive entry digest is invalid")
        target = destination / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        target.chmod(0o755 if name in {"deploy/install.sh", "deploy/notify-sender", "deploy/uninstall.sh"} else 0o644)
PY

[[ $EUID -eq 0 ]] || fail "installation requires root; run this script through sudo"
echo "Installing verified public release $tag from $REPOSITORY."
if { true </dev/tty; } 2>/dev/null; then
    exec "$extract_root/deploy/install.sh" --release-bundle </dev/tty
fi
exec "$extract_root/deploy/install.sh" --release-bundle
