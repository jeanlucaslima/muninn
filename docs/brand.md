# Muninn — Brand

Companion to `docs/designs/muninn-v2.md` (§4.17). A separate track (D24); it doesn't block engineering gates.


Muninn has **two ravens**, one per medium:

| Raven | Medium | Source |
|---|---|---|
| **Scratched raven** | the **app icon** and the **menu bar icon**, plus artwork derived from them (first run, *About*, empty state) | original scratchboard illustration, `design/brand/` |
| **ASCII raven** | the **terminal** only | `muninn.md` (kept as is); a compact variant for `muninn --version` / `muninn help` on a TTY, worked on separately |

## The scratched raven

- **Style:** scratchboard. Light strokes are scratched out of a dark ground, so the raven appears as if cut into ink. The strokes are rough and hand-made but intentional, never noisy.
- **Recognizable before it's detailed.** The silhouette alone (head, beak, folded wing) must read as a raven. Scratches add character on top and never carry the shape.
- **Original artwork,** drawn for Muninn and not traced from existing raven logos or illustrations.

## App icon

- **The full illustration:** the raven scratched into an ink-black ground, with bone-white strokes and at most one `ember` accent (the eye).
- **Built as layers** (ink ground, raven body, scratch strokes, eye) in Icon Composer's `.icon` format. macOS then renders the **default, dark, tinted and clear** appearances from one source, instead of us hand-making each variant. *(confirm the format and appearances with the Xcode 27.2 toolchain in gate C)*
- **Tested at every size it ships:** 1024 down to 16 px. Below ~64 px, fine scratches are dropped from the export and only the major strokes remain. That's a separate hand-tuned small-size layer, not a downscale.

## Menu bar icon

The hardest constraint: about **18×18 pt** (36×36 px @2x), monochrome, rendered by the system as a **template image** so it follows light/dark menu bars and highlight states automatically.

- **The same raven, reduced.** A solid raven silhouette with **2–3 scratch cuts** as negative space (one across the wing, one at the neck, the eye as a cut). The cuts are what make it *the scratched raven* and not a generic bird, so they're drawn on the pixel grid at @1x and @2x and never scaled down from the app icon.
- **States through pose, not color** (template images are single-color). This makes the icon a status light for the helper:

  | State | Menu bar raven |
  |---|---|
  | Recording | standing, eye cut open |
  | Paused | head tucked, no eye |
  | Clipboard access not granted (§4.16) | turned away |
  | Needs attention: flood pause, limits hit, approval waiting | wings slightly raised |

  Four states, deliberately. More poses wouldn't be distinguishable at 18 pt. Every state has an accessibility label and a matching line in the menu, so the icon never carries meaning alone.
- **Acceptance:** recognizable on a crowded menu bar, in light and dark, on a 1× external display and a 2× Retina display, and in the highlighted (clicked) state.

## Palette (initial)

| Token | Use | Dark | Light |
|---|---|---|---|
| `ink` | icon ground; illustration lines in light mode | warm near-black | warm near-black |
| `bone` | scratches; illustration ground in light mode | warm off-white | warm off-white |
| `ember` | the only accent: the eye in the app icon, attention states, protected badge | muted amber | deeper amber |

The app UI otherwise uses native controls, SF Pro and SF Mono, and system semantic colors, so it respects Increase Contrast and the user's accent color. The character lives in the two icons, not in custom widgets. The raven never appears in the panel's result rows.

## Assets

- `design/brand/`: vector sources for the app icon layers, the menu bar icon (all 4 states, @1x and @2x pixel-fit), and the derived first-run, *About* and empty-state artwork.
- `App/`: the `.icon` app icon and the menu bar template images.
- `docs/` or CLI resources: the terminal ASCII raven variants.

