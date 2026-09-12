from pathlib import Path


def replace(path, old, new, count=1):
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n < count:
        raise SystemExit(f"{path}: expected {count}, found {n}: {old[:120]!r}")
    p.write_text(s.replace(old, new, count))

wall = "Sources/Wallpaper/WallpaperController.swift"
replace(wall, '''            resumeDefaults.set(pausedByUser, forKey: Self.pauseKey)
            if let activeVariantID { resumeDefaults.set(activeVariantID.uuidString, forKey: Self.resumeVariantKey) }
            else { resumeDefaults.removeObject(forKey: Self.resumeVariantKey) }
''', '''            resumeDefaults.set(pausedByUser, forKey: Self.pauseKey)
            if let persistedVariantID = unavailableVariantID ?? activeVariantID {
                resumeDefaults.set(persistedVariantID.uuidString, forKey: Self.resumeVariantKey)
            } else {
                resumeDefaults.removeObject(forKey: Self.resumeVariantKey)
            }
''')
replace(wall, '''        if prePeekSelection == nil, let selectedURL { prePeekSelection = (selectedURL, activeVariantID) }
''', '''        if prePeekSelection == nil, let selectedURL {
            prePeekSelection = (selectedURL, unavailableVariantID ?? activeVariantID)
        }
''')
replace(wall, '''        guard reverting, back.url != selectedURL || back.variantID != activeVariantID else { return }
''', '''        guard reverting, back.url != selectedURL || back.variantID != (unavailableVariantID ?? activeVariantID) else { return }
''')
replace(wall, '''                let requestedVariantID = reloading ? (variantID ?? self.activeVariantID) : variantID
''', '''                let requestedVariantID = reloading ? (variantID ?? self.unavailableVariantID ?? self.activeVariantID) : variantID
''')
replace(wall, '''            self.select(url, variantID: self.activeVariantID, reloading: true)
''', '''            self.select(url, variantID: self.unavailableVariantID ?? self.activeVariantID, reloading: true)
''')

lib = "Sources/Harness/SceneLibraryController.swift"
replace(lib, '''        let variantID: UUID?
        let modified: Bool
''', '''        let variantID: UUID? = nil
        let modified: Bool = false
''')

docs = Path("docs/scene-variants.md")
text = docs.read_text()
needle = "Missing requested UUIDs fall back safely to Default and return a diagnostic so a caller can surface and repair the reference."
if needle in text and "retains the requested UUID" not in text:
    docs.write_text(text.replace(needle, needle + " Wallpaper resume state retains the requested UUID even while Default is playing, so a temporarily missing variant stays repairable."))
