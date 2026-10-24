#!/usr/bin/env bash
set -euo pipefail
export REPO_ROOT
REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 - <<'PY'
import ast
import sys
import shutil
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(os.environ['REPO_ROOT'])
sys.path.insert(0,str(ROOT/'tests'))
from build_fixture import BuildFixture
from verifier_fixture import VerifierFixture

class ScriptsContract(unittest.TestCase):
    def test_all_scripts_parse(self):
        for base in ('scripts','tests'):
            for path in (ROOT/base).rglob('*'):
                if path.is_file() and (path.suffix in ('.sh','.conf') or path.name=='make'):
                    result = subprocess.run(['bash','-n',str(path)],capture_output=True,text=True)
                    self.assertEqual(result.returncode,0,str(path)+result.stderr)
                if path.suffix == '.py': ast.parse(path.read_text(),filename=str(path))

    def test_profiles_are_declarative_without_external_commands(self):
        profiles = sorted((ROOT/'scripts/packages').glob('*.conf'))
        self.assertEqual(len(profiles),8)
        with tempfile.TemporaryDirectory() as directory:
            for name in ('id','timeout','yum','dnf','command','python3','pip','apt-get','apk','pacman'):
                path=Path(directory)/name
                path.write_text('#!/bin/bash\nprintf called >> "$CALL_LOG"\nexit 99\n')
                path.chmod(0o755)
            for profile in profiles:
                env=dict(os.environ,PATH=directory,CALL_LOG=directory+'/calls')
                result=subprocess.run(['/bin/bash','--noprofile','--norc','-euo','pipefail','-c',
                    'source "$1"; declare -p PACKAGES MIRROR_SETUP_COMMANDS EXTRA_SETUP_COMMANDS PACKAGE_MANAGERS >/dev/null',
                    'profile',str(profile)],env=env,capture_output=True,text=True)
                self.assertEqual(result.returncode,0,profile.name+result.stderr)
                self.assertEqual(result.stdout,'')
                self.assertEqual(result.stderr,'')
            self.assertFalse((Path(directory)/'calls').exists())

    def test_make_rejects_unknown_arguments_before_building(self):
        for args in ([],['../builder'],['unknown-target'],['x86_64-unknown-linux-musl','--other'],['x86_64-unknown-linux-musl','--skip-deps','extra']):
            result=subprocess.run([str(ROOT/'scripts/make'),*args],cwd='/',capture_output=True,text=True)
            self.assertEqual(result.returncode,64,result.stderr)

    def test_make_rejects_command_substitution_in_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'scripts').mkdir()
            shutil.copy(ROOT/'scripts/make',root/'scripts/make')
            target=root/'targets/x86_64-unknown-linux-musl'; target.mkdir(parents=True)
            (target/'config').write_text('fixture')
            marker=root/'injected'
            (target/'versions').write_text(f'CTNG_COMMIT=$(touch {marker})\n')
            result=subprocess.run(['bash',str(root/'scripts/make'),'x86_64-unknown-linux-musl','--skip-deps'],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('Invalid version metadata',result.stderr)
            self.assertFalse(marker.exists())

    def test_fresh_host_installs_dependencies_before_all_builder_git_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture=BuildFixture(directory,ROOT)
            dependencies=fixture.root/'scripts/host-dependencies.sh'
            dependencies.write_text('install_dependencies() { touch "$DEPENDENCIES_READY"; }\n')
            git=fixture.root/'bin/git'
            git.write_text('''#!/bin/bash
[[ -f $DEPENDENCIES_READY ]] || { echo "git: command not found (dependencies not installed)" >&2; exit 127; }
[[ $1 == -c && $2 == 'safe.directory=*' ]] || { echo "Missing container-safe Git configuration" >&2; exit 128; }
[[ " $* " != *" -C "* ]] || { echo "Unknown option: -C (CentOS 7 Git)" >&2; exit 129; }
printf '%s\\n' "$*" >> "$GIT_CALLS"
exec "$REAL_GIT" "$@"
''')
            git.chmod(0o755)
            fixture.env.update(DEPENDENCIES_READY=str(fixture.root/'dependencies-ready'),
                               GIT_CALLS=str(fixture.root/'git-calls'),REAL_GIT=shutil.which('git'))
            result=subprocess.run(['bash',str(fixture.root/'scripts/make'),fixture.target],
                                  env=dict(fixture.env,FAIL_BOOTSTRAP='1'),cwd='/',text=True,capture_output=True)
            self.assertEqual(result.returncode,17,result.stderr)
            calls=(fixture.root/'git-calls').read_text()
            for operation in ('rev-parse HEAD','status --porcelain','archive '):
                self.assertIn(operation,calls)

    def test_builder_status_failure_is_not_treated_as_a_clean_worktree(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture=BuildFixture(directory,ROOT)
            git=fixture.root/'bin/git'
            git.write_text('''#!/bin/bash
if [[ " $* " == *" status --porcelain "* ]]; then
 echo "fatal: cannot inspect builder worktree" >&2
 exit 128
fi
exec "$REAL_GIT" "$@"
''')
            git.chmod(0o755)
            fixture.env['REAL_GIT']=shutil.which('git')
            result=fixture.run(bootstrap=True)
            self.assertEqual(result.returncode,128,result.stderr)
            self.assertIn('cannot inspect builder worktree',result.stderr)
            self.assertFalse(fixture.prefix.exists())

    def test_failed_build_cleans_only_its_prefix_temporary_archive_and_lock(self):
        for bootstrap in (True,False):
            with tempfile.TemporaryDirectory() as directory:
                fixture=BuildFixture(directory,ROOT)
                result=fixture.run(bootstrap)
                self.assertEqual(result.returncode,17 if bootstrap else 37,result.stderr)
                self.assertFalse(fixture.prefix.exists())
                self.assertEqual(list(fixture.tmp.iterdir()),[])
                self.assertFalse(list(fixture.root.glob('*.tar.xz.tmp')))
                if not bootstrap:
                    config=(fixture.root/'captured-config').read_text()
                    self.assertIn(fixture.mirror+'\n',config)

    def test_failed_build_does_not_remove_a_preexisting_prefix(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture=BuildFixture(directory,ROOT)
            fixture.prefix.mkdir(parents=True)
            sentinel=fixture.prefix/'keep'; sentinel.write_text('existing')
            result=fixture.run()
            self.assertNotEqual(result.returncode,0)
            self.assertEqual(sentinel.read_text(),'existing')
            self.assertEqual(list(fixture.tmp.iterdir()),[])

    def test_verifier_rejects_invalid_arity(self):
        result=subprocess.run([str(ROOT/'scripts/verify-toolchain.sh')],capture_output=True,text=True)
        self.assertEqual(result.returncode,64)
        self.assertIn('Usage:',result.stderr)

    def test_runtime_symlink_cannot_escape_toolchain(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)/'toolchain'
            target='x86_64-unknown-linux-musl'
            sysroot=root/target/'sysroot'
            (root/'bin').mkdir(parents=True)
            (root/target/'bin').mkdir(parents=True)
            (sysroot/'lib').mkdir(parents=True)
            outside=Path(directory)/'host-library.so'
            outside.write_bytes(b'host library')
            (sysroot/'lib/libasan.so').symlink_to(outside)
            loader=sysroot/'lib/ld-musl-x86_64.so.1'
            loader.write_text('#!/bin/sh\necho "Version 1.2.6"\n')
            compiler=root/'bin'/f'{target}-gcc'
            compiler.write_text(f'#!/bin/sh\ncase "$1" in\n-dumpfullversion) echo 16.2.0;;\n-print-sysroot) echo "{sysroot}";;\n-print-file-name=*) echo "{sysroot}/lib/libasan.so";;\nesac\n')
            cxx=root/'bin'/f'{target}-g++'
            cxx.write_text('#!/bin/sh\nexit 99\n')
            mold=root/target/'bin/ld.mold'
            mold.write_text('#!/bin/sh\necho "mold 2.41.0"\n')
            for path in (loader,compiler,cxx,mold): path.chmod(0o755)
            result=subprocess.run([str(ROOT/'scripts/verify-toolchain.sh'),target,str(root),'16.2.0','1.2.6',loader.name,'2.41.0'],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('escapes toolchain root',result.stderr)

    def test_all_driver_symlink_escapes_are_rejected_before_execution(self):
        for name in ('cc','cxx','mold'):
            with tempfile.TemporaryDirectory() as directory:
                fixture=VerifierFixture(directory,ROOT)
                outside=Path(directory)/'outside-driver'
                outside.write_text('#!/bin/sh\nexit 99\n'); outside.chmod(0o755)
                driver=getattr(fixture,name); driver.unlink(); driver.symlink_to(outside)
                result=fixture.run()
                self.assertNotEqual(result.returncode,0)
                self.assertIn('Compiler/linker escapes toolchain root',result.stderr)
                self.assertFalse((fixture.root/'compiler-entered').exists())

    def test_runtime_search_directory_cannot_escape(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture=VerifierFixture(directory,ROOT)
            outside=Path(directory)/'outside-libraries'; outside.mkdir()
            (fixture.sysroot/'usr/lib').symlink_to(outside)
            result=fixture.run()
            self.assertNotEqual(result.returncode,0)
            self.assertIn('Runtime directory escapes toolchain root',result.stderr)
            self.assertFalse((fixture.root/'compiler-entered').exists())

    def test_compile_commands_have_the_30_second_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture=VerifierFixture(directory,ROOT)
            tools=Path(directory)/'bin'; tools.mkdir()
            timeout=tools/'timeout'
            timeout.write_text('''#!/bin/sh
if [ "$1" = 30 ] && [ "$2" = "$FAKE_CC" ]; then
 case "$3" in -dumpfullversion|-print-*) ;; *) shift; exec "$REAL_TIMEOUT" 0.1 "$@";; esac
fi
exec "$REAL_TIMEOUT" "$@"
''')
            timeout.chmod(0o755)
            fixture.env.update(PATH=str(tools)+':'+os.environ['PATH'],REAL_TIMEOUT=shutil.which('timeout'),FAKE_CC=str(fixture.cc))
            result=fixture.run()
            self.assertEqual(result.returncode,124,result.stderr)
            self.assertTrue((fixture.root/'compiler-entered').exists())
            self.assertEqual(list(fixture.tmp.iterdir()),[])

    def test_package_metadata_update_only_accepts_zero_and_100(self):
        for status in (0,100,1,124):
            code=f'''source "$1"; SUDO=(); PKG_MANAGER=yum
 timeout() {{ return {status}; }}
 update_packages
'''
            result=subprocess.run(['bash','-euo','pipefail','-c',code,'test',str(ROOT/'scripts/host-dependencies.sh')],capture_output=True,text=True)
            self.assertEqual(result.returncode,0 if status in (0,100) else status)

    def test_arch_metadata_refresh_does_not_request_a_system_upgrade(self):
        code='source "$1"; SUDO=(); PKG_MANAGER=pacman; timeout() { printf "%s\\n" "$*"; }; update_packages'
        result=subprocess.run(['bash','-euo','pipefail','-c',code,'test',str(ROOT/'scripts/host-dependencies.sh')],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('pacman -Sy --noconfirm',result.stdout)
        self.assertNotIn('-Syu',result.stdout)

    def test_centos_mirrors_replace_the_installed_scl_files(self):
        with tempfile.TemporaryDirectory() as directory:
            code='''source "$1"; SUDO=(); BUILD_WORK_DIR=$2
 sed() { :; }; timeout() { :; }; cp() { printf "%s\\n" "$3" >> "$BUILD_WORK_DIR/destinations"; }
 setup_centos_repositories
'''
            result=subprocess.run(['bash','-euo','pipefail','-c',code,'test',str(ROOT/'scripts/host-dependencies.sh'),directory],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            paths=(Path(directory)/'destinations').read_text()
            self.assertIn('CentOS-SCLo-scl.repo',paths)
            self.assertIn('CentOS-SCLo-scl-rh.repo',paths)
            text=(Path(directory)/'scl-rh.repo').read_text()
            self.assertIn('/$basearch/rh/',text)
            self.assertNotIn('\\$basearch',text)

    def test_centos_refreshes_repositories_before_and_after_installing_scl(self):
        with tempfile.TemporaryDirectory() as directory:
            code='''source "$1"; SUDO=(); BUILD_WORK_DIR=$2
 sed() { :; }; cp() { :; }; timeout() { printf "%s\\n" "$*" >> "$BUILD_WORK_DIR/commands"; }
 setup_centos_repositories
'''
            result=subprocess.run(['bash','-euo','pipefail','-c',code,'test',str(ROOT/'scripts/host-dependencies.sh'),directory],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            commands=(Path(directory)/'commands').read_text().splitlines()
            install=next(i for i,command in enumerate(commands) if 'install -y epel-release' in command)
            for fragment in ('yum clean all','yum makecache'):
                self.assertTrue(any(fragment in command for command in commands[:install]),commands)
                self.assertTrue(any(fragment in command for command in commands[install+1:]),commands)

    def test_cmake_bootstrap_uses_private_python36_compatible_wheels(self):
        with tempfile.TemporaryDirectory() as directory:
            code='''source "$1"; USE_PIP_CMAKE=true; BUILD_WORK_DIR=$2
 python3() { printf "%s|%s\\n" "${PYTHONPATH:-}" "$*" >> "$BUILD_WORK_DIR/python-calls"; }
 setup_pip_cmake
'''
            result=subprocess.run(['bash','-euo','pipefail','-c',code,'test',str(ROOT/'scripts/host-dependencies.sh'),directory],capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            calls=(Path(directory)/'python-calls').read_text().splitlines()
            self.assertEqual(len(calls),2)
            self.assertIn('--target '+directory+'/bootstrap-python pip==21.3.1',calls[0])
            self.assertTrue(calls[1].startswith(directory+'/bootstrap-python|'),calls[1])
            self.assertIn('--only-binary=:all:',calls[1])
            self.assertIn('--target '+directory+'/host-tools cmake==3.28.4',calls[1])

    def test_disabled_pip_setup_does_not_execute_python(self):
        code='source "$1"; USE_PIP_CMAKE=false; python3() { exit 99; }; setup_pip_cmake'
        result=subprocess.run(['bash','-euo','pipefail','-c',code,'test',str(ROOT/'scripts/host-dependencies.sh')],capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stderr)

unittest.main()
PY
