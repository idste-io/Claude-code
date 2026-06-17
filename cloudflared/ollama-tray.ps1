# Ollama + Cloudflare Tunnel Tray Manager v2.1
# Tails Ollama's server.log (API calls, tokens) + cloudflared streams
# Compile to EXE: Invoke-PS2EXE -InputFile ollama-tray.ps1 -OutputFile ollama-tray.exe -NoConsole -STA

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── C# helpers — no PowerShell closures, works in compiled EXE ────────────────
if (-not ([System.Management.Automation.PSTypeName]'OllamaLogger').Type) {
    Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Collections;
using System.Threading;
using System.Diagnostics;

public static class OllamaLogger {
    // Tail a file from current end — for Ollama server.log
    public static void TailFile(object state) {
        var args   = (object[])state;
        var path   = (string)args[0];
        var prefix = (string)args[1];
        var log    = (ArrayList)args[2];
        try {
            while (!File.Exists(path))
                Thread.Sleep(500);
            using (var fs = new FileStream(path,
                FileMode.Open, FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete))
            {
                fs.Seek(0, SeekOrigin.End);
                var reader = new StreamReader(fs);
                while (true) {
                    var line = reader.ReadLine();
                    if (line != null) {
                        if (line.Length > 0)
                            lock (log.SyncRoot) {
                                log.Add("[" + prefix + "] " + line);
                                if (log.Count > 2000) log.RemoveAt(0);
                            }
                    } else {
                        Thread.Sleep(1000);
                    }
                }
            }
        } catch {}
    }

    // Read a process stream — for cloudflared
    public static void ReadStream(object state) {
        var args   = (object[])state;
        var reader = (StreamReader)args[0];
        var prefix = (string)args[1];
        var log    = (ArrayList)args[2];
        try {
            string line;
            while ((line = reader.ReadLine()) != null)
                if (line.Length > 0)
                    lock (log.SyncRoot) {
                        log.Add("[" + prefix + "] " + line);
                        if (log.Count > 2000) log.RemoveAt(0);
                    }
        } catch {}
    }

    public static Thread StartTail(string path, string prefix, ArrayList log) {
        var t = new Thread(new ParameterizedThreadStart(TailFile));
        t.IsBackground = true;
        t.Start(new object[] { path, prefix, log });
        return t;
    }

    public static Thread StartStream(StreamReader reader, string prefix, ArrayList log) {
        var t = new Thread(new ParameterizedThreadStart(ReadStream));
        t.IsBackground = true;
        t.Start(new object[] { reader, prefix, log });
        return t;
    }

    // Kill all processes with a given exact name (never kills the tray itself)
    public static void KillAllByName(string name) {
        int selfId = Process.GetCurrentProcess().Id;
        foreach (var p in Process.GetProcessesByName(name)) {
            try { if (p.Id != selfId && !p.HasExited) p.Kill(); } catch {}
        }
    }

    // Kill all processes whose name starts with a prefix (catches llama-server-cuda_v13 etc.)
    // Excludes the current process so the tray never kills itself (ollama-tray starts with "ollama")
    public static void KillAllByPrefix(string prefix) {
        int selfId = Process.GetCurrentProcess().Id;
        foreach (var p in Process.GetProcesses()) {
            try {
                if (p.Id != selfId &&
                    p.ProcessName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
                    if (!p.HasExited) p.Kill();
            } catch {}
        }
    }

    public static bool IsRunning(string name) {
        return Process.GetProcessesByName(name).Length > 0;
    }

    public static bool IsAnyRunningByPrefix(string prefix) {
        foreach (var p in Process.GetProcesses()) {
            try {
                if (p.ProcessName.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)
                    && !p.HasExited) return true;
            } catch {}
        }
        return false;
    }
}
"@
}

# ── Env vars Ollama needs ──────────────────────────────────────────────────────
$env:OLLAMA_ORIGINS        = "*"
$env:OLLAMA_HOST           = "0.0.0.0:11434"
$env:OLLAMA_FLASH_ATTENTION = "0"    # disable — MMA Flash Attention kernel crashes on RTX 5060 Ti with Ollama 0.30.8
$env:OLLAMA_NUM_PARALLEL    = "1"    # one request at a time — avoids OOM crashes on large models

# ── Paths ──────────────────────────────────────────────────────────────────────
$cloudflaredExe = "C:\Program Files (x86)\cloudflared\cloudflared.exe"
$cloudflaredCfg = "C:\Users\aidan\.cloudflared\config.yml"
$ollamaExe      = "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe"
$ollamaLog      = "$env:LOCALAPPDATA\Ollama\server.log"
if (-not (Test-Path $ollamaExe)) { $ollamaExe = "ollama" }

# ── Thread-safe log buffer ─────────────────────────────────────────────────────
$script:logLines     = [System.Collections.ArrayList]::Synchronized([System.Collections.ArrayList]::new())
$script:logForm      = $null
$script:logLastIndex = 0
$script:tailThread   = $null

function Add-Log {
    param([string]$prefix, [string]$line)
    if ([string]::IsNullOrEmpty($line)) { return }
    $script:logLines.Add("[$prefix] $line") | Out-Null
    if ($script:logLines.Count -gt 2000) { $script:logLines.RemoveAt(0) }
}

# ── Process launch ─────────────────────────────────────────────────────────────
$script:ollamaProc = $null
$script:cfProc     = $null

function Start-Ollama {
    if (-not [OllamaLogger]::IsRunning("ollama")) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = $ollamaExe
        $psi.Arguments = "serve"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        $psi.EnvironmentVariables["OLLAMA_ORIGINS"]         = "*"
        $psi.EnvironmentVariables["OLLAMA_HOST"]            = "0.0.0.0:11434"
        $psi.EnvironmentVariables["OLLAMA_FLASH_ATTENTION"] = "0"
        $psi.EnvironmentVariables["OLLAMA_NUM_PARALLEL"]    = "1"
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $p.Start() | Out-Null
        $script:ollamaProc = $p
        Start-Sleep -Seconds 2
    }
    # Always (re)start the log tail so new server.log is picked up
    $script:tailThread = [OllamaLogger]::StartTail($ollamaLog, "ollama", $script:logLines)
}

function Start-Tunnel {
    if ([OllamaLogger]::IsRunning("cloudflared")) { return }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $cloudflaredExe
    $psi.Arguments              = "tunnel --config `"$cloudflaredCfg`" run"
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $true

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $p.Start() | Out-Null

    [OllamaLogger]::StartStream($p.StandardOutput, "cloudflared", $script:logLines) | Out-Null
    [OllamaLogger]::StartStream($p.StandardError,  "cloudflared", $script:logLines) | Out-Null

    $script:cfProc = $p
}

function Stop-All {
    # Try tracked process objects first
    if ($script:ollamaProc -ne $null) {
        try { if (-not $script:ollamaProc.HasExited) { $script:ollamaProc.Kill() } } catch {}
    }
    if ($script:cfProc -ne $null) {
        try { if (-not $script:cfProc.HasExited) { $script:cfProc.Kill() } } catch {}
    }
    # Kill all by name/prefix — catches llama-server, llama-server-cuda_v13, etc.
    [OllamaLogger]::KillAllByPrefix("llama-server")
    [OllamaLogger]::KillAllByPrefix("ollama")
    [OllamaLogger]::KillAllByName("cloudflared")
    $script:ollamaProc = $null
    $script:cfProc     = $null
}

# ── Start both ────────────────────────────────────────────────────────────────
Add-Log "tray" "Starting Ollama..."
Start-Ollama
Add-Log "tray" "Starting cloudflared tunnel..."
Start-Tunnel
Add-Log "tray" "Ready - ollamav2.invoxio.work"
Add-Log "tray" "Tailing $ollamaLog"

# ── Drain timer: push buffered lines into the open log window ─────────────────
$drainTimer          = New-Object System.Windows.Forms.Timer
$drainTimer.Interval = 3000
$drainTimer.Add_Tick({
    $count = $script:logLines.Count
    if ($count -gt $script:logLastIndex -and $script:logForm -and $script:logForm.Visible) {
        $tb       = $script:logForm.Tag
        $newLines = $script:logLines.GetRange($script:logLastIndex, $count - $script:logLastIndex)
        foreach ($line in $newLines) {
            if ($line -match "error|ERR|fatal|FATAL|failed|panic" ) {
                $tb.SelectionColor = [System.Drawing.Color]::OrangeRed
            } elseif ($line -match "^\[ollama\]") {
                if ($line -match "print_timing|prompt eval|eval time|total time|t/s") {
                    $tb.SelectionColor = [System.Drawing.Color]::Yellow
                } elseif ($line -match "\[GIN\]") {
                    $tb.SelectionColor = [System.Drawing.Color]::LightGoldenrodYellow
                } else {
                    $tb.SelectionColor = [System.Drawing.Color]::LightCyan
                }
            } elseif ($line -match "^\[cloudflared\]") {
                $tb.SelectionColor = [System.Drawing.Color]::LightGreen
            } else {
                $tb.SelectionColor = [System.Drawing.Color]::Gray
            }
            $tb.AppendText($line + "`n")
        }
        $tb.ScrollToCaret()
        $script:logLastIndex = $count
    }
})
$drainTimer.Start()

# ── Watchdog: auto-restart Ollama or cloudflared if they crash ────────────────
$watchdogTimer          = New-Object System.Windows.Forms.Timer
$watchdogTimer.Interval = 30000
$watchdogTimer.Add_Tick({
    $ollamaOk = [OllamaLogger]::IsRunning("ollama")
    $cfOk     = [OllamaLogger]::IsRunning("cloudflared")

    if (-not $ollamaOk) {
        Add-Log "watchdog" "Ollama not running — killing llama-server children and restarting..."
        [OllamaLogger]::KillAllByPrefix("llama-server")
        [OllamaLogger]::KillAllByPrefix("ollama")
        $script:ollamaProc = $null
        Start-Sleep -Seconds 2
        Start-Ollama
        $tray.ShowBalloonTip(3000, "Ollama Tunnel", "Ollama crashed — auto-restarted", [System.Windows.Forms.ToolTipIcon]::Warning)
    }
    if (-not $cfOk) {
        Add-Log "watchdog" "cloudflared not running — auto-restarting..."
        [OllamaLogger]::KillAllByName("cloudflared")
        $script:cfProc = $null
        Start-Sleep -Seconds 1
        Start-Tunnel
        $tray.ShowBalloonTip(3000, "Ollama Tunnel", "Tunnel crashed — auto-restarted", [System.Windows.Forms.ToolTipIcon]::Warning)
    }

    $ollamaStatus = if ([OllamaLogger]::IsRunning("ollama")) { "running" } else { "down" }
    $cfStatus     = if ([OllamaLogger]::IsRunning("cloudflared")) { "running" } else { "down" }
    $tray.Text    = "Ollama: $ollamaStatus | Tunnel: $cfStatus"
    if ($script:statusItem) { $script:statusItem.Text = "Ollama: $ollamaStatus | Tunnel: $cfStatus" }
})
$watchdogTimer.Start()

# ── Tray icon ─────────────────────────────────────────────────────────────────
$tray         = New-Object System.Windows.Forms.NotifyIcon
$tray.Text    = "Ollama Tunnel"
$tray.Visible = $true

$bmp = New-Object System.Drawing.Bitmap 16, 16
$g   = [System.Drawing.Graphics]::FromImage($bmp)
$g.FillEllipse([System.Drawing.Brushes]::DodgerBlue, 1, 1, 13, 13)
$g.Dispose()
$tray.Icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())

# ── Context menu ──────────────────────────────────────────────────────────────
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$itemStatus         = $menu.Items.Add("Ollama Tunnel - running")
$itemStatus.Enabled = $false
$script:statusItem  = $itemStatus

$menu.Items.Add("-") | Out-Null

# Watch Logs
$itemWatchLogs = $menu.Items.Add("Watch Logs")
$itemWatchLogs.Add_Click({
    if ($script:logForm -and $script:logForm.Visible) {
        $script:logForm.BringToFront(); return
    }

    $f = New-Object System.Windows.Forms.Form
    $f.Text            = "Ollama + Cloudflared - Live Logs"
    $f.Size            = New-Object System.Drawing.Size(900, 500)
    $f.StartPosition   = "CenterScreen"
    $f.BackColor       = [System.Drawing.Color]::FromArgb(12, 12, 12)
    $f.FormBorderStyle = "Sizable"

    $tb             = New-Object System.Windows.Forms.RichTextBox
    $tb.Dock        = "Fill"
    $tb.BackColor   = [System.Drawing.Color]::FromArgb(10, 10, 10)
    $tb.ForeColor   = [System.Drawing.Color]::White
    $tb.Font        = New-Object System.Drawing.Font("Consolas", 9)
    $tb.ReadOnly    = $true
    $tb.ScrollBars  = "Vertical"
    $tb.WordWrap    = $false
    $f.Controls.Add($tb)
    $f.Tag = $tb

    $script:logLastIndex = 0
    foreach ($line in $script:logLines) {
        if ($line -match "error|ERR|fatal|FATAL|failed|panic") {
            $tb.SelectionColor = [System.Drawing.Color]::OrangeRed
        } elseif ($line -match "^\[ollama\]") {
            if ($line -match "print_timing|prompt eval|eval time|total time|t/s") {
                $tb.SelectionColor = [System.Drawing.Color]::Yellow
            } elseif ($line -match "\[GIN\]") {
                $tb.SelectionColor = [System.Drawing.Color]::LightGoldenrodYellow
            } else {
                $tb.SelectionColor = [System.Drawing.Color]::LightCyan
            }
        } elseif ($line -match "^\[cloudflared\]") {
            $tb.SelectionColor = [System.Drawing.Color]::LightGreen
        } else {
            $tb.SelectionColor = [System.Drawing.Color]::Gray
        }
        $tb.AppendText($line + "`n")
    }
    $script:logLastIndex = $script:logLines.Count
    $tb.ScrollToCaret()

    $f.Add_FormClosing({ $script:logForm = $null })
    $script:logForm = $f
    $f.Show()
})

$menu.Items.Add("-") | Out-Null

# Restart Tunnel
$itemRestart = $menu.Items.Add("Restart Tunnel")
$itemRestart.Add_Click({
    Add-Log "tray" "Restarting tunnel..."
    [OllamaLogger]::KillAllByName("cloudflared")
    $script:cfProc = $null
    Start-Sleep -Seconds 2
    Start-Tunnel
    $tray.ShowBalloonTip(2000, "Ollama Tunnel", "Tunnel restarted", [System.Windows.Forms.ToolTipIcon]::Info)
})

# Restart Ollama (kills llama-server children too, then restarts clean)
$itemRestartOllama = $menu.Items.Add("Restart Ollama")
$itemRestartOllama.Add_Click({
    Add-Log "tray" "Restarting Ollama (killing all llama processes)..."
    [OllamaLogger]::KillAllByPrefix("llama-server")
    [OllamaLogger]::KillAllByPrefix("ollama")
    $script:ollamaProc = $null
    Start-Sleep -Seconds 3
    Start-Ollama
    $tray.ShowBalloonTip(2000, "Ollama Tunnel", "Ollama restarted", [System.Windows.Forms.ToolTipIcon]::Info)
})

$menu.Items.Add("-") | Out-Null

# Exit
$itemExit = $menu.Items.Add("Exit (stops Ollama + Tunnel)")
$itemExit.Add_Click({
    $drainTimer.Stop()
    $watchdogTimer.Stop()
    Add-Log "tray" "Stopping all services..."
    Stop-All
    $tray.Visible = $false
    $tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$tray.ContextMenuStrip = $menu
$tray.ShowBalloonTip(3000, "Ollama Tunnel", "Ollama + cloudflared running`nollamav2.invoxio.work", [System.Windows.Forms.ToolTipIcon]::Info)

# ── Message loop ──────────────────────────────────────────────────────────────
[System.Windows.Forms.Application]::Run()
