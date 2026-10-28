# Provider marks

Artwork for the built-in provider presets. Each mark identifies its provider in
Veyra; the marks are not Veyra branding, and they do not imply endorsement.

Supplied by the project owner on 2026-10-28. The single-color files were collected
from a third-party icon set; the trademarks belong to their owners. Confirm usage
terms with each provider before any public distribution.

| File | Provider | Preset | Filled with | SHA-256 |
| --- | --- | --- | --- | --- |
| `deepseek-color.svg` | DeepSeek | `deepseek` | `#4D6BFE` | `deba5f98a5c1796e20fcac3149bcd7eb8a32f0bdd04d048819400b1f28bd1439` |
| `kimi-color.svg` | Kimi (Moonshot AI) | `kimi` | `currentColor` + `#1783FF` accent | `0bdb95375d7c6e90a1850e91cd36770da2bc98fa33ec2d783f4a8fed027da85f` |
| `zai.svg` | Z.ai / GLM | `glm` | `currentColor` | `e748cb5108ce37b116d7a5ba97d37e0ae97eadf6849b0de11afb248e244a01e1` |
| `minimax-color.svg` | MiniMax | `minimax` | `#E2167E` → `#FE603C` gradient | `7f7187fa6d9b341ac5f22f6c5a970523afb439dc45566d64eb4f4b9b604d6b01` |
| `xiaomi-mi-512.png` | Xiaomi | `mimo` | orange `#FF6900` tile, white mark | `049f96e52ea00ec87f4deb362cf38f9ce01c2547d1d345d9dbbede8849d429ba` |

`xiaomi-mi-512.png` is the 512 px icon published by Xiaomi for its PWA manifest
(`i01.appmifile.com/webfile/globalimg/logo/pwa-mi/512x512.png`, linked from
[mi.com/global](https://www.mi.com/global/), downloaded 2026-10-28). The supplied
two-line "Xiaomi MiMo" lockup was unreadable in a 16–24 pt slot and is replaced
by this tile. It keeps its own color, so it renders as a color image rather than
a template.

`currentColor` resolves to black when the SVG is rendered outside a web page, so
the PNG keeps black artwork on transparency. `ProviderMark.isTemplate` marks the
single-color images as AppKit templates; they follow the system light and dark
appearance. DeepSeek and MiniMax keep their own colors in both appearances.

Regenerate the bundled PNGs from the repository root:

```sh
swift scripts/prepare_brand.swift
```

The script writes `Veyra/Resources/<Name>Provider.png` at 512 pt and trims only
transparent margins. No runtime image download occurs.
