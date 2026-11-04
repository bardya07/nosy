"""Exercise the install-time guard verbatim, with only its home directory mocked."""
import json
import os
from pathlib import Path
import tempfile
from unittest.mock import patch

source = Path('build.sh').read_text().split("python3 - <<'PYTHON'\n", 1)[1].split('\nPYTHON\n', 1)[0]
code = compile(source, 'build.sh install guard', 'exec')
with tempfile.TemporaryDirectory(prefix='nosy-install-guard-') as directory:
    home = Path(directory)
    audio = home / 'Library/Application Support/Nosy/audio'
    audio.mkdir(parents=True)

    def run(blocked):
        before = {p.name: p.read_bytes() for p in audio.iterdir()}
        try:
            with patch.object(Path, 'home', return_value=home), patch.dict(os.environ, {}, clear=True):
                exec(code, {})
        except SystemExit as error:
            assert blocked and 'INSTALL BLOCKED' in str(error), str(error)
        else:
            assert not blocked, 'Invalid or active recording was allowed to install'
        assert {p.name: p.read_bytes() for p in audio.iterdir()} == before

    run(False)
    latest = audio / 'record.json'
    for status in ['recording', 'transcribing', 'done', 'failed']:
        latest.write_text(json.dumps({'id': 'record', 'lecture': 'L', 'session': 'S',
                                      'startedAt': '2026-01-01T00:00:00Z', 'status': status}))
        run(status in ['recording', 'transcribing'])
    (audio / 'record.segments.json').write_text('{malformed timing data')
    (audio / '.whisper-record-12345678-1234-1234-1234-123456789abc.json').write_text('{scratch')
    run(False)
    latest.write_text('{broken')
    run(True)
    latest.write_text(json.dumps({'id': 'wrong', 'lecture': 'L', 'session': 'S',
                                  'startedAt': '2026-01-01T00:00:00Z', 'status': 'done'}))
    run(True)
    latest.write_text(json.dumps({'status': 'done'}))
    run(True)
print('INSTALL GUARD PASS: records, malformed candidates, legacy timing and scratch; sidecars unchanged')
