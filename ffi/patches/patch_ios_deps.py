#!/usr/bin/env python3
"""iOS-патчи для зависимостей grin-wallet.

1. sysinfo-0.38.4: proc_pidinfo/RTM_IFINFO2 — macOS-only API, отсутствуют на iOS.
2. grin_wallet_impls-5.5.1: зависимость sysinfo 0.29 (со сломанной iOS-сборкой)
   заменена на заглушку — tor-process management на iOS не используется.

Использование: patch_ios_deps.py <папка с распакованными крейтами>
"""
import io
import os
import sys

TAB = "\t"


def patch_file(root: str, rel: str, replacements: list) -> bool:
    path = os.path.join(root, rel)
    src = io.open(path, encoding="utf-8").read()
    for old, new in replacements:
        if old not in src:
            print(f"PATCH TARGET NOT FOUND в {path}:\n{old[:120]!r}", file=sys.stderr)
            return False
        src = src.replace(old, new)
    io.open(path, "w", encoding="utf-8").write(src)
    print(f"patched: {path}")
    return True


def main() -> int:
    patches_dir = sys.argv[1].rstrip("/")

    # --- sysinfo 0.38.4 ---
    sysinfo = os.path.join(patches_dir, "sysinfo-0.38.4")
    ok = patch_file(sysinfo, "src/unix/apple/process.rs", [(
        '''        let buffer_size_bytes = unsafe {
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
        }''',
        '''        // Заплатка GrinFlint: proc_pidinfo недоступен на iOS.
        let _ = self;
        None''',
    )])
    ok = patch_file(sysinfo, "Cargo.toml", [(
        '''default = [
    "component",
    "disk",
    "network",
    "system",
    "user",
]''',
        '''default = [
    "component",
    "disk",
    "system",
    "user",
]''',
    )]) and ok

    # --- grin_wallet_impls 5.5.1: выкидываем sysinfo 0.29 ---
    impls = os.path.join(patches_dir, "grin_wallet_impls-5.5.1")
    ok = patch_file(impls, "src/tor/process.rs", [
        ("use sysinfo::{Process, ProcessExt, System, SystemExt};\n", ""),
        (f"{TAB}sys: System,\n", ""),
        (f"{TAB}{TAB}{TAB}sys: System::new(),\n", ""),
        (
            f"{TAB}fn get_process(&mut self, pid: i32) -> Option<&Process> {{\n"
            f"{TAB}{TAB}self.sys.refresh_all();\n"
            f"{TAB}{TAB}self.sys.process((pid as usize).into())\n"
            f"{TAB}}}\n",
            f"{TAB}#[allow(unused_variables)]\n"
            f"{TAB}fn get_process(&mut self, _pid: i32) -> Option<()> {{\n"
            f"{TAB}{TAB}// Заплатка GrinFlint: sysinfo убрана (не нужна на iOS).\n"
            f"{TAB}{TAB}None\n"
            f"{TAB}}}\n",
        ),
        (
            f"{TAB}{TAB}{TAB}{TAB}if let Some(p) = self.get_process(pid) {{\n"
            f"{TAB}{TAB}{TAB}{TAB}{TAB}let _ = p.kill();\n"
            f"{TAB}{TAB}{TAB}{TAB}}}\n",
            f"{TAB}{TAB}{TAB}{TAB}let _ = self.get_process(pid);\n",
        ),
    ]) and ok
    ok = patch_file(impls, "Cargo.toml", [(
        '[dependencies.sysinfo]\nversion = "0.29"\n', "",
    )]) and ok

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
