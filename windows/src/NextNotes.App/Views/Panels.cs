using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Speechify.App.Controls;
using Speechify.App.Design;

namespace Speechify.App.Views;

/// <summary>
/// Shared panel furniture — search rows, footers, cards, buttons on a dark readout.
/// </summary>
/// <remarks>
/// Every value comes from <see cref="Tokens"/>. Factoring these out is what stops the same
/// padding being typed slightly differently in three views, which is how a design system
/// erodes.
/// </remarks>
internal static class Panels
{
    /// <summary>A search field styled for a dark readout well.</summary>
    public static TextBox SearchBox(string placeholder) => new()
    {
        Watermark = placeholder,
        FontFamily = Tokens.Fonts.Grotesque,
        FontSize = Tokens.Fonts.Body,
        Foreground = Tokens.Brushes.InkOnDeck,
        Background = Brushes.Transparent,
        BorderThickness = new Thickness(0),
        Padding = new Thickness(0),
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>The row a search field sits in, with a seam beneath it.</summary>
    public static Border SearchRow(Control search, Control? trailing = null)
    {
        var row = new DockPanel();

        if (trailing is not null)
        {
            DockPanel.SetDock(trailing, Dock.Right);
            row.Children.Add(trailing);
        }

        row.Children.Add(search);

        return new Border
        {
            Background = Tokens.Brushes.Deck,
            Padding = new Thickness(Tokens.Space.Base, Tokens.Space.Snug),
            BorderBrush = new SolidColorBrush(Tokens.Colors.Seam),
            BorderThickness = new Thickness(0, 0, 0, Tokens.Border.Seam),
            Child = row,
        };
    }

    /// <summary>A footer strip with a count on the left and an action on the right.</summary>
    public static Border Footer(Control leading, Control trailing)
    {
        var row = new DockPanel();
        DockPanel.SetDock(trailing, Dock.Right);
        row.Children.Add(trailing);
        row.Children.Add(leading);

        return new Border
        {
            Background = Tokens.Brushes.Deck,
            Padding = new Thickness(Tokens.Space.Base, Tokens.Space.Snug),
            BorderBrush = new SolidColorBrush(Tokens.Colors.Seam),
            BorderThickness = new Thickness(0, Tokens.Border.Seam, 0, 0),
            Child = row,
        };
    }

    /// <summary>A small outlined button for use on a dark readout.</summary>
    public static Button DeckButton(string label) => new()
    {
        Content = label,
        FontFamily = Tokens.Fonts.Grotesque,
        FontSize = Tokens.Fonts.Silkscreen,
        FontWeight = FontWeight.Medium,
        Foreground = new SolidColorBrush(Tokens.Colors.InkOnDeck, 0.65),
        Background = Brushes.Transparent,
        BorderBrush = new SolidColorBrush(Tokens.Colors.InkOnDeck, 0.3),
        BorderThickness = new Thickness(Tokens.Border.Hairline),
        CornerRadius = new CornerRadius(Tokens.Radius.Chip),
        Padding = new Thickness(Tokens.Space.Snug, Tokens.Space.Hair),
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>One row of content, on the dark readout surface.</summary>
    public static Border DeckCard(Control content) => new()
    {
        Background = Tokens.Brushes.Deck,
        CornerRadius = new CornerRadius(Tokens.Radius.Panel),
        BorderBrush = new SolidColorBrush(Tokens.Colors.Seam),
        BorderThickness = new Thickness(Tokens.Border.Hairline),
        Padding = new Thickness(Tokens.Space.Base),
        Child = content,
    };

    /// <summary>Centred "nothing here yet" copy.</summary>
    public static Control EmptyState(string label, string detail) => new StackPanel
    {
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Center,
        Spacing = Tokens.Space.Snug,
        Margin = new Thickness(0, Tokens.Space.Panel),
        Children =
        {
            new Silkscreen
            {
                Text = label,
                IsLarge = true,
                Foreground = new SolidColorBrush(Tokens.Colors.InkOnDeck, 0.55),
                HorizontalAlignment = HorizontalAlignment.Center,
            },
            new TextBlock
            {
                Text = detail,
                FontFamily = Tokens.Fonts.Grotesque,
                FontSize = Tokens.Fonts.Label,
                Foreground = new SolidColorBrush(Tokens.Colors.InkOnDeck, 0.4),
                HorizontalAlignment = HorizontalAlignment.Center,
            },
        },
    };

    /// <summary>
    /// Docks a control and returns it, so it reads inline in a Children list.
    /// </summary>
    /// <remarks>Not named <c>Dock</c>: that shadows the <see cref="Avalonia.Controls.Dock"/>
    /// enum at every call site.</remarks>
    public static Control Docked(Control control, Dock side)
    {
        DockPanel.SetDock(control, side);
        return control;
    }

    /// <summary>A silkscreen label above a control, the way a panel is printed.</summary>
    public static StackPanel Labelled(string label, Control content) => new()
    {
        Spacing = Tokens.Space.Tight,
        Children = { new Silkscreen { Text = label }, content },
    };
}
