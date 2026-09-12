from pathlib import Path

p = Path('.github/curator_memory_model_patch.py')
s = p.read_text()
s = s.replace('try statement.bindNull(at: 2)', 'try statement.bind(Optional<Double>.none, at: 2)')
s = s.replace('try predicate.bindNull(at: 6)', 'try predicate.bind(Optional<Int>.none, at: 6)')
s = s.replace('SELECT item_id, recent_at FROM item_state WHERE recent_at IS NOT NULL")',
              'SELECT item_id, recent_at FROM item_state WHERE recent_at IS NOT NULL ORDER BY item_id")')
s = s.replace('guard let id = statement.text(0) else { throw failure("An item state row is invalid.") }\n            result[id] = Date(timeIntervalSinceReferenceDate: statement.double(1))',
              'guard let id = statement.text(0), let time = statement.optionalDouble(1) else { throw failure("An item state row is invalid.") }\n            result[id] = Date(timeIntervalSinceReferenceDate: time)')
s = s.replace('statement.double(1)', 'statement.optionalDouble(1)!')
s = s.replace("'            SELECT id, name, playback_present, playback_minutes, playback_shuffle, playback_start_minute, playback_end_minute, weekdays_present\\n'",
              "'            SELECT id, name, playback_present, playback_minutes, playback_shuffle,\\n                   playback_start_minute, playback_end_minute, weekdays_present\\n'")
s = s.replace('''                var settings = SceneLibraryStore.Playback(minutes: statement.int(3), shuffle: statement.int(4) != 0,
                    startMinute: statement.isNull(5) ? nil : statement.int(5),
                    endMinute: statement.isNull(6) ? nil : statement.int(6),
                    weekdays: statement.int(7) == 0 ? nil : Set(weekdays[id] ?? []))
''', '''                playback = .init(minutes: minutes, shuffle: shuffleValue != 0,
                    startMinute: statement.optionalInt(5), endMinute: statement.optionalInt(6),
                    weekdays: statement.int(7) == 1 ? (weekdays[id] ?? []) : nil)
''')
s = s.replace('''                var settings = SceneLibraryStore.Playback(minutes: statement.int(3), shuffle: statement.int(4) != 0,
                    mode: statement.text(5).flatMap(SceneLibraryStore.Playback.SelectionMode.init(rawValue:)),
                    startMinute: statement.isNull(6) ? nil : statement.int(6),
                    endMinute: statement.isNull(7) ? nil : statement.int(7),
                    weekdays: statement.int(8) == 0 ? nil : Set(weekdays[id] ?? []))
''', '''                playback = .init(minutes: minutes, shuffle: shuffleValue != 0,
                    mode: statement.text(5).flatMap(SceneLibraryStore.Playback.SelectionMode.init(rawValue:)),
                    startMinute: statement.optionalInt(6), endMinute: statement.optionalInt(7),
                    weekdays: statement.int(8) == 1 ? (weekdays[id] ?? []) : nil)
''')
p.write_text(s)
