import argparse
import glob
import importlib.metadata
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import winreg


def get_latest(pattern, optional=False):
    matches = sorted(glob.glob(pattern))
    if not matches:
        if optional:
            return None
        raise RuntimeError(f"No match for {pattern}")
    return matches[-1]


def find_kernelfoundry_pkg(kf_root: Path) -> Path | None:
    """Locate the installed kernelfoundry package directory (PyPI site-packages or repo checkout)."""
    candidates = [
        kf_root / ".venv" / "Lib" / "site-packages" / "kernelfoundry",
        kf_root / "kernelfoundry",
    ]
    for c in candidates:
        if (c / "__init__.py").exists():
            return c
    try:
        spec = importlib.util.find_spec("kernelfoundry")
        if spec and spec.origin:
            return Path(spec.origin).parent
    except Exception:
        pass
    return None


def apply_windows_patches(kf_root: str):
    """Apply Windows compatibility and VTune default profiler adjustments to KernelFoundry."""
    pkg_dir = find_kernelfoundry_pkg(Path(kf_root))
    if pkg_dir is None:
        return

    # 1. Patch test_custom_task.py so sys.executable uses forward slashes on Windows
    #    (prevents shlex.join from wrapping C:\...\python.exe in POSIX single quotes)
    test_task_py = pkg_dir / "eval_pipeline" / "tasks" / "test_custom_task.py"
    if test_task_py.exists():
        content = test_task_py.read_text(encoding="utf-8")
        old_cmd = 'cmd = [sys.executable, "-u", "-m", "pytest", "--color=no"]'
        new_cmd = 'cmd = [Path(sys.executable).as_posix(), "-u", "-m", "pytest", "--color=no"]'
        if old_cmd in content:
            content = content.replace(old_cmd, new_cmd)
            test_task_py.write_text(content, encoding="utf-8")
            print("Patched test_custom_task.py for Windows profiler command wrapping.")

    # 2. Patch profiler_command.py:
    #    - Convert WindowsPath in VTune.env_vars() to str (required by Windows CreateProcess)
    #    - Set default SYCL profiler to VTune on Windows
    prof_cmd_py = pkg_dir / "eval_pipeline" / "profiler_command.py"
    if prof_cmd_py.exists():
        content = prof_cmd_py.read_text(encoding="utf-8")
        changed = False
        old_env = '"KERNELFOUNDRY_vtune_result_dir": self.output_dir / "vtune_result"'
        new_env = '"KERNELFOUNDRY_vtune_result_dir": str(self.output_dir / "vtune_result")'
        if old_env in content:
            content = content.replace(old_env, new_env)
            changed = True

        old_default = '_DEFAULT_PROFILERS = {\n    "sycl": "unitrace",'
        new_default = '_DEFAULT_PROFILERS = {\n    "sycl": "vtune",'
        if old_default in content:
            content = content.replace(old_default, new_default)
            changed = True

        if changed:
            prof_cmd_py.write_text(content, encoding="utf-8")
            print("Patched profiler_command.py for Windows VTune profiling.")

    # 3. Patch profiler_feedback.py to default SYCL profiler feedback to VTune on Windows
    prof_fb_py = pkg_dir / "eval_pipeline" / "profiler_feedback.py"
    if prof_fb_py.exists():
        content = prof_fb_py.read_text(encoding="utf-8")
        old_fb_default = '_DEFAULT_PROFILER_FEEDBACK = {\n    "sycl": "unitrace",'
        new_fb_default = '_DEFAULT_PROFILER_FEEDBACK = {\n    "sycl": "vtune",'
        if old_fb_default in content:
            content = content.replace(old_fb_default, new_fb_default)
            prof_fb_py.write_text(content, encoding="utf-8")
            print("Patched profiler_feedback.py to default SYCL feedback to VTune.")

    # 4. Patch hardware_info.py to map Windows GPU device name for Lunar Lake Roofline analysis
    hw_info_py = pkg_dir / "eval_pipeline" / "utils" / "hardware_info.py"
    if hw_info_py.exists():
        content = hw_info_py.read_text(encoding="utf-8")
        alias_line = 'hardware_info["Intel(R) Arc(TM) 140V GPU (16GB)"] = hardware_info["Intel(R) Core(TM) Ultra 7 258V"]'
        if alias_line not in content and '"Intel(R) Core(TM) Ultra 7 258V"' in content:
            content = content.rstrip() + f"\n\n# Windows GPU device name alias for Lunar Lake\n{alias_line}\n"
            hw_info_py.write_text(content, encoding="utf-8")
            print("Patched hardware_info.py with Windows Lunar Lake GPU roofline alias.")


def configure_mcp(kf_root: str):
    """Register KernelFoundry MCP server and custom coding agents (VS Code, Copilot, Claude, Cursor)."""
    python_exe = os.path.join(kf_root, ".venv", "Scripts", "python.exe")
    user_home = os.path.expanduser("~")

    with open(os.path.join(kf_root, "kf_env.json"), "r", encoding="utf-8") as f:
        kf_env = json.load(f)

    for client in ("claude", "copilot"):
        for scope in ("user", "project"):
            subprocess.run(
                [
                    python_exe,
                    "-m",
                    "kernelfoundry.mcp_server",
                    "install_agent",
                    "--client",
                    client,
                    "--scope",
                    scope,
                    "--force",
                ],
                cwd=kf_root,
                check=True,
            )
            print(f"Installed agent for {client} (scope={scope})")

    mcp_env = {k: v for k, v in kf_env.items() if k != "PATH_PREPEND"}
    mcp_env["CMAKE_GENERATOR"] = "Ninja"

    vscode_config = {
        "servers": {
            "kernelfoundry-mcp": {
                "type": "stdio",
                "command": python_exe,
                "args": ["-P", "-m", "kernelfoundry.mcp_server"],
                "env": mcp_env,
            }
        }
    }

    standard_mcp_config = {
        "mcpServers": {
            "kernelfoundry-mcp": {
                "type": "stdio",
                "command": python_exe,
                "args": ["-P", "-m", "kernelfoundry.mcp_server"],
                "env": mcp_env,
            }
        }
    }

    vscode_ws_dir = os.path.join(kf_root, ".vscode")
    os.makedirs(vscode_ws_dir, exist_ok=True)
    with open(os.path.join(vscode_ws_dir, "mcp.json"), "w", encoding="utf-8") as f:
        json.dump(vscode_config, f, indent=2)
    print("Wrote", os.path.join(vscode_ws_dir, "mcp.json"))

    appdata_roaming = os.environ.get("APPDATA") or os.path.join(user_home, "AppData", "Roaming")
    vscode_user_dir = os.path.join(appdata_roaming, "Code", "User")
    os.makedirs(vscode_user_dir, exist_ok=True)
    with open(os.path.join(vscode_user_dir, "mcp.json"), "w", encoding="utf-8") as f:
        json.dump(vscode_config, f, indent=2)
    print("Wrote", os.path.join(vscode_user_dir, "mcp.json"))

    with open(os.path.join(kf_root, ".mcp.json"), "w", encoding="utf-8") as f:
        json.dump(standard_mcp_config, f, indent=2)
    print("Wrote", os.path.join(kf_root, ".mcp.json"))

    cursor_dir = os.path.join(user_home, ".cursor")
    os.makedirs(cursor_dir, exist_ok=True)
    with open(os.path.join(cursor_dir, "mcp.json"), "w", encoding="utf-8") as f:
        json.dump(standard_mcp_config, f, indent=2)
    print("Wrote", os.path.join(cursor_dir, "mcp.json"))


def run_verification(kf_root: str):
    """Run a self-contained verification suite for the PyPI KernelFoundry installation on Intel GPU."""
    print("=== 1. Verifying Toolchain & Profiler Binaries ===")
    for tool in ("icpx", "ocloc", "cl", "vtune", "dot"):
        resolved = shutil.which(tool)
        if not resolved:
            raise RuntimeError(f"Required tool '{tool}' not found on PATH.")
        print(f"  [OK] {tool}: {resolved}")

    icpx_out = subprocess.check_output(["icpx", "--version"], text=True, stderr=subprocess.STDOUT).splitlines()[0]
    vtune_out = subprocess.check_output(["vtune", "--version"], text=True, stderr=subprocess.STDOUT).splitlines()[0]
    print(f"  [OK] DPC++ Compiler: {icpx_out}")
    print(f"  [OK] VTune Profiler: {vtune_out}")

    print("\n=== 2. Verifying KernelFoundry Package & Windows VTune Configuration ===")
    kf_ver = importlib.metadata.version("kernelfoundry")
    import kernelfoundry
    from kernelfoundry.eval_pipeline.profiler_command import _DEFAULT_PROFILERS
    from kernelfoundry.eval_pipeline.profiler_feedback import _DEFAULT_PROFILER_FEEDBACK

    assert _DEFAULT_PROFILERS.get("sycl") == "vtune", f"Expected sycl profiler 'vtune', got {_DEFAULT_PROFILERS}"
    assert _DEFAULT_PROFILER_FEEDBACK.get("sycl") == "vtune", f"Expected sycl feedback 'vtune', got {_DEFAULT_PROFILER_FEEDBACK}"
    print(f"  [OK] kernelfoundry {kf_ver} imported from {kernelfoundry.__file__}")
    print(f"  [OK] Default profilers: SYCL={_DEFAULT_PROFILERS['sycl']}, OpenCL={_DEFAULT_PROFILERS['ocl']}")

    print("\n=== 3. Verifying PyTorch XPU (SYCL Runtime) on Intel GPU ===")
    import torch

    if not torch.xpu.is_available():
        raise RuntimeError("torch.xpu.is_available() returned False!")
    dev_name = torch.xpu.get_device_name(0)
    a = torch.randn(256, 256, device="xpu")
    b = torch.randn(256, 256, device="xpu")
    c = torch.matmul(a, b)
    torch.xpu.synchronize()
    assert c.shape == (256, 256)
    print(f"  [OK] PyTorch {torch.__version__} XPU active on '{dev_name}' (256x256 matmul verified)")

    print("\n=== 4. Verifying OpenCL Kernel Compilation & Execution on Intel GPU ===")
    import numpy as np
    import pyopencl as cl

    platforms = cl.get_platforms()
    intel_devs = [
        d for p in platforms for d in p.get_devices(device_type=cl.device_type.GPU)
        if "Intel" in d.name or "Arc" in d.name
    ]
    if not intel_devs:
        raise RuntimeError("No Intel OpenCL GPU device found!")
    ctx = cl.Context([intel_devs[0]])
    queue = cl.CommandQueue(ctx)
    prg = cl.Program(
        ctx,
        "__kernel void vadd(__global const float *a, __global const float *b, __global float *c) {"
        " int i = get_global_id(0); c[i] = a[i] + b[i]; }",
    ).build()
    x_np = np.ones(1024, dtype=np.float32) * 2.0
    y_np = np.ones(1024, dtype=np.float32) * 3.0
    z_np = np.empty_like(x_np)
    mf = cl.mem_flags
    x_buf = cl.Buffer(ctx, mf.READ_ONLY | mf.COPY_HOST_PTR, hostbuf=x_np)
    y_buf = cl.Buffer(ctx, mf.READ_ONLY | mf.COPY_HOST_PTR, hostbuf=y_np)
    z_buf = cl.Buffer(ctx, mf.WRITE_ONLY, z_np.nbytes)
    prg.vadd(queue, x_np.shape, None, x_buf, y_buf, z_buf)
    cl.enqueue_copy(queue, z_np, z_buf).wait()
    assert np.allclose(z_np, 5.0)
    print(f"  [OK] OpenCL kernel compiled and verified on '{intel_devs[0].name}'")

    print("\n=== 5. Verifying Vulkan Compute Device on Intel GPU ===")
    import vulkan as vk

    app_info = vk.VkApplicationInfo(
        sType=vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        pApplicationName="kf_verify",
        applicationVersion=vk.VK_MAKE_VERSION(1, 0, 0),
        pEngineName="NoEngine",
        engineVersion=vk.VK_MAKE_VERSION(1, 0, 0),
        apiVersion=vk.VK_API_VERSION_1_0,
    )
    inst_info = vk.VkInstanceCreateInfo(
        sType=vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        pApplicationInfo=app_info,
    )
    instance = vk.vkCreateInstance(inst_info, None)
    phys_devs = vk.vkEnumeratePhysicalDevices(instance)
    vk_names = [vk.vkGetPhysicalDeviceProperties(d).deviceName for d in phys_devs]
    vk.vkDestroyInstance(instance, None)
    if not vk_names:
        raise RuntimeError("No Vulkan physical devices found!")
    print(f"  [OK] Vulkan physical devices available: {', '.join(vk_names)}")
    print("\nAll KernelFoundry GPU verification checks passed!")


def main():
    parser = argparse.ArgumentParser(description="Configure selective Windows toolchain environment for KernelFoundry.")
    parser.add_argument(
        "--kf-root",
        default=os.path.join(os.path.expanduser("~"), "kernelfoundry"),
        help="Path to the KernelFoundry workspace directory.",
    )
    parser.add_argument(
        "--configure-mcp",
        action="store_true",
        help="Register KernelFoundry MCP server and coding agents.",
    )
    parser.add_argument(
        "--verify",
        action="store_true",
        help="Run the self-contained GPU and toolchain verification suite.",
    )
    args = parser.parse_args()

    kf_root = os.path.abspath(args.kf_root)
    if args.configure_mcp:
        configure_mcp(kf_root)
        return
    if args.verify:
        apply_windows_patches(kf_root)
        run_verification(kf_root)
        return

    venv_dir = os.path.join(kf_root, ".venv")
    oneapi_root = r"C:\Program Files (x86)\Intel\oneAPI"
    cmplr_root = os.path.join(oneapi_root, "compiler", "latest")
    clang_dir = get_latest(os.path.join(cmplr_root, "lib", "clang", "*"))
    clang_ver = os.path.basename(clang_dir)

    ocloc_bin = os.path.join(oneapi_root, "ocloc", "latest", "bin")
    vtune_bin = os.path.join(oneapi_root, "vtune", "latest", "bin64")

    msvc_dir = get_latest(r"C:\Program Files\Microsoft Visual Studio\*\*\VC\Tools\MSVC\*")
    vs_dir = os.path.abspath(os.path.join(msvc_dir, "..", "..", "..", ".."))
    ninja_dir = os.path.join(vs_dir, r"Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja")

    winkit_dir = r"C:\Program Files (x86)\Windows Kits\10"
    sdk_inc_dir = get_latest(os.path.join(winkit_dir, "Include", "10.*"))
    sdk_ver = os.path.basename(sdk_inc_dir)

    vulkan_sdk = get_latest(r"C:\VulkanSDK\*", optional=True)
    levelzero_sdk = get_latest(r"C:\Program Files\LevelZeroSDK\*", optional=True)
    graphviz_root = r"C:\Program Files\Graphviz"

    include_dirs = [
        os.path.join(cmplr_root, "include"),
        os.path.join(cmplr_root, "include", "sycl"),
        os.path.join(msvc_dir, "include"),
        os.path.join(winkit_dir, "Include", sdk_ver, "ucrt"),
        os.path.join(winkit_dir, "Include", sdk_ver, "shared"),
        os.path.join(winkit_dir, "Include", sdk_ver, "um"),
        os.path.join(winkit_dir, "Include", sdk_ver, "winrt"),
        os.path.join(winkit_dir, "Include", sdk_ver, "cppwinrt"),
        os.path.join(graphviz_root, "include"),
    ]
    if levelzero_sdk:
        include_dirs.append(os.path.join(levelzero_sdk, "include"))
    if vulkan_sdk:
        include_dirs.append(os.path.join(vulkan_sdk, "Include"))
    include_dirs = [d for d in include_dirs if os.path.exists(d)]

    lib_dirs = [
        os.path.join(cmplr_root, "lib", "clang", clang_ver, "lib", "windows"),
        os.path.join(cmplr_root, "opt", "compiler", "lib"),
        os.path.join(cmplr_root, "lib"),
        os.path.join(msvc_dir, "lib", "x64"),
        os.path.join(winkit_dir, "Lib", sdk_ver, "ucrt", "x64"),
        os.path.join(winkit_dir, "Lib", sdk_ver, "um", "x64"),
        os.path.join(graphviz_root, "lib"),
    ]
    if levelzero_sdk:
        lib_dirs.append(os.path.join(levelzero_sdk, "lib"))
    if vulkan_sdk:
        lib_dirs.append(os.path.join(vulkan_sdk, "Lib"))
    lib_dirs = [d for d in lib_dirs if os.path.exists(d)]

    libpath_dirs = [
        os.path.join(msvc_dir, "lib", "x64"),
        os.path.join(winkit_dir, "UnionMetadata", sdk_ver),
        os.path.join(winkit_dir, "References", sdk_ver),
    ]
    libpath_dirs = [d for d in libpath_dirs if os.path.exists(d)]

    path_dirs = [
        os.path.join(venv_dir, "Scripts"),
        os.path.join(venv_dir, "Library", "bin"),
        os.path.join(msvc_dir, "bin", "Hostx64", "x64"),
        os.path.join(winkit_dir, "bin", sdk_ver, "x64"),
        ninja_dir,
        r"C:\Program Files\CMake\bin",
        os.path.join(cmplr_root, "bin"),
        os.path.join(cmplr_root, "bin", "compiler"),
        os.path.join(cmplr_root, "lib", "ocloc"),
        ocloc_bin,
        vtune_bin,
    ]
    if vulkan_sdk:
        path_dirs.append(os.path.join(vulkan_sdk, "Bin"))
    path_dirs.append(os.path.join(graphviz_root, "bin"))
    path_dirs = [d for d in path_dirs if os.path.exists(d)]

    env_vars = {
        "CMPLR_ROOT": cmplr_root,
        "VCToolsInstallDir": msvc_dir + "\\",
        "__MS_VC_INSTALL_PATH": msvc_dir + "\\",
        "WindowsSdkDir": winkit_dir + "\\",
        "WindowsSDKVersion": sdk_ver + "\\",
        "UCRTVersion": sdk_ver,
        "C_INCLUDE_PATH": os.path.join(cmplr_root, "include"),
        "CPLUS_INCLUDE_PATH": os.path.join(cmplr_root, "include"),
        "INCLUDE": ";".join(include_dirs),
        "LIB": ";".join(lib_dirs),
        "LIBPATH": ";".join(libpath_dirs),
        "CMAKE_GENERATOR": "Ninja",
        "PYTHONUTF8": "1",
        "PYTHONIOENCODING": "utf-8",
    }

    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment", 0, winreg.KEY_ALL_ACCESS) as key:
        try:
            existing_user_path, _ = winreg.QueryValueEx(key, "Path")
        except FileNotFoundError:
            existing_user_path = ""

        existing_parts = [p for p in existing_user_path.split(";") if p.strip()]
        norm_new = {os.path.normcase(os.path.normpath(p)) for p in path_dirs}
        filtered_existing = [
            p for p in existing_parts
            if os.path.normcase(os.path.normpath(p)) not in norm_new
        ]
        new_user_path = ";".join(path_dirs + filtered_existing)
        winreg.SetValueEx(key, "Path", 0, winreg.REG_EXPAND_SZ, new_user_path)

        for k, v in env_vars.items():
            winreg.SetValueEx(key, k, 0, winreg.REG_SZ, v)

    os.makedirs(kf_root, exist_ok=True)
    full_env = dict(env_vars)
    full_env["PATH_PREPEND"] = path_dirs
    with open(os.path.join(kf_root, "kf_env.json"), "w", encoding="utf-8") as f:
        json.dump(full_env, f, indent=2)

    ps1_lines = ["# KernelFoundry Toolchain Environment Setup for Windows 11 (Intel GPU)"]
    for k, v in env_vars.items():
        ps1_lines.append(f'$env:{k} = "{v}"')
    joined_path = ";".join(path_dirs)
    ps1_lines.append(f'$env:PATH = "{joined_path};" + $env:PATH')
    ps1_lines.append('Write-Host "KernelFoundry environment initialized (CMPLR_ROOT=$env:CMPLR_ROOT)" -ForegroundColor Green')
    with open(os.path.join(kf_root, "setup_kf_env.ps1"), "w", encoding="utf-8") as f:
        f.write("\n".join(ps1_lines) + "\n")

    cmd_lines = [
        "@echo off",
        "rem KernelFoundry Toolchain Environment Setup for Windows 11 (Intel GPU)",
    ]
    for k, v in env_vars.items():
        cmd_lines.append(f'set "{k}={v}"')
    cmd_lines.append(f'set "PATH={joined_path};%PATH%"')
    cmd_lines.append('echo KernelFoundry environment initialized.')
    with open(os.path.join(kf_root, "setup_kf_env.cmd"), "w", encoding="utf-8") as f:
        f.write("\r\n".join(cmd_lines) + "\r\n")

    apply_windows_patches(kf_root)

    print("Successfully configured KernelFoundry environment:")
    print("  CMPLR_ROOT:", cmplr_root)
    print("  Clang version:", clang_ver)
    print("  MSVC:", msvc_dir)
    print("  Windows SDK:", sdk_ver)
    print("  VTune Profiler:", vtune_bin)
    print("  PATH entries added:", len(path_dirs))


if __name__ == "__main__":
    main()
