# PDFSquish Design System

Established: February 26, 2026

---

## Typography Scale (5 sizes)

| Token     | Spec                                                      | Usage                              |
|-----------|-----------------------------------------------------------|-------------------------------------|
| display   | `.system(size: 20, weight: .bold, design: .rounded)`      | Savings percentage (hero element)   |
| title     | `.system(size: 15, weight: .semibold, design: .rounded)`  | App name, file sizes                |
| body      | `.system(size: 13, weight: .medium)`                      | Button labels, descriptions, errors |
| caption   | `.system(size: 11, weight: .medium)`                      | Metadata labels, status, method     |
| mono      | `.system(size: 11, weight: .medium, design: .monospaced)` | Technical details (engine, brew)    |

---

## Color Roles

| Role       | Value              | Usage                                |
|------------|--------------------|--------------------------------------|
| success    | `Color.green`      | Savings badge only                   |
| warning    | `Color.orange`     | Engine status (qpdf missing)         |
| error      | `Color.red`        | Error states                         |
| accent     | `Color.accentColor`| Primary buttons, active drop zone    |
| primary    | `.primary`         | Headings, file sizes, filenames      |
| secondary  | `.secondary`       | Body text, icons, status             |
| tertiary   | `.tertiary`        | Labels ("Original"/"Compressed"), hints |

**Rule:** One color, one meaning. Orange = informational warning only. Red = error only. Green = savings badge only.

---

## Spacing

| Token            | Value | Usage                        |
|------------------|-------|------------------------------|
| window-padding-h | 24    | Horizontal window inset      |
| window-padding-v | 24    | Bottom window inset          |
| card-padding     | 16    | Internal card padding        |
| stack-gap        | 12    | Main VStack spacing          |
| tight-gap        | 4     | Label-to-value pairs         |

---

## Radii

| Token | Value | Usage                                        |
|-------|-------|----------------------------------------------|
| card  | 14    | Drop zone, result card, error card           |
| pill  | 100   | Capsule shapes (engine pill, savings badge)  |

**Rule:** Two radii only. Every card-level container uses 14. Every pill/badge uses capsule.

---

## Icon Weights

| Tier         | Weight     | Usage                                |
|--------------|------------|--------------------------------------|
| decorative   | `.light`   | Title icon, drop zone icon, arrows   |
| interactive  | `.regular` | Button icons, status icons           |

---

## Materials

| Token      | Value                    | Usage                |
|------------|--------------------------|----------------------|
| window     | `.hudWindow` behindWindow| Window background    |
| card       | `.ultraThinMaterial`     | All card backgrounds |
| badge-fill | `[color].opacity(0.1)`  | Badge backgrounds    |

---

## Drop Zone Border

| State   | Border                                      | Fill                               |
|---------|---------------------------------------------|-------------------------------------|
| idle    | `secondary.opacity(0.5)`, dash `[10, 5]`, 1.5pt | `secondary.opacity(0.02)`      |
| hover   | `accentColor`, dash `[10, 5]`, 1.5pt        | `accentColor.opacity(0.05)`        |

---

## States Reference

| State       | Drop Zone         | Result Card | Button           |
|-------------|-------------------|-------------|------------------|
| idle        | Full height, icon | Hidden      | "Choose PDF"     |
| compressing | Full height, spinner (pulsing) | Hidden | Disabled  |
| done        | 80pt, filename + "Drop to replace" | Dominant, savings hero | "Choose PDF" |
| error       | Full height, icon | Hidden (error card shown) | "Choose PDF" |

---

## Animations

| Trigger       | Animation                                                |
|---------------|----------------------------------------------------------|
| State change  | `.spring(response: 0.4, dampingFraction: 0.8)`          |
| Drag hover    | `.easeInOut(duration: 0.15)`                             |
| Pulse (compressing) | `.easeInOut(duration: 1.0).repeatForever(autoreverses: true)` |
| Error dismiss | Auto-dismiss after 4 seconds                            |
