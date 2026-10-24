#!/usr/bin/env python3
"""Write failure diagnostics and optionally deliver an authenticated SMTP email."""
from email.message import EmailMessage
import json
import os
from pathlib import Path
import smtplib
import ssl
import sys


def annotate(code,message):
    escaped=message.replace('%','%25').replace('\r','%0D').replace('\n','%0A')
    print(f'::error title={code}::{escaped}',flush=True)


def main():
    try:
        needs=json.loads(os.environ.get('NEEDS_JSON','{}'))
        failures=[name for name,value in needs.items() if value.get('result')=='failure']
    except (ValueError,AttributeError):
        failures=['unknown (invalid job-result diagnostics)']
    url=os.environ.get('RUN_URL','unknown')
    # Emit the original failure even if all diagnostic files are unavailable.
    annotate('TOOLCHAIN_WORKFLOW_FAILED','Failed stages: '+', '.join(failures)+'; '+url)
    text='## Toolchain workflow failure\n\nFailed stages: '+', '.join(failures)+'\n\nRun: '+url+'\n\n'
    directory=Path(os.environ.get('DIAGNOSTIC_DIR','.'))
    diagnostics=[]
    touched=False
    unknown=False
    candidate=None
    for name in ('upstream-summary.md','source.json','publication.json'):
        for path in sorted(directory.rglob(name)):
            try:
                content=path.read_text()
                diagnostics.append((name,content))
                if name=='publication.json':
                    value=json.loads(content).get('publication_touched')
                    if type(value) is not bool: raise ValueError('invalid publication_touched')
                    touched=touched or value
                if name=='source.json': candidate=json.loads(content).get('versions')
            except (OSError,ValueError,AttributeError):
                diagnostics.append((name,'Diagnostic unavailable or malformed.'))
                if name=='publication.json': unknown=True
    if touched or unknown:
        text+='Publication state: assets may have been partially updated; inspect publication.json and rollback_status.\n\n'
        if unknown: annotate('PUBLICATION_STATE_UNKNOWN','Publication journal is unreadable; inspect the publisher log')
    else:
        text+='Published v0.0.1 Release: UNTOUCHED\n\nNo publication journal reports release writes.\n\n'
    if isinstance(candidate,dict):
        text+='### Candidate component expectations\n\n~~~json\n'+json.dumps(candidate,indent=2)+'\n~~~\n\n'
    else:
        versions=Path(__file__).resolve().parent.parent/'targets/x86_64-unknown-linux-musl/versions'
        try: content=versions.read_text()
        except OSError: content='Version metadata unavailable; inspect the failed job diagnostics.'
        text+='### Checked-out fallback (candidate expectations unavailable)\n\n~~~text\n'+content+'\n~~~\n\n'
    for name,content in diagnostics:
        text+=f'### {name}\n\n~~~text\n'+content+'\n~~~\n\n'
    text+='Review the failed patch/stage log, repair in a disposable checkout, run bash tests/run.sh, then rerun the workflow.\n'
    text+='\nGitHub native Actions email depends on the Owner/subscriber notification settings; delivery is not guaranteed.\n'
    summary=os.environ.get('GITHUB_STEP_SUMMARY')

    def append_summary(content):
        if summary:
            try:
                with open(summary,'a') as stream: stream.write(content)
            except OSError: annotate('DIAGNOSTIC_WRITE_FAILED','Unable to write the step summary; inspect the job log')

    append_summary(text)
    keys=('SMTP_HOST','SMTP_USERNAME','SMTP_PASSWORD','NOTIFY_EMAIL_TO')
    if not all(os.environ.get(key) for key in keys):
        message='SMTP notification not configured; configure all four secrets for designated failure email.'
        print(message,flush=True)
        append_summary('\n'+message+'\n')
        return 0
    message=EmailMessage()
    message['Subject']='musl-cross build/update failed: '+', '.join(failures)
    message['From']=os.environ.get('SMTP_FROM') or os.environ['SMTP_USERNAME']
    message['To']=os.environ['NOTIFY_EMAIL_TO']
    message.set_content(text)
    try:
        port=int(os.environ.get('SMTP_PORT') or '587')
        context=ssl.create_default_context()
        if port==465:
            connection=smtplib.SMTP_SSL(os.environ['SMTP_HOST'],port,timeout=30,context=context)
        else:
            connection=smtplib.SMTP(os.environ['SMTP_HOST'],port,timeout=30)
        with connection as client:
            if port!=465: client.starttls(context=context)
            client.login(os.environ['SMTP_USERNAME'],os.environ['SMTP_PASSWORD'])
            client.send_message(message)
    except (OSError,ValueError,OverflowError,smtplib.SMTPException):
        annotate('EMAIL_DELIVERY_FAILED','SMTP delivery failed; inspect provider settings without exposing credentials')
        return 1
    print('Failure email delivered to the configured SMTP provider.',flush=True)
    return 0


if __name__=='__main__': sys.exit(main())
