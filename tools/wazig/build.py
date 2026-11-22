#!/usr/bin/env python3
"""Self-contained Wasm build and test driver for nanoui using wazig + wasmtime."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def find_tool(explicit: str | None, name: str, env_var: str) -> str:
    if explicit or os.environ.get(env_var) or shutil.which(name):
        return explicit or os.environ.get(env_var) or shutil.which(name) or name
    for base in (Path.home() / ".local/bin", Path.home() / ".local/share/ghr/bin"):
        if (base / name).exists():
            return str(base / name)
    raise SystemExit(f"error: required tool '{name}' not found on PATH")


def path_for_wasi(target: Path, base: Path) -> str:
    resolved, base_res = target.resolve(), base.resolve()
    if resolved == base_res:
        return "."
    return resolved.relative_to(base_res).as_posix() if resolved.is_relative_to(base_res) else resolved.as_posix()


def resolve_plan_path(raw: str, base: Path) -> Path:
    p = Path(raw)
    return p if p.is_absolute() else base / p


def build_child_env(local_cache: Path, global_cache: Path, repo_root: Path) -> dict[str, str]:
    env = os.environ.copy()
    env["ZIG_GLOBAL_CACHE_DIR"] = path_for_wasi(global_cache, repo_root)
    env["ZIG_LOCAL_CACHE_DIR"] = path_for_wasi(local_cache, repo_root)
    if not env.get("WASMTIME_CACHE_CONFIG"):
        wt_dir = (local_cache / "wasmtime-cache").resolve()
        wt_dir.mkdir(parents=True, exist_ok=True)
        wt_toml = (local_cache / "wasmtime-cache.toml").resolve()
        wt_toml.write_text(f'[cache]\nenabled = true\ndirectory = "{wt_dir.as_posix()}"\n', encoding="utf-8")
        env["WASMTIME_CACHE_CONFIG"] = str(wt_toml)
    for var, sub in (("WASMTIME_HOME", "wasmtime-home"), ("TMPDIR", "tmp")):
        if not env.get(var):
            d = (local_cache / sub).resolve()
            d.mkdir(parents=True, exist_ok=True)
            env[var] = str(d)
    return env


def parse_ghr_manifest(tool_path: str) -> tuple[str, list[str]] | None:
    for p in (Path(f"{tool_path}.ghr"), Path(f"{Path(tool_path).resolve()}.ghr")):
        if p.exists():
            text = p.read_text(encoding="utf-8")
            wm = re.search(r'\.targetWasm\s*=\s*"([^"]+)"', text)
            am = re.search(r"\.runtimeArgs\s*=\s*\.\{(.*?)\}", text, re.S)
            if wm and am:
                return wm.group(1), re.findall(r'"([^"]+)"', am.group(1))
    return None


def make_wazig_cmd(wazig: str, wasmtime: str, extra_dirs: list[Path], args: list[str]) -> list[str]:
    if extra_dirs and (ghr := parse_ghr_manifest(wazig)) is not None:
        target_wasm, rargs = ghr
        return [wasmtime, *rargs, *(f"--dir={d.as_posix()}" for d in extra_dirs), "--", target_wasm, *args]
    return [wazig, *args]


def extract_brace_block(text: str, start_brace: int) -> str:
    depth, in_str, escape = 0, False, False
    for idx in range(start_brace, len(text)):
        ch = text[idx]
        if in_str:
            escape = (ch == "\\") if not escape else False
            if ch == '"' and not escape:
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start_brace + 1 : idx]
    return ""


def parse_zon_dependencies(zon_path: Path) -> list[dict[str, Any]]:
    if not zon_path.exists():
        return []
    text = zon_path.read_text(encoding="utf-8")
    if not (m := re.search(r"\.dependencies\s*=\s*\.\{", text)):
        return []
    body = extract_brace_block(text, m.end() - 1)
    deps, pos = [], 0
    while em := re.search(r"\.([A-Za-z0-9_]+)\s*=\s*\.\{", body[pos:]):
        brace_idx = pos + em.end() - 1
        fields = extract_brace_block(body, brace_idx)
        pos = brace_idx + len(fields) + 2
        pm, hm = re.search(r'\.path\s*=\s*"([^"]+)"', fields), re.search(r'\.hash\s*=\s*"([^"]+)"', fields)
        deps.append({"name": em.group(1), "path": pm.group(1) if pm else None, "hash": hm.group(1) if hm else None, "lazy": bool(re.search(r"\.lazy\s*=\s*true\b", fields))})
    return deps


def zig_escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def build_package_graph(build_root: Path, global_cache: Path, repo_root: Path) -> tuple[dict[str, dict[str, Any]], list[tuple[str, str]]]:
    packages: dict[str, dict[str, Any]] = {}

    def visit_dir(pkg_dir: Path) -> list[tuple[str, str]]:
        pairs: list[tuple[str, str]] = []
        for d in parse_zon_dependencies(pkg_dir / "build.zig.zon"):
            if d["path"] is not None:
                dep_dir = (pkg_dir / d["path"]).resolve()
                pkg_id = f"local_{d['name']}_{hashlib.sha256(str(dep_dir).encode()).hexdigest()[:12]}"
            else:
                pkg_id = d["hash"]
                dep_dir = (global_cache / "p" / pkg_id).resolve()
            pairs.append((d["name"], pkg_id))
            if pkg_id in packages:
                continue
            if d["lazy"] and not dep_dir.exists():
                packages[pkg_id] = {"available": False, "lazy": True}
            elif dep_dir.exists():
                packages[pkg_id] = {
                    "available": True,
                    "lazy": d["lazy"],
                    "build_root": path_for_wasi(dep_dir, repo_root),
                    "abs_root": dep_dir,
                    "has_build_zig": (dep_dir / "build.zig").exists(),
                    "deps": [],
                }
                packages[pkg_id]["deps"] = visit_dir(dep_dir)
            else:
                raise SystemExit(f"error: missing required dependency '{d['name']}' ({pkg_id}) in {global_cache / 'p'}")
        return pairs

    return packages, visit_dir(build_root)


def generate_deps_zig(packages: dict[str, dict[str, Any]], root_deps: list[tuple[str, str]]) -> str:
    lines = ["pub const packages = struct {"]
    for pkg_id in sorted(packages):
        info = packages[pkg_id]
        lines.append(f'    pub const @"{zig_escape(pkg_id)}" = struct {{')
        if not info["available"]:
            lines.extend(["        pub const available = false;", "    };"])
            continue
        if info.get("lazy"):
            lines.append("        pub const available = true;")
        lines.append(f'        pub const build_root = "{zig_escape(info["build_root"])}";')
        if info["has_build_zig"]:
            lines.append(f'        pub const build_zig = @import("{zig_escape(pkg_id)}");')
        entries = ", ".join(f'.{{ "{zig_escape(dn)}", "{zig_escape(did)}" }}' for dn, did in info["deps"])
        lines.append(f"        pub const deps: []const struct {{ []const u8, []const u8 }} = &.{{ {entries} }};")
        lines.append("    };")
    lines.append("};")
    root_entries = ", ".join(f'.{{ "{zig_escape(dn)}", "{zig_escape(did)}" }}' for dn, did in root_deps)
    lines.append(f"pub const root_deps: []const struct {{ []const u8, []const u8 }} = &.{{ {root_entries} }};")
    return "\n".join(lines) + "\n"


def compile_and_run_configurer(
    wazig: str, wasmtime: str, build_root: Path, local_cache: Path, global_cache: Path,
    install_prefix: Path, extra_dirs: list[Path], steps: list[str], config_args: list[str],
    env: dict[str, str], verbose: bool,
) -> tuple[dict[str, Any], float, bool]:
    t0 = time.perf_counter()
    packages, root_deps = build_package_graph(build_root, global_cache, REPO_ROOT)
    deps_src = generate_deps_zig(packages, root_deps)
    meta_dir = local_cache / "wazig"
    meta_dir.mkdir(parents=True, exist_ok=True)
    deps_path = meta_dir / "deps.zig"
    deps_path.write_text(deps_src, encoding="utf-8")

    ver_proc = subprocess.run(
        make_wazig_cmd(wazig, wasmtime, extra_dirs, ["version"]),
        cwd=REPO_ROOT, env=env, capture_output=True, text=True, check=True,
    )
    h = hashlib.sha256((ver_proc.stdout.strip() + "\n" + deps_src).encode("utf-8"))
    for p in (build_root / "build.zig", build_root / "build.zig.zon"):
        if p.exists():
            h.update(p.read_bytes())
    for sub in ("web", "ios", "android", "wazig"):
        if (sub_dir := REPO_ROOT / "tools" / sub).exists():
            for zp in sorted(sub_dir.glob("*.zig")):
                h.update(zp.name.encode("utf-8") + zp.read_bytes())
    for pkg_id, info in sorted(packages.items()):
        if info["available"] and info["has_build_zig"]:
            h.update((info["abs_root"] / "build.zig").read_bytes())

    configurer_wasm = meta_dir / f"configurer_{h.hexdigest()[:16]}.wasm"
    built_cfg = not configurer_wasm.exists()
    if built_cfg:
        zig_args = [
            "build-exe", "-fno-llvm", "-ODebug", "-target", "wasm32-wasi", "-lc",
            f"-femit-bin={path_for_wasi(configurer_wasm, REPO_ROOT)}",
            "--dep", "@build", "--dep", "@dependencies",
            f"-Mroot={path_for_wasi(REPO_ROOT / 'tools/wazig/configurer.zig', REPO_ROOT)}",
        ]
        for dn, did in root_deps:
            if packages[did]["available"] and packages[did]["has_build_zig"]:
                zig_args.extend(["--dep", f"{dn}={did}"])
        zig_args.append(f"-M@build={path_for_wasi(build_root / 'build.zig', REPO_ROOT)}")
        for pkg_id, info in sorted(packages.items()):
            if info["available"] and info["has_build_zig"]:
                zig_args.extend(["--dep", pkg_id])
        zig_args.append(f"-M@dependencies={path_for_wasi(deps_path, REPO_ROOT)}")
        for pkg_id, info in sorted(packages.items()):
            if info["available"] and info["has_build_zig"]:
                for sname, sid in info["deps"]:
                    if packages[sid]["available"] and packages[sid]["has_build_zig"]:
                        zig_args.extend(["--dep", f"{sname}={sid}"])
                zig_args.append(f"-M{pkg_id}={path_for_wasi(info['abs_root'] / 'build.zig', REPO_ROOT)}")
        zig_args.extend(["--cache-dir", path_for_wasi(local_cache, REPO_ROOT), "--global-cache-dir", path_for_wasi(global_cache, REPO_ROOT)])
        cmd = make_wazig_cmd(wazig, wasmtime, extra_dirs, zig_args)
        if verbose:
            print("+", " ".join(cmd), file=sys.stderr)
        subprocess.run(cmd, cwd=REPO_ROOT, env=env, check=True)

    zig_id = "wazigl" if os.environ.get("WAZIG_LLVM") == "1" else Path(wazig).name
    run_cmd = [
        wasmtime, "run", "-W", "simd=y,bulk-memory=y", "-S", "inherit-env=y",
        "--dir=.", *(f"--dir={d.as_posix()}" for d in extra_dirs), "--",
        str(configurer_wasm), "--zig", zig_id,
        "--build-root", path_for_wasi(build_root, REPO_ROOT),
        "--cache-root", path_for_wasi(local_cache, REPO_ROOT),
        "--global-cache-root", path_for_wasi(global_cache, REPO_ROOT),
        "--prefix", path_for_wasi(install_prefix, REPO_ROOT),
        *(x for s in steps for x in ("--step", s)), *config_args,
    ]
    if verbose:
        print("+", " ".join(run_cmd), file=sys.stderr)
    proc = subprocess.run(run_cmd, cwd=REPO_ROOT, env=env, capture_output=True, text=True)
    if proc.stderr:
        sys.stderr.write(proc.stderr)
    if proc.returncode != 0:
        raise SystemExit(proc.returncode)
    return json.loads(proc.stdout), time.perf_counter() - t0, built_cfg


def verify_run_checks(step_name: str, proc: subprocess.CompletedProcess[str], checks: list[dict[str, Any]]) -> None:
    for chk in checks:
        kind = chk["kind"]
        if kind == "exit_code" and proc.returncode != chk["code"]:
            raise SystemExit(f"error: '{step_name}' exited with {proc.returncode}, expected {chk['code']}")
        if kind == "stdout_exact" and proc.stdout != chk["value"]:
            raise SystemExit(f"error: '{step_name}' stdout mismatch")
        if kind == "stdout_match" and chk["value"] not in proc.stdout:
            raise SystemExit(f"error: '{step_name}' stdout missing {chk['value']!r}")
        if kind == "stderr_exact" and proc.stderr != chk["value"]:
            raise SystemExit(f"error: '{step_name}' stderr mismatch")
        if kind == "stderr_match" and chk["value"] not in proc.stderr:
            raise SystemExit(f"error: '{step_name}' stderr missing {chk['value']!r}")


def parse_args(argv: list[str]) -> dict[str, Any]:
    opts: dict[str, Any] = {
        "build_root": REPO_ROOT, "prefix": None, "cache": None, "global_cache": None,
        "wazig": None, "wasmtime": None, "steps": [], "config_args": [], "passthru": [],
        "summary": False, "verbose": False,
    }
    value_flags = {
        "--prefix": "prefix", "-p": "prefix", "--cache-dir": "cache",
        "--global-cache-dir": "global_cache", "--build-root": "build_root",
        "--wazig": "wazig", "--wasmtime": "wasmtime",
    }
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == "--":
            opts["passthru"] = argv[i + 1 :]
            break
        if arg in ("-h", "--help"):
            print("usage: build.py [steps...] [-Dopt=val] [--prefix DIR] [--cache-dir DIR] [--global-cache-dir DIR] [--wazig PATH] [--wasmtime PATH] [--summary] [--verbose]")
            raise SystemExit(0)
        if arg in value_flags or ("=" in arg and arg.split("=", 1)[0] in value_flags):
            flag, val = arg.split("=", 1) if "=" in arg else (arg, argv[i := i + 1])
            opts[value_flags[flag]] = (REPO_ROOT / val).resolve() if value_flags[flag] == "build_root" else val
        elif arg == "--summary" or arg.startswith("--summary="):
            opts["summary"] = True
            if arg == "--summary" and i + 1 < len(argv) and argv[i + 1] in ("all", "new", "failures", "none"):
                i += 1
        elif arg in ("--verbose", "-v"):
            opts["verbose"] = True
            opts["config_args"].append("--verbose")
        elif arg.startswith("-D") or arg.startswith("--color="):
            opts["config_args"].append(arg)
        elif arg == "--search-prefix":
            i += 1
            opts["config_args"].extend(["--search-prefix", argv[i]])
        elif arg.startswith("-j") or arg == "-fwasmtime":
            pass
        elif arg.startswith("-"):
            raise SystemExit(f"error: unrecognized option '{arg}'")
        else:
            opts["steps"].append(arg)
        i += 1
    return opts


def main(argv: list[str]) -> int:
    opts = parse_args(argv)
    build_root: Path = opts["build_root"]
    steps: list[str] = opts["steps"]
    config_args: list[str] = opts["config_args"]
    verbose: bool = opts["verbose"]

    wazig = find_tool(opts["wazig"], "wazig", "WAZIG")
    wasmtime = find_tool(opts["wasmtime"], "wasmtime", "WASMTIME")
    local_cache = Path(opts["cache"] or os.environ.get("ZIG_LOCAL_CACHE_DIR") or (build_root / ".zig-cache")).resolve()
    global_cache = Path(opts["global_cache"] or os.environ.get("ZIG_GLOBAL_CACHE_DIR") or (local_cache / "global")).resolve()
    install_prefix = Path(opts["prefix"] or (build_root / "zig-out")).resolve()
    for d in (local_cache, global_cache, install_prefix):
        d.mkdir(parents=True, exist_ok=True)

    extra_dirs: list[Path] = []
    for d in (build_root, local_cache, global_cache, install_prefix):
        dr = d.resolve()
        if not dr.is_relative_to(REPO_ROOT) and dr not in extra_dirs:
            extra_dirs.append(dr)

    env = build_child_env(local_cache, global_cache, REPO_ROOT)
    if steps and steps[0] == "fmt":
        return subprocess.run(make_wazig_cmd(wazig, wasmtime, extra_dirs, steps), cwd=REPO_ROOT, env=env).returncode

    if any(s in ("test", "test-bin") or s.startswith("test-") for s in steps):
        if not any(opt.startswith("-Dtarget=") for opt in config_args):
            config_args.append("-Dtarget=wasm32-wasi")

    total_start = time.perf_counter()
    plan, cfg_sec, built_cfg = compile_and_run_configurer(
        wazig, wasmtime, build_root, local_cache, global_cache, install_prefix, extra_dirs, steps, config_args, env, verbose
    )
    timings: list[tuple[str, float]] = [(f"configure ({'cold' if built_cfg else 'cached'})", cfg_sec)]
    installed_count, install_sec = 0, 0.0

    for step in plan.get("steps", []):
        kind, t0 = step["kind"], time.perf_counter()
        if kind == "fail":
            raise SystemExit(f"error: {step['message']}")
        if kind == "compile":
            resolve_plan_path(step["output"], REPO_ROOT).parent.mkdir(parents=True, exist_ok=True)
            cmd = make_wazig_cmd(wazig, wasmtime, extra_dirs, step["args"])
            if verbose:
                print("+", " ".join(cmd), file=sys.stderr)
            subprocess.run(cmd, cwd=REPO_ROOT, env=env, check=True)
            timings.append((f"{step['name']} [{step['mcpu']}]", time.perf_counter() - t0))
        elif kind in ("install_file", "install_dir"):
            src, dest = resolve_plan_path(step["src"], REPO_ROOT), resolve_plan_path(step["dest"], REPO_ROOT)
            dest.parent.mkdir(parents=True, exist_ok=True)
            if kind == "install_file":
                shutil.copy2(src, dest)
            else:
                shutil.copytree(src, dest, dirs_exist_ok=True)
            installed_count += 1
            install_sec += time.perf_counter() - t0
        elif kind == "run":
            run_cwd = resolve_plan_path(step["cwd"], REPO_ROOT) if step.get("cwd") else REPO_ROOT
            args = [*step["args"], *(opts["passthru"] if step.get("passthru") else [])]
            if step.get("is_wasm", True):
                wasm_features = "simd=y,bulk-memory=y,memory64=y" + (",threads=y" if step.get("threads") else "")
                wasi_flags = ["-S", "inherit-env=y", *(["-S", "threads=y"] if step.get("threads") else [])]
                preopens = ["--dir=."]
                if run_cwd.resolve() != REPO_ROOT.resolve():
                    preopens.append(f"--dir={REPO_ROOT.as_posix()}")
                preopens.extend(f"--dir={d.as_posix()}" for d in extra_dirs)
                exec_cmd = [wasmtime, "run", "-W", wasm_features, *wasi_flags, *preopens, "--", str(resolve_plan_path(args[0], REPO_ROOT)), *args[1:]]
            else:
                exec_cmd = args
            if verbose:
                print("+", " ".join(exec_cmd), file=sys.stderr)
            checks, cap_out = step.get("checks"), step.get("capture_stdout")
            if checks is not None or cap_out:
                proc = subprocess.run(exec_cmd, cwd=run_cwd, env=env, capture_output=True, text=True)
                if cap_out:
                    out_p = resolve_plan_path(cap_out, REPO_ROOT)
                    out_p.parent.mkdir(parents=True, exist_ok=True)
                    out_p.write_text(proc.stdout, encoding="utf-8")
                if checks is not None:
                    verify_run_checks(step["name"], proc, checks)
                elif proc.returncode != 0:
                    sys.stderr.write(proc.stderr)
                    raise SystemExit(proc.returncode)
            else:
                subprocess.run(exec_cmd, cwd=run_cwd, env=env, check=True)
            timings.append((step["name"], time.perf_counter() - t0))

    if installed_count:
        timings.append((f"install ({installed_count} items)", install_sec))
    if opts["summary"]:
        sys.stderr.write(f"wazig build summary ({time.perf_counter() - total_start:.2f}s total):\n")
        for label, dur in timings:
            sys.stderr.write(f"  {dur:6.2f}s  {label}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
