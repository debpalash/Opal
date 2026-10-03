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
