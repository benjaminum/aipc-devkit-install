<#
.SYNOPSIS
    Automated Windows 11 Setup Tool (GUI & CLI) for KernelFoundry on Intel AI PC (Lunar Lake / Arc GPU).

.DESCRIPTION
    Prepares an Intel AI PC running Windows 11 for GPU kernel development and hardware-aware
    optimization (SYCL, OpenCL, and Vulkan) using the KernelFoundry Python package from PyPI.
    Designed as part of https://github.com/intel/aipc-devkit-install.git.

    Supports both an interactive Windows Forms GUI mode and headless command-line modes:
      - .\kernelfoundry_setup.ps1 gui       (or -Gui)       : Launches the interactive Windows Forms GUI
      - .\kernelfoundry_setup.ps1 install   (or -Install)   : Runs the full automated installation in CLI mode
      - .\kernelfoundry_setup.ps1 verify    (or -Verify)    : Runs the GPU verification test suite (SYCL, OpenCL, Vulkan)
      - .\kernelfoundry_setup.ps1 uninstall (or -Uninstall) : Removes KernelFoundry .venv and workspace MCP configs

    Steps performed during installation:
      1. Ensures Intel oneAPI Toolkit 2026.2 (providing icpx, ocloc, and VTune Profiler) and Graphviz are installed.
      2. Creates the workspace directory and a Python 3.12 virtual environment (.venv) using uv.
      3. Configures selective Windows toolchain environment variables (MSVC, Windows SDK, oneAPI icpx/ocloc/vtune,
         Vulkan SDK, Level Zero SDK, Graphviz, CMAKE_GENERATOR=Ninja, PYTHONUTF8=1).
      4. Installs PyTorch XPU (torch==2.15.0+xpu, torchvision, torchaudio).
      5. Installs kernelfoundry[all] from PyPI and applies Windows VTune profiler integration.
      6. Registers the KernelFoundry MCP server and custom coding agents (VS Code, GitHub Copilot, Claude Code, Cursor).
      7. Runs self-contained GPU verification checks across SYCL/XPU, OpenCL, Vulkan, and VTune on the Intel GPU.
#>

param(
    [Parameter(Position = 0)]
    [string]$Command = "",
    [string]$InstallDir = "$env:USERPROFILE\kernelfoundry",
    [switch]$Gui,
    [switch]$Install,
    [switch]$Verify,
    [switch]$Uninstall,
    [switch]$SkipWinget,
    [switch]$SkipVerify
)

$ErrorActionPreference = "Stop"
$ScriptDir = $PSScriptRoot
$LogDir = Join-Path $ScriptDir "logs"
if (-not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
}
$LogFile = Join-Path $LogDir "kernelfoundry_setup.log"

# Normalize command mode
if ($Command -match "^-{1,2}(\w+)$") {
    $Command = $matches[1].ToLower()
} else {
    $Command = $Command.ToLower()
}

if ($Gui)           { $Command = "gui" }
elseif ($Uninstall) { $Command = "uninstall" }
elseif ($Verify)    { $Command = "verify" }
elseif ($Install)   { $Command = "install" }
elseif ([string]::IsNullOrWhiteSpace($Command)) {
    $Command = "install"
}

$script:GuiLogBox = $null

function Write-StepLog {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] $Message"
    Add-Content -Path $LogFile -Value $logLine -Encoding UTF8 -ErrorAction SilentlyContinue

    $consoleColor = switch ($Color) {
        "Cyan"   { [ConsoleColor]::Cyan }
        "Green"  { [ConsoleColor]::Green }
        "Yellow" { [ConsoleColor]::Yellow }
        "Red"    { [ConsoleColor]::Red }
        default  { [ConsoleColor]::White }
    }
    Write-Host $Message -ForegroundColor $consoleColor

    if ($null -ne $script:GuiLogBox -and -not $script:GuiLogBox.IsDisposed) {
        $drawingColor = switch ($Color) {
            "Cyan"   { [System.Drawing.Color]::Cyan }
            "Green"  { [System.Drawing.Color]::LightGreen }
            "Yellow" { [System.Drawing.Color]::Khaki }
            "Red"    { [System.Drawing.Color]::Salmon }
            default  { [System.Drawing.Color]::Gainsboro }
        }
        $script:GuiLogBox.SelectionStart = $script:GuiLogBox.TextLength
        $script:GuiLogBox.SelectionLength = 0
        $script:GuiLogBox.SelectionColor = $drawingColor
        $script:GuiLogBox.AppendText("$logLine`r`n")
        $script:GuiLogBox.ScrollToCaret()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Invoke-ExternalCommand {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $PWD.Path
    )
    Write-StepLog "  > $FilePath $($Arguments -join ' ')" "Cyan"
    Push-Location $WorkingDirectory
    try {
        $output = & $FilePath @Arguments 2>&1
        foreach ($line in $output) {
            if ($null -ne $line) {
                Write-StepLog "    $line" "White"
            }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Command exited with code ${LASTEXITCODE}: $FilePath $($Arguments -join ' ')"
        }
    } finally {
        Pop-Location
    }
}

function Get-StepDefinitions {
    return @(
        [PSCustomObject]@{
            Id          = "winget-deps"
            Name        = "1. System Dependencies (oneAPI 2026.2 & Graphviz)"
            Description = "Install Intel oneAPI Toolkit 2026.2 (icpx, ocloc, VTune Profiler) & Graphviz (dot)"
            DefaultRun  = (-not $SkipWinget)
        },
        [PSCustomObject]@{
            Id          = "python-venv"
            Name        = "2. Python 3.12 Virtual Environment"
            Description = "Create workspace folder, isolated .venv via uv, and install pip"
            DefaultRun  = $true
        },
        [PSCustomObject]@{
            Id          = "toolchain-env"
            Name        = "3. Windows Toolchain & VTune Setup"
            Description = "Configure selective PATH, INCLUDE, LIB, CMPLR_ROOT & VTune environment"
            DefaultRun  = $true
        },
        [PSCustomObject]@{
            Id          = "pytorch-xpu"
            Name        = "4. PyTorch XPU Runtime"
            Description = "Install torch==2.15.0+xpu, torchvision, torchaudio"
            DefaultRun  = $true
        },
        [PSCustomObject]@{
            Id          = "kernelfoundry-pkg"
            Name        = "5. KernelFoundry Package (PyPI)"
            Description = "Install kernelfoundry[all] from PyPI (CLI, Web UI, MCP server) & apply Windows VTune config"
            DefaultRun  = $true
        },
        [PSCustomObject]@{
            Id          = "mcp-agents"
            Name        = "6. MCP Server & Coding Agents"
            Description = "Register kernelfoundry-mcp and kernelfoundry-optimize agent (VS Code, Copilot, Claude, Cursor)"
            DefaultRun  = $true
        },
        [PSCustomObject]@{
            Id          = "verify-gpu"
            Name        = "7. GPU Verification Suite"
            Description = "Verify Toolchain, VTune, PyTorch XPU, OpenCL kernel compilation, and Vulkan on Intel GPU"
            DefaultRun  = (-not $SkipVerify)
        }
    )
}

function Get-StepStatus {
    param(
        [string]$StepId,
        [string]$KfDir
    )
    $venvPython = Join-Path $KfDir ".venv\Scripts\python.exe"
    switch ($StepId) {
        "winget-deps" {
            $hasOneApi = (Test-Path "C:\Program Files (x86)\Intel\oneAPI\compiler\2026.2\bin\icpx.exe") -and
                         (Test-Path "C:\Program Files (x86)\Intel\oneAPI\vtune\latest\bin64\vtune.exe")
            $hasGraphviz = Test-Path "C:\Program Files\Graphviz\bin\dot.exe"
            if ($hasOneApi -and $hasGraphviz) { return "Installed" }
            elseif ($hasOneApi -or $hasGraphviz) { return "Partial" }
            else { return "Not Installed" }
        }
        "python-venv" {
            if (Test-Path $venvPython) { return "Installed" }
            else { return "Not Installed" }
        }
        "toolchain-env" {
            if (Test-Path (Join-Path $KfDir "setup_kf_env.ps1")) { return "Configured" }
            else { return "Not Configured" }
        }
        "pytorch-xpu" {
            if (Test-Path (Join-Path $KfDir ".venv\Lib\site-packages\torch\__init__.py")) { return "Installed" }
            else { return "Not Installed" }
        }
        "kernelfoundry-pkg" {
            if (Test-Path (Join-Path $KfDir ".venv\Scripts\kernelfoundry-gui.exe")) { return "Installed" }
            else { return "Not Installed" }
        }
        "mcp-agents" {
            if (Test-Path (Join-Path $KfDir ".vscode\mcp.json")) { return "Configured" }
            else { return "Not Configured" }
        }
        "verify-gpu" {
            return "Ready"
        }
        default {
            return "Ready"
        }
    }
}

function Invoke-SetupStep {
    param(
        [Parameter(Mandatory)]
        [string]$StepId,
        [Parameter(Mandatory)]
        [string]$KfDir
    )

    $venvDir = Join-Path $KfDir ".venv"
    $pythonExe = Join-Path $venvDir "Scripts\python.exe"
    $cfgScript = Join-Path $ScriptDir "configure_kf_env.py"
    if (-not (Test-Path $cfgScript)) { $cfgScript = Join-Path $KfDir "configure_kf_env.py" }

    switch ($StepId) {
        "winget-deps" {
            if (-not (Test-Path "C:\Program Files (x86)\Intel\oneAPI\compiler\2026.2\bin\icpx.exe")) {
                Write-StepLog "[1/7] Downloading and installing Intel oneAPI Toolkit 2026.2 (icpx, ocloc, VTune)..." "Yellow"
                $oneApiUrl = "https://registrationcenter-download.intel.com/akdlm/IRC_NAS/728c4418-1b40-47a9-ad51-31530fb27c94/intel-oneapi-toolkit-2026.2.0.661_offline.exe"
                $oneApiInstaller = Join-Path $env:TEMP "intel-oneapi-toolkit-2026.2.0.661_offline.exe"
                Invoke-ExternalCommand -FilePath "curl.exe" -Arguments @("-L", "-s", "-S", $oneApiUrl, "-o", $oneApiInstaller)
                Invoke-ExternalCommand -FilePath $oneApiInstaller -Arguments @(
                    "-s", "-a", "--silent", "--eula", "accept",
                    "-p=NEED_VS2019_INTEGRATION=0", "-p=NEED_VS2022_INTEGRATION=0", "-p=NEED_VS2026_INTEGRATION=0"
                )
                Remove-Item -Path $oneApiInstaller -Force -ErrorAction SilentlyContinue
            } else {
                Write-StepLog "[1/7] Intel oneAPI Toolkit 2026.2 already installed." "Green"
            }

            if (-not (Test-Path "C:\Program Files\Graphviz\bin\dot.exe")) {
                Write-StepLog "[1/7] Installing Graphviz via winget..." "Yellow"
                Invoke-ExternalCommand -FilePath "winget" -Arguments @("install", "--id", "Graphviz.Graphviz", "--silent", "--accept-package-agreements", "--accept-source-agreements")
            } else {
                Write-StepLog "[1/7] Graphviz already installed." "Green"
            }
        }

        "python-venv" {
            if (-not (Test-Path $KfDir)) {
                New-Item -Path $KfDir -ItemType Directory -Force | Out-Null
            }
            $srcHelper = Join-Path $ScriptDir "configure_kf_env.py"
            if (Test-Path $srcHelper) {
                Copy-Item -Path $srcHelper -Destination (Join-Path $KfDir "configure_kf_env.py") -Force
            }
            if (-not (Test-Path $pythonExe)) {
                Write-StepLog "[2/7] Creating Python 3.12 virtual environment at $venvDir..." "Yellow"
                Invoke-ExternalCommand -FilePath "uv" -Arguments @("venv", $venvDir, "--python", "3.12")
            } else {
                Write-StepLog "[2/7] Virtual environment already exists at $venvDir." "Green"
            }
            Invoke-ExternalCommand -FilePath "uv" -Arguments @("pip", "install", "--python", $pythonExe, "pip")
        }

        "toolchain-env" {
            Write-StepLog "[3/7] Configuring selective Windows toolchain & VTune profiler environment..." "Yellow"
            Invoke-ExternalCommand -FilePath $pythonExe -Arguments @($cfgScript, "--kf-root", $KfDir)
            $setupEnvPs1 = Join-Path $KfDir "setup_kf_env.ps1"
            if (Test-Path $setupEnvPs1) {
                . $setupEnvPs1
            }
        }

        "pytorch-xpu" {
            Write-StepLog "[4/7] Installing PyTorch 2.15.0+xpu for Intel GPU..." "Yellow"
            Invoke-ExternalCommand -FilePath "uv" -Arguments @(
                "pip", "install", "--python", $pythonExe,
                "torch==2.15.0+xpu", "torchvision", "torchaudio",
                "--index-url", "https://download.pytorch.org/whl/xpu"
            )
        }

        "kernelfoundry-pkg" {
            Write-StepLog "[5/7] Installing kernelfoundry[all] from PyPI..." "Yellow"
            $setupEnvPs1 = Join-Path $KfDir "setup_kf_env.ps1"
            if (Test-Path $setupEnvPs1) { . $setupEnvPs1 }
            Invoke-ExternalCommand -FilePath "uv" -Arguments @("pip", "install", "--python", $pythonExe, "kernelfoundry[all]")
            Invoke-ExternalCommand -FilePath $pythonExe -Arguments @($cfgScript, "--kf-root", $KfDir)
        }

        "mcp-agents" {
            Write-StepLog "[6/7] Configuring KernelFoundry MCP server and coding agents..." "Yellow"
            Invoke-ExternalCommand -FilePath $pythonExe -Arguments @($cfgScript, "--kf-root", $KfDir, "--configure-mcp")
        }

        "verify-gpu" {
            Write-StepLog "[7/7] Running GPU & toolchain verification suite on Intel GPU..." "Yellow"
            $setupEnvPs1 = Join-Path $KfDir "setup_kf_env.ps1"
            if (Test-Path $setupEnvPs1) { . $setupEnvPs1 }
            Invoke-ExternalCommand -FilePath $pythonExe -Arguments @($cfgScript, "--kf-root", $KfDir, "--verify") -WorkingDirectory $KfDir
        }
    }
}

function Invoke-UninstallKernelFoundry {
    param(
        [string]$KfDir
    )
    Write-StepLog "Starting KernelFoundry environment uninstallation..." "Yellow"
    $venvDir = Join-Path $KfDir ".venv"
    if (Test-Path $venvDir) {
        Write-StepLog "Removing virtual environment: $venvDir" "Yellow"
        Remove-Item -Path $venvDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($cfg in @(
        (Join-Path $KfDir ".vscode\mcp.json"),
        (Join-Path $KfDir ".mcp.json"),
        (Join-Path $KfDir "setup_kf_env.ps1"),
        (Join-Path $KfDir "setup_kf_env.cmd"),
        (Join-Path $KfDir "kf_env.json")
    )) {
        if (Test-Path $cfg) {
            Remove-Item -Path $cfg -Force -ErrorAction SilentlyContinue
        }
    }
    Write-StepLog "KernelFoundry virtual environment and workspace configs removed." "Green"
}

function Show-KernelFoundryGUI {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "KernelFoundry Setup & GPU Optimization Tool (Intel AI PC)"
    $form.Size = New-Object System.Drawing.Size(980, 720)
    $form.MinimumSize = New-Object System.Drawing.Size(880, 640)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"

    # Top Header Panel
    $pnlHeader = New-Object System.Windows.Forms.Panel
    $pnlHeader.Dock = "Top"
    $pnlHeader.Height = 105
    $pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "KernelFoundry Installer & Environment Manager"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 84, 159)
    $lblTitle.Location = New-Object System.Drawing.Point(16, 10)
    $lblTitle.AutoSize = $true

    $lblSubtitle = New-Object System.Windows.Forms.Label
    $lblSubtitle.Text = "Hardware-aware GPU kernel optimization (SYCL, OpenCL, Vulkan) with Intel VTune Profiler on Windows 11"
    $lblSubtitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $lblSubtitle.ForeColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $lblSubtitle.Location = New-Object System.Drawing.Point(18, 38)
    $lblSubtitle.AutoSize = $true

    # Install Dir input
    $lblKfDir = New-Object System.Windows.Forms.Label
    $lblKfDir.Text = "Workspace Dir:"
    $lblKfDir.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $lblKfDir.Location = New-Object System.Drawing.Point(16, 70)
    $lblKfDir.Size = New-Object System.Drawing.Size(120, 22)

    $txtKfDir = New-Object System.Windows.Forms.TextBox
    $txtKfDir.Text = $InstallDir
    $txtKfDir.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $txtKfDir.Location = New-Object System.Drawing.Point(140, 68)
    $txtKfDir.Size = New-Object System.Drawing.Size(340, 24)

    $btnBrowseKf = New-Object System.Windows.Forms.Button
    $btnBrowseKf.Text = "Browse..."
    $btnBrowseKf.Location = New-Object System.Drawing.Point(488, 67)
    $btnBrowseKf.Size = New-Object System.Drawing.Size(75, 25)

    $lblSupportedApis = New-Object System.Windows.Forms.Label
    $lblSupportedApis.Text = "Supported Kernels: SYCL (icpx), OpenCL (ocloc), Vulkan (SPIR-V) | Profiler: Intel VTune"
    $lblSupportedApis.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Italic)
    $lblSupportedApis.ForeColor = [System.Drawing.Color]::DarkSlateBlue
    $lblSupportedApis.Location = New-Object System.Drawing.Point(580, 70)
    $lblSupportedApis.Size = New-Object System.Drawing.Size(380, 22)

    $pnlHeader.Controls.AddRange(@(
        $lblTitle, $lblSubtitle,
        $lblKfDir, $txtKfDir, $btnBrowseKf,
        $lblSupportedApis
    ))

    # DataTable for Step Checklist
    $dt = New-Object System.Data.DataTable
    [void]$dt.Columns.Add("Check", [bool])
    [void]$dt.Columns.Add("Id", [string])
    [void]$dt.Columns.Add("Step", [string])
    [void]$dt.Columns.Add("Description", [string])
    [void]$dt.Columns.Add("Status", [string])

    $steps = Get-StepDefinitions
    foreach ($s in $steps) {
        $row = $dt.NewRow()
        $row.Check = $s.DefaultRun
        $row.Id = $s.Id
        $row.Step = $s.Name
        $row.Description = $s.Description
        $row.Status = Get-StepStatus -StepId $s.Id -KfDir $txtKfDir.Text
        $dt.Rows.Add($row)
    }

    # DataGridView for Steps
    $dg = New-Object System.Windows.Forms.DataGridView
    $dg.DataSource = $dt
    $dg.Dock = "Top"
    $dg.Height = 230
    $dg.AllowUserToAddRows = $false
    $dg.AllowUserToDeleteRows = $false
    $dg.RowHeadersVisible = $false
    $dg.SelectionMode = "FullRowSelect"
    $dg.BackgroundColor = [System.Drawing.Color]::White
    $dg.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $dg.AutoSizeColumnsMode = "Fill"

    # Bottom Panel (Progress Bar, Action Buttons, and Live Console)
    $pnlBottom = New-Object System.Windows.Forms.Panel
    $pnlBottom.Dock = "Fill"
    $pnlBottom.Padding = New-Object System.Windows.Forms.Padding(12, 8, 12, 12)

    $progressBar = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Dock = "Top"
    $progressBar.Height = 22
    $progressBar.Minimum = 0
    $progressBar.Maximum = 100
    $progressBar.Value = 0

    $pnlButtons = New-Object System.Windows.Forms.Panel
    $pnlButtons.Dock = "Top"
    $pnlButtons.Height = 46

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Select All"
    $btnSelectAll.Size = New-Object System.Drawing.Size(90, 32)
    $btnSelectAll.Location = New-Object System.Drawing.Point(0, 7)

    $btnClearAll = New-Object System.Windows.Forms.Button
    $btnClearAll.Text = "Clear All"
    $btnClearAll.Size = New-Object System.Drawing.Size(90, 32)
    $btnClearAll.Location = New-Object System.Drawing.Point(96, 7)

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh Status"
    $btnRefresh.Size = New-Object System.Drawing.Size(110, 32)
    $btnRefresh.Location = New-Object System.Drawing.Point(192, 7)

    $btnRunSelected = New-Object System.Windows.Forms.Button
    $btnRunSelected.Text = "Install / Run Selected"
    $btnRunSelected.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnRunSelected.BackColor = [System.Drawing.Color]::FromArgb(0, 113, 197)
    $btnRunSelected.ForeColor = [System.Drawing.Color]::White
    $btnRunSelected.FlatStyle = "Flat"
    $btnRunSelected.Size = New-Object System.Drawing.Size(175, 32)
    $btnRunSelected.Location = New-Object System.Drawing.Point(312, 7)

    $btnUninstallGui = New-Object System.Windows.Forms.Button
    $btnUninstallGui.Text = "Uninstall Env"
    $btnUninstallGui.Size = New-Object System.Drawing.Size(115, 32)
    $btnUninstallGui.Location = New-Object System.Drawing.Point(497, 7)

    $btnExit = New-Object System.Windows.Forms.Button
    $btnExit.Text = "Exit"
    $btnExit.Size = New-Object System.Drawing.Size(90, 32)
    $btnExit.Location = New-Object System.Drawing.Point(622, 7)

    $pnlButtons.Controls.AddRange(@(
        $btnSelectAll, $btnClearAll, $btnRefresh,
        $btnRunSelected, $btnUninstallGui, $btnExit
    ))

    $txtLog = New-Object System.Windows.Forms.RichTextBox
    $txtLog.Dock = "Fill"
    $txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 28)
    $txtLog.ForeColor = [System.Drawing.Color]::Gainsboro
    $txtLog.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $script:GuiLogBox = $txtLog

    $pnlBottom.Controls.Add($txtLog)
    $pnlBottom.Controls.Add($pnlButtons)
    $pnlBottom.Controls.Add($progressBar)

    $form.Controls.Add($pnlBottom)
    $form.Controls.Add($dg)
    $form.Controls.Add($pnlHeader)

    $form.Add_Shown({
        if ($dg.Columns.Count -ge 5) {
            $dg.Columns[0].HeaderText = "Run?"
            $dg.Columns[0].FillWeight = 8
            $dg.Columns[1].Visible = $false
            $dg.Columns[2].HeaderText = "Step"
            $dg.Columns[2].ReadOnly = $true
            $dg.Columns[2].FillWeight = 27
            $dg.Columns[3].HeaderText = "Description"
            $dg.Columns[3].ReadOnly = $true
            $dg.Columns[3].FillWeight = 50
            $dg.Columns[4].HeaderText = "Status"
            $dg.Columns[4].ReadOnly = $true
            $dg.Columns[4].FillWeight = 15
        }
        Write-StepLog "KernelFoundry Setup GUI ready. Select steps above and click 'Install / Run Selected'." "Cyan"
    })

    $btnBrowseKf.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.SelectedPath = $txtKfDir.Text
        if ($fbd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtKfDir.Text = $fbd.SelectedPath
        }
    })

    $btnSelectAll.Add_Click({
        foreach ($row in $dt.Rows) { $row.Check = $true }
    })

    $btnClearAll.Add_Click({
        foreach ($row in $dt.Rows) { $row.Check = $false }
    })

    $refreshAction = {
        foreach ($row in $dt.Rows) {
            $row.Status = Get-StepStatus -StepId $row.Id -KfDir $txtKfDir.Text
        }
        $dg.Refresh()
    }
    $btnRefresh.Add_Click($refreshAction)

    $btnRunSelected.Add_Click({
        $dg.EndEdit()
        $selectedRows = @($dt.Rows | Where-Object { $_.Check })
        if ($selectedRows.Count -eq 0) {
            [void][System.Windows.Forms.MessageBox]::Show(
                "No setup steps selected. Please check at least one step to run.",
                "KernelFoundry Setup",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }

        $btnRunSelected.Enabled = $false
        $btnUninstallGui.Enabled = $false
        $progressBar.Value = 0

        $total = $selectedRows.Count
        $current = 0
        $failedSteps = @()

        foreach ($row in $selectedRows) {
            $current++
            $row.Status = "Running..."
            $dg.Refresh()
            [System.Windows.Forms.Application]::DoEvents()

            try {
                Invoke-SetupStep -StepId $row.Id -KfDir $txtKfDir.Text
                $row.Status = "Success"
            } catch {
                $row.Status = "Failed"
                $failedSteps += $row.Step
                Write-StepLog "[ERROR] Step '$($row.Step)' failed: $($_.Exception.Message)" "Red"
            }

            $progressBar.Value = [Math]::Min(100, [int](($current / $total) * 100))
            $dg.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $btnRunSelected.Enabled = $true
        $btnUninstallGui.Enabled = $true

        if ($failedSteps.Count -eq 0) {
            Write-StepLog "All selected steps completed successfully!" "Green"
            [void][System.Windows.Forms.MessageBox]::Show(
                "All $($selectedRows.Count) selected step(s) completed successfully!`n`nLog saved to:`n$LogFile",
                "KernelFoundry Setup - Completed Successfully",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        } else {
            [void][System.Windows.Forms.MessageBox]::Show(
                "$($failedSteps.Count) step(s) failed:`n- $($failedSteps -join "`n- ")`n`nCheck the live console and $LogFile for details.",
                "KernelFoundry Setup - Completed with Errors",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }
    })

    $btnUninstallGui.Add_Click({
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Are you sure you want to remove the KernelFoundry virtual environment (.venv) and workspace MCP configs?",
            "KernelFoundry Setup - Confirm Uninstall",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($confirm -eq [System.Windows.Forms.DialogResult]::Yes) {
            Invoke-UninstallKernelFoundry -KfDir $txtKfDir.Text
            & $refreshAction
            [void][System.Windows.Forms.MessageBox]::Show(
                "KernelFoundry environment uninstalled.",
                "KernelFoundry Setup",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
        }
    })

    $btnExit.Add_Click({
        $form.Close()
    })

    [void]$form.ShowDialog()
}

# ===================== MAIN EXECUTION DISPATCH =====================
if ($Command -eq "gui") {
    Show-KernelFoundryGUI
}
elseif ($Command -eq "uninstall") {
    Invoke-UninstallKernelFoundry -KfDir $InstallDir
}
elseif ($Command -eq "verify") {
    Write-StepLog "=================================================================" "Cyan"
    Write-StepLog "  KernelFoundry GPU Verification Suite (SYCL, OpenCL, Vulkan)" "Cyan"
    Write-StepLog "=================================================================" "Cyan"
    Invoke-SetupStep -StepId "verify-gpu" -KfDir $InstallDir
    Write-StepLog "=================================================================" "Green"
    Write-StepLog "  All verification tests passed!" "Green"
    Write-StepLog "=================================================================" "Green"
}
elseif ($Command -eq "install") {
    Write-StepLog "=================================================================" "Cyan"
    Write-StepLog "  KernelFoundry Setup for Intel AI PC DevKit (Windows 11)" "Cyan"
    Write-StepLog "=================================================================" "Cyan"

    foreach ($step in (Get-StepDefinitions)) {
        if ($step.DefaultRun) {
            Invoke-SetupStep -StepId $step.Id -KfDir $InstallDir
        } else {
            Write-StepLog "Skipping step: $($step.Name)" "Yellow"
        }
    }

    Write-StepLog "=================================================================" "Green"
    Write-StepLog "  KernelFoundry setup complete! Ready for GPU kernel optimization." "Green"
    Write-StepLog "=================================================================" "Green"
}
else {
    Write-Host @"
Usage:
    .\kernelfoundry_setup.ps1 gui       (or -Gui)       : Launch interactive Windows Forms GUI
    .\kernelfoundry_setup.ps1 install   (or -Install)   : Run full automated setup in CLI mode
    .\kernelfoundry_setup.ps1 verify    (or -Verify)    : Run GPU verification tests (SYCL, OpenCL, Vulkan)
    .\kernelfoundry_setup.ps1 uninstall (or -Uninstall) : Remove KernelFoundry .venv and workspace configs
"@ -ForegroundColor Yellow
}
