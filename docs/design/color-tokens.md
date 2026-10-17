# Color Tokens

Runnir follows Fintropy's primitive-palette -> semantic-theme -> component pattern, implemented natively in Swift. The Runnir Pen palette is retained; Fintropy's product colors and web runtime are not copied.

Source of truth: Runnir/DesignSystem/Theme/RunnirTheme.swift.

- RunnirPalette owns concrete sRGB values. Only this layer defines production RGB/hex colors.
- RunnirColorToken maps each semantic role to light/dark palette entries. An exhaustive switch makes missing mappings a compile error.
- RunnirTheme exposes adaptive SwiftUI colors backed by an NSColor appearance provider. macOS appearance changes do not require a restart or a global mutable theme singleton.

| Role | Tokens |
| --- | --- |
| Surfaces | background, sidebar, surface, selected, editor |
| Text | foreground, secondaryForeground, mutedForeground |
| Buttons | primary / primaryForeground, secondary / secondaryContent |
| Feedback | success, warning, destructive, info |
| Boundaries | border, focusRing |
| YAML styling | syntaxKey, syntaxString, syntaxLiteral; comments use mutedForeground |

secondaryForeground is subdued explanatory text; secondaryContent is the foreground paired with the secondary button surface. primary is the action fill, not primary text. Use foreground for primary text. Status colors are foregrounds on the app background, not backgrounds with an assumed white label.

```swift
Text("Workflow").foregroundStyle(RunnirTheme.foreground)
Label("Succeeded", systemImage: "checkmark.circle")
    .foregroundStyle(RunnirTheme.success)
```

Components must use semantic roles, not palette shade names or direct Color RGB values. Transparent fills and native system materials/controls may remain native; do not replace system interaction/focus behavior with decorative token use. New status treatments need a corresponding foreground/background pair and contrast check, not arbitrary opacity.

Tokens follow system appearance. A manual theme selector, user-defined themes and automatic Pen-variable synchronization are not implemented. Add tokens only for actual distinct roles, not unused full color scales.

RunnirTheme.swift includes named Light and Dark color-catalog previews. They render every semantic role without loading repositories, credentials or Core. The catalog is debug-only and is not included in release builds.

Tests cover all mappings in both appearances, the retained Pen values, button foreground polarity and normal enabled body/button/status contrast. Decorative muted metadata, disabled opacity, focus rings and native materials are not claimed to meet the same body-text contrast threshold.
