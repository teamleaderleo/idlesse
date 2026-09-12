# Library stacks

#36 keeps every wallpaper as an independent stable Library entry. Stacks are a browsing relationship above those entries.

- Source stacks use explicit Source-scoped `groupID` with identity `(sourceID, groupID)`. Descriptive metadata such as series and character can name/filter a stack but does not create membership.
- User stacks store an ordered list of stable `Entry.id` values and an optional remembered representative.
- Search chooses a transient representative from the matching available children. Outside search, a remembered representative wins, then the first available child.
- Missing entries keep their stack state through Source reconciliation. Explicit Library removal cleans stack references; a stack with fewer than two remaining entries is removed.
- User-stack membership wins presentation priority when it overlaps a Source stack so one entry never appears in two stack cards at once.
- Ordinary collections continue to own concrete ordered entry IDs.
- Quarry SQLite persists `groupID`, user stack rows, ordered memberships, and remembered representatives. Media remains external.

The gallery/UI layer consumes `LibraryStackBrowser`: a card needs only the chosen representative entry, while focused stack browsing can request child artwork on demand. Flat browsing remains a presentation option.

📚 Curator

## Gallery behavior

Studio Library defaults to **Stacks** browsing with a persistent **Flat** toggle. A stack card carries one representative `Entry`, so the virtualized grid asks for one thumbnail. Search can swap that representative to the best matching child. Double-clicking a stack enters a focused child browser; the active query remains in force, and the Stacks menu returns to the compact gallery. User stacks can be created from an explicit shared series, character, or tag and can remember a chosen representative.
