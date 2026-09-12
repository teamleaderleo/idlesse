from pathlib import Path
p = Path('Sources/Harness/SceneLibrarySQLiteStore.swift')
s = p.read_text()
old = '''                CREATE INDEX user_stack_items_entry ON user_stack_items(entry_id, stack_id);
                PRAGMA user_version = 2;
'''
new = '''                CREATE INDEX user_stack_items_entry ON user_stack_items(entry_id, stack_id);
                UPDATE catalog_meta SET value = '2' WHERE key = 'schema_version';
                PRAGMA user_version = 2;
'''
if old not in s:
    raise SystemExit('stack schema upgrade anchor missing')
p.write_text(s.replace(old, new, 1))
