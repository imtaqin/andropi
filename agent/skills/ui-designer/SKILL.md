---
name: ui-designer
description: Design distinctive, modern interfaces - visual direction, type, color, layout, motion and polish for web pages, app screens, dashboards and components. Use when the user asks for a design, a redesign, "make it look good/modern/premium", a landing page, or UI that should not look generic.
---

# UI designer

Aim for work that looks intentionally designed, not templated. Decide a
direction first, then execute it consistently.

## 1. Pick a direction (say it in one line before building)

Choose one and commit: *editorial* (big serif display, generous whitespace),
*technical* (mono accents, grids, hairlines - Vercel/Linear), *soft/tactile*
(rounded, pastel, layered shadows), *bold/brutal* (heavy type, flat color
blocks), *luxury* (dark, restrained, fine lines, one metallic accent),
*playful* (saturated palette, motion, illustration). Match it to the product
and audience. Avoid the default "white card, blue button, Inter" look unless
asked.

## 2. Type

- Two families max: a display face with character plus a clean text face
  (Google Fonts: Geist, Inter Tight, Manrope, Space Grotesk, Instrument Serif,
  Fraunces, DM Serif Display, JetBrains Mono).
- A real scale (e.g. 12/14/16/20/28/40/56), tight tracking on large headings
  (-0.02em to -0.04em), line-height 1.1-1.2 for display, 1.5-1.65 for body.
- Limit line length to ~60-75 characters.

## 3. Color

- Build from neutrals (zinc/stone/slate) plus **one** accent; a second only
  for status. Define CSS variables: `--bg --surface --raised --border --text
  --muted --accent`.
- Dark mode is not inverted light mode: raise surfaces with lighter greys,
  lower contrast of borders, keep text off pure white (#fafafa).
- Gradients: subtle, two close hues, used for one hero element or CTA.
- Check contrast (text 4.5:1, large text 3:1).

## 4. Layout and spacing

- 4/8 px spacing scale; group with space before lines.
- Mobile first, one column, 16-20 px gutters, 44 px touch targets; then widen
  with a max width (~1100-1200 px) and a 12-column feel on desktop.
- Clear hierarchy per screen: one primary action, obvious secondary ones.
- Radius system (e.g. 8 inputs, 12 cards, 999 pills) used consistently.

## 5. Depth and detail

- Prefer 1 px borders and soft, large, low-opacity shadows over heavy drop
  shadows. Frosted glass (`backdrop-filter: blur`) only for floating bars.
- Icons from one family (Lucide, Phosphor, Tabler via CDN), 1.5-2 px stroke,
  sized to the text they sit with. Use real brand logos (Simple Icons) for
  brands.
- Empty, loading (skeletons) and error states are part of the design.

## 6. Motion

- 150-250 ms, ease-out for entering, ease-in for leaving. Animate opacity and
  transform, not layout. Respect `prefers-reduced-motion`.
- One signature moment (hero reveal, hover lift, number count-up) beats
  animating everything.

## 7. Before you finish

Review your own output as a picky designer: alignment, consistent radii and
spacing, no orphaned words in headings, real-looking content instead of lorem
ipsum, dark and light both good, nothing overflowing at 360 px wide. In
AndroPI, write the page to a file so the user can tap Preview.
