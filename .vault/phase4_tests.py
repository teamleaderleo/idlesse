from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:80]!r}")
    p.write_text(text.replace(old, new, 1))


# Add the new source and focused stack test executable to the canonical test runner.
test_sh = "test.sh"
replace_once(test_sh, r'''LIBRARY_CORE_SRCS=(Sources/Harness/SceneLibraryStore.swift Sources/Harness/SceneLibraryReconciliation.swift Sources/Harness/SceneLibrarySafety.swift Sources/Harness/SceneLibrarySQLiteStore.swift)
''', r'''LIBRARY_CORE_SRCS=(Sources/Harness/SceneLibraryStore.swift Sources/Harness/SceneLibraryReconciliation.swift Sources/Harness/SceneLibrarySafety.swift Sources/Harness/SceneLibrarySQLiteStore.swift Sources/Harness/SceneLibraryStacks.swift)
''')
replace_once(test_sh, r'''LIBRARY_SQLITE_SRCS=("${LIBRARY_CORE_SRCS[@]}" Tests/LibrarySQLiteTests.swift)
needs_build build/tests/library-sqlite "${LIBRARY_SQLITE_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${LIBRARY_SQLITE_SRCS[@]}" -lsqlite3 -o build/tests/library-sqlite & pids+=($!); }
LIBRARY_BENCH_SRCS=("${LIBRARY_CORE_SRCS[@]}" Tests/LibraryPersistenceBenchmark.swift)
''', r'''LIBRARY_SQLITE_SRCS=("${LIBRARY_CORE_SRCS[@]}" Tests/LibrarySQLiteTests.swift)
needs_build build/tests/library-sqlite "${LIBRARY_SQLITE_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${LIBRARY_SQLITE_SRCS[@]}" -lsqlite3 -o build/tests/library-sqlite & pids+=($!); }
LIBRARY_STACK_SRCS=("${LIBRARY_CORE_SRCS[@]}" Tests/LibraryStackTests.swift)
needs_build build/tests/library-stacks "${LIBRARY_STACK_SRCS[@]}" && { xcrun swiftc "$OPT_FLAG" "${LIBRARY_STACK_SRCS[@]}" -lsqlite3 -o build/tests/library-stacks & pids+=($!); }
LIBRARY_BENCH_SRCS=("${LIBRARY_CORE_SRCS[@]}" Tests/LibraryPersistenceBenchmark.swift)
''')
replace_once(test_sh, r'''build/tests/library-sqlite
build/tests/library-benchmark
''', r'''build/tests/library-sqlite
build/tests/library-stacks
build/tests/library-benchmark
''')

sqlite_tests = "Tests/LibrarySQLiteTests.swift"
replace_once(sqlite_tests, '        precondition(text.contains("idlesse-library-debug-v2"))\n', '        precondition(text.contains("idlesse-library-debug-v3"))\n')
replace_once(sqlite_tests, r'''            "entries_media_type", "entry_tags_value", "item_state_recent", "collection_items_scene",
            "collection_items_selection"
''', r'''            "entries_media_type", "entry_tags_value", "item_state_recent", "collection_items_scene",
            "collection_items_selection", "entries_source_group", "user_stack_items_entry", "user_stacks_name_nocase"
''')
replace_once(sqlite_tests, r'''        precondition(entryColumns.isSuperset(of: ["provenance_present", "observation_present"]))
''', r'''        precondition(entryColumns.isSuperset(of: ["provenance_present", "observation_present", "group_id"]))
''')

print("tests transformed")
