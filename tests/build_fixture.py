"""Run the real build driver with temporary paths and external build-tool stubs."""
import os
from pathlib import Path
import shutil
import subprocess


class BuildFixture:
    def __init__(self,root,source):
        self.root=Path(root)
        self.target='x86_64-unknown-linux-musl'
        self.prefix=self.root/'install'/self.target
        self.tmp=self.root/'tmp'; self.tmp.mkdir()
        scripts=self.root/'scripts'; scripts.mkdir()
        driver=(source/'scripts/make').read_text().replace('/opt/x-tools',str(self.root/'install'))
        driver=driver.replace('[[ $EUID == 0 ]] || SUDO=(sudo)','SUDO=()')
        (scripts/'make').write_text(driver)
        shutil.copy(source/'scripts/host-dependencies.sh',scripts/'host-dependencies.sh')
        (scripts/'verify-toolchain.sh').write_text('#!/bin/sh\nexit 0\n')
        (scripts/'verify-toolchain.sh').chmod(0o755)
        target=self.root/'targets'/self.target; target.mkdir(parents=True)
        self.mirror='CT_MUSL_MIRRORS="https://example.invalid/musl-1.2.6?a=1&b=2|suffix"'
        config=(source/'targets'/self.target/'config').read_text()
        config='\n'.join(self.mirror if line.startswith('CT_MUSL_MIRRORS=') else line for line in config.splitlines())+'\n'
        (target/'config').write_text(config)
        values=dict(line.split('=',1) for line in (source/'targets'/self.target/'versions').read_text().splitlines() if line)
        builder=self.root/'builder'; builder.mkdir()
        (builder/'bootstrap').write_text('#!/bin/sh\nif [ "${FAIL_BOOTSTRAP:-0}" = 1 ]; then exit 17; fi\n')
        (builder/'configure').write_text('#!/bin/sh\nprintf "%s" "${1#--prefix=}" > ctng-prefix\n')
        ctng='#!/bin/sh\ncase "$1" in\nolddefconfig) cat >> .config <<\'CONFIG\'\n'
        for name in ('GCC','MUSL','MOLD','BINUTILS','LINUX'):
            ctng+=f'CT_{name}_VERSION="{values["EXPECTED_"+name+"_VERSION"]}"\n'
        ctng+='CONFIG\n;;\nbuild.*) cp .config "$CAPTURE_CONFIG";;\nesac\n'
        (builder/'ct-ng').write_text(ctng)
        for path in builder.iterdir(): path.chmod(0o755)
        identity=dict(os.environ,GIT_AUTHOR_NAME='Fixture',GIT_AUTHOR_EMAIL='fixture@example.invalid',
                      GIT_COMMITTER_NAME='Fixture',GIT_COMMITTER_EMAIL='fixture@example.invalid')
        subprocess.run(['git','init','-q',str(builder)],check=True)
        subprocess.run(['git','-C',str(builder),'add','.'],check=True)
        tree=subprocess.check_output(['git','-C',str(builder),'write-tree'],text=True).strip()
        sha=subprocess.check_output(['git','-C',str(builder),'commit-tree',tree,'-m','fixture'],env=identity,text=True).strip()
        subprocess.run(['git','-C',str(builder),'update-ref','HEAD',sha],check=True)
        values['CTNG_COMMIT']=sha
        (target/'versions').write_text(''.join(f'{key}={value}\n' for key,value in values.items()))
        tools=self.root/'bin'; tools.mkdir()
        (tools/'make').write_text('''#!/bin/sh
if [ "$1" = install ]; then
 prefix=$(cat ctng-prefix)
 mkdir -p "$prefix/bin"
 cp ct-ng "$prefix/bin/ct-ng"
fi
''')
        (tools/'tar').write_text('''#!/bin/sh
case " $* " in
 *" -cJvf "*)
 while [ "$1" != -cJvf ]; do shift; done
 printf partial > "$2"
 exit 37;;
esac
exec "$REAL_TAR" "$@"
''')
        for path in tools.iterdir(): path.chmod(0o755)
        self.env=dict(os.environ,PATH=str(tools)+':'+os.environ['PATH'],REAL_TAR=shutil.which('tar'),
                      TMPDIR=str(self.tmp),CAPTURE_CONFIG=str(self.root/'captured-config'))

    def run(self,bootstrap=False):
        return subprocess.run(['bash',str(self.root/'scripts/make'),self.target,'--skip-deps'],
                              env=dict(self.env,FAIL_BOOTSTRAP='1' if bootstrap else '0'),cwd='/',text=True,capture_output=True)
