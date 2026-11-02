"""Restore exact public RPC evidence files from the text archive; never overwrite different files."""
import hashlib
import json
from pathlib import Path


def restore(archive: Path, destination: Path) -> int:
    records = json.loads(archive.read_text())['records']
    for record in records:
        relative = Path(record['path'])
        if relative.is_absolute() or '..' in relative.parts or relative.parts[0] != 'raw':
            raise ValueError('invalid archived evidence path')
        content = record['content'].encode()
        if hashlib.sha256(content).hexdigest() != record['sha256']:
            raise ValueError('archived evidence checksum mismatch')
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            if target.read_bytes() != content:
                raise FileExistsError(f'refusing to overwrite changed evidence: {relative}')
        else:
            target.write_bytes(content)
    return len(records)


if __name__ == '__main__':
    root = Path(__file__).resolve().parent
    print('Restored public RPC records:', restore(root / 'raw-records.json', root))
