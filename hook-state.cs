// Fast hook helper for claude-caps-blink. Compiled locally by install.ps1 via
// the .NET Framework csc.exe (no downloads); starts in ~50ms vs ~1-2s for a
// powershell.exe cold start. Mirrors hook-state.ps1 exactly:
//   hook-state.exe -State working|attention|done|end [-Launch]
// Reads Claude Code hook JSON on stdin (only session_id is used).

using System;
using System.Diagnostics;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;

static class HookState
{
    static int Main(string[] args)
    {
        try
        {
            string state = null;
            bool launch = false;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i] == "-State" && i + 1 < args.Length) state = args[++i];
                else if (args[i] == "-Launch") launch = true;
            }
            if (state == null) return 1;

            string baseDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "claude-caps-blink");
            string flagDir = Path.Combine(baseDir, "flags");
            Directory.CreateDirectory(flagDir);

            string sid = "unknown";
            string input = Console.In.ReadToEnd();
            Match m = Regex.Match(input, "\"session_id\"\\s*:\\s*\"([^\"]+)\"");
            if (m.Success) sid = m.Groups[1].Value;
            foreach (char c in Path.GetInvalidFileNameChars()) sid = sid.Replace(c, '_');
            string file = Path.Combine(flagDir, sid + ".flag");

            switch (state)
            {
                case "end":
                    if (File.Exists(file)) File.Delete(file);
                    break;
                case "done":
                    File.WriteAllText(file, "done");
                    break;
                case "attention":
                    File.WriteAllText(file, "attention");
                    break;
                case "working":
                    // Without -Launch (PostToolUse) only update an existing flag, so a
                    // late async hook cannot resurrect a finished session.
                    if (launch) File.WriteAllText(file, "working");
                    else if (File.Exists(file) && File.ReadAllText(file).Trim() != "done")
                        File.WriteAllText(file, "working");
                    break;
                default:
                    return 1;
            }

            if (launch)
            {
                foreach (string f in Directory.GetFiles(flagDir, "*.flag"))
                    if (File.GetLastWriteTime(f) < DateTime.Now.AddHours(-2)) File.Delete(f);

                if (!File.Exists(Path.Combine(baseDir, "disabled")) && !BlinkerRunning())
                    StartBlinker();
            }
            return 0;
        }
        catch
        {
            return 0; // never block Claude Code on a status-light failure
        }
    }

    static bool BlinkerRunning()
    {
        try { Mutex.OpenExisting("ClaudeCapsBlinker").Dispose(); return true; }
        catch (UnauthorizedAccessException) { return true; } // elevated instance
        catch { return false; }
    }

    static void StartBlinker()
    {
        // Prefer the scheduled task: it runs the blinker elevated (LED mode)
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe", "/Run /TN ClaudeCapsBlink");
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            Process p = Process.Start(psi);
            if (p.WaitForExit(5000) && p.ExitCode == 0) return;
        }
        catch { }
        try
        {
            string blinker = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "blinker.ps1");
            ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + blinker + "\"");
            psi.CreateNoWindow = true;
            psi.UseShellExecute = false;
            Process.Start(psi);
        }
        catch { }
    }
}
