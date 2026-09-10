using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Media;
using Avalonia.Threading;
using NextNotes.App.Design;

namespace NextNotes.App.Controls;

/// <summary>
/// A brushed-metal panel.
/// </summary>
/// <remarks>
/// The grain is drawn, not an image: it stays sharp at any scale, follows the silver/black
/// face automatically, and adds nothing to the download.
/// </remarks>
public sealed class BrushedPanel : Decorator
{
    /// <summary>Corner radius of the panel.</summary>
    public static readonly StyledProperty<double> CornerRadiusProperty =
        AvaloniaProperty.Register<BrushedPanel, double>(nameof(CornerRadius), Tokens.Radius.Panel);

    /// <inheritdoc cref="CornerRadiusProperty"/>
    public double CornerRadius
    {
        get => GetValue(CornerRadiusProperty);
        set => SetValue(CornerRadiusProperty, value);
    }

    static BrushedPanel() => AffectsRender<BrushedPanel>(CornerRadiusProperty);

    /// <inheritdoc />
    public override void Render(DrawingContext context)
    {
        var bounds = new Rect(Bounds.Size);
        if (bounds.Width <= 0 || bounds.Height <= 0) return;

        var shape = new RoundedRect(bounds, CornerRadius);
        context.DrawRectangle(Tokens.Brushes.Panel, null, shape);

        using (context.PushClip(bounds))
        {
            // Fine horizontal striations — the direction a rolled aluminium sheet is brushed.
            var light = new SolidColorBrush(Avalonia.Media.Colors.White, Tokens.Material.GrainLight);
            var dark = new SolidColorBrush(Avalonia.Media.Colors.Black, Tokens.Material.GrainDark);
            var alternate = false;

            for (var y = 0.0; y < bounds.Height; y += Tokens.Material.GrainPitch)
            {
                context.FillRectangle(
                    alternate ? dark : light,
                    new Rect(0, y, bounds.Width, Tokens.Material.GrainPitch / 2));
                alternate = !alternate;
            }
        }

        // Top bevel catches the light; the whole edge carries a seam.
        var bevel = new Pen(new SolidColorBrush(Tokens.Colors.PanelHighlight, 0.5), Tokens.Border.Bevel);
        context.DrawLine(bevel, bounds.TopLeft, bounds.TopRight);

        var seam = new Pen(new SolidColorBrush(Tokens.Colors.Seam, 0.35), Tokens.Border.Seam);
        context.DrawRectangle(null, seam, shape);
    }
}

/// <summary>
/// A silkscreened panel label: small, uppercase, tightly tracked.
/// </summary>
/// <remarks>
/// The uppercasing happens here rather than at the call site so a label can never be
/// half-styled — the look depends on all three of size, tracking and case.
/// </remarks>
public sealed class Silkscreen : TextBlock
{
    /// <summary>Uses the larger silkscreen size.</summary>
    public static readonly StyledProperty<bool> IsLargeProperty =
        AvaloniaProperty.Register<Silkscreen, bool>(nameof(IsLarge));

    /// <inheritdoc cref="IsLargeProperty"/>
    public bool IsLarge
    {
        get => GetValue(IsLargeProperty);
        set => SetValue(IsLargeProperty, value);
    }

    /// <summary>Creates an empty label.</summary>
    public Silkscreen()
    {
        FontFamily = Tokens.Fonts.Grotesque;
        FontSize = Tokens.Fonts.Silkscreen;
        FontWeight = FontWeight.Medium;
        LetterSpacing = Tokens.Fonts.SilkscreenTracking;
        Foreground = Tokens.Brushes.Silkscreen;
    }

    /// <inheritdoc />
    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);

        if (change.Property == TextProperty && Text is { } text)
        {
            var upper = text.ToUpperInvariant();
            if (!string.Equals(text, upper, StringComparison.Ordinal)) Text = upper;
        }
        else if (change.Property == IsLargeProperty)
        {
            FontSize = IsLarge ? Tokens.Fonts.SilkscreenLarge : Tokens.Fonts.Silkscreen;
        }
    }
}

/// <summary>
/// An indicator lamp behind a lens.
/// </summary>
/// <remarks>
/// A lit lamp gets a specular dot, not a bloom. The brief rules out glow, and real lamps read
/// as lit because of the highlight on the lens rather than light spilling past it.
/// </remarks>
public sealed class Lamp : Control
{
    /// <summary>Whether the lamp is lit.</summary>
    public static readonly StyledProperty<bool> IsLitProperty =
        AvaloniaProperty.Register<Lamp, bool>(nameof(IsLit));

    /// <summary>The lamp's colour when lit.</summary>
    public static readonly StyledProperty<Color> LampColorProperty =
        AvaloniaProperty.Register<Lamp, Color>(nameof(LampColor), Tokens.Colors.Record);

    /// <inheritdoc cref="IsLitProperty"/>
    public bool IsLit
    {
        get => GetValue(IsLitProperty);
        set => SetValue(IsLitProperty, value);
    }

    /// <inheritdoc cref="LampColorProperty"/>
    public Color LampColor
    {
        get => GetValue(LampColorProperty);
        set => SetValue(LampColorProperty, value);
    }

    static Lamp() => AffectsRender<Lamp>(IsLitProperty, LampColorProperty);

    /// <summary>Creates a lamp at the token size.</summary>
    public Lamp()
    {
        Width = Tokens.Material.LampSize;
        Height = Tokens.Material.LampSize;
    }

    /// <inheritdoc />
    public override void Render(DrawingContext context)
    {
        var size = Math.Min(Bounds.Width, Bounds.Height);
        if (size <= 0) return;

        var centre = new Point(Bounds.Width / 2, Bounds.Height / 2);
        var radius = size / 2;

        var lens = new SolidColorBrush(LampColor, IsLit ? 1 : Tokens.Material.LampUnlitOpacity);
        context.DrawEllipse(lens, null, centre, radius, radius);

        var rim = new Pen(new SolidColorBrush(Tokens.Colors.Seam, 0.7), Tokens.Border.Hairline);
        context.DrawEllipse(null, rim, centre, radius, radius);

        if (!IsLit) return;

        var specular = new SolidColorBrush(Avalonia.Media.Colors.White, Tokens.Material.LampSpecular);
        var dot = size * 0.15;
        context.DrawEllipse(
            specular, null,
            new Point(centre.X - (radius * 0.3), centre.Y - (radius * 0.32)),
            dot, dot);
    }
}

/// <summary>
/// A transport key: rectangular, chunky, with real travel.
/// </summary>
/// <remarks>
/// Pressed means <i>pressed</i> — the cap sinks and its bevel inverts — rather than merely
/// tinted. That distinction is most of what separates equipment from software.
/// </remarks>
public sealed class TransportKey : Button
{
    /// <summary>Whether this key is latched down.</summary>
    public static readonly StyledProperty<bool> IsEngagedProperty =
        AvaloniaProperty.Register<TransportKey, bool>(nameof(IsEngaged));

    /// <summary>Label colour when engaged.</summary>
    public static readonly StyledProperty<Color> EngagedColorProperty =
        AvaloniaProperty.Register<TransportKey, Color>(nameof(EngagedColor), Tokens.Colors.Record);

    /// <inheritdoc cref="IsEngagedProperty"/>
    public bool IsEngaged
    {
        get => GetValue(IsEngagedProperty);
        set => SetValue(IsEngagedProperty, value);
    }

    /// <inheritdoc cref="EngagedColorProperty"/>
    public Color EngagedColor
    {
        get => GetValue(EngagedColorProperty);
        set => SetValue(EngagedColorProperty, value);
    }

    static TransportKey() => AffectsRender<TransportKey>(IsEngagedProperty, IsPressedProperty);

    /// <summary>Creates a key at the token dimensions.</summary>
    public TransportKey()
    {
        MinWidth = Tokens.Material.KeyMinWidth;
        Height = Tokens.Material.KeyHeight;
        Padding = new Thickness(Tokens.Space.Base, 0);
        HorizontalContentAlignment = Avalonia.Layout.HorizontalAlignment.Center;
        VerticalContentAlignment = Avalonia.Layout.VerticalAlignment.Center;
        Background = null;
        BorderBrush = null;
        FontFamily = Tokens.Fonts.Grotesque;
        FontSize = Tokens.Fonts.Silkscreen;
        FontWeight = FontWeight.Medium;
        Foreground = Tokens.Brushes.Ink;
    }

    /// <inheritdoc />
    public override void Render(DrawingContext context)
    {
        var bounds = new Rect(Bounds.Size);
        if (bounds.Width <= 0 || bounds.Height <= 0) return;

        // The cap sinks by the travel distance while held.
        var sunk = IsPressed
            ? bounds.Translate(new Vector(0, Tokens.Material.KeyTravel))
            : bounds;
        var shape = new RoundedRect(sunk, Tokens.Radius.Control);

        context.DrawRectangle(Tokens.Brushes.Cap, null, shape);

        // Bevel: highlight on top when proud, shade on top when pressed.
        var bevelColor = IsPressed ? Tokens.Colors.PanelShade : Tokens.Colors.PanelHighlight;
        context.DrawRectangle(null, new Pen(new SolidColorBrush(bevelColor), Tokens.Border.Bevel), shape);

        var seam = new Pen(new SolidColorBrush(Tokens.Colors.Seam, 0.5), Tokens.Border.Hairline);
        context.DrawRectangle(null, seam, shape);
    }

    /// <inheritdoc />
    protected override void OnPropertyChanged(AvaloniaPropertyChangedEventArgs change)
    {
        base.OnPropertyChanged(change);

        // Foreground is updated HERE, not in Render. Assigning a property during the render
        // pass invalidates the visual mid-pass, and Avalonia throws "Visual was invalidated
        // during the render pass" rather than merely logging it. Render must be a pure
        // function of current state.
        if (change.Property == IsEngagedProperty || change.Property == EngagedColorProperty)
        {
            Foreground = new SolidColorBrush(IsEngaged ? EngagedColor : Tokens.Colors.Ink);
        }
    }
}

/// <summary>
/// A VU meter with a real needle.
/// </summary>
/// <remarks>
/// <para>
/// The needle is damped rather than driven straight from the signal. A physical VU movement
/// takes ~300 ms to reach a step and overshoots slightly before settling, and that lag is the
/// instrument's character.
/// </para>
/// <para>
/// The physics live in plain fields stepped by a timer, deliberately kept out of the property
/// system: a styled property invalidated 60 times a second would push a full layout pass each
/// frame for a value only this control's <c>Render</c> ever reads.
/// </para>
/// </remarks>
public sealed class VuMeter : Control
{
    /// <summary>Current input level, 0…1.</summary>
    public static readonly StyledProperty<double> LevelProperty =
        AvaloniaProperty.Register<VuMeter, double>(nameof(Level));

    /// <summary>Whether the meter lamp is lit.</summary>
    public static readonly StyledProperty<bool> IsActiveProperty =
        AvaloniaProperty.Register<VuMeter, bool>(nameof(IsActive));

    /// <inheritdoc cref="LevelProperty"/>
    public double Level
    {
        get => GetValue(LevelProperty);
        set => SetValue(LevelProperty, value);
    }

    /// <inheritdoc cref="IsActiveProperty"/>
    public bool IsActive
    {
        get => GetValue(IsActiveProperty);
        set => SetValue(IsActiveProperty, value);
    }

    private double _needle;
    private double _velocity;
    private DispatcherTimer? _ticker;

    static VuMeter() => AffectsRender<VuMeter>(IsActiveProperty);

    /// <inheritdoc />
    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);

        _ticker = new DispatcherTimer(DispatcherPriority.Render)
        {
            Interval = TimeSpan.FromMilliseconds(16),
        };
        _ticker.Tick += (_, _) => { AdvanceNeedle(); InvalidateVisual(); };
        _ticker.Start();
    }

    /// <inheritdoc />
    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        _ticker?.Stop();
        _ticker = null;
        base.OnDetachedFromVisualTree(e);
    }

    /// <summary>Steps the movement one frame toward the current level.</summary>
    private void AdvanceNeedle()
    {
        var target = Math.Clamp(Level, 0, 1);
        var rising = target > _needle;
        var time = rising ? Tokens.Motion.NeedleAttackSeconds : Tokens.Motion.NeedleReleaseSeconds;

        var stiffness = 1 / time;
        _velocity += (target - _needle) * stiffness * 0.16;
        _velocity *= 0.72;
        _needle = Math.Clamp(_needle + _velocity, 0, 1 + Tokens.Motion.NeedleOvershoot);
    }

    /// <inheritdoc />
    public override void Render(DrawingContext context)
    {
        var bounds = new Rect(Bounds.Size);
        if (bounds.Width <= 0 || bounds.Height <= 0) return;

        context.DrawRectangle(
            Tokens.Brushes.MeterFace, null, new RoundedRect(bounds, Tokens.Radius.Chip));

        if (IsActive)
        {
            var lamp = new SolidColorBrush(Tokens.Colors.MeterLamp, 0.14);
            context.DrawRectangle(lamp, null, new RoundedRect(bounds, Tokens.Radius.Chip));
        }

        // The pivot sits just below the face, so the needle sweeps across it like a real
        // moving-coil movement rather than rotating about its centre.
        var pivot = new Point(bounds.Width / 2, bounds.Height * 1.05);
        var radius = Math.Min(bounds.Width * 0.46, bounds.Height * 0.92);
        var sweep = Tokens.Material.NeedleSweepDegrees * Math.PI / 180;

        var scalePen = new Pen(new SolidColorBrush(Tokens.Colors.MeterNeedle), Tokens.Border.Hairline);
        var overPen = new Pen(new SolidColorBrush(Tokens.Colors.MeterRed), Tokens.Border.Hairline);

        for (var tick = 0.0; tick <= 1.0001; tick += 0.1)
        {
            var angle = -sweep / 2 + (sweep * tick);
            var major = tick % 0.2 < 0.01;
            var inner = radius * (major ? 0.78 : 0.86);

            context.DrawLine(
                tick >= Tokens.Material.MeterZeroPoint ? overPen : scalePen,
                Polar(pivot, angle, inner),
                Polar(pivot, angle, radius));
        }

        var needleAngle = -sweep / 2 + (sweep * _needle);
        var needlePen = new Pen(
            new SolidColorBrush(Tokens.Colors.MeterNeedle), Tokens.Material.NeedleWidth);
        context.DrawLine(needlePen, pivot, Polar(pivot, needleAngle, radius * 0.98));

        var frame = new Pen(new SolidColorBrush(Tokens.Colors.Seam), Tokens.Border.Hairline);
        context.DrawRectangle(null, frame, new RoundedRect(bounds, Tokens.Radius.Chip));
    }

    private static Point Polar(Point origin, double angle, double distance) =>
        new(origin.X + (Math.Sin(angle) * distance), origin.Y - (Math.Cos(angle) * distance));
}

/// <summary>A run of ventilation slots.</summary>
/// <remarks>
/// Purely decorative, and deliberately so — real equipment has vents and fasteners, and their
/// absence is one of the things that makes software look like software.
/// </remarks>
public sealed class Vents : Control
{
    /// <summary>How many slots to draw.</summary>
    public static readonly StyledProperty<int> CountProperty =
        AvaloniaProperty.Register<Vents, int>(nameof(Count), 6);

    /// <inheritdoc cref="CountProperty"/>
    public int Count
    {
        get => GetValue(CountProperty);
        set => SetValue(CountProperty, value);
    }

    static Vents() => AffectsRender<Vents>(CountProperty);

    /// <inheritdoc />
    protected override Size MeasureOverride(Size availableSize) => new(
        (Count * Tokens.Material.VentSlotWidth) + ((Count - 1) * Tokens.Material.VentSlotGap),
        Tokens.Material.VentSlotHeight);

    /// <inheritdoc />
    public override void Render(DrawingContext context)
    {
        var brush = new SolidColorBrush(Tokens.Colors.Seam, 0.5);
        var pitch = Tokens.Material.VentSlotWidth + Tokens.Material.VentSlotGap;

        for (var i = 0; i < Count; i++)
        {
            var slot = new Rect(
                i * pitch, 0,
                Tokens.Material.VentSlotWidth, Tokens.Material.VentSlotHeight);
            context.DrawRectangle(brush, null, new RoundedRect(slot, 1.5));
        }
    }
}
