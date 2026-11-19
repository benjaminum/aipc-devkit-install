# KernelFoundry Setup & GPU Kernel Optimization Guide for Intel® AI PC (Windows 11)

This directory contains the automated setup (GUI & CLI) and integration files for [**KernelFoundry**](https://github.com/isl-org/kernelfoundry) on Intel® AI PCs (Lunar Lake / Intel® Arc™ Graphics) running Windows 11, as part of [`intel/aipc-devkit-install`](https://github.com/intel/aipc-devkit-install).

---

## 1. Overview

**KernelFoundry** ([PyPI](https://pypi.org/project/kernelfoundry/) | [GitHub](https://github.com/isl-org/kernelfoundry)) is an open-source toolkit for hardware-aware GPU kernel development and optimization targeting **SYCL**, **OpenCL**, and **Vulkan** on Intel GPUs.

It supports two primary workflows:
1. **Agentic IDE Workflow (MCP Server + Custom Agent):** Use your coding IDE (VS Code, GitHub Copilot, Claude Code, Cursor) to isolate a GPU kernel into a task package, iteratively compile, test, benchmark, and profile candidate kernels on the local Intel GPU using the `build_and_test` MCP tool, and inspect historical optimization runs via `search_kernels_in_db`.
2. **Autonomous Evolutionary Search CLI (`kernelfoundry.algorithm`):** Run multi-iteration hardware-aware evolutionary search driven by an LLM API and real GPU hardware performance counters (**Intel® VTune™ Profiler**), with live visualization in the KernelFoundry Web UI (`python -m kernelfoundry.gui`).

---

## 2. Prerequisites & Components Installed

### Base System Prerequisites (`WingetGUI_Installer\Setup_1.ps1`)
- **Visual Studio Community 2026** (`Microsoft.VisualStudio.Community`) with Desktop Development with C++ (`MSVC 14.44+` / `14.51+` and Windows 11 SDK `10.0.26100.0`)
- **Python 3.12** (`Python.Python.3.12`) & **uv** (`Astral-sh.uv`)
- **CMake** (`Kitware.CMake`)
- **Khronos Vulkan SDK** (`KhronosGroup.VulkanSDK`, provides `glslangValidator.exe`)

### Components Installed & Configured by `kernelfoundry_setup.ps1`
- **Intel® oneAPI Toolkit 2026.2** (`intel-oneapi-toolkit-2026.2.0.661_offline.exe`, installed to `C:\Program Files (x86)\Intel\oneAPI`):
  - `icpx.exe` (Intel® oneAPI DPC++/C++ Compiler `2026.2` for SYCL kernels)
  - `ocloc.exe` (Intel® OpenCL Offline Compiler for AOT `spir64_gen` compilation)
  - `vtune.exe` (Intel® VTune™ Profiler `2026.6` for GPU hotspot, roofline, and XVE stall analysis)
- **Graphviz** (`Graphviz.Graphviz`, installed via `winget` to `C:\Program Files\Graphviz`, provides `dot.exe` and C headers/libraries for `pygraphviz` in the KernelFoundry Web UI)
- **Dedicated Python 3.12 Virtual Environment (`$HOME\kernelfoundry\.venv`):**
  - `torch==2.15.0+xpu`, `torchvision`, `torchaudio` from `https://download.pytorch.org/whl/xpu`
  - `kernelfoundry[all]` from PyPI (includes `mcp`, `algo`, `ui` with `pygraphviz` and `nicegui`)
- **Selective Windows Toolchain & VTune Environment (`setup_kf_env.ps1` / `setup_kf_env.cmd` & `HKCU\Environment`):**
  - Configures `CMPLR_ROOT`, `INCLUDE`, `LIB`, `LIBPATH`, `CMAKE_GENERATOR=Ninja`, `PYTHONUTF8=1`, `PYTHONIOENCODING=utf-8`, and selective `PATH` entries (including `vtune.exe`).
  - Configures **Intel® VTune™ Profiler** (`vtune`) as the default profiler for both SYCL and OpenCL kernels on Windows.
- **MCP Server & Custom Agent Registration:**
  - Configures `kernelfoundry-mcp` in VS Code (`.vscode/mcp.json` and `%APPDATA%\Code\User\mcp.json`), Claude Code (`.mcp.json`), and Cursor (`~/.cursor/mcp.json`).
  - Installs the `kernelfoundry-optimize` custom agent for GitHub Copilot and Claude Code.

---

## 3. Installation & Usage (GUI and CLI Modes)

### Option A: Interactive Windows Forms GUI (Desktop Session)
Launch the interactive graphical installer to inspect component status, select/deselect individual setup steps, watch live console output, or run GPU verification tests:

```powershell
cd "Windows_Software_Installation\KernelFoundry"
.\kernelfoundry_setup.ps1 gui
```

### Option B: Automated Command-Line Installation (Headless / SSH)
Run all setup and verification steps from the command line:

```powershell
cd "Windows_Software_Installation\KernelFoundry"

# Full installation + verification
.\kernelfoundry_setup.ps1 install

# Run only GPU verification tests (Toolchain, VTune, PyTorch XPU, OpenCL, Vulkan)
.\kernelfoundry_setup.ps1 verify

# Uninstall KernelFoundry .venv and workspace configs
.\kernelfoundry_setup.ps1 uninstall
```

---

## 4. Important Windows 11 Technical Notes

1. **Do NOT source full `setvars.bat` globally:**
   - Running `C:\Program Files (x86)\Intel\oneAPI\setvars.bat` sets `OCL_ICD_FILENAMES` to the CPU OpenCL ICD (`intelocl64.dll`) and prepends `oneAPI\compiler\latest\bin` ahead of the Python virtual environment, which can shadow PyTorch XPU runtime DLLs or hide the Intel Arc GPU OpenCL device.
   - Instead, `configure_kf_env.py` / `setup_kf_env.ps1` places `.venv\Scripts` and `.venv\Library\bin` **ahead** of `oneAPI\compiler\latest\bin` on `PATH`, omits `OCL_ICD_FILENAMES`, and sets `CMPLR_ROOT`, `INCLUDE`, `LIB`, and `LIBPATH` explicitly.
2. **PyTorch XPU + MSVC 14.44+ Compatibility (`torch==2.15.0+xpu`):**
   - Visual Studio 2026 ships MSVC `14.51` (`19.51`). Older PyTorch headers (`torch==2.9`) trigger `error C2872: 'std': ambiguous symbol` with newer MSVC standard library headers.
   - `torch==2.15.0+xpu` compiles SYCL C++/PyTorch extensions cleanly with `icpx` (`2026.2`) + MSVC `14.51` and bundles the `sycl9.dll` runtime.
3. **Intel® VTune™ Profiler on Windows (`vtune.exe`):**
   - Intel® oneAPI Toolkit `2026.2` installs `vtune.exe` (`C:\Program Files (x86)\Intel\oneAPI\vtune\latest\bin64\vtune.exe`).
   - `configure_kf_env.py` configures the installed `kernelfoundry` package to use `vtune` by default on Windows (`_DEFAULT_PROFILERS["sycl"] = "vtune"`), fixes `VTune.env_vars()` so `KERNELFOUNDRY_vtune_result_dir` is passed as a `str` (required by Windows `CreateProcess`), and uses `Path(sys.executable).as_posix()` in `test_custom_task.py` so `shlex.join` does not wrap backslashed paths in POSIX single quotes.
4. **Windows GPU Name Alias for Roofline Modeling (`hardware_info.py`):**
   - On Linux, `worker_info` resolves Lunar Lake roofline limits via `cpu_info` from `/proc/cpuinfo` (`"Intel(R) Core(TM) Ultra 7 258V"`). On Windows, `gpu_name` is reported as `"Intel(R) Arc(TM) 140V GPU (16GB)"`. Adding this alias to `hardware_info.py` enables full roofline percentage and bottleneck analysis.
5. **UTF-8 Console I/O (`PYTHONUTF8=1`):**
   - Setting `PYTHONUTF8=1` and `PYTHONIOENCODING=utf-8` prevents `cp1252` `UnicodeEncodeError` exceptions when KernelFoundry logs or documentation containing Unicode symbols are printed over SSH or redirected subprocesses.

---

## 5. Quickstart Usage

### Activate the Environment (if in an older shell)
New shells automatically inherit the User environment variables. To explicitly load the environment in an existing PowerShell session:
```powershell
cd $HOME\kernelfoundry
.\setup_kf_env.ps1
.\.venv\Scripts\Activate.ps1
```

### Run End-to-End Pipeline Validation with VTune Profiling (No LLM API Key Needed)
```powershell
python -m kernelfoundry.algorithm run `
    task=<path/to/your_task_folder> `
    task_origin=custom `
    job_name=quickstart_lnl `
    gpu_arch=lnl `
    language=SYCL `
    validate=true `
    max_iters=0
```

### Launch the Web UI
```powershell
python -m kernelfoundry.gui
# Open http://localhost:8885 in your browser
```
