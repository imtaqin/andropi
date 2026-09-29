"""Fetch Node.js (and ripgrep/fd, git, ...) for each Android ABI from the Termux
apt repo and repackage them as jniLibs so they can be exec'd from
nativeLibraryDir.

Android only lets apps exec files that live in the (read-only) native library
directory, and the packager only ships files named lib*.so. So every binary is
renamed to lib<name>.so and every shared library whose soname does not end in
.so gets a new soname; DT_NEEDED entries are rewritten to match and RUNPATHs
pointing at the Termux prefix are dropped (we use LD_LIBRARY_PATH instead).

Usage: python tool/bundle_runtime.py [arm64-v8a] [armeabi-v7a] [x86_64]
       (no arguments: all three)
"""

import io
import lzma
import shutil
import sys
import tarfile
import urllib.request
from pathlib import Path

import lief

REPO = "https://packages.termux.dev/apt/termux-main"
# Android ABI -> Termux architecture.
ABIS = {"arm64-v8a": "aarch64", "armeabi-v7a": "arm", "x86_64": "x86_64"}

ROOT = Path(__file__).resolve().parent.parent
JNILIBS = ROOT / "android" / "app" / "src" / "main" / "jniLibs"

# package -> {binary path inside prefix: output name}
# Output names must not collide with a real library soname (libcurl.so, ...).
BINARIES = {
    "nodejs-lts": {"bin/node": "libnode.so"},
    "ripgrep": {"bin/rg": "librg.so"},
    "fd": {"bin/fd": "libfd.so"},
    "git": {
        "bin/git": "libgit.so",
        "libexec/git-core/git-remote-http": "libgit_remote_http.so",
    },
    "openssh": {
        "bin/ssh": "libssh_cli.so",
        "bin/ssh-keygen": "libssh_keygen.so",
        "bin/scp": "libscp_cli.so",
    },
    "rsync": {"bin/rsync": "librsync_cli.so"},
    "curl": {"bin/curl": "libcurl_cli.so"},
    # Linux container: proot runs a glibc rootfs the app downloads on demand.
    "proot": {"bin/proot": "libproot.so", "libexec/proot/loader": "libproot_loader.so"},
}
# Shell scripts shipped as "libraries" so they land in the executable
# native library directory: output name -> source in tool/.
SCRIPTS = {"libbox.so": "box.sh"}
# Runtime-only data packages we don't need inside the APK. The rest are
# server/pager pieces the bundled clients never load.
SKIP = {
    "resolv-conf", "ca-certificates", "termux-keyring",
    "less", "termux-auth", "openssh-sftp-server", "openssl-tool", "dropbear",
}
# Provided by the Android platform.
SYSTEM = {"libc.so", "libm.so", "libdl.so", "liblog.so", "libandroid.so", "libz.so"}

PREFIX = "data/data/com.termux/files/usr/"


def parse_index(text):
    pkgs = {}
    for block in text.strip().split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if ":" in line and not line.startswith(" "):
                k, v = line.split(":", 1)
                fields[k] = v.strip()
        if "Package" in fields:
            pkgs[fields["Package"]] = fields
    return pkgs


def deps_of(fields):
    out = []
    for dep in fields.get("Depends", "").split(","):
        name = dep.split("|")[0].split("(")[0].strip()
        if name:
            out.append(name)
    return out


def resolve(pkgs, roots):
    seen, stack = [], list(roots)
    while stack:
        name = stack.pop()
        if name in seen or name in SKIP:
            continue
        seen.append(name)
        stack.extend(deps_of(pkgs[name]))
    return seen


def fetch(url, dest):
    if not dest.exists():
        print(f"  downloading {url.rsplit('/', 1)[-1]}")
        with urllib.request.urlopen(url) as r:
            dest.write_bytes(r.read())
    return dest.read_bytes()


def deb_data_tar(deb):
    """Return the data.tar.* member of an ar archive."""
    assert deb[:8] == b"!<arch>\n"
    pos = 8
    while pos < len(deb):
        name = deb[pos:pos + 16].decode().strip().rstrip("/")
        size = int(deb[pos + 48:pos + 58].decode().strip())
        body = deb[pos + 60:pos + 60 + size]
        if name.startswith("data.tar"):
            if name.endswith(".xz"):
                body = lzma.decompress(body)
            elif not name.endswith(".tar"):
                sys.exit(f"unsupported compression: {name}")
            return tarfile.open(fileobj=io.BytesIO(body))
        pos += 60 + size + (size & 1)
    sys.exit("no data.tar in deb")


def jni_name(soname):
    """libicuuc.so.78 -> libicuuc_78.so; libfoo.so stays as is."""
    if soname.endswith(".so"):
        return soname
    base, ver = soname.split(".so.", 1)
    return f"{base}_{ver.replace('.', '_')}.so"


def main():
    abis = sys.argv[1:] or list(ABIS)
    for abi in abis:
        if abi not in ABIS:
            sys.exit(f"unknown ABI {abi}; pick from {', '.join(ABIS)}")
    for abi in abis:
        print(f"== {abi} ({ABIS[abi]})")
        bundle(ABIS[abi], JNILIBS / abi)


def bundle(arch, OUT):
    CACHE = ROOT / "build" / "termux-cache" / arch
    INDEX = f"{REPO}/dists/stable/main/binary-{arch}/Packages"
    CACHE.mkdir(parents=True, exist_ok=True)
    stage = CACHE / "stage"
    shutil.rmtree(stage, ignore_errors=True)
    stage.mkdir()

    print("reading package index")
    pkgs = parse_index(fetch(INDEX, CACHE / "Packages").decode())
    wanted = resolve(pkgs, BINARIES)
    print("packages:", ", ".join(f"{p} {pkgs[p]['Version']}" for p in wanted))

    links = []
    for name in wanted:
        fields = pkgs[name]
        deb = fetch(f"{REPO}/{fields['Filename']}", CACHE / fields["Filename"].rsplit("/", 1)[-1])
        with deb_data_tar(deb) as tar:
            for m in tar.getmembers():
                path = m.name.lstrip("./")
                if not path.startswith(PREFIX) or not (m.isfile() or m.issym()):
                    continue
                rel = path[len(PREFIX):]
                dest = stage / rel
                dest.parent.mkdir(parents=True, exist_ok=True)
                if m.issym():
                    links.append((rel, m.linkname))
                else:
                    dest.write_bytes(tar.extractfile(m).read())

    # Resolve symlinks (e.g. libicuuc.so.78 -> libicuuc.so.78.3) by copying.
    for rel, target in links:
        src = (stage / rel).parent / target
        if src.is_file() and not (stage / rel).exists():
            shutil.copyfile(src, stage / rel)

    libdir = stage / "lib"
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)

    # Walk the NEEDED closure starting from the binaries.
    todo = []
    for pkg, bins in BINARIES.items():
        for src, dst in bins.items():
            todo.append((stage / src, dst))
    done = set()
    while todo:
        src, dst = todo.pop()
        if dst in done:
            continue
        done.add(dst)
        elf = lief.ELF.parse(str(src))
        for entry in list(elf.dynamic_entries):
            if entry.tag in (lief.ELF.DynamicEntry.TAG.RUNPATH, lief.ELF.DynamicEntry.TAG.RPATH):
                elf.remove(entry)
        for lib in elf.libraries:
            if lib in SYSTEM:
                continue
            if not (libdir / lib).exists():
                sys.exit(f"{src.name}: missing dependency {lib}")
            new = jni_name(lib)
            if new != lib:
                elf.get_library(lib).name = new
            todo.append((libdir / lib, new))
        # Symbol versioning (verneed) names the file too, and bionic checks it.
        for req in elf.symbols_version_requirement:
            if req.name not in SYSTEM:
                req.name = jni_name(req.name)
        if elf.has(lief.ELF.DynamicEntry.TAG.SONAME):
            elf.get(lief.ELF.DynamicEntry.TAG.SONAME).name = dst
        elf.write(str(OUT / dst))
        print(f"  {dst:28} {(OUT / dst).stat().st_size / 1e6:6.1f} MB")

    for dst, src in SCRIPTS.items():
        shutil.copyfile(ROOT / "tool" / src, OUT / dst)
        print(f"  {dst:28} script")

    total = sum(p.stat().st_size for p in OUT.iterdir())
    print(f"wrote {len(done)} files, {total / 1e6:.1f} MB -> {OUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
