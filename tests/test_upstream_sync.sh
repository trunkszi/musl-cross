#!/usr/bin/env bash
set -euo pipefail
export REPO_ROOT
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ['REPO_ROOT'])
IDENTITY = dict(os.environ, GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid')

def git(directory, *args, data=None):
    return subprocess.check_output(['git', '-C', str(directory), *args], input=data,
                                   text=True, env=IDENTITY, stderr=subprocess.DEVNULL).strip()

class UpstreamSync(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copytree(ROOT / 'scripts', self.root / 'scripts')
        self.target = self.root / 'targets/x86_64-unknown-linux-musl'
        self.target.mkdir(parents=True)
        self.remote = self.root / 'remote'
        self.remote.mkdir()
        git(self.remote, 'init', '-q')
        for package, versions in {'gcc':['16.2.0','17.1.0','99.0-rc1','18.0.0'],
                                  'musl':['1.2.6','1.2.7'], 'mold':['2.9.0','2.42.0']}.items():
            for version in versions:
                path = self.remote / 'packages' / package / version
                path.mkdir(parents=True)
                (path / 'chksum').write_text('fixture checksum\n')
                (path / 'version.desc').write_text('experimental=yes\n' if version == '18.0.0' else '')
        (self.remote/'packages/gcc/package.desc').write_text("relevantpattern='4.*|. *|.'\n")
        (self.remote / 'marker').write_text('before\n')
        git(self.remote, 'add', '.')
        tree = git(self.remote, 'write-tree')
        self.old = git(self.remote, 'commit-tree', tree, data='fixture\n')
        git(self.remote, 'update-ref', 'HEAD', self.old)
        git(self.remote, 'tag', 'crosstool-ng-1.0.0')
        (self.remote / 'extra').write_text('new release\n')
        git(self.remote, 'add', '.')
        tree = git(self.remote, 'write-tree')
        self.new = git(self.remote, 'commit-tree', tree, '-p', self.old, data='fixture\n')
        git(self.remote, 'update-ref', 'HEAD', self.new)
        git(self.remote, 'tag', '-a', '-m', 'annotated stable', 'crosstool-ng-2.0.0')
        subprocess.run(['git','clone','-q',str(self.remote),str(self.root/'builder')], check=True)
        git(self.root/'builder', 'checkout', '-q', '--detach', self.old)
        self.target.joinpath('config').write_text('CT_GCC_V_16=y\nCT_MUSL_V_1_2_6=y\nCT_MOLD_V_2_9_0=y\nCT_MUSL_MIRRORS="https://example.invalid/musl-1.2.6"\n')
        versions = (ROOT/'targets/x86_64-unknown-linux-musl/versions').read_text()
        values = dict(line.split('=',1) for line in versions.splitlines() if line)
        values.update(CTNG_RELEASE_TAG='crosstool-ng-1.0.0', CTNG_COMMIT=self.old)
        self.target.joinpath('versions').write_text(''.join(f'{k}={v}\n' for k,v in values.items()))
        self.release = self.root/'release.json'
        self.env = dict(os.environ, UPSTREAM_RELEASE_JSON_FILE=str(self.release), UPSTREAM_BUILDER_DIR=str(self.remote))
        self.env.pop('GITHUB_OUTPUT', None)
        self.env.pop('GITHUB_STEP_SUMMARY', None)

    def run_sync(self, tag='crosstool-ng-2.0.0', mode='--apply', **fields):
        self.release.write_text(json.dumps(dict(tag_name=tag,draft=False,prerelease=False,**fields)))
        return subprocess.run([str(self.root/'scripts/sync-upstream.sh'),mode,'--summary-file',str(self.root/'summary.md')],
                              env=self.env,text=True,capture_output=True)

    def test_missing_release_is_discovery_failure(self):
        self.env['UPSTREAM_RELEASE_JSON_FILE'] = str(self.root/'missing')
        result = subprocess.run([str(self.root/'scripts/sync-upstream.sh'),'--check'],env=self.env,text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('DISCOVERY_FAILED',result.stderr)
        self.assertIn('should_build=false',result.stdout)

    def test_draft_and_prerelease_do_not_build(self):
        for draft, prerelease in [(True,False),(False,True)]:
            self.release.write_text(json.dumps(dict(tag_name='crosstool-ng-9.0.0',draft=draft,prerelease=prerelease)))
            result=subprocess.run([str(self.root/'scripts/sync-upstream.sh'),'--apply'],env=self.env,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertIn('should_build=false',result.stdout)
            self.assertEqual(git(self.root/'builder','rev-parse','HEAD'),self.old)

    def test_same_peeled_commit_is_no_update(self):
        result = self.run_sync(tag='crosstool-ng-1.0.0')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('status=no_update',result.stdout)
        self.assertIn('should_build=false',result.stdout)
        self.assertEqual(git(self.root/'builder','rev-parse','HEAD'),self.old)

    def test_annotated_release_updates_numeric_versions_and_selectors(self):
        result = self.run_sync()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('upstream_updated=true',result.stdout)
        metadata = self.target.joinpath('versions').read_text()
        config = self.target.joinpath('config').read_text()
        for line in ['EXPECTED_GCC_VERSION=17.1.0','EXPECTED_MUSL_VERSION=1.2.7','EXPECTED_MOLD_VERSION=2.42.0']:
            self.assertIn(line,metadata)
        for line in ['CT_GCC_V_17=y','CT_MUSL_V_1_2_7=y','CT_MOLD_V_2_42_0=y','musl-1.2.7']:
            self.assertIn(line,config)
        self.assertNotIn('CT_GCC_V_16=',config)
        self.assertNotIn('CT_MOLD_V_2_9_0=',config)
        self.assertEqual(git(self.root/'builder','rev-parse','HEAD'),self.new)

    def refresh_catalog(self,tag='crosstool-ng-2.0.0'):
        git(self.remote,'add','.')
        tree=git(self.remote,'write-tree')
        self.new=git(self.remote,'commit-tree',tree,'-p',self.new,data='updated catalog\n')
        git(self.remote,'update-ref','HEAD',self.new)
        git(self.remote,'tag','-f',tag,self.new)

    def test_gcc_selector_uses_the_package_relevantpattern(self):
        for path in (self.remote/'packages/gcc').iterdir():
            if path.is_dir(): shutil.rmtree(path)
        gcc=self.remote/'packages/gcc/4.9.4'; gcc.mkdir()
        (gcc/'version.desc').write_text(''); (gcc/'chksum').write_text('fixture')
        self.refresh_catalog()
        result=self.run_sync()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('CT_GCC_V_4_9=y',self.target.joinpath('config').read_text())
        self.assertNotIn('CT_GCC_V_4=y',self.target.joinpath('config').read_text())

    def test_equal_versions_with_trailing_zero_are_not_downgrades(self):
        path=self.target/'versions'
        path.write_text(path.read_text().replace('crosstool-ng-1.0.0','crosstool-ng-1.29.0'))
        git(self.remote,'tag','crosstool-ng-1.29',self.new)
        result=self.run_sync(tag='crosstool-ng-1.29')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('status=updated',result.stdout)

    def test_uppercase_experimental_and_obsolete_flags_are_excluded(self):
        (self.remote/'packages/gcc/18.0.0/version.desc').write_text('experimental=YES\n')
        mold=self.remote/'packages/mold/99.0.0'; mold.mkdir()
        (mold/'version.desc').write_text('OBSOLETE="TRUE"\n'); (mold/'chksum').write_text('fixture')
        self.refresh_catalog()
        result=self.run_sync()
        self.assertEqual(result.returncode,0,result.stderr)
        versions=self.target.joinpath('versions').read_text()
        self.assertIn('EXPECTED_GCC_VERSION=17.1.0',versions)
        self.assertIn('EXPECTED_MOLD_VERSION=2.42.0',versions)

    def test_patch_parent_escape_is_rejected_on_stdout(self):
        (self.target/'escape.patch').write_text('--- a/../escape\n+++ b/../escape\n@@ -0,0 +1 @@\n+outside\n')
        result=self.run_sync()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('::error title=UPSTREAM_PATCH_CONFLICT::',result.stdout)
        self.assertIn('Unsafe patch target',result.stdout)
        self.assertNotIn('::error',result.stderr)
        self.assertFalse((self.root/'escape').exists())

    def run_with_rollback_faults(self,checkout_failure=False,file_restore_failure=False):
        self.release.write_text(json.dumps(dict(tag_name='crosstool-ng-2.0.0',draft=False,prerelease=False)))
        tools=self.root/'bin'; tools.mkdir()
        wrapper=tools/'git'
        wrapper.write_text('''#!/usr/bin/env python3
import os,sys
from pathlib import Path
args=sys.argv[1:]
if 'checkout' in args and args[-1]==os.environ['OLD_SHA']:
 Path(os.environ['ROLLBACK_ATTEMPT']).write_text('attempted')
 if os.environ.get('FAIL_CHECKOUT')=='1':
  print('ROLLBACK_CHECKOUT_FAILURE',file=sys.stderr); sys.exit(9)
os.execv(os.environ['REAL_GIT'],[os.environ['REAL_GIT'],*args])
''')
        wrapper.chmod(0o755)
        runner='''import os,runpy,sys
from pathlib import Path
from unittest.mock import patch
text_write=Path.write_text
bytes_write=Path.write_bytes
def fail_text(path,*args,**kwargs):
 if str(path)==os.environ['METADATA_PATH']: raise OSError('ORIGINAL_WRITE_FAILURE')
 return text_write(path,*args,**kwargs)
def fail_bytes(path,*args,**kwargs):
 if str(path)==os.environ['CONFIG_PATH'] and os.environ.get('FAIL_FILE_RESTORE')=='1': raise OSError('CONFIG_ROLLBACK_FAILURE')
 return bytes_write(path,*args,**kwargs)
sys.argv=[os.environ['SYNC_SCRIPT'],'--apply','--summary-file',os.environ['SUMMARY_PATH']]
with patch.object(Path,'write_text',fail_text), patch.object(Path,'write_bytes',fail_bytes):
 runpy.run_path(os.environ['SYNC_SCRIPT'],run_name='__main__')
'''
        env=dict(self.env,PATH=str(tools)+':'+os.environ['PATH'],REAL_GIT=shutil.which('git'),OLD_SHA=self.old,
                 ROLLBACK_ATTEMPT=str(self.root/'rollback-attempt'),FAIL_CHECKOUT='1' if checkout_failure else '0',
                 FAIL_FILE_RESTORE='1' if file_restore_failure else '0',METADATA_PATH=str(self.target/'versions'),
                 CONFIG_PATH=str(self.target/'config'),SYNC_SCRIPT=str(self.root/'scripts/upstream.py'),SUMMARY_PATH=str(self.root/'summary.md'))
        return subprocess.run(['python3','-c',runner],env=env,text=True,capture_output=True)

    def test_checkout_rollback_failure_does_not_skip_restoring_files(self):
        before={name:(self.target/name).read_bytes() for name in ('config','versions')}
        result=self.run_with_rollback_faults(checkout_failure=True)
        self.assertNotEqual(result.returncode,0)
        for name,content in before.items():self.assertEqual((self.target/name).read_bytes(),content)
        self.assertIn('ORIGINAL_WRITE_FAILURE',result.stdout)
        self.assertIn('ROLLBACK_CHECKOUT_FAILURE',result.stdout)
        self.assertTrue((self.root/'rollback-attempt').exists())

    def test_file_rollback_failure_does_not_skip_checkout_or_original_error(self):
        before=(self.target/'versions').read_bytes()
        result=self.run_with_rollback_faults(file_restore_failure=True)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual((self.target/'versions').read_bytes(),before)
        self.assertEqual(git(self.root/'builder','rev-parse','HEAD'),self.old)
        self.assertIn('ORIGINAL_WRITE_FAILURE',result.stdout)
        self.assertIn('CONFIG_ROLLBACK_FAILURE',result.stdout)
        self.assertTrue((self.root/'rollback-attempt').exists())

    def test_dirty_builder_is_not_overwritten(self):
        (self.root/'builder/marker').write_text('local work\n')
        before=self.target.joinpath('versions').read_bytes()
        result=self.run_sync()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('dirty',result.stderr)
        self.assertEqual((self.root/'builder/marker').read_text(),'local work\n')
        self.assertEqual(git(self.root/'builder','rev-parse','HEAD'),self.old)
        self.assertEqual(self.target.joinpath('versions').read_bytes(),before)

    def test_check_does_not_modify_inputs(self):
        before = self.target.joinpath('config').read_bytes()
        result = self.run_sync(mode='--check')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('status=update_available',result.stdout)
        self.assertEqual(self.target.joinpath('config').read_bytes(),before)
        self.assertEqual(git(self.root/'builder','rev-parse','HEAD'),self.old)

    def test_conflict_reports_patch_and_leaves_every_input_untouched(self):
        patch = self.target/'broken.patch'
        patch.write_text('--- a/marker\n+++ b/marker\n@@ -1 +1 @@\n-wrong context\n+changed\n')
        before = {name:(self.target/name).read_bytes() for name in ['config','versions']}
        result = self.run_sync()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('UPSTREAM_PATCH_CONFLICT',result.stderr)
        summary = self.root.joinpath('summary.md').read_text()
        for expected in ['broken.patch',self.old,self.new,'17.1.0','FAILED','Published v0.0.1 Release: UNTOUCHED','Manual repair']:
            self.assertIn(expected,summary)
        for name,value in before.items(): self.assertEqual((self.target/name).read_bytes(),value)
        self.assertEqual(git(self.root/'builder','rev-parse','HEAD'),self.old)
        self.assertEqual(git(self.root/'builder','status','--porcelain'),'')

    def test_dependent_patches_are_preflighted_in_order(self):
        for name,old,new in [('first','before','middle'),('second','middle','after')]:
            self.target.joinpath(name+'.patch').write_text(f'--- a/marker\n+++ b/marker\n@@ -1 +1 @@\n-{old}\n+{new}\n')
        result = self.run_sync()
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual((self.root/'builder/marker').read_text(),'before\n')

    def test_schedule_skips_no_update(self):
        self.release.write_text(json.dumps(dict(tag_name='crosstool-ng-1.0.0',draft=False,prerelease=False)))
        env=dict(self.env,CI_EVENT='schedule',INPUT_TARGETS='',INPUT_CONTAINERS='',CHECK_UPSTREAM='false',CREATE_RELEASE='false',SOURCE_RUN_ID='')
        result=subprocess.run(['python3',str(self.root/'scripts/ci.py'),'prepare',str(self.root/'payload')],env=env,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('should_build=false',result.stdout)
        self.assertIn('should_release=false',result.stdout)
        self.assertFalse((self.root/'payload/candidate.bundle').exists())

    def initialize_parent(self):
        git(self.root,'init','-q')
        git(self.root,'add','scripts','targets')
        git(self.root,'update-index','--add','--cacheinfo',f'160000,{self.old},builder')
        tree=git(self.root,'write-tree')
        base=git(self.root,'commit-tree',tree,data='fixture root\n')
        git(self.root,'update-ref','HEAD',base)
        return base

    def test_prepare_creates_one_root_snapshot_without_advancing_head(self):
        base=self.initialize_parent()
        self.release.write_text(json.dumps(dict(tag_name='crosstool-ng-2.0.0',draft=False,prerelease=False)))
        env=dict(self.env,CI_EVENT='schedule',INPUT_TARGETS='',INPUT_CONTAINERS='',CHECK_UPSTREAM='false',CREATE_RELEASE='false',SOURCE_RUN_ID='')
        result=subprocess.run(['python3',str(self.root/'scripts/ci.py'),'prepare',str(self.root/'payload')],env=env,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        source=json.loads((self.root/'payload/source.json').read_text())
        sha=source['source_sha']
        self.assertTrue(source['upstream_updated'])
        self.assertNotEqual(sha,base)
        self.assertEqual(git(self.root,'rev-parse','HEAD'),base)
        self.assertEqual(git(self.root,'rev-list','--count',sha),'1')
        self.assertEqual(git(self.root,'show','-s','--format=%an <%ae>%n%cn <%ce>%n%B',sha),
                         'Nathan Shea <itzrustz@gmail.com>\nNathan Shea <itzrustz@gmail.com>\nfirst commit')
        self.assertIn(self.new,git(self.root,'ls-tree',sha,'builder'))
        self.assertIn(sha,git(self.root,'bundle','list-heads',str(self.root/'payload/candidate.bundle')))

    def test_manual_check_without_change_still_builds(self):
        self.initialize_parent()
        self.release.write_text(json.dumps(dict(tag_name='crosstool-ng-1.0.0',draft=False,prerelease=False)))
        env=dict(self.env,CI_EVENT='workflow_dispatch',INPUT_TARGETS='',INPUT_CONTAINERS='',CHECK_UPSTREAM='true',CREATE_RELEASE='false',SOURCE_RUN_ID='')
        result=subprocess.run(['python3',str(self.root/'scripts/ci.py'),'prepare',str(self.root/'payload')],env=env,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('should_build=true',result.stdout)
        self.assertIn('upstream_updated=false',result.stdout)
        self.assertTrue((self.root/'payload/candidate.bundle').is_file())

unittest.main()
PY
