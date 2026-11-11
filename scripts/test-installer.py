#!/usr/bin/env python3
"""Offline adversarial tests. All keys and refs are disposable fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def run(args, *, env=None, cwd=None, data=None, ok=True):
    p = subprocess.run(args, env=env, cwd=cwd, input=data, text=True, capture_output=True)
    if ok and p.returncode:
        raise RuntimeError(f'{args[0]} failed: {p.stderr}')
    return p

with tempfile.TemporaryDirectory(prefix='bk-test-', dir='/tmp') as temp:
    home = Path(temp) / 'keys'
    home.mkdir(mode=0o700)
    env = dict(os.environ, GNUPGHOME=str(home))
    repo = Path(temp) / 'repo'
    try:
        run(['gpg', '--batch', '--pinentry-mode', 'loopback', '--passphrase', '', '--quick-generate-key',
             'Blinker Installer Fixture <fixture@example.invalid>', 'ed25519', 'sign', '0'], env=env)
        listing = run(['gpg', '--batch', '--with-colons', '--list-keys'], env=env).stdout
        fingerprint = next(line.split(':')[9] for line in listing.splitlines() if line.startswith('fpr:'))
        run(['git', 'init', '--quiet', str(repo)])
        # Use an existing commit; no unsigned commits or application execution.
        run(['git', 'fetch', '--quiet', str(ROOT), 'HEAD'], cwd=repo)
        commit = run(['git', 'rev-parse', 'FETCH_HEAD'], cwd=repo).stdout.strip()
        run(['git', '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
             '-c', 'user.signingkey=' + fingerprint, '-c', 'gpg.format=openpgp', '-c', 'gpg.program=gpg',
             'tag', '-s', 'v0.1.3', commit, '-m', 'Fixture'], env=env, cwd=repo)
        original = run(['git', 'rev-parse', 'refs/tags/v0.1.3'], cwd=repo).stdout.strip()
        payload = run(['git', 'cat-file', 'tag', original], cwd=repo).stdout
        def verify(ref, signer=fingerprint):
            return run(['bash', '-c', 'source "$1"; verify_release "$2" "$3" "$4" "$5"', '_',
                        str(ROOT / 'install.sh'), str(repo), ref, str(home), signer], env=env, ok=False).returncode == 0
        def expect(label, result):
            assert result, label
            print('PASS:', label)
        expect('valid signed release accepted', verify('v0.1.3'))
        run(['git', 'update-ref', 'refs/tags/v999.0.0', original], cwd=repo)
        expect('renamed signed release rejected', not verify('v999.0.0'))
        expect('wrong signer rejected', not verify('v0.1.3', '0' * 40))
        run(['git', 'update-ref', 'refs/tags/v0.1.4', commit], cwd=repo)
        expect('lightweight tag rejected', not verify('v0.1.4'))
        for label, content in [
            ('tampered signed payload', payload.replace('Fixture', 'Modified')),
            ('unsigned annotated tag', payload.split('-----BEGIN PGP SIGNATURE-----')[0]),
            ('nested tag', payload.replace('type commit', 'type tag')),
        ]:
            obj = run(['git', 'hash-object', '-t', 'tag', '-w', '--stdin'], cwd=repo, data=content).stdout.strip()
            run(['git', 'update-ref', 'refs/tags/v0.1.3', obj], cwd=repo)
            expect(label + ' rejected', not verify('v0.1.3'))
        def version(a, b, allow='0'):
            return run(['bash', '-c', 'source "$1"; check_version "$2" "$3"', '_',
                        str(ROOT / 'install.sh'), a, b], env=dict(env, BLINKER_ALLOW_DOWNGRADE=allow), ok=False).returncode == 0
        expect('downgrade rejected', not version('v0.1.2', 'v0.1.3'))
        expect('numeric version order', version('v0.1.10', 'v0.1.3'))
        expect('same version accepted', version('v0.1.3', 'v0.1.3'))
        expect('explicit rollback accepted', version('v0.1.2', 'v0.1.3', '1'))
    finally:
        run(['gpgconf', '--kill', 'gpg-agent'], env=env, ok=False)
