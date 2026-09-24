#!/usr/bin/env python3
"""bundle-runtime.py - makes Contents/Resources/bin/{ffmpeg,ffprobe} self-contained.

Copies every non-system dylib the two binaries depend on (transitively) into
Contents/Resources/lib/, then rewrites every LC_LOAD_DYLIB / LC_ID_DYLIB command that
pointed at the original absolute (Homebrew) path to a path relative to the bundle
(@executable_path/@loader_path). After this, the binaries run standalone: they do not
need Homebrew, and moving or renaming the .app does not break them.

This bundles Homebrew's dynamically-linked ffmpeg rather than building ffmpeg as a
single static binary (spec Appendix A). That is a deliberate trade-off: a from-source
static build of x264+x265+SVT-AV1+ffmpeg is a multi-hour undertaking with real risk of
toolchain breakage, and the reason the spec preferred static — avoiding the
com.apple.security.cs.disable-library-validation entitlement for a notarised, hardened
runtime build — does not apply yet, since this app is not signed with a Developer ID.
Revisit if and when notarisation is pursued; see README "Bundling ffmpeg".

usage: bundle-runtime.py <path-to-.app>
"""
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path

# Anything under these prefixes ships with macOS itself and is never bundled.
SYSTEM_PREFIXES = ("/usr/lib/", "/System/")


def otool_deps(path: Path) -> list[str]:
    """Returns the absolute paths this Mach-O file loads, excluding its own id."""
    out = subprocess.run(
        ["otool", "-L", str(path)], capture_output=True, text=True, check=True
    ).stdout
    lines = out.splitlines()[1:]  # first line just echoes the file path
    deps = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        dep_path = line.split(" (compatibility")[0].strip()
        deps.append(dep_path)
    return deps


def is_bundleable(dep_path: str) -> bool:
    if dep_path.startswith(SYSTEM_PREFIXES):
        return False
    if dep_path.startswith("@"):
        return False  # already relocated (a dylib we bundled in an earlier pass)
    return True


def resolve_real_path(dep_path: str) -> Path:
    # Homebrew's /opt/homebrew/opt/<formula>/lib/*.dylib entries are symlinks into
    # the versioned Cellar; resolve so we copy the real file, not a dangling link.
    return Path(dep_path).resolve()


def collect_closure(roots: list[Path]) -> dict[str, Path]:
    """BFS over the dependency graph. Returns {basename: real_source_path}."""
    found: dict[str, Path] = {}
    queue: list[Path] = list(roots)
    visited: set[str] = {str(r) for r in roots}

    while queue:
        current = queue.pop()
        for dep in otool_deps(current):
            if not is_bundleable(dep):
                continue
            real = resolve_real_path(dep)
            found.setdefault(real.name, real)
            if str(real) not in visited:
                visited.add(str(real))
                queue.append(real)
    return found


def rewrite(path: Path, lib_dir_token: str, name_map: dict[str, str]) -> None:
    """Rewrites this file's own id (if it has one) and every dependency that maps
    to a bundled library, then re-signs (install_name_tool invalidates the signature)."""
    # Only dylibs have a meaningful id; executables' -id call is a harmless no-op error
    # we can ignore.
    subprocess.run(
        ["install_name_tool", "-id", f"{lib_dir_token}/{path.name}", str(path)],
        capture_output=True,
    )

    for dep in otool_deps(path):
        if not is_bundleable(dep):
            continue
        real_name = resolve_real_path(dep).name
        new = name_map.get(real_name)
        if new is None:
            continue
        subprocess.run(
            ["install_name_tool", "-change", dep, new, str(path)], check=True
        )

    subprocess.run(
        ["codesign", "--force", "--sign", "-", str(path)],
        check=True,
        capture_output=True,
    )


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(f"usage: {sys.argv[0]} <path-to-.app>")

    app = Path(sys.argv[1]).resolve()
    bin_dir = app / "Contents" / "Resources" / "bin"
    lib_dir = app / "Contents" / "Resources" / "lib"

    ffmpeg = bin_dir / "ffmpeg"
    ffprobe = bin_dir / "ffprobe"
    for exe in (ffmpeg, ffprobe):
        if not exe.exists():
            sys.exit(f"expected {exe} to already be copied into the bundle")

    print("==> Resolving dependency closure")
    closure = collect_closure([ffmpeg, ffprobe])
    print(f"    {len(closure)} non-system libraries to bundle")

    lib_dir.mkdir(parents=True, exist_ok=True)
    for name, source in sorted(closure.items()):
        dest = lib_dir / name
        shutil.copy2(source, dest)
        dest.chmod(0o755)
        print(f"    {name}  <-  {source}")

    # @loader_path from a lib/*.dylib resolves relative to lib/ itself; from
    # bin/{ffmpeg,ffprobe} it would resolve to bin/, so those two use
    # @executable_path/../lib instead.
    name_map_for_libs = {name: f"@loader_path/{name}" for name in closure}
    name_map_for_bin = {name: f"@executable_path/../lib/{name}" for name in closure}

    print("==> Rewriting load commands")
    for dylib in sorted(lib_dir.iterdir()):
        rewrite(dylib, "@loader_path", name_map_for_libs)
    for exe in (ffmpeg, ffprobe):
        rewrite(exe, "@executable_path", name_map_for_bin)

    print("==> Verifying no external references remain")
    leftover = False
    for f in [ffmpeg, ffprobe, *lib_dir.iterdir()]:
        for dep in otool_deps(f):
            if is_bundleable(dep):
                print(f"    STILL EXTERNAL: {f.name} -> {dep}")
                leftover = True
            # A bare @rpath entry (rather than the @loader_path/@executable_path
            # this script itself writes) means the original binary already used
            # @rpath and this script never handled that convention — it would
            # only resolve if an LC_RPATH search path happens to reach into the
            # bundle, which is not something this script sets up.
            elif dep.startswith("@rpath/"):
                print(f"    UNHANDLED @rpath: {f.name} -> {dep}")
                leftover = True
    if leftover:
        sys.exit("bundling incomplete — see lines above")

    print(f"==> Done: {len(closure)} libraries bundled into {lib_dir}")


if __name__ == "__main__":
    main()
