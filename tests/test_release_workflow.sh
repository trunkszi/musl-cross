#!/usr/bin/env bash
set -euo pipefail
export REPO_ROOT
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(os.environ['REPO_ROOT'])
HOSTS=['amazonlinux2','alinux3','centos7','ubuntu22']
TARGET='x86_64-unknown-linux-musl'

class ReleaseWorkflow(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work=Path(self.temp.name)
        self.artifacts=self.work/'artifacts'
        self.artifacts.mkdir()
        self.sha=subprocess.check_output(['git','-C',str(ROOT),'rev-parse','HEAD'],text=True).strip()
        versions=dict(line.split('=',1) for line in (ROOT/'targets'/TARGET/'versions').read_text().splitlines() if line)
        self.source=dict(schema=1,source_sha=self.sha,base_sha=self.sha,upstream_updated=False,versions=versions)
        self.source_file=self.work/'source.json'
        self.source_file.write_text(json.dumps(self.source))
        for host in HOSTS:
            name=f'{TARGET}-{host}.tar.xz'
            archive=self.artifacts/name
            archive.write_bytes(b'fixture archive '+host.encode())
            digest=hashlib.sha256(archive.read_bytes()).hexdigest()
            self.artifacts.joinpath(name+'.sha256').write_text(digest+'\n')
            receipt=dict(source_sha=self.sha,host=host,target=TARGET,versions=versions,filename=name,sha256=digest)
            self.artifacts.joinpath(name+'.json').write_text(json.dumps(receipt))
        stub=self.work/'gh'
        stub.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as stream: stream.write(json.dumps(args)+'\\n')
p=Path(os.environ['STATE'])
s=json.loads(p.read_text()) if p.exists() else {'main':os.environ['GITHUB_SHA'],'tag':None if os.environ.get('NO_TAG') else 'b'*40,'release':None if os.environ.get('NO_RELEASE') else {'id':100,'draft':False,'immutable':False}}
def save(): p.write_text(json.dumps(s))
if args[:1]==['api'] and args[1]!='--method':
 include=args[1]=='--include'; path=args[2] if include else args[1]; status=200
 if '/actions/runs/' in path:
  data={'event':'workflow_dispatch','status':'completed','conclusion':os.environ.get('RUN_CONCLUSION','success'),'head_sha':os.environ['GITHUB_SHA'],'head_branch':'main','path':'.github/workflows/release.yaml','repository':{'full_name':os.environ['GITHUB_REPOSITORY']}}
 elif '/git/ref/heads/main' in path: data={'object':{'sha':s['main']}}
 elif '/git/ref/tags/' in path:
  data={'object':{'sha':s['tag']}}
  if s['tag'] is None: status=404
 elif '/releases/tags/' in path:
  data=s['release']
  if data is None: status=404
  if os.environ.get('API_FAILURE'): status=403
 else: sys.exit(99)
 save()
 print(('HTTP/2.0 '+str(status)+' Status\\nContent-type: application/json\\n\\n' if include else '')+json.dumps(data))
 sys.exit(0 if status==200 else 1)
if args[:2]==['release','create']:
 s['release']={'id':101,'draft':True,'immutable':False}
 if os.environ.get('CREATE_TAG_EARLY'): s['tag']=os.environ['SOURCE_SHA']
elif args[:2]==['release','upload'] and os.environ.get('FAIL_UPLOAD'): sys.exit(2)
elif args[:2]==['release','edit']:
 if os.environ.get('FAIL_EDIT') or ('--draft=false' in args and os.environ.get('FAIL_PUBLISH')): sys.exit(2)
 s['release']['draft']='--draft=false' not in args
elif args[:2]==['release','delete']: s['release']=None
elif args[:3]==['api','--method','DELETE']:
 if '/releases/' in args[3]: s['release']=None
 else: s['tag']=None
elif args[:3] in (['api','--method','PATCH'],['api','--method','POST']):
 if os.environ.get('FAIL_TAG'): sys.exit(2)
 s['tag']=next(a[4:] for a in args if a.startswith('sha='))
save()
sys.exit(0)
''')
        git_stub=self.work/'git'
        git_stub.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
args=sys.argv[1:]
with open(os.environ['CALLS'],'a') as stream: stream.write(json.dumps(['git',*args])+'\\n')
if 'rev-parse' in args: print(os.environ['SOURCE_SHA'])
elif 'rev-list' in args: print('1')
elif 'show' in args: print('Nathan Shea <itzrustz@gmail.com>\\nNathan Shea <itzrustz@gmail.com>\\nfirst commit')
elif args[:1]==['push'] and args[-1].endswith(':refs/heads/main'):
 if os.environ.get('FAIL_MAIN') and args[-1].split(':')[0]==os.environ['SOURCE_SHA']: sys.exit(2)
 p=Path(os.environ['STATE']); state=json.loads(p.read_text()); state['main']=args[-1].split(':')[0]; p.write_text(json.dumps(state))
sys.exit(0)
''')
        git_stub.chmod(0o755)
        stub.chmod(0o755)
        self.env=dict(os.environ,PATH=str(self.work)+os.pathsep+os.environ['PATH'],CALLS=str(self.work/'calls'),
                      GITHUB_REPOSITORY='fixture/musl-cross',GITHUB_SHA=self.sha,SOURCE_SHA=self.sha,STATE=str(self.work/'state.json'),
                      GITHUB_STEP_SUMMARY=str(self.work/'summary.md'),PYTHONDONTWRITEBYTECODE='1')

    def invoke(self,command='publish',*extra):
        return subprocess.run(['python3',str(ROOT/'scripts/release.py'),command,str(self.artifacts),str(self.source_file),
                               '--notes',str(self.work/'RELEASE.md'),*extra],env=self.env,capture_output=True,text=True)

    def calls(self):
        path=self.work/'calls'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def test_manual_and_scheduled_plans(self):
        for event,publish,check in [('schedule',True,True),('workflow_dispatch',False,False)]:
            env=dict(self.env,CI_EVENT=event,CHECK_UPSTREAM='false',CREATE_RELEASE='false',INPUT_CONTAINERS='all',INPUT_TARGETS=TARGET,SOURCE_RUN_ID='')
            result=subprocess.run(['python3',str(ROOT/'scripts/ci.py'),'plan'],env=env,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            plan=json.loads(result.stdout)
            self.assertEqual(plan['publish'],publish)
            self.assertEqual(plan['check_upstream'],check)
            self.assertEqual(len(plan['matrix']['include']),4)

    def test_partial_publish_is_rejected(self):
        result=subprocess.run(['python3',str(ROOT/'scripts/ci.py'),'plan'],env=dict(self.env,CREATE_RELEASE='true',INPUT_CONTAINERS='ubuntu22'),text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0)

    def test_upload_and_edit_happen_before_tag_update(self):
        result=self.invoke()
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.calls()
        upload=next(i for i,c in enumerate(calls) if c[:2]==['release','upload'])
        edit=next(i for i,c in enumerate(calls) if c[:2]==['release','edit'])
        tag=next(i for i,c in enumerate(calls) if c[:3]==['api','--method','PATCH'])
        self.assertLess(upload,edit)
        self.assertLess(edit,tag)
        self.assertIn('sha='+self.sha,calls[tag])

    def updated_source(self):
        self.source['upstream_updated']=True
        self.source['base_sha']='a'*40
        self.source_file.write_text(json.dumps(self.source))
        self.env['GITHUB_SHA']='a'*40

    def test_new_release_upload_failure_removes_owned_draft_and_implicit_tag(self):
        self.env.update(NO_RELEASE='1',NO_TAG='1',CREATE_TAG_EARLY='1',FAIL_UPLOAD='1')
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        state=json.loads((self.work/'state.json').read_text())
        self.assertIsNone(state['release'])
        self.assertIsNone(state['tag'])

    def test_new_release_metadata_failure_cleans_draft(self):
        self.env.update(NO_RELEASE='1',NO_TAG='1',FAIL_EDIT='1')
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        state=json.loads((self.work/'state.json').read_text())
        self.assertIsNone(state['release'])
        self.assertIsNone(state['tag'])

    def test_first_publish_failure_rolls_back_both_refs_and_draft(self):
        self.updated_source(); self.env.update(NO_RELEASE='1',NO_TAG='1',FAIL_PUBLISH='1')
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        state=json.loads((self.work/'state.json').read_text())
        self.assertEqual(state['main'],'a'*40)
        self.assertIsNone(state['tag'])
        self.assertIsNone(state['release'])
        journal=json.loads((self.work/'publication.json').read_text())
        self.assertEqual(journal['failed_stage'],'draft_publish_attempted')
        self.assertEqual(journal['rollback_status'],'complete')

    def test_updated_tag_moves_before_main(self):
        self.updated_source()
        result=self.invoke()
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.calls()
        tag=next(i for i,c in enumerate(calls) if c[:3]==['api','--method','PATCH'])
        main=next(i for i,c in enumerate(calls) if c[:2]==['git','push'] and c[-1].endswith(':refs/heads/main'))
        self.assertLess(tag,main)

    def test_tag_failure_does_not_advance_main(self):
        self.updated_source(); self.env['FAIL_TAG']='1'
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(json.loads((self.work/'state.json').read_text())['main'],'a'*40)

    def test_main_failure_restores_previous_tag_and_records_rollback(self):
        self.updated_source(); self.env['FAIL_MAIN']='1'
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        state=json.loads((self.work/'state.json').read_text())
        self.assertEqual(state['tag'],'b'*40)
        self.assertEqual(state['main'],'a'*40)
        journal=json.loads((self.work/'publication.json').read_text())
        self.assertEqual(journal['rollback_status'],'complete')

    def test_upload_failure_never_moves_tag(self):
        self.env['FAIL_UPLOAD']='1'
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:3]==['api','--method','PATCH'] for c in self.calls()))
        self.assertFalse(any(c[:2]==['release','edit'] for c in self.calls()))
        self.assertIn('partial',result.stderr)

    def test_edit_failure_never_moves_tag(self):
        self.env['FAIL_EDIT']='1'
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:3]==['api','--method','PATCH'] for c in self.calls()))

    def test_bad_checksum_and_missing_cell_block_all_remote_calls(self):
        self.artifacts.joinpath(f'{TARGET}-centos7.tar.xz.sha256').write_text('0'*64+'\n')
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.calls(),[])

    def test_foreign_receipt_is_rejected(self):
        path=self.artifacts/f'{TARGET}-ubuntu22.tar.xz.json'
        data=json.loads(path.read_text()); data['source_sha']='a'*40; path.write_text(json.dumps(data))
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.calls(),[])

    def test_new_release_is_prepared_as_draft(self):
        self.env['NO_RELEASE']='1'
        result=self.invoke()
        self.assertEqual(result.returncode,0,result.stderr)
        create=next(c for c in self.calls() if c[:2]==['release','create'])
        self.assertIn('--draft',create)
        self.assertIn('--target',create)

    def test_http_403_is_not_treated_as_missing_release(self):
        self.env['API_FAILURE']='1'
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        self.assertIn('HTTP 403',result.stderr)
        self.assertFalse(any(c[:1]==['release'] for c in self.calls()))

    def test_invalid_repository_is_rejected_before_api_access(self):
        self.env['GITHUB_REPOSITORY']='owner/repo/../../other'
        result=self.invoke('publish','--source-run-id','42')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Invalid repository name',result.stdout)
        self.assertEqual(self.calls(),[])

    def test_failed_historical_run_cannot_publish(self):
        self.env['RUN_CONCLUSION']='failure'
        result=self.invoke('publish','--source-run-id','42')
        self.assertNotEqual(result.returncode,0)
        self.assertFalse(any(c[:1]==['release'] for c in self.calls()))

    def test_failure_summary_without_smtp_secrets(self):
        env=dict(self.env,NEEDS_JSON=json.dumps({'prepare-matrix':{'result':'failure'},'build':{'result':'skipped'},'release':{'result':'skipped'}}),
                 DIAGNOSTIC_DIR=str(self.work),RUN_URL='https://example.invalid/run/42')
        for key in ('SMTP_HOST','SMTP_USERNAME','SMTP_PASSWORD','NOTIFY_EMAIL_TO'): env.pop(key,None)
        result=subprocess.run(['python3',str(ROOT/'scripts/notify-failure.py')],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('::error',result.stdout)
        summary=Path(env['GITHUB_STEP_SUMMARY']).read_text()
        self.assertIn('prepare-matrix',summary)
        self.assertIn('UNTOUCHED',summary)
        self.assertIn('SMTP notification not configured',summary)

    def test_release_failure_uses_publication_journal(self):
        for touched in (None,False,True):
            journal=self.work/'publication.json'
            if touched is None:
                if journal.exists(): journal.unlink()
            else: journal.write_text(json.dumps({'publication_touched':touched}))
            summary=self.work/'notification.md'
            if summary.exists(): summary.unlink()
            env=dict(self.env,NEEDS_JSON=json.dumps({'release':{'result':'failure'}}),DIAGNOSTIC_DIR=str(self.work),GITHUB_STEP_SUMMARY=str(summary))
            for key in ('SMTP_HOST','SMTP_USERNAME','SMTP_PASSWORD','NOTIFY_EMAIL_TO'): env.pop(key,None)
            result=subprocess.run(['python3',str(ROOT/'scripts/notify-failure.py')],env=env,text=True,capture_output=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual('Published v0.0.1 Release: UNTOUCHED' in summary.read_text(),not bool(touched))

    def test_missing_versions_still_emits_failure_annotation(self):
        script=self.work/'scripts/notify-failure.py'
        script.parent.mkdir()
        script.write_text((ROOT/'scripts/notify-failure.py').read_text())
        env=dict(self.env,NEEDS_JSON=json.dumps({'release':{'result':'failure'}}),DIAGNOSTIC_DIR=str(self.work/'empty-diagnostics'))
        for key in ('SMTP_HOST','SMTP_USERNAME','SMTP_PASSWORD','NOTIFY_EMAIL_TO'): env.pop(key,None)
        result=subprocess.run(['python3',str(script)],env=env,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('::error title=TOOLCHAIN_WORKFLOW_FAILED::',result.stdout)
        self.assertNotIn('Traceback',result.stderr)

    def test_notification_prefers_candidate_metadata(self):
        self.source['versions']['EXPECTED_GCC_VERSION']='candidate-version'
        self.source_file.write_text(json.dumps(self.source))
        env=dict(self.env,NEEDS_JSON=json.dumps({'build':{'result':'failure'}}),DIAGNOSTIC_DIR=str(self.work))
        for key in ('SMTP_HOST','SMTP_USERNAME','SMTP_PASSWORD','NOTIFY_EMAIL_TO'): env.pop(key,None)
        result=subprocess.run(['python3',str(ROOT/'scripts/notify-failure.py')],env=env,text=True,capture_output=True)
        self.assertEqual(result.returncode,0,result.stderr)
        summary=(self.work/'summary.md').read_text()
        self.assertIn('Candidate component expectations',summary)
        self.assertIn('candidate-version',summary)
        self.assertNotIn('Checked-out fallback',summary)

    def test_mail_errors_emit_stdout_annotation_without_network(self):
        env=dict(self.env,NEEDS_JSON=json.dumps({'build':{'result':'failure'}}),DIAGNOSTIC_DIR=str(self.work),
                 SMTP_HOST='example.invalid',SMTP_USERNAME='fixture',SMTP_PASSWORD='secret-placeholder',NOTIFY_EMAIL_TO='owner@example.invalid',SMTP_PORT='invalid')
        result=subprocess.run(['python3',str(ROOT/'scripts/notify-failure.py')],env=env,text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('::error title=EMAIL_DELIVERY_FAILED::',result.stdout)
        self.assertNotIn('::error',result.stderr)
        self.assertNotIn('secret-placeholder',result.stdout+result.stderr)

    def test_ci_annotations_use_stdout(self):
        result=subprocess.run(['python3',str(ROOT/'scripts/ci.py'),'plan'],env=dict(self.env,CI_EVENT='unsupported'),text=True,capture_output=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('::error title=CI_PREPARATION_FAILED::',result.stdout)
        self.assertNotIn('::error',result.stderr)

    def test_configured_smtp_uses_tls_and_sends_diagnostics_without_leaking_password(self):
        stub=self.work/'smtplib.py'
        stub.write_text('''import os
from pathlib import Path
class SMTPException(Exception): pass
class SMTP:
 def __init__(self,host,port,timeout):
  assert host=='smtp.example.invalid' and port==587 and timeout==30
  self.ready=False
 def __enter__(self): return self
 def __exit__(self,*args): pass
 def starttls(self,context): self.ready=True
 def login(self,user,password):
  assert self.ready and user=='ci@example.invalid' and password=='do-not-log-this-password'
 def send_message(self,message):
  Path(os.environ['MAIL_CAPTURE']).write_text(message.as_string())
SMTP_SSL=SMTP
''')
        env=dict(self.env,PYTHONPATH=str(self.work),SMTP_HOST='smtp.example.invalid',SMTP_USERNAME='ci@example.invalid',
                 SMTP_PASSWORD='do-not-log-this-password',NOTIFY_EMAIL_TO='owner@example.invalid',SMTP_PORT='587',
                 MAIL_CAPTURE=str(self.work/'mail.txt'),DIAGNOSTIC_DIR=str(self.work),
                 NEEDS_JSON=json.dumps({'build':{'result':'failure'}}))
        result=subprocess.run(['python3',str(ROOT/'scripts/notify-failure.py')],env=env,capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue((self.work/'mail.txt').is_file())
        self.assertIn('build',(self.work/'mail.txt').read_text())
        self.assertNotIn('do-not-log-this-password',result.stdout+result.stderr)

    def test_missing_artifact_blocks_all_remote_calls(self):
        self.artifacts.joinpath(f'{TARGET}-ubuntu22.tar.xz').unlink()
        result=self.invoke()
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(self.calls(),[])

    def test_workflow_wires_the_declared_entrypoints(self):
        text=(ROOT/'.github/workflows/release.yaml').read_text()
        self.assertIn("cron: '10 2 * * *'",text)
        for name in ('targets','containers','create_release','release_tag','source_run_id','check_upstream'):
            self.assertIn('      '+name+':',text)
        self.assertIn('scripts/ci.py prepare',text)
        self.assertIn('scripts/release.py publish',text)
        self.assertIn('scripts/notify-failure.py',text)
        self.assertIn("needs.prepare-matrix.outputs.should_build == 'true'",text)
        self.assertIn("needs.prepare-matrix.result == 'failure'",text)

unittest.main()
PY
