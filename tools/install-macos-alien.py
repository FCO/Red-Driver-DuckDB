#!/usr/bin/env python3
"""Install Alien::Libduckdb 1.1.0 with its missing macOS filenames fixed."""
import pathlib
import subprocess
import tarfile
import tempfile
import urllib.request

URL = 'https://360.zef.pm/A/LI/ALIEN_LIBDUCKDB/616cec8e8469ca04c087236ec2cc9fc0ae42c825.tar.gz'
with tempfile.TemporaryDirectory(prefix='red-duckdb-alien-') as directory:
    root = pathlib.Path(directory)
    archive = root / 'alien.tar.gz'
    urllib.request.urlretrieve(URL, archive)
    source = root / 'source'
    source.mkdir()
    with tarfile.open(archive) as tar:
        tar.extractall(source, filter='data')
    spec = next(source.rglob('Spec.rakumod'))
    text = spec.read_text()
    replacements = {
        "spec-is-win() ?? 'duckdb.dll' !! 'libduckdb.so'":
        "spec-is-win() ?? 'duckdb.dll' !! (spec-is-mac() ?? 'libduckdb.dylib' !! 'libduckdb.so')",
        "!! ('libduckdb.so', 'libduckdb.so.1')":
        "!! (spec-is-mac() ?? ('libduckdb.dylib',) !! ('libduckdb.so', 'libduckdb.so.1'))",
    }
    for old, new in replacements.items():
        if old not in text:
            raise RuntimeError('Alien source changed; review macOS workaround')
        text = text.replace(old, new)
    spec.write_text(text)
    distribution = next(source.rglob('META6.json')).parent
    subprocess.run(['zef', 'install', str(distribution), '--/test'], check=True)
