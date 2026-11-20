# 📚 Documentation

English and Japanese app guides use matching filenames in separate catalogs:

- `en.lproj/VQMetrix.docc`
- `ja.lproj/VQMetrix.docc`

The `.lproj` directories organize language sources. DocC does not automatically choose
between them: `Scripts/build_swift_documentation.rb` selects each catalog and compiles
it independently with the toolchain's `docc convert`. Do not place duplicate translated
article names inside one catalog.

```sh
ruby Scripts/build_swift_documentation.rb /tmp/vqmetrix-reference
```

Outputs are `swift/` and `ja/swift/`. The site assembler keeps legacy 1.0.x help links
working. App resources use their separate standard `Resources/*.lproj` localizations.
