#!/usr/bin/env python3
"""Патч sysinfo для сборки под iOS: proc_pidinfo/PIDLISTFDS/proc_fdinfo
отсутствуют в libc для aarch64-apple-ios.

Использование: patch_sysinfo.py <путь к распакованному sysinfo-0.38.4>
"""
import io
import sys

OLD = '''        let buffer_size_bytes = unsafe {
            libc::proc_pidinfo(
                self.pid().0,
                libc::PROC_PIDLISTFDS,
                0,
                std::ptr::null_mut(),
                0,
            )
        };

        if buffer_size_bytes < 0 {
            sysinfo_debug!("proc_pidinfo failed");
            None
        } else {
            Some(buffer_size_bytes as usize / std::mem::size_of::<libc::proc_fdinfo>())
        }'''

NEW = '''        // Заплатка GrinFlint: proc_pidinfo недоступен на iOS.
        let _ = self;
        None'''


OLD_CARGO = '''default = [
    "component",
    "disk",
    "network",
    "system",
    "user",
]'''

NEW_CARGO = '''default = [
    "component",
    "disk",
    "system",
    "user",
]'''


def main() -> int:
    root = sys.argv[1].rstrip("/")
    path = f"{root}/src/unix/apple/process.rs"
    src = io.open(path, encoding="utf-8").read()
    if OLD not in src:
        print("PATCH TARGET NOT FOUND — возможно, версия sysinfo изменилась", file=sys.stderr)
        return 1
    io.open(path, "w", encoding="utf-8").write(src.replace(OLD, NEW))
    print(f"patched: {path}")

    cargo_path = f"{root}/Cargo.toml"
    cargo = io.open(cargo_path, encoding="utf-8").read()
    if OLD_CARGO not in cargo:
        print("PATCH TARGET NOT FOUND в Cargo.toml", file=sys.stderr)
        return 1
    io.open(cargo_path, "w", encoding="utf-8").write(cargo.replace(OLD_CARGO, NEW_CARGO))
    print(f"patched: {cargo_path} (отключена фича network — macOS-only API на iOS)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
