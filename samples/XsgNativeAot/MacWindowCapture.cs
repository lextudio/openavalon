using System.Runtime.InteropServices;

namespace XsgAot;

/// <summary>
/// Saves this process's own on-screen window as a PNG, on macOS. A process may capture its own windows without the Screen Recording
/// permission (another process, including screencapture, may not), and neither DevFlow's screenshot nor WPF's RenderTargetBitmap works
/// here (both need the Windows-only wpfgfx). Plain P/Invoke into system frameworks, so it runs the same under NativeAOT.
/// </summary>
internal static class MacWindowCapture
{
    private const string CoreGraphics = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics";
    private const string CoreFoundation = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation";
    private const string ImageIO = "/System/Library/Frameworks/ImageIO.framework/ImageIO";
    private const uint Utf8 = 0x08000100;

    [StructLayout(LayoutKind.Sequential)]
    private struct CGRect { public double X, Y, Width, Height; }

    [DllImport(CoreGraphics)] private static extern IntPtr CGWindowListCopyWindowInfo(uint option, uint relativeToWindow);
    [DllImport(CoreGraphics)] private static extern IntPtr CGWindowListCreateImage(CGRect bounds, uint listOption, uint windowId, uint imageOption);
    [DllImport(CoreGraphics)] private static extern nuint CGImageGetWidth(IntPtr image);
    [DllImport(CoreGraphics)] private static extern nuint CGImageGetHeight(IntPtr image);
    [DllImport(CoreFoundation)] private static extern nint CFArrayGetCount(IntPtr array);
    [DllImport(CoreFoundation)] private static extern IntPtr CFArrayGetValueAtIndex(IntPtr array, nint index);
    [DllImport(CoreFoundation)] private static extern IntPtr CFDictionaryGetValue(IntPtr dictionary, IntPtr key);
    [DllImport(CoreFoundation)] private static extern IntPtr CFStringCreateWithCString(IntPtr allocator, [MarshalAs(UnmanagedType.LPUTF8Str)] string text, uint encoding);
    [DllImport(CoreFoundation)] private static extern byte CFNumberGetValue(IntPtr number, int type, out long value);
    [DllImport(CoreFoundation)] private static extern byte CFStringGetCString(IntPtr text, byte[] buffer, nint size, uint encoding);
    [DllImport(CoreFoundation)] private static extern IntPtr CFURLCreateWithFileSystemPath(IntPtr allocator, IntPtr path, nint style, byte isDirectory);
    [DllImport(CoreFoundation)] private static extern void CFRelease(IntPtr value);
    [DllImport(ImageIO)] private static extern IntPtr CGImageDestinationCreateWithURL(IntPtr url, IntPtr type, nuint count, IntPtr options);
    [DllImport(ImageIO)] private static extern void CGImageDestinationAddImage(IntPtr destination, IntPtr image, IntPtr properties);
    [DllImport(ImageIO)] private static extern byte CGImageDestinationFinalize(IntPtr destination);

    private static long? Number(IntPtr dictionary, string key)
    {
        var cfKey = CFStringCreateWithCString(IntPtr.Zero, key, Utf8);
        try
        {
            var value = CFDictionaryGetValue(dictionary, cfKey);
            return value != IntPtr.Zero && CFNumberGetValue(value, 4, out var number) != 0 ? number : null;
        }
        finally { CFRelease(cfKey); }
    }

    private static string? Text(IntPtr dictionary, string key)
    {
        var cfKey = CFStringCreateWithCString(IntPtr.Zero, key, Utf8);
        try
        {
            var value = CFDictionaryGetValue(dictionary, cfKey);
            var buffer = new byte[512];
            return value != IntPtr.Zero && CFStringGetCString(value, buffer, buffer.Length, Utf8) != 0
                ? System.Text.Encoding.UTF8.GetString(buffer, 0, Array.IndexOf(buffer, (byte)0))
                : null;
        }
        finally { CFRelease(cfKey); }
    }

    /// <summary>
    /// The window number of this process's window titled <paramref name="title"/>. The process has a dozen helper windows (the renderer's
    /// surfaces), so "the first window on screen" is not the one to capture.
    /// </summary>
    private static uint? OwnWindow(string title)
    {
        var windows = CGWindowListCopyWindowInfo(0, 0);
        try
        {
            for (nint i = 0; i < CFArrayGetCount(windows); i++)
            {
                var info = CFArrayGetValueAtIndex(windows, i);
                if (Number(info, "kCGWindowOwnerPID") == Environment.ProcessId && Number(info, "kCGWindowIsOnscreen") == 1
                    && Number(info, "kCGWindowLayer") == 0 && Text(info, "kCGWindowName") == title)
                {
                    return (uint?)Number(info, "kCGWindowNumber");
                }
            }
            return null;
        }
        finally { CFRelease(windows); }
    }

    /// <summary>Saves this process's window titled <paramref name="title"/> to <paramref name="path"/>; returns "WxH" or the reason it could not.</summary>
    public static string Save(string path, string title)
    {
        if (!OperatingSystem.IsMacOS()) return "not macOS";
        if (OwnWindow(title) is not { } window) return $"no on-screen window titled '{title}' in this process";
        var image = CGWindowListCreateImage(new CGRect { X = double.PositiveInfinity, Y = double.PositiveInfinity }, 1 << 3, window, 1 << 0);
        if (image == IntPtr.Zero) return "CGWindowListCreateImage returned no image";
        var cfPath = CFStringCreateWithCString(IntPtr.Zero, path, Utf8);
        var url = CFURLCreateWithFileSystemPath(IntPtr.Zero, cfPath, 0, 0);
        var type = CFStringCreateWithCString(IntPtr.Zero, "public.png", Utf8);
        var destination = CGImageDestinationCreateWithURL(url, type, 1, IntPtr.Zero);
        CGImageDestinationAddImage(destination, image, IntPtr.Zero);
        var saved = CGImageDestinationFinalize(destination) != 0;
        return saved ? $"{CGImageGetWidth(image)}x{CGImageGetHeight(image)}" : "could not write the PNG";
    }
}
