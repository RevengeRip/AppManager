# Translating AppManager

## How to Contribute Translations

1. **Edit an existing translation**: Find the relevant `.po` file for your language and submit a PR with your improvements.
2. **Add a new language**: Use `app-manager.pot` as a template, save it as `po/xx.po` (where `xx` is your language code), translate the strings, and create a PR.

## Translation Status

| Language | Code | Status |
| -------- | ---- | ------ |
| German | de | 74% |
| Spanish | es | 77% |
| Estonian | et | 78% |
| Finnish | fi | 77% |
| French | fr | 75% |
| Italian | it | 77% |
| Japanese | ja | 77% |
| Lithuanian | lt | 77% |
| Latvian | lv | 77% |
| Norwegian Bokmål | nb | 77% |
| Dutch | nl | 100% |
| Portuguese (Brazil) | pt_BR | 77% |
| Swedish | sv | 76% |
| Chinese (Simplified) | zh_CN | 80% |

## Note

> Some translations are machine-generated and may contain mistakes. Native speakers are welcome to review and improve them!

## Testing Translations Locally

After building with meson, translations are compiled automatically. To test:

```bash
meson setup build --prefix=$HOME/.local
meson compile -C build
meson install -C build
```

Then run the app with a specific locale:

```bash
LANGUAGE=de app-manager
```

## Further Reading

- [GNU gettext Manual](https://www.gnu.org/software/gettext/manual/gettext.html)
- [Vala i18n documentation](https://wiki.gnome.org/Projects/Vala/TranslationSample)
