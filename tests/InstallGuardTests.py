"""Exercise the install-time guard verbatim, with only its home directory mocked."""
import json
from pathlib import Path
import tempfile
from unittest.mock import patch

source = Path('build.sh').read_text().split("python3 - <<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
code = compile(source, 'build.sh install guard', 'exec')
with tempfile.TemporaryDirectory(prefix='nosy-install-guard-') as directory:
    home = Path(directory)
    audio = home / 'Library/Application Support/Nosy/audio'
    audio.mkdir(parents=True)

    def run(blocked):
        before = {p.name: p.read_bytes() for p in audio.iterdir()}
        try:
            with patch.object(Path, 'home', return_value=home):
                exec(code, {})
        except SystemExit as error:
            assert blocked and 'INSTALL BLOCKED' in str(error), str(error)
        else:
            assert not blocked, 'Active recording was allowed to install'
        assert {p.name: p.read_bytes() for p in audio.iterdir()} == before

    run(False)
    latest = audio / 'record.json'
    for status in ['recording', 'transcribing', 'done', 'failed']:
        latest.write_text(json.dumps({'status': status}))
        run(status in ['recording', 'transcribing'])
    latest.write_text('{broken')
    run(True)
print('INSTALL GUARD PASS: empty, recording, transcribing, done, failed, corrupt; sidecars never changed')
