# Embedded UI fonts

Opal embeds the regular and bold faces of Noto Sans so DVUI renders the same
hinted typeface on every desktop instead of falling back to Bitstream Vera.

The files were sourced from Arch Linux's `noto-fonts` package
(`1:2026.08.01-1`) and are distributed under Apache-2.0; see
`LICENSE-NOTO.txt`.

- `NotoSans-Regular.ttf`: `478c558ea716033cd60c03438f628dfa75694dcf6b5f6d505a2f05fd2b4f3823`
- `NotoSans-Bold.ttf`: `1df075a380fc7cb898acf64c1f7b3b4dd780de3caa860178bf929de35817a913`

Media titles containing Han, kana, or Hangul use `NotoSansKR-Regular.ttf`
from the pinned DVUI dependency (`dvui 0.5.0-dev`), with its original bytes.
This face includes Japanese, Chinese, and Korean glyphs; it does not promise
coverage for arbitrary Unicode. Other titles retain the regular UI font.
It is distributed under SIL OFL 1.1; see `LICENSE-NOTO-CJK.txt`.

- `NotoSansKR-Regular.ttf`: `9db318b65ee9c575a43e7efd273dbdd1afef26e467eea3e1073a50e1a6595f6d`

## Monospace (embedded terminal)

The agent terminal draws with Hack (regular, bold, italic, bold italic), taken
unchanged from the pinned DVUI dependency's `fonts/hack`. Hack is licensed
under the MIT license with the Bitstream Vera terms; see `LICENSE-HACK.txt`.
It covers the box-drawing and block characters terminal programs draw with.

- `Hack-Bold.ttf`: `5bbf531eff7f8a0c2559c9a0656718e2828a012a9b1f60b5f54006d59a4de8d4`
- `Hack-BoldItalic.ttf`: `64f74a079700b7dfe128551a1e28875d5ba980971e55f5e0f0596e37bdc6a6bc`
- `Hack-Italic.ttf`: `096fb67a2b85f3c866e9cb3e965b27c2c10b977315f4d3d7f095674be35091c1`
- `Hack-Regular.ttf`: `15f55cc0c85a2988d2b4b3a8cdb5d77fdfbaf319e1bb5309d725db9818fb7125`
