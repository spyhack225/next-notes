using Avalonia;
using Avalonia.Media;
using Avalonia.Styling;

namespace Speechify.App.Design;

/// <summary>
/// The design system, in one place.
/// </summary>
/// <remarks>
/// <para>
/// A direct port of <c>DesignSystem.swift</c> — same names, same values, so the two platforms
/// stay recognisably one product. Direction: 1980s portable field recorders and cassette
/// decks. Equipment, not theme.
/// </para>
/// <para>
/// <b>Views must not contain literal values.</b> If a control needs a number that isn't here,
/// add the token rather than inlining it.
/// </para>
/// <para>Two rules that are not negotiable:</para>
/// <list type="bullet">
/// <item><b>Red means recording.</b> Nothing else in the app is red.</item>
/// <item><b>Amber and green are instrumentation only</b> — level meters, never UI chrome.</item>
/// </list>
/// <para>
/// Explicitly ruled out: neon, vaporwave, synthwave, purple/pink gradients, glowing text,
/// chrome lettering, grid horizons. There are <b>no gradients anywhere</b>; depth comes from
/// flat panels, hairline bevels and procedurally-drawn brushed grain.
/// </para>
/// </remarks>
public static class Tokens
{
    /// <summary>
    /// Whether the black-face palette is in use.
    /// </summary>
    /// <remarks>
    /// Decks shipped in two finishes, so the app does too: <b>silver face</b> (brushed
    /// aluminium, the Sony TC-D5) in light, <b>black face</b> (matte, the Marantz PMD) in dark.
    /// </remarks>
    public static bool IsBlackFace =>
        Application.Current?.ActualThemeVariant == ThemeVariant.Dark;

    // ---- Colour ----

    /// <summary>Surfaces, from the outer body inward.</summary>
    public static class Colors
    {
        /// <summary>The outer body of the unit. Darkest surface; frames everything.</summary>
        public static Color Chassis => Face(0x2A2825, 0x121110);

        /// <summary>The main working surface.</summary>
        public static Color Panel => Face(0xB8B4AD, 0x2E2C29);

        /// <summary>Top bevel highlight on a raised element.</summary>
        public static Color PanelHighlight => Face(0xC9C5BE, 0x3C3936);

        /// <summary>Bottom bevel shade on a raised element.</summary>
        public static Color PanelShade => Face(0x9E9A93, 0x211F1D);

        /// <summary>Recessed wells, set into the panel.</summary>
        public static Color Well => Face(0x6E6A64, 0x1A1917);

        /// <summary>The dark readout window of a tape deck.</summary>
        public static Color Deck => Face(0x38352F, 0x151412);

        /// <summary>Button caps and other moulded plastic.</summary>
        public static Color Cap => Face(0xE8E3D8, 0x35322E);

        /// <summary>The hard line where two panels meet.</summary>
        public static Color Seam => Face(0x6B6862, 0x000000);

        /// <summary>Primary readable text.</summary>
        public static Color Ink => Face(0x1C1A17, 0xE4DED0);

        /// <summary>Supporting text.</summary>
        public static Color InkSecondary => Face(0x514D47, 0x9A948A);

        /// <summary>Silkscreened labels printed onto the panel.</summary>
        public static Color Silkscreen => Face(0x3A3630, 0xB0AA9E);

        /// <summary>Text on a dark readout well, regardless of face.</summary>
        public static Color InkOnDeck => Rgb(0xD8D2C4);

        /// <summary>The record lamp. Lacquered, not fluorescent. The only red in the app.</summary>
        public static Color Record => Rgb(0xC8342A);

        /// <summary>The record lamp unlit — a dark lens, not an absence.</summary>
        public static Color RecordIdle => Face(0x7A4A45, 0x4A2724);

        /// <summary>A selected row. The panel lifts rather than tints.</summary>
        public static Color Selection => Face(0xCDC8C0, 0x3A3733);

        /// <summary>Edge on a selected or focused element.</summary>
        public static Color SelectionEdge => Face(0x8A857D, 0x585349);

        /// <summary>Keyboard focus ring. Reads without relying on colour.</summary>
        public static Color FocusRing => Face(0x6B665E, 0x726C61);

        /// <summary>Row under the pointer, before selection.</summary>
        public static Color Hover => Face(0xC2BDB6, 0x343130);

        // Instrumentation only. Never use these for UI chrome.

        /// <summary>Classic cream VU face.</summary>
        public static Color MeterFace => Rgb(0xD8CFB4);

        /// <summary>The amber lamp behind a VU face.</summary>
        public static Color MeterLamp => Rgb(0xE8B860);

        /// <summary>Needle and scale printing.</summary>
        public static Color MeterNeedle => Rgb(0x1C1A17);

        /// <summary>Nominal level.</summary>
        public static Color MeterGreen => Rgb(0x6F9E45);

        /// <summary>Approaching peak.</summary>
        public static Color MeterAmber => Rgb(0xD39A2E);

        /// <summary>Over.</summary>
        public static Color MeterRed => Rgb(0xC0392B);

        private static Color Rgb(uint hex) => Color.FromRgb(
            (byte)((hex >> 16) & 0xFF), (byte)((hex >> 8) & 0xFF), (byte)(hex & 0xFF));

        private static Color Face(uint light, uint dark) => Rgb(IsBlackFace ? dark : light);
    }

    /// <summary>Brushes for the colours above, allocated per call.</summary>
    public static class Brushes
    {
        /// <inheritdoc cref="Colors.Chassis"/>
        public static IBrush Chassis => new SolidColorBrush(Colors.Chassis);

        /// <inheritdoc cref="Colors.Panel"/>
        public static IBrush Panel => new SolidColorBrush(Colors.Panel);

        /// <inheritdoc cref="Colors.Well"/>
        public static IBrush Well => new SolidColorBrush(Colors.Well);

        /// <inheritdoc cref="Colors.Deck"/>
        public static IBrush Deck => new SolidColorBrush(Colors.Deck);

        /// <inheritdoc cref="Colors.Cap"/>
        public static IBrush Cap => new SolidColorBrush(Colors.Cap);

        /// <inheritdoc cref="Colors.Ink"/>
        public static IBrush Ink => new SolidColorBrush(Colors.Ink);

        /// <inheritdoc cref="Colors.Silkscreen"/>
        public static IBrush Silkscreen => new SolidColorBrush(Colors.Silkscreen);

        /// <inheritdoc cref="Colors.InkOnDeck"/>
        public static IBrush InkOnDeck => new SolidColorBrush(Colors.InkOnDeck);

        /// <inheritdoc cref="Colors.Record"/>
        public static IBrush Record => new SolidColorBrush(Colors.Record);

        /// <inheritdoc cref="Colors.MeterFace"/>
        public static IBrush MeterFace => new SolidColorBrush(Colors.MeterFace);
    }

    // ---- Type ----

    /// <summary>
    /// A neutral grotesque, the way equipment was labelled.
    /// </summary>
    /// <remarks>
    /// Helvetica on macOS, Arial on Windows — the closest widely-installed grotesques. A
    /// humanist UI font has rounded terminals that fight the silkscreen look.
    /// </remarks>
    public static class Fonts
    {
        /// <summary>The panel typeface.</summary>
        public static FontFamily Grotesque { get; } =
            new("Helvetica Neue, Helvetica, Arial, sans-serif");

        /// <summary>Readouts and timings. Monospaced so digits don't shift as they tick.</summary>
        public static FontFamily Mono { get; } =
            new("Consolas, Menlo, SF Mono, monospace");

        /// <summary>Panel labels: small, uppercase, tightly tracked.</summary>
        public const double Silkscreen = 9;

        /// <summary>A larger silkscreen label, for section headers.</summary>
        public const double SilkscreenLarge = 11;

        /// <summary>Caption text.</summary>
        public const double Caption = 10;

        /// <summary>Secondary label text.</summary>
        public const double Label = 11;

        /// <summary>Body text.</summary>
        public const double Body = 13;

        /// <summary>Section titles.</summary>
        public const double Title = 17;

        /// <summary>The big transport counter.</summary>
        public const double CounterLarge = 26;

        /// <summary>Letter spacing for silkscreen labels, in device-independent pixels.</summary>
        public const double SilkscreenTracking = 1.1;
    }

    // ---- Geometry ----

    /// <summary>A 4pt grid. Panels are laid out on it; nothing sits between steps.</summary>
    public static class Space
    {
        /// <summary>2</summary>
        public const double Hair = 2;

        /// <summary>4</summary>
        public const double Tight = 4;

        /// <summary>8</summary>
        public const double Snug = 8;

        /// <summary>12</summary>
        public const double Base = 12;

        /// <summary>16</summary>
        public const double Roomy = 16;

        /// <summary>24</summary>
        public const double Wide = 24;

        /// <summary>32</summary>
        public const double Panel = 32;
    }

    /// <summary>
    /// Small by design. Equipment has hard edges; anything soft reads as software.
    /// </summary>
    public static class Radius
    {
        /// <summary>Seams and dividers — square.</summary>
        public const double None = 0;

        /// <summary>Indicator chips, small lamps.</summary>
        public const double Chip = 2;

        /// <summary>Button caps and controls.</summary>
        public const double Control = 3;

        /// <summary>Recessed wells and grouped panels.</summary>
        public const double Panel = 5;

        /// <summary>The window itself.</summary>
        public const double Window = 8;
    }

    /// <summary>Line weights. All 1 — a machined edge reads the same at any density.</summary>
    public static class Border
    {
        /// <summary>A drawn hairline.</summary>
        public const double Hairline = 1;

        /// <summary>The seam between two panels.</summary>
        public const double Seam = 1;

        /// <summary>Bevel thickness on raised controls.</summary>
        public const double Bevel = 1;
    }

    // ---- Material ----

    /// <summary>
    /// The physical detail that makes a panel read as a machined object: metal grain,
    /// fasteners, ventilation, lamps, key travel, needle sweep.
    /// </summary>
    public static class Material
    {
        /// <summary>Opacity of the lighter striations in brushed metal.</summary>
        public const double GrainLight = 0.055;

        /// <summary>Opacity of the darker striations.</summary>
        public const double GrainDark = 0.07;

        /// <summary>Distance between striations.</summary>
        public const double GrainPitch = 2;

        /// <summary>Diameter of a panel screw head.</summary>
        public const double ScrewSize = 9;

        /// <summary>A single vent slot.</summary>
        public const double VentSlotWidth = 3;

        /// <summary>Height of a vent slot.</summary>
        public const double VentSlotHeight = 22;

        /// <summary>Gap between vent slots.</summary>
        public const double VentSlotGap = 4;

        /// <summary>Indicator lamp diameter.</summary>
        public const double LampSize = 7;

        /// <summary>A lit lamp's lens highlight — a specular dot, not a bloom.</summary>
        public const double LampSpecular = 0.45;

        /// <summary>How far an unlit lamp sits below the lit value.</summary>
        public const double LampUnlitOpacity = 0.22;

        /// <summary>Transport key height.</summary>
        public const double KeyHeight = 34;

        /// <summary>Minimum transport key width.</summary>
        public const double KeyMinWidth = 52;

        /// <summary>How far a key sinks when pressed.</summary>
        public const double KeyTravel = 1.5;

        /// <summary>Total sweep of the VU needle, in degrees, centred on vertical.</summary>
        public const double NeedleSweepDegrees = 96;

        /// <summary>Needle thickness.</summary>
        public const double NeedleWidth = 1.5;

        /// <summary>Where 0 VU sits along the scale, 0…1. The red zone begins here.</summary>
        public const double MeterZeroPoint = 0.72;
    }

    // ---- Motion ----

    /// <summary>Mechanical, not bouncy. A key travels and stops; it doesn't spring.</summary>
    public static class Motion
    {
        /// <summary>Key travel down. Fast enough to feel like contact.</summary>
        public static TimeSpan Press { get; } = TimeSpan.FromMilliseconds(60);

        /// <summary>Key travel up.</summary>
        public static TimeSpan Release { get; } = TimeSpan.FromMilliseconds(120);

        /// <summary>Panel and view changes.</summary>
        public static TimeSpan Panel { get; } = TimeSpan.FromMilliseconds(180);

        /// <summary>The record lamp coming on — instant, like a filament.</summary>
        public static TimeSpan Lamp { get; } = TimeSpan.FromMilliseconds(80);

        /// <summary>
        /// VU ballistics: seconds to reach a step going up.
        /// </summary>
        /// <remarks>
        /// A real VU movement reaches 99% of a step in ~300 ms and overshoots slightly. That
        /// lag <i>is</i> the instrument's character — a needle that tracks the signal exactly
        /// reads as a progress bar with a stick on it.
        /// </remarks>
        public const double NeedleAttackSeconds = 0.30;

        /// <summary>Seconds for the needle to fall back.</summary>
        public const double NeedleReleaseSeconds = 0.42;

        /// <summary>Peak overshoot as a fraction of the step, before settling.</summary>
        public const double NeedleOvershoot = 0.06;
    }
}
