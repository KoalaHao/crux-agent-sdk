"""Check the vendored-source manifest without third-party dependencies."""
import hashlib
import json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
manifest = json.loads((root / 'UPSTREAM.json').read_text())
for name, record in manifest['files'].items():
    path = root / 'lib/src' / name
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != record['localSha256']:
        raise SystemExit(f'Source manifest mismatch: {name}')
print(f"Verified {len(manifest['files'])} source files from {manifest['revision']}")
