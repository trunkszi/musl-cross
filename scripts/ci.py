#!/usr/bin/env python3
"""Candidate snapshots and artifact receipts shared by the Actions jobs."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys

from upstream import ROOT, TARGET, read_versions, annotate

HOSTS = {
    'amazonlinux2': 'public.ecr.aws/amazonlinux/amazonlinux:2',
    'alinux3': 'alibaba-cloud-linux-3-registry.cn-hangzhou.cr.aliyuncs.com/alinux3/alinux3:latest',
    'centos7': 'centos:7.9.2009',
    'ubuntu22': 'ubuntu:22.04',
}


def git(*args, env=None):
    return subprocess.check_output(['git', '-C', str(ROOT), *args], env=env, text=True).strip()


def boolean(name):
    value = os.environ.get(name, 'false').lower()
    if value not in ('true', 'false', ''):
        raise ValueError(f'{name} must be true or false')
    return value == 'true'


def plan():
    event = os.environ.get('CI_EVENT', 'workflow_dispatch')
    if event not in ('schedule', 'workflow_dispatch'):
        raise ValueError('Unsupported workflow event')
    targets = os.environ.get('INPUT_TARGETS') or TARGET
    hosts = os.environ.get('INPUT_CONTAINERS') or 'all'
    selected = list(HOSTS) if hosts == 'all' else hosts.split(',')
    if targets != TARGET or not selected or len(set(selected)) != len(selected) or any(host not in HOSTS for host in selected):
        raise ValueError('Unsupported or duplicate target/container selection')
    reuse = os.environ.get('SOURCE_RUN_ID', '')
    check = event == 'schedule' or boolean('CHECK_UPSTREAM')
    if reuse and (not reuse.isdecimal() or check):
        raise ValueError('source_run_id must be numeric and cannot be combined with upstream checking')
    tag = os.environ.get('RELEASE_TAG') or 'v0.0.1'
    publish = event == 'schedule' or boolean('CREATE_RELEASE')
    if publish and (tag != 'v0.0.1' or set(selected) != set(HOSTS)):
        raise ValueError('Publication requires v0.0.1 and all four host profiles')
    if event == 'schedule' and (targets != TARGET or hosts != 'all'):
        raise ValueError('Scheduled updates require the full canonical matrix')
    return {'matrix': {'include': [{'target': TARGET, 'container': {'label': host, 'image': HOSTS[host]}} for host in selected]},
            'check_upstream': check, 'reuse': bool(reuse), 'publish': publish, 'event': event}


def write_outputs(data):
    lines = []
    for key, value in data.items():
        if isinstance(value, bool): value = str(value).lower()
        elif isinstance(value, (dict, list)): value = json.dumps(value, separators=(',', ':'))
        lines.append(f'{key}={value}')
    text = '\n'.join(lines) + '\n'
    print(text, end='')
    if os.environ.get('GITHUB_OUTPUT'):
        with open(os.environ['GITHUB_OUTPUT'], 'a') as stream: stream.write(text)


def prepare(directory):
    decision = plan()
    if decision['reuse']:
        write_outputs(dict(matrix=decision['matrix'], should_build=False, upstream_updated=False,
                           should_release=decision['publish']))
        return
    directory.mkdir(parents=True, exist_ok=True)
    updated = False
    if decision['check_upstream']:
        env = dict(os.environ)
        env.pop('GITHUB_OUTPUT', None)
        summary = directory / 'upstream-summary.md'
        result = subprocess.run([str(ROOT/'scripts/sync-upstream.sh'), '--apply', '--summary-file', str(summary)], env=env, text=True, capture_output=True)
        print(result.stdout, end='')
        print(result.stderr, end='', file=sys.stderr)
        if summary.exists() and os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as stream: stream.write(summary.read_text())
        if result.returncode: raise ValueError('Upstream synchronization failed; inspect the patch/discovery summary')
        updated = 'upstream_updated=true' in result.stdout.splitlines()
        if not updated and decision['event'] == 'schedule':
            write_outputs(dict(matrix=decision['matrix'], should_build=False, upstream_updated=False, should_release=False))
            return
    base = git('rev-parse', 'HEAD')
    candidate = base
    if updated:
        env = dict(os.environ, GIT_INDEX_FILE=str(directory/'candidate.index'),
                   GIT_AUTHOR_NAME='Nathan Shea', GIT_AUTHOR_EMAIL='itzrustz@gmail.com',
                   GIT_COMMITTER_NAME='Nathan Shea', GIT_COMMITTER_EMAIL='itzrustz@gmail.com')
        git('read-tree', 'HEAD', env=env)
        git('add', '--', 'builder', f'targets/{TARGET}/config', f'targets/{TARGET}/versions', env=env)
        tree = git('write-tree', env=env)
        candidate = git('commit-tree', tree, '-m', 'first commit', env=env)
    ref = 'refs/musl-cross/candidate'
    git('update-ref', ref, candidate)
    try:
        git('bundle', 'create', str(directory/'candidate.bundle'), ref)
    finally:
        git('update-ref', '-d', ref)
    source = {'schema': 1, 'source_sha': candidate, 'base_sha': base, 'candidate_ref': ref,
              'upstream_updated': updated, 'versions': read_versions(ROOT/'targets'/TARGET/'versions')}
    (directory/'source.json').write_text(json.dumps(source, indent=2)+'\n')
    write_outputs(dict(matrix=decision['matrix'], should_build=True, upstream_updated=updated,
                       should_release=decision['publish'], source_sha=candidate))


def validate_repository(repository):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+',repository):
        raise ValueError('Invalid repository name')
    return repository


def validate_run(source, run_id):
    if not re.fullmatch('[0-9a-f]{40}', source.get('base_sha','')):
        raise ValueError('Invalid base source SHA')
    if not run_id:
        if source['base_sha'] != os.environ.get('GITHUB_SHA'):
            raise ValueError('Current-run source does not match GITHUB_SHA')
        return
    if not run_id.isdecimal(): raise ValueError('Invalid source run ID')
    repository = validate_repository(os.environ['GITHUB_REPOSITORY'])
    response = subprocess.check_output(['gh','api',f'repos/{repository}/actions/runs/{run_id}'],text=True,timeout=60)
    build = json.loads(response)
    if (build.get('status') != 'completed' or build.get('conclusion') != 'success'
            or build.get('head_sha') != source['base_sha'] or build.get('head_branch') != 'main'
            or build.get('path') != '.github/workflows/release.yaml'
            or build.get('event') not in ('schedule','workflow_dispatch')
            or build.get('repository',{}).get('full_name') != repository):
        raise ValueError('Historical run is not a successful canonical source build')


def restore(directory):
    source = json.loads((directory/'source.json').read_text())
    if source.get('schema') != 1 or source.get('candidate_ref') != 'refs/musl-cross/candidate':
        raise ValueError('Invalid candidate source contract')
    sha = source['source_sha']
    if len(sha) != 40 or any(c not in '0123456789abcdef' for c in sha): raise ValueError('Invalid source SHA')
    git('fetch', '--no-tags', str(directory/'candidate.bundle'), source['candidate_ref'])
    if git('rev-parse', 'FETCH_HEAD') != sha: raise ValueError('Candidate bundle SHA mismatch')
    git('checkout', '--detach', sha)
    subprocess.run(['git','-C',str(ROOT),'submodule','update','--init','builder'], check=True)
    if read_versions(ROOT/'targets'/TARGET/'versions') != source['versions']:
        raise ValueError('Source metadata does not match the candidate receipt')


def receipt(source_path, archive, host):
    source = json.loads(source_path.read_text())
    if host not in HOSTS or archive.name != f'{TARGET}-{host}.tar.xz': raise ValueError('Unexpected artifact identity')
    if git('rev-parse','HEAD') != source['source_sha']: raise ValueError('Build did not use the candidate source')
    digest = file_hash(archive)
    sidecar = Path(str(archive)+'.sha256').read_text().strip()
    if sidecar != digest: raise ValueError('Artifact checksum mismatch')
    data = dict(source_sha=source['source_sha'], host=host, target=TARGET, versions=source['versions'], filename=archive.name, sha256=digest)
    Path(str(archive)+'.json').write_text(json.dumps(data,indent=2)+'\n')


def file_hash(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024*1024),b''): digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('plan')
    for name in ('prepare','restore'):
        sub.add_parser(name).add_argument('directory', type=Path)
    validation = sub.add_parser('validate-run')
    validation.add_argument('source', type=Path)
    validation.add_argument('--source-run-id', default='')
    create = sub.add_parser('receipt')
    create.add_argument('source', type=Path)
    create.add_argument('archive', type=Path)
    create.add_argument('host', choices=HOSTS)
    args = parser.parse_args()
    try:
        if args.command == 'plan': print(json.dumps(plan()))
        elif args.command == 'prepare': prepare(args.directory.resolve())
        elif args.command == 'restore': restore(args.directory.resolve())
        elif args.command == 'validate-run': validate_run(json.loads(args.source.read_text()),args.source_run_id)
        else: receipt(args.source, args.archive, args.host)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        annotate('CI_PREPARATION_FAILED',str(error))
        return 1
    return 0


if __name__ == '__main__': sys.exit(main())
