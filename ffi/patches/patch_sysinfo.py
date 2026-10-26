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


def main() -> int:
    root = sys.argv[1].rstrip("/")
    path = f"{root}/src/unix/apple/process.rs"
    src = io.open(path, encoding="utf-8").read()
    if OLD not in src:
        print("PATCH TARGET NOT FOUND — возможно, версия sysinfo изменилась", file=sys.stderr)
        return 1
    io.open(path, "w", encoding="utf-8").write(src.replace(OLD, NEW))
    print(f"patched: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
