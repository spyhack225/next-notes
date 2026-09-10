using System.Runtime.InteropServices;
using Speechify.Abstractions;

namespace Speechify.Platform.Windows;

/// <summary>Keys that work as a push-to-talk trigger.</summary>
public enum PushToTalkKey
{
    /// <summary>
    /// Right Ctrl — <b>the default, and the right one.</b>
    /// </summary>
    /// <remarks>
    /// Right Ctrl produces no character on any keyboard layout, so holding it is always safe.
    /// </remarks>
    RightControl = 0xA3,

    /// <summary>Right Shift.</summary>
    RightShift = 0xA1,

    /// <summary>
    /// Right Alt — <b>avoid unless you know the user's layout.</b>
    /// </summary>
    /// <remarks>
    /// On German, Polish, UK, Nordic and most Latin-American layouts this key is AltGr: it is
    /// how those users type <c>@</c>, <c>€</c>, <c>\</c>, <c>|</c> and <c>~</c>. Windows also
    /// synthesises a phantom Left Ctrl around it. It is the natural port of the macOS build's
    /// Right Option, and it is the wrong choice here.
    /// </remarks>
    RightAlt = 0xA5,

    /// <summary>Caps Lock.</summary>
    CapsLock = 0x14,

    /// <summary>F13 — present on many full-size and gaming keyboards, bound to nothing.</summary>
    F13 = 0x7C,
}

/// <summary>
/// Detects press <i>and</i> release of a single held key, globally.
/// </summary>
/// <remarks>
/// <para>
/// <b>Why not <c>RegisterHotKey</c>:</b> it has no key-up notification at all — the API
/// delivers exactly one <c>WM_HOTKEY</c> on press — and its modifier masks are qualifiers
/// rather than triggers, with no left/right distinction. Neither limitation can be worked
/// around. It is the right API for "Ctrl+Shift+D toggles something" and the wrong one for
/// hold-to-talk.
/// </para>
/// <para>
/// <b>Why a dedicated thread:</b> Microsoft's guidance is explicit — low-level hooks should
/// run on their own thread that hands work off and returns immediately. If the hook procedure
/// exceeds <c>LowLevelHooksTimeout</c> (capped at 1000 ms since Windows 10 1709) the system
/// <b>silently removes the hook, with no way for the application to know</b>. A hook on the
/// UI thread dies the first time the app does a slow layout pass.
/// </para>
/// <para>
/// <b>Why the key is never swallowed:</b> the macOS build consumes Right Option because on
/// macOS that key types characters. Here, suppression buys nothing and risks something much
/// worse — if the key-down is swallowed but the key-up escapes (the hook timed out
/// mid-gesture, or focus crossed into an elevated window), the target application believes
/// the modifier is held down forever.
/// </para>
/// </remarks>
public sealed class PushToTalkHook : IHotkeySource
{
    private const int WH_KEYBOARD_LL = 13;
    private const int HC_ACTION = 0;

    private const int WM_KEYDOWN = 0x0100;
    private const int WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104;
    private const int WM_SYSKEYUP = 0x0105;
    private const uint WM_QUIT = 0x0012;

    private const uint LLKHF_EXTENDED = 0x01;

    private const int VK_SHIFT = 0x10;
    private const int VK_CONTROL = 0x11;
    private const int VK_MENU = 0x12;
    private const int VK_LSHIFT = 0xA0;
    private const int VK_RSHIFT = 0xA1;
    private const int VK_LCONTROL = 0xA2;
    private const int VK_RCONTROL = 0xA3;
    private const int VK_LMENU = 0xA4;
    private const int VK_RMENU = 0xA5;

    private const int ScanCodeRightShift = 0x36;

    /// <summary>
    /// Stamped into <c>dwExtraInfo</c> on every event this app injects, so our own Ctrl+V
    /// paste cannot re-enter this hook and re-trigger dictation.
    /// </summary>
    public static readonly IntPtr InjectedTag = unchecked((IntPtr)0x4D524D52); // 'MRMR'

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint VirtualKey;
        public uint ScanCode;
        public uint Flags;
        public uint Time;
        public IntPtr ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr Window;
        public uint Message;
        public IntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public int X;
        public int Y;
    }

    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", EntryPoint = "SetWindowsHookExW", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc callback, IntPtr module, uint threadId);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hook);

    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", EntryPoint = "GetModuleHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? name);

    [DllImport("user32.dll", EntryPoint = "GetMessageW")]
    private static extern int GetMessage(out MSG message, IntPtr window, uint filterMin, uint filterMax);

    [DllImport("user32.dll", EntryPoint = "PostThreadMessageW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostThreadMessage(uint threadId, uint message, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    /// <summary>
    /// Roots the delegate for the lifetime of the hook.
    /// </summary>
    /// <remarks>
    /// Microsoft: "you must ensure the callback is not moved around by the garbage collector,
    /// otherwise your app will crash with an ExecutionEngineException." A local variable here
    /// produces a crash minutes or hours later, at random, with no useful stack.
    /// </remarks>
    private static HookProc? s_callback;

    private static PushToTalkHook? s_instance;

    private IntPtr _hook;
    private Thread? _thread;
    private uint _threadId;
    private volatile bool _isDown;

    /// <summary>Which key triggers dictation.</summary>
    public PushToTalkKey Key { get; set; } = PushToTalkKey.RightControl;

    /// <inheritdoc />
    public event EventHandler? Pressed;

    /// <inheritdoc />
    public event EventHandler? Released;

    /// <inheritdoc />
    public bool Start()
    {
        StopListening();
        s_instance = this;

        using var ready = new ManualResetEventSlim(false);
        var installed = false;

        _thread = new Thread(() =>
        {
            _threadId = GetCurrentThreadId();
            s_callback = StaticCallback;

            // Pass the running module's handle. IntPtr.Zero is documented as possibly
            // failing when threadId is 0, which is exactly the global case.
            _hook = SetWindowsHookEx(WH_KEYBOARD_LL, s_callback, GetModuleHandle(null), 0);
            installed = _hook != IntPtr.Zero;

            // ReSharper disable once AccessToDisposedClosure
            ready.Set();
            if (!installed) return;

            // Required. The system delivers hook callbacks by *sending a message* to this
            // thread, so without a pump the hook is installed but never invoked.
            while (GetMessage(out var message, IntPtr.Zero, 0, 0) > 0)
            {
                // No TranslateMessage/DispatchMessage: this thread owns no windows, and the
                // only message it cares about is the WM_QUIT that ends the loop.
            }

            if (_hook != IntPtr.Zero)
            {
                UnhookWindowsHookEx(_hook);
                _hook = IntPtr.Zero;
            }
        })
        {
            IsBackground = true,
            Name = "Speechify push-to-talk hook",
            // Stay ahead of the 1000 ms timeout that silently removes the hook.
            Priority = ThreadPriority.AboveNormal,
        };

        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        ready.Wait(TimeSpan.FromSeconds(3));

        return installed;
    }

    /// <inheritdoc />
    public void StopListening()
    {
        if (_thread is null) return;

        if (_threadId != 0) PostThreadMessage(_threadId, WM_QUIT, IntPtr.Zero, IntPtr.Zero);
        _thread.Join(TimeSpan.FromSeconds(2));

        _thread = null;
        _threadId = 0;
        _isDown = false;

        if (ReferenceEquals(s_instance, this))
        {
            s_instance = null;
            s_callback = null;
        }
    }

    /// <summary>Static, per Microsoft's guidance. Keep the body short.</summary>
    private static IntPtr StaticCallback(int code, IntPtr wParam, IntPtr lParam)
    {
        var self = s_instance;
        if (code != HC_ACTION || self is null) return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);

        try
        {
            self.Handle(wParam, lParam);
        }
        catch (Exception)
        {
            // An exception escaping into the hook chain would take the process down from a
            // thread with no useful context. Swallow and keep the chain intact.
        }

        // Always chain. Microsoft: otherwise "other applications that have installed
        // WH_KEYBOARD_LL hooks will not receive hook notifications and may behave
        // incorrectly as a result."
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    private void Handle(IntPtr wParam, IntPtr lParam)
    {
        var e = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);

        // Ignore anything this app injected itself.
        if (e.ExtraInfo == InjectedTag) return;

        // ToInt32 rather than a cast: since .NET 7 an explicit (int)IntPtr conversion
        // silently truncates instead of throwing, which CA2020 flags. Window messages are
        // always small, so the checked conversion is free and states the intent.
        var message = wParam.ToInt32();
        var isDown = message is WM_KEYDOWN or WM_SYSKEYDOWN;
        var isUp = message is WM_KEYUP or WM_SYSKEYUP;
        if (!isDown && !isUp) return;

        if (Normalize(e) != (int)Key) return;

        if (isDown)
        {
            // The OS re-fires key-down while a key is held; only the first is a press.
            if (_isDown) return;
            _isDown = true;
            Pressed?.Invoke(this, EventArgs.Empty);
        }
        else
        {
            if (!_isDown) return;
            _isDown = false;
            Released?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Collapses the side-agnostic <c>VK_SHIFT</c>/<c>VK_CONTROL</c>/<c>VK_MENU</c> codes into
    /// left/right-specific ones.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Physical keys normally arrive already specific, but input injected by another app via
    /// <c>keybd_event</c> or <c>SendInput</c> often uses the neutral form. AutoHotkey — the
    /// most battle-tested low-level keyboard hook in existence — translates defensively for
    /// exactly this reason, and so does this.
    /// </para>
    /// <para>
    /// Right Shift is the awkward one: Microsoft's keyboard-input documentation states it is
    /// <i>not</i> an extended key and is identified by scan code <c>0x36</c>, while
    /// AutoHotkey's source insists it must be treated as extended "or there will be problems".
    /// Both signals are accepted here.
    /// </para>
    /// </remarks>
    private static int Normalize(in KBDLLHOOKSTRUCT e)
    {
        var key = (int)e.VirtualKey;
        var scan = (int)(e.ScanCode & 0xFF);
        var extended = (e.Flags & LLKHF_EXTENDED) != 0;

        return key switch
        {
            VK_CONTROL => extended ? VK_RCONTROL : VK_LCONTROL,
            VK_MENU => extended ? VK_RMENU : VK_LMENU,
            VK_SHIFT => scan == ScanCodeRightShift || extended ? VK_RSHIFT : VK_LSHIFT,
            _ => key,
        };
    }

    /// <inheritdoc />
    public void Dispose() => StopListening();
}
