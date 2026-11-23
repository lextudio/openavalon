using System.Windows;

namespace XsgAot;

/// <summary>
/// A plain WPF entry point. Run with <c>check</c> to verify, once the first frame is rendered, what the NativeAOT prototype claims
/// (see SelfCheck) and exit with 0/1. XSGAOT_TRACE=1 prints each distinct first-chance exception: under NativeAOT a swallowed
/// "No metadata found" or "No parameterless constructor" is usually the first sign of a trimmed reflection path.
/// </summary>
public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (Environment.GetEnvironmentVariable("XSGAOT_TRACE") == "1")
        {
            var seen = new HashSet<string>();
            AppDomain.CurrentDomain.FirstChanceException += (_, e) =>
            {
                var key = e.Exception.GetType().Name + ": " + e.Exception.Message;
                if (seen.Add(key))
                {
                    Console.WriteLine("first-chance " + key);
                }
            };
        }

        var app = new Application();
        var window = new MainWindow();
        if (args.Contains("check"))
        {
            window.ContentRendered += (_, _) => window.Dispatcher.BeginInvoke(() =>
            {
                if (Environment.GetEnvironmentVariable("XSGAOT_CAPTURE") is { Length: > 0 } capturePath)
                {
                    // Let the GPU present a few frames, then save this process's own window.
                    var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
                    timer.Tick += (_, _) =>
                    {
                        timer.Stop();
                        Console.WriteLine("capture=" + MacWindowCapture.Save(capturePath, window.Title));
                        app.Shutdown();
                    };
                    timer.Start();
                    return;
                }

                try
                {
                    SelfCheck.Run(window);
                }
                catch (Exception ex)
                {
                    Console.WriteLine("self-check failed: " + ex);
                    Environment.ExitCode = 1;
                }
                app.Shutdown(Environment.ExitCode);
            }, System.Windows.Threading.DispatcherPriority.ApplicationIdle);
        }

        return app.Run(window);
    }
}
