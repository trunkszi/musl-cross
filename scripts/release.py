#!/usr/bin/env python3
"""Verify all four artifact receipts, then publish assets before moving refs."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from ci import HOSTS, ROOT, TARGET, file_hash, git, validate_run, validate_repository
from upstream import annotate, read_versions


def run(*args):
    subprocess.run(args, cwd=ROOT, check=True, timeout=1800)


def github_get(path):
    result = subprocess.run(['gh','api','--include',path], capture_output=True, text=True, timeout=60)
    text = result.stdout.replace('\r\n','\n')
    header, sep, body = text.partition('\n\n')
    status = re.search(r'^HTTP/\S+\s+(\d{3})',header)
    if not status:
        raise ValueError(f'GitHub API failed without an HTTP response: {path}')
    code = int(status[1])
    if code == 404: return None
    if result.returncode or code != 200:
        raise ValueError(f'GitHub API request failed: {path}, HTTP {code}')
    if not sep: raise ValueError('Missing GitHub response body')
    return json.loads(body)


def verify(directory, source, notes):
    if source.get('schema') != 1 or not re.fullmatch('[0-9a-f]{40}',source.get('source_sha','')):
        raise ValueError('Invalid candidate metadata')
    files, rows = [], []
    for host in HOSTS:
        name = f'{TARGET}-{host}.tar.xz'
        archive = directory/name
        sidecar = directory/(name+'.sha256')
        receipt = directory/(name+'.json')
        expected = sidecar.read_text().strip()
        if not archive.stat().st_size or not re.fullmatch('[0-9a-f]{64}',expected) or file_hash(archive) != expected:
            raise ValueError(f'Artifact checksum validation failed: {name}')
        identity = json.loads(receipt.read_text())
        contract = dict(source_sha=source['source_sha'],host=host,target=TARGET,versions=source['versions'],filename=name,sha256=expected)
        if identity != contract: raise ValueError(f'Artifact provenance mismatch: {name}')
        files.extend([archive,sidecar,receipt])
        rows.append(f'| {name} | {expected} |')
    if set(directory.iterdir()) != set(files): raise ValueError('Unexpected files in artifact set')
    content = ['# musl-cross v0.0.1', '', f'Source: {source["source_sha"]}',
               f'CTNG: {source["versions"]["CTNG_RELEASE_TAG"]} ({source["versions"]["CTNG_COMMIT"]})', '',
               '| Archive | SHA-256 |', '|---|---|', *rows, '',
               'v0.0.1 is mutable. Pin the source SHA and artifact digest for repeatable consumption.',
               'Asset replacement is per-file; retry a download if archive and digest generations differ.', '']
    notes.write_text('\n'.join(content))
    return files


def publish(directory, source, notes, source_run):
    files = verify(directory,source,notes)
    repository = validate_repository(os.environ['GITHUB_REPOSITORY'])
    tag = os.environ.get('RELEASE_TAG') or 'v0.0.1'
    if tag != 'v0.0.1': raise ValueError('Only v0.0.1 may be published')
    if git('rev-parse','HEAD') != source['source_sha']: raise ValueError('Publisher source differs from built source')
    if read_versions(ROOT/'targets'/TARGET/'versions') != source['versions']:
        raise ValueError('Publisher version metadata differs from artifact receipts')
    validate_run(source,source_run)
    branch = github_get(f'repos/{repository}/git/ref/heads/main')
    if not branch or branch['object']['sha'] != source['base_sha']:
        raise ValueError('STALE_CANDIDATE: main changed; rebuild without publishing')
    old_tag = github_get(f'repos/{repository}/git/ref/tags/{tag}')
    existing = github_get(f'repos/{repository}/releases/tags/{tag}')
    if existing and existing.get('immutable'): raise ValueError('Immutable release cannot be overwritten')
    if source['upstream_updated']:
        if git('rev-list','--count','HEAD') != '1': raise ValueError('Updated candidate must have exactly one root commit')
        identity = git('show','-s','--format=%an <%ae>%n%cn <%ce>%n%B','HEAD')
        if identity != 'Nathan Shea <itzrustz@gmail.com>\nNathan Shea <itzrustz@gmail.com>\nfirst commit':
            raise ValueError('Updated root identity/message mismatch')
    temporary_ref = 'refs/heads/__release_candidate_' + os.environ.get('GITHUB_RUN_ID','manual')
    journal = notes.with_name('publication.json')
    state = dict(publication_touched=False,stage='verified',source_sha=source['source_sha'],
                 old_main=source['base_sha'],old_tag=old_tag['object']['sha'] if old_tag else None,
                 tag_attempted=False,main_attempted=False,draft_created=False,draft_id=None,
                 candidate_pushed=False,rollback_status='not_needed')

    def record(stage, **fields):
        state.update(stage=stage, **fields)
        temporary = journal.with_suffix('.json.tmp')
        temporary.write_text(json.dumps(state,indent=2)+'\n')
        temporary.replace(journal)

    def set_tag(sha, current):
        if current:
            run('gh','api','--method','PATCH',f'repos/{repository}/git/refs/tags/{tag}',
                '-f',f'sha={sha}','-F','force=true')
        else:
            run('gh','api','--method','POST',f'repos/{repository}/git/refs',
                '-f',f'ref=refs/tags/{tag}','-f',f'sha={sha}')

    def rollback():
        errors = []
        # Ref writes may have reached GitHub even if the client lost the response.
        if state['tag_attempted'] or state['draft_created']:
            try:
                current = github_get(f'repos/{repository}/git/ref/tags/{tag}')
                current_sha = current['object']['sha'] if current else None
                if current_sha != state['old_tag']:
                    if current_sha != source['source_sha']:
                        raise ValueError('tag changed concurrently; refusing to overwrite it')
                    if old_tag:
                        set_tag(state['old_tag'],current)
                    else:
                        run('gh','api','--method','DELETE',f'repos/{repository}/git/refs/tags/{tag}')
            except (ValueError,OSError,subprocess.SubprocessError) as error:
                errors.append(f'tag rollback: {error}')
        if state['main_attempted']:
            try:
                current = github_get(f'repos/{repository}/git/ref/heads/main')
                if not current: raise ValueError('main ref disappeared')
                if current['object']['sha'] != source['base_sha']:
                    if current['object']['sha'] != source['source_sha']:
                        raise ValueError('main changed concurrently; refusing to overwrite it')
                    run('git','push',f'--force-with-lease=refs/heads/main:{source["source_sha"]}',
                        'origin',f'{source["base_sha"]}:refs/heads/main')
            except (ValueError,OSError,subprocess.SubprocessError) as error:
                errors.append(f'main rollback: {error}')
        if state['draft_created']:
            try:
                if state['draft_id'] is None:
                    raise ValueError('created draft ID unavailable; inspect and remove the owned draft manually')
                run('gh','api','--method','DELETE',f'repos/{repository}/releases/{state["draft_id"]}')
            except (ValueError,OSError,subprocess.SubprocessError) as error:
                errors.append(f'draft cleanup: {error}')
        return errors

    record('verified')
    try:
        # Transfer the object without advancing main or the release tag.
        if source['upstream_updated']:
            state['candidate_pushed'] = True
            run('git','push','origin',f'{source["source_sha"]}:{temporary_ref}')
        if not existing:
            record('draft_create_attempted',publication_touched=True)
            run('gh','release','create',tag,'--draft','--target',source['source_sha'],'--title',f'Release {tag}')
            state['draft_created'] = True
            created = github_get(f'repos/{repository}/releases/tags/{tag}')
            state['draft_id'] = created['id'] if created else None
            record('draft_created')
        # An attempted upload may replace bytes before failing; it is not a transaction.
        record('asset_upload_attempted',publication_touched=True)
        run('gh','release','upload',tag,*map(str,files),'--clobber')
        record('assets_uploaded')
        run('gh','release','edit',tag,'--target',source['source_sha'],'--title',f'Release {tag}',
            '--notes-file',str(notes),'--draft=true' if state['draft_created'] else '--draft=false')
        record('metadata_updated')
        branch_now = github_get(f'repos/{repository}/git/ref/heads/main')
        tag_now = github_get(f'repos/{repository}/git/ref/tags/{tag}')
        if branch_now != branch or (old_tag is not None and tag_now != old_tag) or (old_tag is None and tag_now is not None and tag_now['object']['sha'] != source['source_sha']):
            raise ValueError('STALE_CANDIDATE: refs changed during upload; inspect publication journal')
        record('tag_update_attempted',tag_attempted=True)
        set_tag(source['source_sha'],tag_now)
        record('tag_updated')
        if source['upstream_updated']:
            record('main_update_attempted',main_attempted=True)
            run('git','push',f'--force-with-lease=refs/heads/main:{source["base_sha"]}',
                'origin',f'{source["source_sha"]}:refs/heads/main')
            record('main_updated')
        if state['draft_created']:
            record('draft_publish_attempted')
            run('gh','release','edit',tag,'--draft=false')
        record('complete')
    except (ValueError,OSError,subprocess.SubprocessError) as original:
        failed_stage = state['stage']
        errors = rollback()
        try:
            record('failed',failed_stage=failed_stage,rollback_status='failed' if errors else 'complete',rollback_errors=errors)
        except OSError as error:
            errors.append(f'journal write: {error}')
        message = 'Asset publication may be partial; inspect publication.json before manual recovery.' if state['publication_touched'] else 'Published v0.0.1 Release: UNTOUCHED'
        if errors: message += ' Rollback errors: '+'; '.join(errors)
        annotate('RELEASE_PUBLICATION_FAILED',message)
        if os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(os.environ['GITHUB_STEP_SUMMARY'],'a') as stream: stream.write('## Release failure\n\n'+message+'\n')
        raise ValueError(f'{original}; {message}') from original
    finally:
        if state['candidate_pushed']:
            if state['rollback_status'] == 'failed':
                annotate('CANDIDATE_RETAINED',f'Manual recovery may use {temporary_ref}')
            else:
                try: run('git','push','origin',':'+temporary_ref)
                except subprocess.SubprocessError: annotate('CANDIDATE_CLEANUP_FAILED',f'Remove {temporary_ref} manually')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command',choices=('verify','publish'))
    parser.add_argument('directory',type=Path)
    parser.add_argument('source',type=Path)
    parser.add_argument('--notes',type=Path,default=Path('RELEASE.md'))
    parser.add_argument('--source-run-id',default='')
    args = parser.parse_args()
    try:
        source = json.loads(args.source.read_text())
        if args.command == 'verify': verify(args.directory,source,args.notes)
        else: publish(args.directory,source,args.notes,args.source_run_id)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        annotate('RELEASE_FAILED',str(error))
        return 1
    return 0


if __name__ == '__main__': sys.exit(main())
