from pathlib import Path

path = Path('Sources/Harness/SceneLibrarySQLiteStore.swift')
s = path.read_text()

def replace_once(old, new):
    global s
    if old not in s:
        raise SystemExit('missing anchor: ' + old[:120])
    s = s.replace(old, new, 1)

replace_once('    static let schemaVersion = 1\n', '    static let schemaVersion = 2\n')
replace_once('''    static func readSelectedCatalog(for jsonFile: URL) throws -> SceneLibraryStore.Catalog {
        guard try hasSQLiteSelector(for: jsonFile) else {
            throw failure("The SQLite Library backend is not active.")
        }
        return try readCatalog(at: paths(for: jsonFile).database)
    }
''', '''    static func readSelectedCatalog(for jsonFile: URL) throws -> SceneLibraryStore.Catalog {
        guard try hasSQLiteSelector(for: jsonFile) else {
            throw failure("The SQLite Library backend is not active.")
        }
        let url = paths(for: jsonFile).database
        try upgradeSchemaIfNeeded(at: url)
        return try readCatalog(at: url)
    }
''')
replace_once('''        let url = paths(for: jsonFile).database
        try ensureDatabaseBound(url)
        let db = try Database(url: url, mode: .readWrite)
''', '''        let url = paths(for: jsonFile).database
        try upgradeSchemaIfNeeded(at: url)
        try ensureDatabaseBound(url)
        let db = try Database(url: url, mode: .readWrite)
''')
anchor = '''    static func verifyDatabase(at url: URL) throws {
'''
upgrade = '''    private static func upgradeSchemaIfNeeded(at url: URL) throws {
        try ensureDatabaseBound(url)
        let db = try Database(url: url, mode: .readWrite)
        try configureWritePragmas(db, isNew: false)
        let version = try db.scalarInt("PRAGMA user_version")
        if version == schemaVersion { return }
        guard version == 1 else {
            throw failure("This Library database uses unsupported schema version \\(version).")
        }
        try db.transaction {
            try db.execute("ALTER TABLE entries ADD COLUMN group_id TEXT")
            try db.execute("""
                CREATE TABLE user_stacks (
                    id TEXT PRIMARY KEY,
                    ordinal INTEGER NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    representative_entry_id TEXT REFERENCES entries(id) ON DELETE SET NULL
                );
                CREATE TABLE user_stack_items (
                    stack_id TEXT NOT NULL REFERENCES user_stacks(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    entry_id TEXT NOT NULL REFERENCES entries(id) ON DELETE CASCADE,
                    PRIMARY KEY(stack_id, ordinal),
                    UNIQUE(stack_id, entry_id)
                ) WITHOUT ROWID;
                CREATE INDEX entries_source_group ON entries(source_id, group_id);
                CREATE INDEX user_stack_items_entry ON user_stack_items(entry_id, stack_id);
                PRAGMA user_version = 2;
                """)
        }
        try verifyDatabase(at: url)
    }

'''
replace_once(anchor, upgrade + anchor)
path.write_text(s)
print('Stack SQLite schema upgrade patch applied')
