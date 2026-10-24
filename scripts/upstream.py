#!/usr/bin/env python3
"""Resolve one stable CTNG candidate and preflight it before changing local inputs."""
import argparse
import json
import fnmatch
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
TARGET = 'x86_64-unknown-linux-musl'
API = 'https://api.github.com/repos/crosstool-ng/crosstool-ng'
UPSTREAM = 'https://github.com/crosstool-ng/crosstool-ng.git'
SHA = re.compile(r'[0-9a-f]{40}')


class SyncError(Exception):
    def __init__(self, code, detail, patch=''):
        super().__init__(detail)
        self.code, self.patch = code, patch


def command(*args, cwd=None):
    result = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=300)
    if result.returncode:
        raise SyncError('DISCOVERY_FAILED', f'{args[0]} failed ({result.returncode}):\n{result.stderr}{result.stdout}')
    return result.stdout.strip()


def read_versions(path):
    values = {}
    for line in path.read_text().splitlines():
        if not line or line.startswith('#'):
            continue
        key, sep, value = line.partition('=')
        if not sep or not re.fullmatch(r'[A-Z_]+', key) or not re.fullmatch(r'[A-Za-z0-9_.-]+', value):
            raise SyncError('DISCOVERY_FAILED', f'Invalid version metadata: {line}')
        if key in values: raise SyncError('DISCOVERY_FAILED',f'Duplicate version metadata key: {key}')
        values[key] = value
    for key in ('CTNG_RELEASE_TAG', 'CTNG_COMMIT', 'EXPECTED_GCC_VERSION', 'EXPECTED_MUSL_VERSION', 'EXPECTED_MOLD_VERSION'):
        if not values.get(key):
            raise SyncError('DISCOVERY_FAILED', f'Missing version metadata: {key}')
    if not SHA.fullmatch(values['CTNG_COMMIT']):
        raise SyncError('DISCOVERY_FAILED', 'Invalid CTNG_COMMIT')
    return values


def api_json(path):
    headers = {'Accept': 'application/vnd.github+json', 'User-Agent': 'musl-cross-updater'}
    if os.environ.get('GH_TOKEN'):
        headers['Authorization'] = 'Bearer ' + os.environ['GH_TOKEN']
    request = urllib.request.Request(API + path, headers=headers)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def release_identity():
    fixture = os.environ.get('UPSTREAM_RELEASE_JSON_FILE')
    release = json.loads(Path(fixture).read_text()) if fixture else api_json('/releases/latest')
    if not isinstance(release, dict) or type(release.get('draft')) is not bool or type(release.get('prerelease')) is not bool:
        raise SyncError('DISCOVERY_FAILED', 'Malformed release response')
    if release['draft'] or release['prerelease']:
        print('Ignoring draft/prerelease; no stable candidate accepted', file=sys.stderr)
        return None, None
    tag = release.get('tag_name', '')
    if not re.fullmatch(r'crosstool-ng-\d+(?:\.\d+)+', tag):
        raise SyncError('DISCOVERY_FAILED', f'Invalid stable release tag: {tag!r}')
    offline = os.environ.get('UPSTREAM_BUILDER_DIR')
    if fixture:
        if not offline:
            raise SyncError('DISCOVERY_FAILED', 'Offline release fixtures require UPSTREAM_BUILDER_DIR')
        commit = command('git', '-C', offline, 'rev-parse', f'refs/tags/{tag}^{{commit}}')
    else:
        obj = api_json('/git/ref/tags/' + urllib.parse.quote(tag, safe=''))['object']
        for _ in range(8):
            if obj['type'] == 'commit':
                break
            if obj['type'] != 'tag':
                raise SyncError('DISCOVERY_FAILED', 'Release tag does not reference a commit')
            obj = api_json('/git/tags/' + obj['sha'])['object']
        else:
            raise SyncError('DISCOVERY_FAILED', 'Annotated tag nesting exceeds limit')
        commit = obj['sha']
    if not SHA.fullmatch(commit):
        raise SyncError('DISCOVERY_FAILED', 'Release commit must be a complete SHA-1')
    return tag, commit


def newest_package(source, package):
    directory = source / 'packages' / package
    versions = []
    for entry in directory.iterdir():
        if not entry.is_dir() or not re.fullmatch(r'\d+(?:\.\d+)+', entry.name):
            continue
        descriptor = entry / 'version.desc'
        if not descriptor.is_file() or not (entry / 'chksum').is_file():
            continue
        if re.search(r'(?m)^\s*(?:experimental|obsolete)\s*=\s*[\'"]?(?:yes|y|true|1)\b', descriptor.read_text(), re.IGNORECASE):
            continue
        versions.append(entry.name)
    if not versions:
        raise SyncError('DISCOVERY_FAILED', f'No stable checksummed version for {package}')
    result = subprocess.run(['sort', '-V'], input='\n'.join(versions) + '\n', capture_output=True, text=True, check=True)
    return result.stdout.splitlines()[-1]


def unpack_source(repository, commit, destination):
    archive = destination.parent / 'source.tar'
    with archive.open('wb') as output:
        subprocess.run(['git', '-C', str(repository), 'archive', commit], stdout=output, check=True, timeout=300)
    destination.mkdir()
    with tarfile.open(archive) as stream:
        stream.extractall(destination, filter='data')


def validate_patch_paths(source, patch):
    root = source.resolve()
    for line in patch.read_text().splitlines():
        if line.startswith('diff --git '):
            paths = shlex.split(line)[2:]
        elif line.startswith(('--- ','+++ ')):
            field = line[4:].split('\t',1)[0]
            paths = shlex.split(field)[:1] if field.startswith('"') else [field]
        else:
            continue
        for name in paths:
            if name == '/dev/null': continue
            path = PurePosixPath(name)
            stripped = Path(*path.parts[1:])
            if path.is_absolute() or '..' in path.parts or '\\' in name or not stripped.parts:
                raise SyncError('UPSTREAM_PATCH_CONFLICT',f'Unsafe patch target: {name}',patch.name)
            destination = (root/stripped).resolve()
            if os.path.commonpath([str(root),str(destination)]) != str(root):
                raise SyncError('UPSTREAM_PATCH_CONFLICT',f'Patch target escapes source: {name}',patch.name)


def selector_version(source, package, version):
    descriptor = source/'packages'/package/'package.desc'
    if not descriptor.exists(): return version
    matches = re.findall(r'(?m)^relevantpattern=(.*)$',descriptor.read_text())
    if not matches: return version
    fields = shlex.split(matches[-1])
    if len(fields) != 1: raise SyncError('DISCOVERY_FAILED','Invalid relevantpattern')
    for rule in fields[0].split():
        if rule.count('|') != 1: raise SyncError('DISCOVERY_FAILED','Invalid relevantpattern rule')
        prefix,suffix = rule.split('|')
        # Match CTNG's shortest shell-prefix removal and shortest suffix removal.
        for split in range(len(version)+1):
            if fnmatch.fnmatchcase(version[:split],prefix+suffix):
                remainder = version[split:]
                for stop in range(len(version),-1,-1):
                    if fnmatch.fnmatchcase(version[stop:],suffix+remainder):
                        if stop != len(version): return version[:stop]
                        break
                break
    return version


def release_version(tag):
    parts = list(map(int,tag.removeprefix('crosstool-ng-').split('.')))
    while len(parts)>1 and parts[-1]==0: parts.pop()
    return tuple(parts)


def preflight(source, patches):
    for patch in sorted(patches.glob('*.patch')):
        validate_patch_paths(source,patch)
        for dry in (True, False):
            args = ['patch', '--fuzz=0', '--batch', '-Np1']
            if dry:
                args.append('--dry-run')
            result = subprocess.run(args + ['-i', str(patch)], cwd=source, capture_output=True, text=True, timeout=60)
            if result.returncode:
                raise SyncError('UPSTREAM_PATCH_CONFLICT', result.stdout + result.stderr, patch.name)


def new_config(text, versions, source):
    text = re.sub(r'(?m)^(?:# )?CT_(?:GCC|MUSL|MOLD)_V_[A-Za-z0-9_]+(?:=.*| is not set)\n?', '', text)
    text = re.sub(r'musl-\d+(?:\.\d+)+', 'musl-' + versions['musl'], text)
    for package, version in versions.items():
        selector = selector_version(source,package,version).replace('.', '_')
        text += f'CT_{package.upper()}_V_{selector}=y\n'
    return text


def annotate(code, message):
    escaped = message.replace('%', '%25').replace('\r', '%0D').replace('\n', '%0A')
    print(f'::error title={code}::{escaped}', flush=True)
    print(f'{code}: {message}',file=sys.stderr,flush=True)


def outputs(status, should_build, **values):
    data = dict(status=status, should_build=str(should_build).lower(), **values)
    text = ''.join(f'{key}={value}\n' for key, value in data.items())
    print(text, end='')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
            stream.write(text)


def summary(path, old, new, status, detail='', patch=''):
    if not path:
        return
    lines = ['## Upstream synchronization', '', f'Status: **{status}**', '', '| Input | Accepted | Candidate |', '|---|---|---|']
    for key in ('CTNG_RELEASE_TAG', 'CTNG_COMMIT', 'EXPECTED_GCC_VERSION', 'EXPECTED_MUSL_VERSION', 'EXPECTED_MOLD_VERSION'):
        lines.append(f'| {key} | {old.get(key, "unknown")} | {new.get(key, "unknown")} |')
    lines += ['', f'Patch: {patch or "none"}', '', 'This sync step does not publish.', '']
    if status not in ('updated','update_available','no_update'):
        lines += ['Published v0.0.1 Release: UNTOUCHED', '']
    if detail:
        lines += ['### Failure details', '', '~~~text', detail.replace('~~~', '---'), '~~~', '',
                  '### Manual repair', '', 'Review the candidate in a disposable checkout; update the named patch and rerun:',
                  '', '~~~sh', './scripts/sync-upstream.sh --check --summary-file upstream-summary.md',
                  'bash tests/run.sh', '~~~', '']
    if patch:
        lines += ['### Reproduce the patch conflict', '', '~~~sh', 'work=$(mktemp -d)',
                  f'git clone --single-branch --branch {new["CTNG_RELEASE_TAG"]} {UPSTREAM} "$work/builder"',
                  f'patch --fuzz=0 --batch --dry-run -Np1 -d "$work/builder" -i "$PWD/targets/{TARGET}/{patch}"', '~~~', '']
    with open(path, 'a') as stream:
        stream.write('\n'.join(lines) + '\n')


def synchronize(args, old, new):
    tag, commit = release_identity()
    if tag is None:
        return 'no_update'
    new.update(CTNG_RELEASE_TAG=tag, CTNG_COMMIT=commit)
    if commit == old['CTNG_COMMIT']:
        return 'no_update'
    if release_version(tag) < release_version(old['CTNG_RELEASE_TAG']):
        raise SyncError('DISCOVERY_FAILED', 'Refusing an upstream release downgrade')
    with tempfile.TemporaryDirectory(prefix='musl-cross-upstream.') as directory:
        temp = Path(directory)
        repository = os.environ.get('UPSTREAM_BUILDER_DIR')
        if not repository:
            repository = str(temp / 'repository')
            command('git', 'clone', '--quiet', '--no-checkout', '--depth=1', '--branch', tag, UPSTREAM, repository)
        source = temp / 'source'
        unpack_source(repository, commit, source)
        selected = {package: newest_package(source, package) for package in ('gcc', 'musl', 'mold')}
        new.update({f'EXPECTED_{key.upper()}_VERSION': value for key, value in selected.items()})
        preflight(source, ROOT / 'targets' / TARGET)
        if args.apply:
            builder = ROOT / 'builder'
            if command('git', '-C', str(builder), 'status', '--porcelain'):
                raise SyncError('DISCOVERY_FAILED', 'builder is dirty; refusing to overwrite local changes')
            previous = command('git', '-C', str(builder), 'rev-parse', 'HEAD')
            if previous != old['CTNG_COMMIT']:
                raise SyncError('DISCOVERY_FAILED', 'builder HEAD disagrees with accepted metadata')
            config = ROOT / 'targets' / TARGET / 'config'
            metadata = config.with_name('versions')
            original_config, original_metadata = config.read_bytes(), metadata.read_bytes()
            try:
                command('git', '-C', str(builder), 'fetch', '--quiet', '--no-tags', str(repository), commit)
                command('git', '-C', str(builder), 'checkout', '--quiet', '--detach', commit)
                config.write_text(new_config(original_config.decode(), selected, source))
                metadata.write_text(''.join(f'{key}={value}\n' for key, value in new.items()))
            except BaseException as original:
                failures = []
                for path,content in ((config,original_config),(metadata,original_metadata)):
                    try: path.write_bytes(content)
                    except OSError as error: failures.append(f'{path.name} restore: {error}')
                try: command('git','-C',str(builder),'checkout','--quiet','--detach',previous)
                except (SyncError,OSError,subprocess.SubprocessError) as error:
                    failures.append(f'builder restore: {error}')
                detail = '; '.join(failures) if failures else 'complete'
                raise SyncError('DISCOVERY_FAILED',f'Apply failed: {original}; rollback: {detail}') from original
    return 'updated' if args.apply else 'update_available'


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog='Offline fixtures: UPSTREAM_RELEASE_JSON_FILE supplies the release JSON; UPSTREAM_BUILDER_DIR supplies a Git repository containing its tag. --check never changes builder/config/versions.')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--apply', action='store_true')
    parser.add_argument('--summary-file', default=os.environ.get('GITHUB_STEP_SUMMARY'))
    args = parser.parse_args()
    old, new = {}, {}
    try:
        old = read_versions(ROOT / 'targets' / TARGET / 'versions')
        new = dict(old)
        status = synchronize(args, old, new)
        summary(args.summary_file, old, new, status)
        outputs(status, status != 'no_update', upstream_updated=str(status == 'updated').lower())
        return 0
    except (SyncError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        code = error.code if isinstance(error, SyncError) else 'DISCOVERY_FAILED'
        context = f'{old.get("CTNG_RELEASE_TAG", "unknown")} ({old.get("CTNG_COMMIT", "unknown")}) -> {new.get("CTNG_RELEASE_TAG", "unknown")} ({new.get("CTNG_COMMIT", "unknown")})'
        patch = getattr(error, 'patch', '')
        annotate(code, f'{context}; {patch}: {error}' if patch else f'{context}; {error}')
        summary(args.summary_file, old, new, code, str(error), getattr(error, 'patch', ''))
        outputs('failed', False, upstream_updated='false')
        return 1


if __name__ == '__main__':
    sys.exit(main())
