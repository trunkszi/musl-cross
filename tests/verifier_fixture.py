"""Minimal compiler boundary used to test verifier admission and timeouts."""
import os
from pathlib import Path
import subprocess


class VerifierFixture:
    def __init__(self,directory,source):
        self.root=Path(directory)
        self.tool=self.root/'toolchain'
        self.target='x86_64-unknown-linux-musl'
        self.sysroot=self.tool/'sysroot'
        self.tmp=self.root/'tmp'
        for path in (self.tool/'bin',self.tool/self.target/'bin',self.sysroot/'lib',self.sysroot/'usr',self.tmp): path.mkdir(parents=True,exist_ok=True)
        self.cc=self.tool/'bin'/f'{self.target}-gcc'
        self.cxx=self.tool/'bin'/f'{self.target}-g++'
        self.mold=self.tool/self.target/'bin/ld.mold'
        runtime=self.tool/'runtime.so'; runtime.write_text('placeholder')
        compiler=f'''#!/bin/sh
case "$1" in
-dumpfullversion) echo 16.2.0;;
-print-sysroot) echo "{self.sysroot}";;
-print-file-name=*) echo "{runtime}";;
*) printf compile > "{self.root}/compiler-entered"; exec sleep 5;;
esac
'''
        self.cc.write_text(compiler); self.cxx.write_text(compiler)
        self.mold.write_text('#!/bin/sh\necho "mold 2.41.0"\n')
        loader=self.sysroot/'lib/ld-musl-x86_64.so.1'
        loader.write_text('#!/bin/sh\necho "Version 1.2.6"\n')
        for path in (self.cc,self.cxx,self.mold,loader):path.chmod(0o755)
        self.script=source/'scripts/verify-toolchain.sh'
        self.env=dict(os.environ,TMPDIR=str(self.tmp))

    def run(self):
        return subprocess.run(['bash',str(self.script),self.target,str(self.tool),'16.2.0','1.2.6','ld-musl-x86_64.so.1','2.41.0'],
                              env=self.env,capture_output=True,text=True,timeout=3)
