import Foundation

@main
enum OpenUsageSelfTest {
    static func main() async throws {
        var assertions = 0

        func expect(
            _ condition: @autoclosure () -> Bool,
            _ message: String,
            file: StaticString = #filePath,
            line: UInt = #line
        ) throws {
            assertions += 1
            guard condition() else {
                throw SelfTestFailure(message: message, file: "\(file)", line: line)
            }
        }

        let authData = Data(
            """
            {
              "account": {
                "uid": "user-123",
                "nickname": "Fixture",
                "accountType": "pro",
                "phoneNumber": "13800138000"
              },
              "auth": { "accessToken": "fixture-token" }
            }
            """.utf8
        )
        let document = try AuthDocument(data: authData)
        try expect(document.userID == "user-123", "auth uid")
        try expect(document.nickname == "Fixture", "auth nickname")
        try expect(document.phoneHint == "138****8000", "phone masking")
        let fixtureToken = try document.accessToken()
        try expect(fixtureToken == "fixture-token", "token extraction")

        let usageLine = Data(
            """
            {
              "type": "message",
              "role": "assistant",
              "sessionId": "session-1",
              "timestamp": 1784822400000,
              "providerData": {
                "model": "auto",
                "rawUsage": {
                  "prompt_tokens": 1200,
                  "completion_tokens": 300,
                  "prompt_cache_hit_tokens": 400,
                  "completion_thinking_tokens": 80,
                  "credit": 1.25
                }
              }
            }
            """.utf8
        )
        let parsedA = UsageParser.parseLine(
            usageLine,
            sourceFingerprint: "copy-a"
        )
        let parsedB = UsageParser.parseLine(
            usageLine,
            sourceFingerprint: "copy-b"
        )
        guard let message = parsedA.message else {
            throw SelfTestFailure(message: "usage message missing", file: #filePath, line: #line)
        }
        try expect(message.tokens.input == 800, "net input")
        try expect(message.tokens.output == 300, "output")
        try expect(message.tokens.cacheRead == 400, "cache hit")
        try expect(message.tokens.cacheWrite == 0, "cache write defaults to zero")
        try expect(message.tokens.reasoning == 80, "reasoning")
        try expect(message.tokens.requestCount == 1, "usage record defaults to one request")
        try expect(message.tokens.total == 1500, "total")
        try expect(message.credits == 1.25, "credits")
        try expect(
            parsedA.message?.deduplicationKey == parsedB.message?.deduplicationKey,
            "copied rows must deduplicate"
        )

        let cacheWriteLine = Data(
            """
            {
              "type": "message",
              "role": "assistant",
              "sessionId": "cache-write-session",
              "id": "cache-write-message",
              "timestamp": 1784822400000,
              "providerData": {
                "model": "fixture-model",
                "rawUsage": {
                  "prompt_tokens": 1000,
                  "completion_tokens": 100,
                  "prompt_cache_hit_tokens": 400,
                  "prompt_cache_miss_tokens": 600,
                  "cache_creation_input_tokens": 250,
                  "prompt_cache_write_tokens": 250,
                  "completion_tokens_details": {
                    "reasoning_tokens": 30
                  }
                }
              }
            }
            """.utf8
        )
        guard let cacheWriteMessage = UsageParser.parseLine(
            cacheWriteLine,
            sourceFingerprint: "cache-write"
        ).message else {
            throw SelfTestFailure(
                message: "cache-write usage missing",
                file: #filePath,
                line: #line
            )
        }
        try expect(cacheWriteMessage.tokens.input == 350, "cache write removed from net input")
        try expect(cacheWriteMessage.tokens.cacheRead == 400, "explicit cache read")
        try expect(cacheWriteMessage.tokens.cacheWrite == 250, "duplicate cache write fields use max")
        try expect(cacheWriteMessage.tokens.reasoning == 30, "reasoning detail fallback")
        try expect(cacheWriteMessage.tokens.total == 1100, "cache split preserves reported total")
        try expect(cacheWriteMessage.credits == 0, "tokens without credit are not converted")

        let normalizedOnlyLine = Data(
            """
            {
              "type": "message",
              "role": "assistant",
              "sessionId": "normalized-session",
              "id": "normalized-message",
              "timestamp": 1784822400000,
              "providerData": {
                "model": "normalized-model",
                "usage": {
                  "requests": 2,
                  "inputTokens": 2200,
                  "outputTokens": 300,
                  "inputTokensDetails": [{ "cached_tokens": 2000 }],
                  "outputTokensDetails": [{ "reasoning_tokens": 75 }]
                }
              }
            }
            """.utf8
        )
        guard let normalizedMessage = UsageParser.parseLine(
            normalizedOnlyLine,
            sourceFingerprint: "normalized"
        ).message else {
            throw SelfTestFailure(
                message: "normalized usage missing",
                file: #filePath,
                line: #line
            )
        }
        try expect(normalizedMessage.tokens.input == 200, "normalized net input")
        try expect(normalizedMessage.tokens.output == 300, "normalized output")
        try expect(normalizedMessage.tokens.cacheRead == 2000, "normalized cache details")
        try expect(normalizedMessage.tokens.reasoning == 75, "normalized reasoning details")
        try expect(normalizedMessage.tokens.requestCount == 2, "normalized request count")
        try expect(normalizedMessage.tokens.total == 2500, "normalized total")

        let missingUsageLine = Data(
            """
            {
              "type": "message",
              "role": "assistant",
              "sessionId": "missing-usage-session",
              "id": "missing-usage-message",
              "timestamp": 1784822400000,
              "providerData": { "model": "kimi-k3-1" }
            }
            """.utf8
        )
        try expect(
            UsageParser.parseLine(
                missingUsageLine,
                sourceFingerprint: "missing-usage"
            ).message == nil,
            "messages without official usage are not estimated"
        )

        let kimiParts: [(prompt: Int, cacheHit: Int, output: Int, credit: Double)] = [
            (300_000, 299_500, 400, 15.39),
            (300_000, 299_500, 400, 16.50),
            (300_000, 299_500, 400, 17.69),
            (300_000, 299_500, 400, 15.24),
            (293_390, 292_944, 531, 10.04)
        ]
        var kimiMessages: [UsageMessage] = []
        for (index, part) in kimiParts.enumerated() {
            let object: [String: Any] = [
                "type": "message",
                "role": "assistant",
                "sessionId": "kimi-session",
                "id": "kimi-message-\(index)",
                "timestamp": 1_784_822_400_000 + index,
                "providerData": [
                    "model": "kimi-k3-1",
                    "usage": [
                        "requests": 1,
                        "inputTokens": part.prompt,
                        "outputTokens": part.output
                    ],
                    "rawUsage": [
                        "prompt_tokens": part.prompt,
                        "completion_tokens": part.output,
                        "prompt_cache_hit_tokens": part.cacheHit,
                        "prompt_cache_miss_tokens": part.prompt - part.cacheHit,
                        "cache_creation_input_tokens": 0,
                        "prompt_cache_write_tokens": 0,
                        "completion_thinking_tokens": 1,
                        "credit": part.credit
                    ]
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            guard let parsed = UsageParser.parseLine(
                data,
                sourceFingerprint: "kimi-\(index)"
            ).message else {
                throw SelfTestFailure(
                    message: "Kimi usage record \(index) missing",
                    file: #filePath,
                    line: #line
                )
            }
            kimiMessages.append(parsed)
        }
        let kimiSnapshot = UsageParser.aggregate(
            messages: kimiMessages,
            titles: ["kimi-session": "Kimi fixture"],
            accountBySession: ["kimi-session": "account-1"],
            period: .all,
            accountID: "account-1"
        )
        guard let kimiModel = kimiSnapshot.models.first(where: { $0.model == "kimi-k3-1" }) else {
            throw SelfTestFailure(
                message: "Kimi model summary missing",
                file: #filePath,
                line: #line
            )
        }
        try expect(kimiModel.tokens.input == 2_446, "Kimi net input")
        try expect(kimiModel.tokens.output == 2_131, "Kimi output exceeds 2,000")
        try expect(kimiModel.tokens.cacheRead == 1_490_944, "Kimi cache hit")
        try expect(kimiModel.tokens.cacheWrite == 0, "Kimi cache write remains zero")
        try expect(kimiModel.tokens.reasoning == 5, "Kimi reasoning")
        try expect(kimiModel.tokens.requestCount == 5, "Kimi request count")
        try expect(kimiModel.tokens.total == 1_495_521, "Kimi total")
        try expect(
            abs(kimiModel.credits - 74.86) < 0.000_001,
            "Kimi model exposes only locally recorded Credits"
        )
        try expect(
            abs(kimiSnapshot.credits - 74.86) < 0.000_001,
            "usage snapshot keeps locally attributable Credits separate"
        )
        try expect(
            kimiSnapshot.daily.first?.breakdown == kimiModel.tokens,
            "daily breakdown preserves Kimi token components"
        )
        try expect(
            kimiSnapshot.modelDaily.first?.tokens == kimiModel.tokens,
            "model/day series preserves Kimi token components"
        )
        try expect(
            kimiSnapshot.hourly.first?.breakdown == kimiModel.tokens,
            "hourly breakdown preserves Kimi token components"
        )
        try expect(
            kimiSnapshot.modelHourly.first?.tokens == kimiModel.tokens,
            "model/hour series preserves Kimi token components"
        )

        let snapshot = UsageParser.aggregate(
            messages: [message],
            titles: ["session-1": "Fixture session"],
            accountBySession: ["session-1": "account-1"],
            period: .all,
            accountID: "account-1"
        )
        try expect(snapshot.total.total == 1500, "aggregate total")
        try expect(snapshot.sessions.first?.title == "Fixture session", "session title")
        let movedAway = UsageParser.aggregate(
            messages: [message],
            titles: [:],
            accountBySession: ["session-1": "account-2"],
            period: .all,
            accountID: "account-1"
        )
        try expect(movedAway.total.total == 0, "latest session owner removes stale attribution")
        let movedTo = UsageParser.aggregate(
            messages: [message],
            titles: [:],
            accountBySession: ["session-1": "account-2"],
            period: .all,
            accountID: "account-2"
        )
        try expect(movedTo.total.total == 1500, "latest session owner receives attribution")
        let unattributed = UsageParser.aggregate(
            messages: [message],
            titles: [:],
            accountBySession: [:],
            period: .all,
            accountID: "account-1"
        )
        try expect(unattributed.total.total == 0, "unmapped session excluded from account filter")
        let allAccounts = UsageParser.aggregate(
            messages: [message],
            titles: [:],
            accountBySession: [:],
            period: .all,
            accountID: nil
        )
        try expect(allAccounts.total.total == 1500, "unmapped session retained in all accounts")

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let rangeStart = utcCalendar.date(
            from: DateComponents(year: 2026, month: 7, day: 24)
        )!
        let secondDay = utcCalendar.date(byAdding: .day, value: 1, to: rangeStart)!
        let rangeEnd = utcCalendar.date(byAdding: .day, value: 2, to: rangeStart)!
        let boundaryTimestamps = [
            rangeStart.addingTimeInterval(-0.001),
            rangeStart,
            rangeEnd.addingTimeInterval(-0.001),
            rangeEnd
        ]
        let boundaryMessages = boundaryTimestamps.enumerated().map { index, timestamp in
            UsageMessage(
                deduplicationKey: "boundary-\(index)",
                sessionID: "boundary-session",
                timestamp: timestamp,
                model: "boundary-model",
                tokens: TokenBreakdown(input: 1, requestCount: 1),
                credits: 0
            )
        }
        let inclusiveDayRange = UsageDateRange(
            startInclusive: rangeStart,
            endExclusive: rangeEnd
        )
        let boundarySnapshot = UsageParser.aggregate(
            messages: boundaryMessages,
            titles: ["boundary-session": "Boundary"],
            accountBySession: ["boundary-session": "account-1"],
            range: inclusiveDayRange,
            accountID: "account-1"
        )
        try expect(boundarySnapshot.total.total == 2, "date range includes both day boundaries")
        try expect(
            boundarySnapshot.total.requestCount == 2,
            "date range excludes the exact end-exclusive instant"
        )
        try expect(boundarySnapshot.hourly.count == 2, "range aggregation produces hourly points")
        try expect(
            boundarySnapshot.modelHourly.count == 2,
            "range aggregation produces model/hour points"
        )

        let singleDayRange = UsagePeriod.today.dateRange(
            customStart: rangeStart,
            customEnd: rangeStart,
            now: rangeStart.addingTimeInterval(12 * 60 * 60),
            calendar: utcCalendar
        )
        try expect(
            singleDayRange.startInclusive == rangeStart,
            "today starts at local midnight"
        )
        try expect(
            singleDayRange.endExclusive == secondDay,
            "today ends at the next local midnight"
        )
        try expect(
            singleDayRange.spansSingleDay(calendar: utcCalendar),
            "today selects hourly trend granularity"
        )

        let customRange = UsagePeriod.custom.dateRange(
            customStart: secondDay,
            customEnd: rangeStart,
            now: rangeStart,
            calendar: utcCalendar
        )
        try expect(
            customRange.startInclusive == rangeStart,
            "custom range normalizes a reversed start"
        )
        try expect(
            customRange.endExclusive == rangeEnd,
            "custom range includes the selected end date"
        )
        try expect(
            !customRange.spansSingleDay(calendar: utcCalendar),
            "multi-day custom range selects daily trend granularity"
        )

        let preciseQuotaAccount: [String: Any] = [
            "CycleCapacityRemainPrecise": "599.0400001",
            "CycleCapacityRemain": 599
        ]
        try expect(
            abs(
                UsageService.quotaAmount(
                    in: preciseQuotaAccount,
                    preciseKey: "CycleCapacityRemainPrecise",
                    fallbackKey: "CycleCapacityRemain"
                ) - 599.0400001
            ) < 0.000_000_01,
            "quota parsing prefers the precise value"
        )
        let fallbackQuotaAccount: [String: Any] = ["CycleCapacitySize": 2800]
        try expect(
            UsageService.quotaAmount(
                in: fallbackQuotaAccount,
                preciseKey: "CycleCapacitySizePrecise",
                fallbackKey: "CycleCapacitySize"
            ) == 2800,
            "quota parsing falls back to the legacy value"
        )

        try expect(
            WorkBuddyController.sessionDeepLink("session-abc")?.absoluteString
                == "workbuddy://chat/session-abc",
            "deep link"
        )
        try expect(
            !WorkBuddyController.isInteractiveCLICommand(
                "/Applications/WorkBuddy.app/Contents/MacOS/Electron codebuddy --serve --port 1234"
            ),
            "background WorkBuddy service is not treated as an interactive CLI"
        )
        try expect(
            WorkBuddyController.isInteractiveCLICommand(
                "/usr/bin/node codebuddy --resume session-abc"
            ),
            "terminal WorkBuddy resume is detected before migration"
        )

        // WorkBuddy 5.4+ 起用新 bundle ID，旧 ID 保留兜底；候选顺序即优先级
        try expect(
            WorkBuddyController.bundleIdentifiers
                == ["com.tencent.workbuddy.mac", "com.workbuddy.workbuddy"],
            "workbuddy bundle identifier candidates keep new build first"
        )
        try expect(
            WorkBuddyController.resolveApplicationURL(
                identifiers: WorkBuddyController.bundleIdentifiers
            ) { identifier in
                identifier == "com.tencent.workbuddy.mac"
                    ? URL(fileURLWithPath: "/Applications/WorkBuddy.app")
                    : nil
            }?.path == "/Applications/WorkBuddy.app",
            "workbuddy discovery resolves the new bundle id"
        )
        try expect(
            WorkBuddyController.resolveApplicationURL(
                identifiers: WorkBuddyController.bundleIdentifiers
            ) { identifier in
                identifier == "com.workbuddy.workbuddy"
                    ? URL(fileURLWithPath: "/Applications/WorkBuddy Legacy.app")
                    : nil
            }?.path == "/Applications/WorkBuddy Legacy.app",
            "workbuddy discovery falls back to the legacy bundle id"
        )
        try expect(
            WorkBuddyController.resolveApplicationURL(
                identifiers: WorkBuddyController.bundleIdentifiers
            ) { identifier in
                URL(
                    fileURLWithPath: identifier == "com.tencent.workbuddy.mac"
                        ? "/Applications/WorkBuddy.app"
                        : "/Applications/WorkBuddy Legacy.app"
                )
            }?.path == "/Applications/WorkBuddy.app",
            "workbuddy discovery prefers the new build when both exist"
        )
        try expect(
            WorkBuddyController.resolveApplicationURL(
                identifiers: WorkBuddyController.bundleIdentifiers
            ) { _ in nil } == nil,
            "workbuddy discovery returns nil when no candidate is installed"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openusage-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("test.db")
        FileManager.default.createFile(atPath: databaseURL.path, contents: Data())
        let database = try SQLiteDatabase(url: databaseURL, readOnly: false)
        try database.execute("CREATE TABLE rows (id TEXT PRIMARY KEY, value INTEGER)")
        let _ = try database.transaction {
            try database.execute(
                "INSERT INTO rows (id, value) VALUES (?, ?)",
                bindings: [.text("row-1"), .integer(42)]
            )
        }
        let rows = try database.query(
            "SELECT value FROM rows WHERE id = ?",
            bindings: [.text("row-1")]
        )
        try expect(rows.first?["value"]?.int64 == 42, "sqlite parameter binding")

        try database.execute(
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                user_id TEXT NOT NULL,
                title TEXT,
                status TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """
        )
        try database.execute(
            """
            INSERT INTO sessions (id, cwd, user_id, title, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text("legacy-session"),
                .text("/tmp/project"),
                .text("legacy-account"),
                .text("Legacy title"),
                .text("done"),
                .integer(1_784_822_400_000)
            ]
        )
        let legacySessions = try SessionStore(databaseURL: databaseURL).loadSessions()
        try expect(legacySessions.count == 1, "legacy session schema")
        try expect(legacySessions.first?.title == "Legacy title", "legacy session title")
        try expect(legacySessions.first?.model == nil, "legacy optional model")

        let migrationDatabaseURL = directory.appendingPathComponent("migration.db")
        let migrationBackupsURL = directory
            .appendingPathComponent("migration-backups", isDirectory: true)
        do {
            _ = FileManager.default.createFile(
                atPath: migrationDatabaseURL.path,
                contents: Data()
            )
            let migrationDatabase = try SQLiteDatabase(
                url: migrationDatabaseURL,
                readOnly: false
            )
            let journalMode = try migrationDatabase.query("PRAGMA journal_mode = WAL")
            try expect(
                journalMode.first?["journal_mode"]?.string?.lowercased() == "wal",
                "migration fixture uses WAL journal mode"
            )
            try migrationDatabase.execute(
                """
                CREATE TABLE sessions (
                    id TEXT PRIMARY KEY,
                    cwd TEXT NOT NULL,
                    user_id TEXT NOT NULL,
                    title TEXT,
                    status TEXT NOT NULL,
                    created_at INTEGER NOT NULL,
                    updated_at INTEGER,
                    deleted_at INTEGER
                )
                """
            )
            for (id, owner, deletedAt) in [
                ("move-selected", "source-account", nil),
                ("leave-source", "source-account", nil),
                ("deleted-selected", "source-account", 1_784_822_500_000),
                ("already-current", "target-account", nil)
            ] as [(String, String, Int64?)] {
                try migrationDatabase.execute(
                    """
                    INSERT INTO sessions (
                        id, cwd, user_id, title, status, created_at, updated_at, deleted_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(id),
                        .text("/tmp/project"),
                        .text(owner),
                        .text(id),
                        .text("done"),
                        .integer(1_784_822_400_000),
                        .integer(1_784_822_400_000),
                        deletedAt.map(SQLiteValue.integer) ?? .null
                    ]
                )
            }
        }
        let migrationStore = SessionStore(
            databaseURL: migrationDatabaseURL,
            backupDirectoryURL: migrationBackupsURL
        )
        let unchangedMutation = try migrationStore.prepareSessionForResume(
            sessionID: "already-current",
            expectedSourceUserID: "target-account",
            targetUserID: "target-account",
            restoreFromTrash: false
        )
        try expect(!unchangedMutation.changedLocalState, "same-account resume is a no-op")
        try expect(unchangedMutation.backupURL == nil, "same-account resume skips backup")
        try expect(
            !FileManager.default.fileExists(atPath: migrationBackupsURL.path),
            "same-account resume does not create a backup directory"
        )

        var rejectedMigrationOwner = false
        do {
            _ = try migrationStore.prepareSessionForResume(
                sessionID: "move-selected",
                expectedSourceUserID: "wrong-account",
                targetUserID: "target-account",
                restoreFromTrash: false
            )
        } catch OpenUsageError.sessionRestoreConflict {
            rejectedMigrationOwner = true
        }
        try expect(rejectedMigrationOwner, "migration rejects a mismatched source owner")
        let beforeMigration = try migrationStore.loadSessions(includeDeleted: true)
        try expect(
            beforeMigration.first { $0.id == "move-selected" }?.userID == "source-account",
            "rejected migration leaves the selected session unchanged"
        )

        // WorkBuddy can remove WAL sidecars while leaving the main database in WAL mode.
        var stoppedWorkBuddyDatabase: SQLiteDatabase? = try SQLiteDatabase(
            url: migrationDatabaseURL,
            readOnly: false
        )
        try stoppedWorkBuddyDatabase?.checkpointWAL()
        stoppedWorkBuddyDatabase = nil
        for suffix in ["-wal", "-shm"] {
            let sidecarURL = URL(fileURLWithPath: migrationDatabaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecarURL.path) {
                try FileManager.default.removeItem(at: sidecarURL)
            }
        }
        try expect(
            !FileManager.default.fileExists(atPath: migrationDatabaseURL.path + "-wal")
                && !FileManager.default.fileExists(atPath: migrationDatabaseURL.path + "-shm"),
            "stopped WorkBuddy fixture has no WAL sidecars"
        )

        let migrated = try migrationStore.prepareSessionForResume(
            sessionID: "move-selected",
            expectedSourceUserID: "source-account",
            targetUserID: "target-account",
            restoreFromTrash: false
        )
        try expect(migrated.reassignedToCurrentAccount, "selected session is reassigned")
        try expect(!migrated.restoredFromTrash, "active session is not marked restored")
        guard let firstBackupURL = migrated.backupURL else {
            throw SelfTestFailure(
                message: "migration backup missing",
                file: #filePath,
                line: #line
            )
        }
        try expect(
            FileManager.default.fileExists(atPath: firstBackupURL.path),
            "migration creates a recoverable backup"
        )
        let backupDatabase = try SQLiteDatabase(url: firstBackupURL, readOnly: true)
        let backupCheck = try backupDatabase.query("PRAGMA quick_check")
        try expect(
            backupCheck.first?["quick_check"]?.string == "ok",
            "migration backup passes SQLite quick_check"
        )
        let backupJournalMode = try backupDatabase.query("PRAGMA journal_mode")
        try expect(
            backupJournalMode.first?["journal_mode"]?.string?.lowercased() == "delete",
            "migration backup is self-contained outside WAL mode"
        )
        try expect(
            !FileManager.default.fileExists(atPath: firstBackupURL.path + "-wal")
                && !FileManager.default.fileExists(atPath: firstBackupURL.path + "-shm"),
            "migration backup does not depend on SQLite sidecars"
        )
        let backupOwner = try backupDatabase.query(
            "SELECT user_id FROM sessions WHERE id = ?",
            bindings: [.text("move-selected")]
        )
        try expect(
            backupOwner.first?["user_id"]?.string == "source-account",
            "backup captures the owner before mutation"
        )

        let afterMigration = try migrationStore.loadSessions(includeDeleted: true)
        try expect(
            afterMigration.first { $0.id == "move-selected" }?.userID == "target-account",
            "selected session moves to the target account"
        )
        try expect(
            afterMigration.first { $0.id == "leave-source" }?.userID == "source-account",
            "other sessions from the source account do not move"
        )

        let restoredAndMigrated = try migrationStore.prepareSessionForResume(
            sessionID: "deleted-selected",
            expectedSourceUserID: "source-account",
            targetUserID: "target-account",
            restoreFromTrash: true
        )
        try expect(
            restoredAndMigrated.reassignedToCurrentAccount
                && restoredAndMigrated.restoredFromTrash,
            "deleted session restores and reassigns atomically"
        )
        let afterDeletedMigration = try migrationStore.loadSessions(includeDeleted: true)
        let restoredSession = afterDeletedMigration.first { $0.id == "deleted-selected" }
        try expect(restoredSession?.userID == "target-account", "restored session owner")
        try expect(restoredSession?.isDeleted == false, "restored session leaves trash")
        try expect(
            restoredSession?.updatedAt ?? .distantPast > Date(timeIntervalSince1970: 1_784_822_400),
            "trash restoration advances the update timestamp"
        )

        let blockedBackupURL = directory.appendingPathComponent("backup-path-is-a-file")
        try Data("blocked".utf8).write(to: blockedBackupURL)
        let blockedBackupStore = SessionStore(
            databaseURL: migrationDatabaseURL,
            backupDirectoryURL: blockedBackupURL
        )
        var rejectedMissingBackup = false
        do {
            _ = try blockedBackupStore.prepareSessionForResume(
                sessionID: "leave-source",
                expectedSourceUserID: "source-account",
                targetUserID: "target-account",
                restoreFromTrash: false
            )
        } catch {
            rejectedMissingBackup = true
        }
        try expect(rejectedMissingBackup, "migration stops when backup creation fails")
        let afterBackupFailure = try migrationStore.loadSessions(includeDeleted: true)
        try expect(
            afterBackupFailure.first { $0.id == "leave-source" }?.userID == "source-account",
            "backup failure leaves session ownership unchanged"
        )

        let trashDatabaseURL = directory.appendingPathComponent("trash.db")
        _ = FileManager.default.createFile(atPath: trashDatabaseURL.path, contents: Data())
        let trashDatabase = try SQLiteDatabase(url: trashDatabaseURL, readOnly: false)
        try trashDatabase.execute(
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                cwd TEXT NOT NULL,
                user_id TEXT NOT NULL,
                title TEXT,
                status TEXT NOT NULL,
                created_at INTEGER NOT NULL,
                updated_at INTEGER,
                deleted_at INTEGER
            )
            """
        )
        try trashDatabase.execute(
            """
            INSERT INTO sessions (
                id, cwd, user_id, title, status, created_at, updated_at, deleted_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text("trash-session"),
                .text("/tmp/project"),
                .text("owner-account"),
                .text("Deleted title"),
                .text("done"),
                .integer(1_784_822_400_000),
                .integer(1_784_822_400_000),
                .integer(1_784_822_500_000)
            ]
        )
        let trashStore = SessionStore(databaseURL: trashDatabaseURL)
        var rejectedWrongOwner = false
        do {
            try trashStore.restoreFromTrash(
                "trash-session",
                expectedUserID: "other-account"
            )
        } catch OpenUsageError.sessionRestoreConflict {
            rejectedWrongOwner = true
        }
        try expect(rejectedWrongOwner, "trash restore rejects a mismatched owner")
        let sessionsAfterWrongOwner = try trashStore.loadSessions(includeDeleted: true)
        try expect(
            sessionsAfterWrongOwner.first?.isDeleted == true,
            "failed restore leaves trash state unchanged"
        )
        try trashStore.restoreFromTrash(
            "trash-session",
            expectedUserID: "owner-account"
        )
        let sessionsAfterRestore = try trashStore.loadSessions(includeDeleted: true)
        try expect(
            sessionsAfterRestore.first?.isDeleted == false,
            "matching owner restores trash session"
        )
        var rejectedNoChange = false
        do {
            try trashStore.restoreFromTrash(
                "trash-session",
                expectedUserID: "owner-account"
            )
        } catch OpenUsageError.sessionRestoreConflict {
            rejectedNoChange = true
        }
        try expect(rejectedNoChange, "zero-change trash restore reports a conflict")

        let cacheDatabaseURL = directory.appendingPathComponent("usage-cache.db")
        _ = FileManager.default.createFile(atPath: cacheDatabaseURL.path, contents: Data())
        let cacheDatabase = try SQLiteDatabase(url: cacheDatabaseURL, readOnly: false)
        try cacheDatabase.execute(
            """
            CREATE TABLE sessions (
                id TEXT PRIMARY KEY,
                user_id TEXT NOT NULL,
                title TEXT
            )
            """
        )
        try cacheDatabase.execute(
            "INSERT INTO sessions (id, user_id, title) VALUES (?, ?, ?)",
            bindings: [
                .text("session-1"),
                .text("account-1"),
                .text("Cached session")
            ]
        )
        let projectsURL = directory.appendingPathComponent("projects", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectsURL,
            withIntermediateDirectories: true
        )
        let compactUsageLine = try JSONSerialization.data(
            withJSONObject: JSONSerialization.jsonObject(with: usageLine)
        )
        try compactUsageLine.write(to: projectsURL.appendingPathComponent("session.jsonl"))
        let cacheStore = SessionStore(
            databaseURL: cacheDatabaseURL,
            backupDirectoryURL: directory.appendingPathComponent(
                "usage-cache-backups",
                isDirectory: true
            )
        )
        let usageService = UsageService(
            sessionStore: cacheStore,
            projectsURL: projectsURL
        )
        var rejectedUninitializedUsageCache = false
        do {
            _ = try await usageService.aggregateCached(
                period: .all,
                accountID: "account-1"
            )
        } catch OpenUsageError.usageCacheUnavailable {
            rejectedUninitializedUsageCache = true
        }
        try expect(
            rejectedUninitializedUsageCache,
            "uninitialized usage cache cannot publish a false empty snapshot"
        )
        let cachedForOriginalOwner = try await usageService.scan(
            period: .all,
            accountID: "account-1",
            force: true
        )
        try expect(
            cachedForOriginalOwner.total.total == 1500,
            "initial scan uses current session owner"
        )
        let inclusiveCachedRange = UsageDateRange(
            startInclusive: message.timestamp,
            endExclusive: message.timestamp.addingTimeInterval(1)
        )
        let cachedInsideRange = try await usageService.aggregateCached(
            range: inclusiveCachedRange,
            accountID: "account-1"
        )
        try expect(
            cachedInsideRange.total.total == 1500,
            "cached aggregation includes the exact range start"
        )
        let cachedOutsideRange = try await usageService.aggregateCached(
            range: UsageDateRange(
                startInclusive: message.timestamp.addingTimeInterval(1),
                endExclusive: nil
            ),
            accountID: "account-1"
        )
        try expect(
            cachedOutsideRange.total.total == 0,
            "cached aggregation applies a custom range"
        )

        let cancelledScan = Task {
            withUnsafeCurrentTask { task in
                task?.cancel()
            }
            return try await usageService.scan(
                period: .all,
                accountID: "account-1"
            )
        }
        var scanObservedCancellation = false
        do {
            _ = try await cancelledScan.value
        } catch is CancellationError {
            scanObservedCancellation = true
        }
        try expect(scanObservedCancellation, "usage scan observes task cancellation")

        let usageMigration = try cacheStore.prepareSessionForResume(
            sessionID: "session-1",
            expectedSourceUserID: "account-1",
            targetUserID: "account-2",
            restoreFromTrash: false
        )
        try expect(
            usageMigration.reassignedToCurrentAccount,
            "usage fixture migrates through the production session API"
        )
        let cachedAfterOwnerChange = try await usageService.aggregateCached(
            period: .all,
            accountID: "account-1"
        )
        try expect(
            cachedAfterOwnerChange.total.total == 0,
            "cached transcript drops the previous session owner"
        )
        let cachedForNewOwner = try await usageService.aggregateCached(
            period: .all,
            accountID: "account-2"
        )
        try expect(
            cachedForNewOwner.total.total == 1500,
            "cached transcript uses the latest session owner"
        )

        try expect(
            ManagedProvider.workBuddy.traeVariant == nil
                && ManagedProvider.traeCN.traeVariant == .china
                && ManagedProvider.traeWork.traeVariant == .work,
            "managed providers map to isolated Trae variants"
        )
        try expect(
            TraeVariant.china.provider == .traeCN
                && TraeVariant.work.provider == .traeWork,
            "Trae variants map back to their providers"
        )
        let traeProviderHome = directory.appendingPathComponent(
            "trae-provider-home",
            isDirectory: true
        )
        let expectedChinaStorageURL = traeProviderHome
            .appendingPathComponent(
                "Library/Application Support/Trae CN",
                isDirectory: true
            )
            .appendingPathComponent("User/globalStorage/storage.json")
        try expect(
            TraeDataLocation.resolve(
                .china,
                homeURL: traeProviderHome
            ).storageURL == expectedChinaStorageURL,
            "Trae CN resolves its own Application Support path"
        )
        let compatibilityWorkStorageURL = traeProviderHome
            .appendingPathComponent(
                "Library/Application Support/TRAE SOLO CN",
                isDirectory: true
            )
            .appendingPathComponent("User/globalStorage/storage.json")
        try TraeAtomicFile.write(
            Data("{}".utf8),
            to: compatibilityWorkStorageURL
        )
        try expect(
            TraeDataLocation.resolve(
                .work,
                homeURL: traeProviderHome
            ).storageURL == compatibilityWorkStorageURL,
            "TRAE Work resolves an installed compatibility data path"
        )

        let chinaSourceAuth = try fixtureTraeAuth(
            userID: "shared-fixture-user",
            token: "fixture-cn-source-token",
            host: "api.trae.cn",
            displayName: "CN Source",
            keyByte: 11
        )
        let decryptedChinaSource = try TraeByteCrypto.decrypt(chinaSourceAuth.blob)
        try expect(
            decryptedChinaSource == chinaSourceAuth.data,
            "Trae encrypted authentication round-trips"
        )
        let decodedChinaSource = try TraeByteCrypto.decodeJSON(chinaSourceAuth.blob)
        try expect(
            decodedChinaSource["userId"] as? String == "shared-fixture-user",
            "Trae encrypted authentication decodes user identity"
        )
        let chinaSourceStorage = try fixtureTraeStorage(
            authBlob: chinaSourceAuth.blob,
            userTag: "cn-source-tag",
            deviceSuffix: "cn-source-device",
            marker: "keep-cn-source-settings"
        )
        let capturedAt = Date(timeIntervalSince1970: 1_784_822_400)
        let chinaSourceResult = try TraeStorageCodec.readSnapshot(
            from: chinaSourceStorage,
            variant: .china,
            capturedAt: capturedAt
        )
        try expect(
            chinaSourceResult.snapshot.userID == "shared-fixture-user"
                && chinaSourceResult.snapshot.variant == .china,
            "Trae storage creates a variant-scoped credential snapshot"
        )
        try expect(
            chinaSourceResult.payload.displayName == "CN Source"
                && chinaSourceResult.payload.token == "fixture-cn-source-token",
            "Trae storage extracts account metadata"
        )

        let chinaTargetAuth = try fixtureTraeAuth(
            userID: "cn-target-user",
            token: "fixture-cn-target-token",
            host: "api.trae.cn",
            displayName: "CN Target",
            keyByte: 22
        )
        let chinaTargetSnapshot = TraeCredentialSnapshot(
            variant: .china,
            userID: "cn-target-user",
            authBlob: chinaTargetAuth.blob,
            userTagBlob: "cn-target-tag",
            deviceAuthBlobs: [
                "\(TraeStorageCodec.deviceAuthPrefix)cn-target-device":
                    "cn-target-device-value"
            ],
            capturedAt: capturedAt
        )
        let replacedStorage = try TraeStorageCodec.replacingAuthentication(
            in: chinaSourceStorage,
            with: chinaTargetSnapshot,
            variant: .china
        )
        guard
            let replacedObject = try JSONSerialization.jsonObject(
                with: replacedStorage
            ) as? [String: Any],
            let nestedSettings = replacedObject["fixture.nested.settings"]
                as? [String: Any]
        else {
            throw SelfTestFailure(
                message: "replaced Trae storage is not valid JSON",
                file: #filePath,
                line: #line
            )
        }
        try expect(
            replacedObject[TraeStorageCodec.authKey] as? String
                == chinaTargetAuth.blob,
            "Trae storage replaces the primary authentication key"
        )
        try expect(
            replacedObject[TraeStorageCodec.userTagKey] as? String
                == "cn-target-tag"
                && replacedObject[
                    "\(TraeStorageCodec.deviceAuthPrefix)cn-target-device"
                ] as? String == "cn-target-device-value",
            "Trae storage replaces related authentication keys"
        )
        try expect(
            replacedObject[TraeStorageCodec.serverDataKey] == nil
                && replacedObject[
                    "\(TraeStorageCodec.deviceAuthPrefix)cn-source-device"
                ] == nil,
            "Trae storage removes stale authentication keys"
        )
        try expect(
            replacedObject["fixture.settings.marker"] as? String
                == "keep-cn-source-settings"
                && (replacedObject["editor.fontSize"] as? NSNumber)?.intValue == 15
                && nestedSettings["theme"] as? String == "fixture-dark"
                && (nestedSettings["telemetry"] as? NSNumber)?.boolValue == false,
            "Trae storage preserves unrelated editor settings"
        )

        var rejectedCrossVariantSnapshot = false
        do {
            _ = try TraeStorageCodec.replacingAuthentication(
                in: chinaSourceStorage,
                with: chinaTargetSnapshot,
                variant: .work
            )
        } catch TraeSupportError.snapshotVariantMismatch {
            rejectedCrossVariantSnapshot = true
        }
        try expect(
            rejectedCrossVariantSnapshot,
            "Trae storage rejects cross-variant credential snapshots"
        )
        let safeTraeHost = try TraeOfficialHostPolicy.baseURL(
            rawHost: "api.trae.cn",
            variant: .china
        )
        try expect(
            safeTraeHost.scheme == "https" && safeTraeHost.host == "api.trae.cn",
            "Trae usage accepts an official provider host"
        )
        let legacyChinaTraeHost = try TraeOfficialHostPolicy.baseURL(
            rawHost: "api.trae.com.cn",
            variant: .china
        )
        try expect(
            legacyChinaTraeHost.scheme == "https"
                && legacyChinaTraeHost.host == "api.trae.com.cn",
            "Trae usage accepts the legacy official China host"
        )
        var rejectedUnsafeTraeHost = false
        do {
            _ = try TraeOfficialHostPolicy.baseURL(
                rawHost: "https://api.trae.cn.fixture.invalid",
                variant: .china
            )
        } catch TraeSupportError.unsafeAPIHost {
            rejectedUnsafeTraeHost = true
        }
        try expect(
            rejectedUnsafeTraeHost,
            "Trae usage rejects a credential-controlled unofficial host"
        )
        let defaultTraeHTTPClient = URLSessionTraeHTTPClient()
        try expect(
            defaultTraeHTTPClient.session.delegate
                is TraeRedirectPolicyDelegate,
            "Trae HTTP client installs the official-host redirect policy"
        )
        let safeRedirectRequest = URLRequest(
            url: URL(
                string: "https://api.trae.cn/trae/api/v1/pay/usage"
            )!
        )
        let unsafeRedirectRequest = URLRequest(
            url: URL(
                string: "https://api.trae.cn.fixture.invalid/steal"
            )!
        )
        try expect(
            TraeRedirectPolicyDelegate.allowedRedirectRequest(
                safeRedirectRequest
            ) != nil
                && TraeRedirectPolicyDelegate.allowedRedirectRequest(
                    unsafeRedirectRequest
                ) == nil,
            "Trae HTTP redirects cannot leave the official host allowlist"
        )
        let insecureRedirectRequest = URLRequest(
            url: URL(string: "http://api.trae.cn/trae/api/v1/pay/usage")!
        )
        let alternatePortRedirectRequest = URLRequest(
            url: URL(
                string: "https://api.trae.cn:444/trae/api/v1/pay/usage"
            )!
        )
        try expect(
            TraeRedirectPolicyDelegate.allowedRedirectRequest(
                insecureRedirectRequest
            ) == nil
                && TraeRedirectPolicyDelegate.allowedRedirectRequest(
                    alternatePortRedirectRequest
                ) == nil,
            "Trae HTTP redirects require HTTPS on the default secure port"
        )
        defaultTraeHTTPClient.session.invalidateAndCancel()

        let traeStoreDirectory = directory.appendingPathComponent(
            "trae-account-store",
            isDirectory: true
        )
        let chinaStorageURL = traeStoreDirectory
            .appendingPathComponent("china", isDirectory: true)
            .appendingPathComponent("storage.json")
        let workStorageURL = traeStoreDirectory
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("storage.json")
        let traeIndexURL = traeStoreDirectory.appendingPathComponent(
            "trae-accounts.json"
        )
        let workAuth = try fixtureTraeAuth(
            userID: "shared-fixture-user",
            token: "fixture-work-token",
            host: "grow-normal.trae.ai",
            displayName: "Work Source",
            keyByte: 33
        )
        let workStorage = try fixtureTraeStorage(
            authBlob: workAuth.blob,
            userTag: "work-source-tag",
            deviceSuffix: "work-source-device",
            marker: "keep-work-settings"
        )
        try TraeAtomicFile.write(chinaSourceStorage, to: chinaStorageURL)
        try TraeAtomicFile.write(workStorage, to: workStorageURL)

        let traeVault = FixtureTraeVault()
        let traeController = FixtureTraeApplicationController(
            installedVariants: Set(TraeVariant.allCases),
            runningVariants: [.china],
            launchFailuresRemaining: 1
        )
        let traeStore = TraeAccountStore(
            indexURL: traeIndexURL,
            vault: traeVault,
            controller: traeController,
            storageURL: { variant in
                variant == .china ? chinaStorageURL : workStorageURL
            }
        )
        let chinaProfile = try traeStore.captureCurrent(.china)
        let workProfile = try traeStore.captureCurrent(.work)
        try expect(
            chinaProfile.id == "china:shared-fixture-user"
                && workProfile.id == "work:shared-fixture-user"
                && chinaProfile.id != workProfile.id,
            "Trae account profiles namespace identical users by variant"
        )
        try expect(
            chinaSourceResult.snapshot.keychainAccount
                == "china:shared-fixture-user",
            "Trae credential snapshot uses a variant-scoped vault account"
        )
        try expect(
            traeVault.savedAccounts.contains("china:shared-fixture-user")
                && traeVault.savedAccounts.contains("work:shared-fixture-user"),
            "Trae vault keeps CN and Work snapshots in separate namespaces"
        )
        let initiallyStoredProfiles = traeStore.accounts
        try expect(
            Set(initiallyStoredProfiles.map(\.id)) == [
                "china:shared-fixture-user",
                "work:shared-fixture-user"
            ],
            "Trae account index retains both provider namespaces"
        )
        guard
            let indexObject = try JSONSerialization.jsonObject(
                with: Data(contentsOf: traeIndexURL)
            ) as? [String: Any],
            let indexedAccounts = indexObject["accounts"] as? [[String: Any]]
        else {
            throw SelfTestFailure(
                message: "Trae account index is not valid JSON",
                file: #filePath,
                line: #line
            )
        }
        try expect(
            Set(indexedAccounts.compactMap { $0["variant"] as? String })
                == ["china", "work"],
            "Trae account index serializes the provider namespace"
        )
        let reloadedTraeStore = TraeAccountStore(
            indexURL: traeIndexURL,
            vault: traeVault,
            controller: traeController,
            storageURL: { variant in
                variant == .china ? chinaStorageURL : workStorageURL
            }
        )
        let reloadedProfileIDs = reloadedTraeStore.accounts.map(\.id)
        try expect(
            Set(reloadedProfileIDs) == Set(initiallyStoredProfiles.map(\.id)),
            "Trae account index reload preserves namespaced profiles"
        )

        let chinaTargetStorage = try fixtureTraeStorage(
            authBlob: chinaTargetAuth.blob,
            userTag: "cn-target-tag",
            deviceSuffix: "cn-target-device",
            marker: "keep-cn-target-settings"
        )
        try TraeAtomicFile.write(chinaTargetStorage, to: chinaStorageURL)
        let currentTargetProfile = try traeStore.captureCurrent(.china)
        try expect(
            currentTargetProfile.id == "china:cn-target-user",
            "Trae account store captures the second CN account"
        )
        let storageBeforeFailedSwitch = try Data(contentsOf: chinaStorageURL)
        var observedLaunchFailure = false
        do {
            try await traeStore.switchAccount(to: chinaProfile)
        } catch FixtureTraeError.launchFailure {
            observedLaunchFailure = true
        }
        try expect(
            observedLaunchFailure,
            "Trae switch surfaces a launch failure after writing credentials"
        )
        let storageAfterFailedSwitch = try Data(contentsOf: chinaStorageURL)
        try expect(
            storageAfterFailedSwitch == storageBeforeFailedSwitch,
            "Trae switch restores the exact previous storage after failure"
        )
        let restoredTarget = try TraeStorageCodec.readSnapshot(
            from: storageAfterFailedSwitch,
            variant: .china
        )
        let currentUserIDAfterRollback = traeStore.currentUserID(for: .china)
        try expect(
            restoredTarget.snapshot.userID == "cn-target-user"
                && currentUserIDAfterRollback == "cn-target-user",
            "Trae switch rollback restores the previous current account"
        )
        try expect(
            traeStore.switchingVariant == nil,
            "Trae switch clears its in-progress state after rollback"
        )
        let launchCalls = traeController.launchCalls
        let stopCalls = traeController.stopCalls
        try expect(
            launchCalls == [.china, .china]
                && stopCalls == [.china, .china]
                && traeController.isRunning(.china),
            "Trae switch stops the target and relaunches the previous app during rollback"
        )
        let rollbackReloadedStore = TraeAccountStore(
            indexURL: traeIndexURL,
            vault: traeVault,
            controller: traeController,
            storageURL: { variant in
                variant == .china ? chinaStorageURL : workStorageURL
            }
        )
        let rollbackProfileIDs = rollbackReloadedStore.accounts.map(\.id)
        try expect(
            Set(rollbackProfileIDs) == [
                "china:shared-fixture-user",
                "china:cn-target-user",
                "work:shared-fixture-user"
            ],
            "Trae switch rollback leaves a readable namespaced account index"
        )

        let stopFlushDirectory = directory.appendingPathComponent(
            "trae-stop-flush",
            isDirectory: true
        )
        let stopFlushStorageURL = stopFlushDirectory.appendingPathComponent(
            "storage.json"
        )
        let stopFlushIndexURL = stopFlushDirectory.appendingPathComponent(
            "trae-accounts.json"
        )
        try TraeAtomicFile.write(chinaSourceStorage, to: stopFlushStorageURL)
        let stopFlushVault = FixtureTraeVault()
        let stopFlushController = FixtureTraeApplicationController(
            installedVariants: [.china],
            runningVariants: [.china],
            launchFailuresRemaining: 0
        )
        let stopFlushStore = TraeAccountStore(
            indexURL: stopFlushIndexURL,
            vault: stopFlushVault,
            controller: stopFlushController,
            storageURL: { _ in stopFlushStorageURL }
        )
        let stopFlushTargetProfile = try stopFlushStore.captureCurrent(.china)
        try TraeAtomicFile.write(chinaTargetStorage, to: stopFlushStorageURL)
        _ = try stopFlushStore.captureCurrent(.china)

        guard
            var postStopObject = try JSONSerialization.jsonObject(
                with: chinaTargetStorage
            ) as? [String: Any]
        else {
            throw SelfTestFailure(
                message: "post-stop Trae fixture is not valid JSON",
                file: #filePath,
                line: #line
            )
        }
        postStopObject["editor.exitFlush.marker"] = "written-during-stop"
        postStopObject["editor.exitFlush.settings"] = [
            "windowZoomLevel": 2,
            "recentProject": "/tmp/post-stop-project",
            "restoreWindows": true
        ]
        let postStopStorage = try JSONSerialization.data(
            withJSONObject: postStopObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        stopFlushController.setFirstStopAction {
            try TraeAtomicFile.write(
                postStopStorage,
                to: stopFlushStorageURL
            )
        }
        try await stopFlushStore.switchAccount(to: stopFlushTargetProfile)

        let switchedAfterStopData = try Data(contentsOf: stopFlushStorageURL)
        let switchedAfterStopSnapshot = try TraeStorageCodec.readSnapshot(
            from: switchedAfterStopData,
            variant: .china
        )
        guard
            let switchedAfterStopObject = try JSONSerialization.jsonObject(
                with: switchedAfterStopData
            ) as? [String: Any],
            let exitFlushSettings = switchedAfterStopObject[
                "editor.exitFlush.settings"
            ] as? [String: Any]
        else {
            throw SelfTestFailure(
                message: "switched post-stop Trae storage is not valid JSON",
                file: #filePath,
                line: #line
            )
        }
        try expect(
            switchedAfterStopSnapshot.snapshot.userID == "shared-fixture-user"
                && switchedAfterStopObject[TraeStorageCodec.authKey] as? String
                    == chinaSourceAuth.blob,
            "Trae switch applies target authentication after the app stops"
        )
        try expect(
            switchedAfterStopObject["editor.exitFlush.marker"] as? String
                == "written-during-stop"
                && (exitFlushSettings["windowZoomLevel"] as? NSNumber)?.intValue == 2
                && exitFlushSettings["recentProject"] as? String
                    == "/tmp/post-stop-project"
                && (exitFlushSettings["restoreWindows"] as? NSNumber)?.boolValue == true
                && switchedAfterStopObject["fixture.settings.marker"] as? String
                    == "keep-cn-target-settings",
            "Trae switch preserves settings flushed during stop"
        )
        try expect(
            stopFlushController.stopCalls == [.china]
                && stopFlushController.launchCalls == [.china]
                && stopFlushStore.currentUserID(for: .china)
                    == "shared-fixture-user",
            "Trae switch reads the stopped storage before one successful launch"
        )
        try await stopFlushStore.switchAccount(to: stopFlushTargetProfile)
        try expect(
            stopFlushController.stopCalls == [.china]
                && stopFlushController.launchCalls == [.china, .china],
            "Opening the current Trae account does not restart the application"
        )

        let traeUsageData = Data(
            """
            {
              "data": {
                "total_count": 5,
                "user_usage_group_by_sessions": [
                  {
                    "session_id": "trae-session-1",
                    "usage_time": 1784822400000,
                    "model_name": "claude-3-7-sonnet",
                    "mode": "Builder",
                    "amount_float": "2.5",
                    "cost_money_float": "0.04",
                    "extra_info": {
                      "input_token": "1200",
                      "output_token": 300,
                      "cache_read_token": 400,
                      "cache_write_token": 25
                    }
                  },
                  {
                    "session_id": "trae-session-1",
                    "usage_time": 1784822400000,
                    "model_name": "claude-3-7-sonnet",
                    "mode": "Builder",
                    "amount_float": "2.5",
                    "cost_money_float": "0.04",
                    "extra_info": {
                      "input_token": "1200",
                      "output_token": 300,
                      "cache_read_token": 400,
                      "cache_write_token": 25
                    }
                  },
                  {
                    "session_id": "trae-session-2",
                    "usage_time": "2026-07-23T17:00:00Z",
                    "model_name": "gemini-2.5-pro",
                    "mode": "Chat",
                    "amount_float": 1.25,
                    "dollar_float": 0.02,
                    "extra_info": {
                      "input_token": 100,
                      "output_token": "50"
                    }
                  },
                  {
                    "session_id": "outside-range",
                    "usage_time": 1784833200,
                    "model_name": "outside-model",
                    "mode": "Chat",
                    "amount_float": 99,
                    "extra_info": {
                      "input_token": 999,
                      "output_token": 999
                    }
                  },
                  {
                    "session_id": "invalid-without-time",
                    "model_name": "invalid-model",
                    "extra_info": { "input_token": 999999 }
                  }
                ]
              }
            }
            """.utf8
        )
        let traeUsagePage = try TraeAPIParser.parseUsagePage(traeUsageData)
        try expect(
            traeUsagePage.total == 5
                && traeUsagePage.hasExplicitTotal
                && traeUsagePage.rowCount == 5
                && traeUsagePage.invalidRowCount == 1
                && traeUsagePage.records.count == 4,
            "Trae usage parser preserves raw and invalid row counts"
        )
        try expect(
            traeUsagePage.records.first?.tokens.total == 1_925
                && traeUsagePage.records.first?.cost == 0.04,
            "Trae usage parser reads token and cost fields"
        )
        let traeUsageStart = Date(timeIntervalSince1970: 1_784_822_400)
        var traeUTCCalendar = Calendar(identifier: .gregorian)
        traeUTCCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let aggregatedTraeUsage = TraeUsageAggregator.aggregate(
            traeUsagePage.records,
            range: UsageDateRange(
                startInclusive: traeUsageStart,
                endExclusive: traeUsageStart.addingTimeInterval(2 * 3_600)
            ),
            calendar: traeUTCCalendar,
            capturedAt: capturedAt
        )
        try expect(
            aggregatedTraeUsage.total.input == 1_300
                && aggregatedTraeUsage.total.output == 350
                && aggregatedTraeUsage.total.cacheRead == 400
                && aggregatedTraeUsage.total.cacheWrite == 25
                && aggregatedTraeUsage.total.requestCount == 2,
            "Trae usage aggregates parsed token breakdowns"
        )
        try expect(
            aggregatedTraeUsage.total.total == 2_075
                && aggregatedTraeUsage.credits == 3.75
                && aggregatedTraeUsage.scannedFiles == 2,
            "Trae usage deduplicates records and applies the requested range"
        )
        try expect(
            aggregatedTraeUsage.daily.count == 1
                && aggregatedTraeUsage.hourly.count == 2
                && aggregatedTraeUsage.sessions.count == 2
                && aggregatedTraeUsage.models.count == 2,
            "Trae usage builds daily, hourly, session, and model summaries"
        )
        try expect(
            aggregatedTraeUsage.models.first?.model == "claude-3-7-sonnet"
                && aggregatedTraeUsage.sessions.first?.sessionID
                    == "trae-session-2",
            "Trae usage orders model credits and recent sessions"
        )

        let usageServiceAuth = try fixtureTraeAuth(
            userID: "usage-service-user",
            token: "usage-service-token",
            host: "api.trae.cn",
            displayName: "Usage Service",
            keyByte: 87
        )
        let usageServiceSnapshot = TraeCredentialSnapshot(
            variant: .china,
            userID: "usage-service-user",
            authBlob: usageServiceAuth.blob,
            userTagBlob: nil,
            deviceAuthBlobs: [:],
            capturedAt: capturedAt
        )
        let usageQueryStart: Int64 = 1_700_000_000
        let usageQueryEndExclusive: Int64 = 1_700_003_600
        let usageQueryRange = UsageDateRange(
            startInclusive: Date(timeIntervalSince1970: TimeInterval(usageQueryStart)),
            endExclusive: Date(
                timeIntervalSince1970: TimeInterval(usageQueryEndExclusive)
            )
        )
        let firstUsagePage = try fixtureTraeUsageResponse(
            total: 3,
            rows: [
                fixtureTraeUsageRow(
                    id: "page-1-a",
                    timestamp: usageQueryStart + 10
                ),
                fixtureTraeUsageRow(
                    id: "page-1-b",
                    timestamp: usageQueryStart + 20
                )
            ]
        )
        let secondUsagePage = try fixtureTraeUsageResponse(
            total: 3,
            rows: [
                fixtureTraeUsageRow(
                    id: "page-2-a",
                    timestamp: usageQueryStart + 30
                )
            ]
        )
        let pagedUsageClient = FixtureTraeHTTPClient(
            responses: [
                FixtureTraeHTTPResponse(data: firstUsagePage),
                FixtureTraeHTTPResponse(data: secondUsagePage)
            ]
        )
        let pagedUsageService = TraeUsageService(
            client: pagedUsageClient,
            usagePageSize: 2,
            paginationPageLimit: 5
        )
        let pagedUsage = try await pagedUsageService.fetchUsage(
            snapshot: usageServiceSnapshot,
            range: usageQueryRange
        )
        let pagedUsageRequests = await pagedUsageClient.capturedRequests()
        try expect(
            pagedUsage.scannedFiles == 3
                && pagedUsage.total.requestCount == 3
                && pagedUsageRequests.count == 2,
            "Trae usage pagination fetches every declared raw row"
        )
        let firstUsageRequestBody = try requestJSONBody(
            pagedUsageRequests[0]
        )
        let secondUsageRequestBody = try requestJSONBody(
            pagedUsageRequests[1]
        )
        try expect(
            (firstUsageRequestBody["start_time"] as? NSNumber)?.int64Value
                == usageQueryStart
                && (firstUsageRequestBody["end_time"] as? NSNumber)?.int64Value
                    == usageQueryEndExclusive - 1
                && (firstUsageRequestBody["page_num"] as? NSNumber)?.intValue
                    == 1
                && (secondUsageRequestBody["page_num"] as? NSNumber)?.intValue
                    == 2
                && pagedUsageRequests.allSatisfy {
                    $0.url?.path
                        == "/trae/api/v1/pay/query_user_usage_group_by_session"
                },
            "Trae usage-only refresh sends the selected Unix-second range without requesting quota"
        )

        let fractionalRangeClient = FixtureTraeHTTPClient(
            responses: [
                FixtureTraeHTTPResponse(
                    data: try fixtureTraeUsageResponse(
                        total: 1,
                        rows: [
                            fixtureTraeUsageRow(
                                id: "fractional-range",
                                timestamp: usageQueryStart + 1
                            )
                        ]
                    )
                )
            ]
        )
        let fractionalRangeService = TraeUsageService(
            client: fractionalRangeClient,
            usagePageSize: 2
        )
        let fractionalRangeUsage = try await fractionalRangeService.fetchUsage(
            snapshot: usageServiceSnapshot,
            range: UsageDateRange(
                startInclusive: Date(
                    timeIntervalSince1970: TimeInterval(usageQueryStart) + 0.2
                ),
                endExclusive: Date(
                    timeIntervalSince1970: TimeInterval(usageQueryStart) + 1.5
                )
            )
        )
        let fractionalRangeRequests = await fractionalRangeClient
            .capturedRequests()
        let fractionalRangeBody = try requestJSONBody(
            fractionalRangeRequests[0]
        )
        try expect(
            fractionalRangeUsage.scannedFiles == 1
                && (fractionalRangeBody["start_time"] as? NSNumber)?.int64Value
                    == usageQueryStart
                && (fractionalRangeBody["end_time"] as? NSNumber)?.int64Value
                    == usageQueryStart + 1,
            "Trae usage query includes the final Unix second of a fractional range"
        )

        let invalidUsagePage = try fixtureTraeUsageResponse(
            total: 2,
            rows: [
                fixtureTraeUsageRow(
                    id: "valid-row",
                    timestamp: usageQueryStart + 10
                ),
                ["session_id": "missing-usage-time"]
            ]
        )
        let invalidUsageClient = FixtureTraeHTTPClient(
            responses: [FixtureTraeHTTPResponse(data: invalidUsagePage)]
        )
        let invalidUsageService = TraeUsageService(
            client: invalidUsageClient,
            usagePageSize: 2
        )
        var rejectedInvalidUsageRowCount: Int?
        do {
            _ = try await invalidUsageService.fetchUsage(
                snapshot: usageServiceSnapshot,
                range: usageQueryRange
            )
        } catch TraeSupportError.invalidUsageRows(let count) {
            rejectedInvalidUsageRowCount = count
        }
        try expect(
            rejectedInvalidUsageRowCount == 1,
            "Trae usage rejects pages that would silently drop malformed rows"
        )

        let paginationLimitClient = FixtureTraeHTTPClient(
            responses: [
                FixtureTraeHTTPResponse(
                    data: try fixtureTraeUsageResponse(
                        total: 5,
                        rows: [
                            fixtureTraeUsageRow(
                                id: "limit-1-a",
                                timestamp: usageQueryStart + 10
                            ),
                            fixtureTraeUsageRow(
                                id: "limit-1-b",
                                timestamp: usageQueryStart + 20
                            )
                        ]
                    )
                ),
                FixtureTraeHTTPResponse(
                    data: try fixtureTraeUsageResponse(
                        total: 5,
                        rows: [
                            fixtureTraeUsageRow(
                                id: "limit-2-a",
                                timestamp: usageQueryStart + 30
                            ),
                            fixtureTraeUsageRow(
                                id: "limit-2-b",
                                timestamp: usageQueryStart + 40
                            )
                        ]
                    )
                )
            ]
        )
        let paginationLimitService = TraeUsageService(
            client: paginationLimitClient,
            usagePageSize: 2,
            paginationPageLimit: 2
        )
        var rejectedPaginationLimit: Int?
        do {
            _ = try await paginationLimitService.fetchUsage(
                snapshot: usageServiceSnapshot,
                range: usageQueryRange
            )
        } catch TraeSupportError.usagePaginationLimitExceeded(let limit) {
            rejectedPaginationLimit = limit
        }
        let paginationLimitRequestCount = await paginationLimitClient
            .requestCount()
        try expect(
            rejectedPaginationLimit == 2
                && paginationLimitRequestCount == 2,
            "Trae usage throws instead of returning partial data at the pagination limit"
        )

        let stalledUsageClient = FixtureTraeHTTPClient(
            responses: [
                FixtureTraeHTTPResponse(data: firstUsagePage),
                FixtureTraeHTTPResponse(
                    data: try fixtureTraeUsageResponse(total: 3, rows: [])
                )
            ]
        )
        let stalledUsageService = TraeUsageService(
            client: stalledUsageClient,
            usagePageSize: 2
        )
        var rejectedStalledPagination = false
        do {
            _ = try await stalledUsageService.fetchUsage(
                snapshot: usageServiceSnapshot,
                range: usageQueryRange
            )
        } catch TraeSupportError.usagePaginationStalled {
            rejectedStalledPagination = true
        }
        try expect(
            rejectedStalledPagination,
            "Trae usage rejects an empty page before the declared total"
        )

        let inconsistentTotalClient = FixtureTraeHTTPClient(
            responses: [
                FixtureTraeHTTPResponse(
                    data: try fixtureTraeUsageResponse(
                        total: 0,
                        rows: [
                            fixtureTraeUsageRow(
                                id: "unexpected-row",
                                timestamp: usageQueryStart + 10
                            )
                        ]
                    )
                )
            ]
        )
        let inconsistentTotalService = TraeUsageService(
            client: inconsistentTotalClient,
            usagePageSize: 2
        )
        var rejectedInconsistentTotal = false
        do {
            _ = try await inconsistentTotalService.fetchUsage(
                snapshot: usageServiceSnapshot,
                range: usageQueryRange
            )
        } catch TraeSupportError.inconsistentUsageTotal(
            expected: 0,
            received: 1
        ) {
            rejectedInconsistentTotal = true
        }
        try expect(
            rejectedInconsistentTotal,
            "Trae usage does not stop on an explicit zero total with nonempty rows"
        )

        let unsafeFinalURLClient = FixtureTraeHTTPClient(
            responses: [
                FixtureTraeHTTPResponse(
                    data: firstUsagePage,
                    responseURL: URL(
                        string: "https://fixture.invalid/redirected"
                    )!
                )
            ]
        )
        let unsafeFinalURLService = TraeUsageService(
            client: unsafeFinalURLClient,
            usagePageSize: 2
        )
        var rejectedUnsafeFinalURL = false
        do {
            _ = try await unsafeFinalURLService.fetchUsage(
                snapshot: usageServiceSnapshot,
                range: usageQueryRange
            )
        } catch TraeSupportError.unsafeAPIHost {
            rejectedUnsafeFinalURL = true
        }
        try expect(
            rejectedUnsafeFinalURL,
            "Trae usage revalidates the final response URL after redirects"
        )

        let traeQuotaData = Data(
            """
            {
              "data": {
                "entitlements": [
                  {
                    "entitlement_base_info": {
                      "user_id": "shared-fixture-user",
                      "product_type": 1,
                      "start_time": 1784822400,
                      "end_time": 1787500800,
                      "quota": {
                        "basic_usage_limit": 100,
                        "bonus_usage_limit": 20
                      }
                    },
                    "usage": {
                      "basic_usage_amount": 30,
                      "bonus_usage_amount": 5,
                      "pay_go_amount": 2
                    },
                    "next_billing_time": 1787500800
                  },
                  {
                    "entitlement_base_info": {
                      "user_id": "shared-fixture-user",
                      "product_type": 6,
                      "start_time": 1784822400,
                      "end_time": 1787500800,
                      "quota": {
                        "basic_usage_limit": -1,
                        "bonus_usage_limit": 0
                      }
                    },
                    "usage": {
                      "basic_usage_amount": 10,
                      "bonus_usage_amount": 0,
                      "pay_go_amount": 0.5
                    },
                    "next_billing_time": 1787500800
                  }
                ]
              }
            }
            """.utf8
        )
        let traeQuota = try TraeAPIParser.parseQuota(
            traeQuotaData,
            fallbackUserID: "fallback-user",
            capturedAt: capturedAt
        )
        try expect(
            traeQuota.sourceUserID == "shared-fixture-user"
                && traeQuota.used == 45
                && traeQuota.payGoUsed == 2.5,
            "Trae quota parser aggregates package usage"
        )
        try expect(
            traeQuota.isUnlimited
                && traeQuota.total == nil
                && traeQuota.unit == .credits
                && traeQuota.packageName == "Ultra",
            "Trae quota parser preserves unlimited plan semantics"
        )
        let legacyRequestQuotaData = Data(
            """
            {
              "data": {
                "entitlements": [
                  {
                    "entitlement_base_info": {
                      "user_id": "legacy-request-user",
                      "product_type": 1,
                      "quota": {
                        "premium_model_fast_request_limit": 10
                      }
                    },
                    "usage": {
                      "premium_model_fast_amount": 3
                    }
                  }
                ]
              }
            }
            """.utf8
        )
        let legacyRequestQuota = try TraeAPIParser.parseQuota(
            legacyRequestQuotaData,
            fallbackUserID: "fallback-user",
            capturedAt: capturedAt
        )
        try expect(
            legacyRequestQuota.sourceUserID == "legacy-request-user"
                && legacyRequestQuota.used == 3
                && legacyRequestQuota.total == 10
                && legacyRequestQuota.unit == .requests,
            "Trae quota parser supports legacy request-count plans"
        )

        // MARK: - 导入 / 导出账号备份：载荷核心（Phase 1）

        let backupDate = Date(timeIntervalSince1970: 1_750_000_000)

        let workBuddyBlob = Data(
            """
            {
              "account": { "uid": "wb-user-1", "nickname": "WB", "accountType": "pro" },
              "auth": { "accessToken": "wb-token" }
            }
            """.utf8
        )
        let chinaAuthFixture = try fixtureTraeAuth(
            userID: "t-user-1",
            token: "chn-token",
            host: "api.trae.cn",
            displayName: "Fixture CN",
            keyByte: 31
        )
        let workAuthFixture = try fixtureTraeAuth(
            userID: "t-user-2",
            token: "wrk-token",
            host: "grow-normal.trae.ai",
            displayName: "Fixture Work",
            keyByte: 32
        )
        let chinaSnapshot = TraeCredentialSnapshot(
            variant: .china,
            userID: try TraeStorageCodec.authPayload(from: chinaAuthFixture.blob).userID,
            authBlob: chinaAuthFixture.blob,
            userTagBlob: nil,
            deviceAuthBlobs: ["d": "x"],
            capturedAt: backupDate
        )
        let workSnapshot = TraeCredentialSnapshot(
            variant: .work,
            userID: try TraeStorageCodec.authPayload(from: workAuthFixture.blob).userID,
            authBlob: workAuthFixture.blob,
            userTagBlob: "tag",
            deviceAuthBlobs: [:],
            capturedAt: backupDate
        )

        func backupMetadata(
            _ id: String,
            nickname: String = "n"
        ) -> BackupAccountMetadata {
            BackupAccountMetadata(
                accountID: id,
                nickname: nickname,
                accountType: nil,
                phoneHint: nil,
                email: nil,
                avatarURL: nil,
                capturedAt: backupDate,
                lastUsedAt: backupDate
            )
        }

        // T-PL-01 / T-PL-02：三端混合记录往返与格式自描述
        let backupRecords: [BackupAccountRecord] = [
            BackupAccountRecord(
                provider: .workBuddy,
                metadata: backupMetadata("wb-user-1", nickname: "WB"),
                credential: .workBuddy(workBuddyBlob)
            ),
            BackupAccountRecord(
                provider: .traeCN,
                metadata: backupMetadata("t-user-1"),
                credential: .trae(chinaSnapshot)
            ),
            BackupAccountRecord(
                provider: .traeWork,
                metadata: backupMetadata("t-user-2"),
                credential: .trae(workSnapshot)
            )
        ]
        let backupEnvelope = BackupEnvelope(
            format: BackupEnvelope.currentFormat,
            version: BackupEnvelope.currentVersion,
            exportedAt: backupDate,
            accounts: backupRecords
        )
        let backupEncoder = JSONEncoder()
        backupEncoder.dateEncodingStrategy = .iso8601
        let backupDecoder = JSONDecoder()
        backupDecoder.dateDecodingStrategy = .iso8601
        let backupEnvelopeData = try backupEncoder.encode(backupEnvelope)
        let decodedBackupEnvelope = try backupDecoder.decode(
            BackupEnvelope.self,
            from: backupEnvelopeData
        )
        try expect(
            decodedBackupEnvelope == backupEnvelope,
            "backup envelope round-trips across providers"
        )
        try expect(
            decodedBackupEnvelope.format == "workbuddy-switch-accounts"
                && decodedBackupEnvelope.version == 1
                && decodedBackupEnvelope.exportedAt == backupDate,
            "backup envelope is self-describing (format/version/exportedAt)"
        )

        // T-VL-01：WorkBuddy 身份校验
        try expect(
            validateBackupRecord(
                BackupAccountRecord(
                    provider: .workBuddy,
                    metadata: backupMetadata("wb-user-1"),
                    credential: .workBuddy(workBuddyBlob)
                )
            ) == nil,
            "valid WorkBuddy record passes identity validation"
        )
        try expect(
            validateBackupRecord(
                BackupAccountRecord(
                    provider: .workBuddy,
                    metadata: backupMetadata("other-user"),
                    credential: .workBuddy(workBuddyBlob)
                )
            ) == .identityMismatch,
            "WorkBuddy credential identity mismatch is rejected"
        )
        try expect(
            validateBackupRecord(
                BackupAccountRecord(
                    provider: .workBuddy,
                    metadata: backupMetadata("wb-user-1"),
                    credential: .workBuddy(Data("not-json".utf8))
                )
            ) == .invalidCredential,
            "malformed WorkBuddy credential is rejected as invalid"
        )

        // T-VL-02：Trae 变体 / 账号 ID 校验与映射
        try expect(
            traeVariant(for: .traeCN) == .china
                && traeVariant(for: .traeWork) == .work
                && traeVariant(for: .workBuddy) == nil,
            "backup provider maps to the correct Trae variant"
        )
        try expect(
            validateBackupRecord(
                BackupAccountRecord(
                    provider: .traeCN,
                    metadata: backupMetadata("t-user-1"),
                    credential: .trae(chinaSnapshot)
                )
            ) == nil,
            "valid Trae CN record passes identity validation"
        )
        try expect(
            validateBackupRecord(
                BackupAccountRecord(
                    provider: .traeCN,
                    metadata: backupMetadata("t-user-1"),
                    credential: .trae(workSnapshot)
                )
            ) == .identityMismatch,
            "Trae variant mismatch is rejected"
        )
        try expect(
            validateBackupRecord(
                BackupAccountRecord(
                    provider: .traeWork,
                    metadata: backupMetadata("t-user-9"),
                    credential: .trae(workSnapshot)
                )
            ) == .identityMismatch,
            "Trae userID mismatch is rejected"
        )

        // T-VL-03：凭据内嵌身份（authBlob）与快照字段/元数据不一致 → 拒绝
        let spoofedSnapshot = TraeCredentialSnapshot(
            variant: .china,
            userID: "spoofed-user",
            authBlob: chinaAuthFixture.blob,
            userTagBlob: nil,
            deviceAuthBlobs: [:],
            capturedAt: backupDate
        )
        try expect(
            validateBackupRecord(
                BackupAccountRecord(
                    provider: .traeCN,
                    metadata: backupMetadata("spoofed-user"),
                    credential: .trae(spoofedSnapshot)
                )
            ) == .identityMismatch,
            "Trae authBlob inner identity must match the snapshot and metadata"
        )

        // T-VL-04：provider 与凭据类型错配 → 拒绝
        try expect(
            validateBackupRecord(
                BackupAccountRecord(
                    provider: .traeCN,
                    metadata: backupMetadata("wb-user-1"),
                    credential: .workBuddy(workBuddyBlob)
                )
            ) == .identityMismatch,
            "WorkBuddy credential under a Trae provider is rejected"
        )
        try expect(
            validateBackupRecord(
                BackupAccountRecord(
                    provider: .workBuddy,
                    metadata: backupMetadata("t-user-2"),
                    credential: .trae(workSnapshot)
                )
            ) == .identityMismatch,
            "Trae credential under the WorkBuddy provider is rejected"
        )

        // T-CF-01..03：冲突决策与索引合并
        try expect(
            backupImportAction(vaultHasRecord: true) == .skip
                && backupImportAction(vaultHasRecord: false) == .apply,
            "import skips only when the vault already has the account"
        )
        let localExistingMetadata = backupMetadata("wb-user-1", nickname: "本机昵称")
        let importedMetadata = backupMetadata("wb-user-1", nickname: "备份昵称")
        try expect(
            mergeIndexMetadata(existing: localExistingMetadata, imported: importedMetadata)
                == localExistingMetadata,
            "existing index metadata is preserved on import"
        )
        try expect(
            mergeIndexMetadata(existing: nil, imported: importedMetadata) == importedMetadata,
            "missing index metadata is appended from the import"
        )

        // MARK: - 导入 / 导出账号备份：加密文件编解码（Phase 2）

        let backupPayloadJSON = Data(
            "{\"format\":\"workbuddy-switch-accounts\",\"version\":1}".utf8
        )
        let backupFileA = try AccountBackupFile.encryptedFile(
            payloadJSON: backupPayloadJSON,
            password: "correct-horse-1"
        )
        let backupFileB = try AccountBackupFile.encryptedFile(
            payloadJSON: backupPayloadJSON,
            password: "correct-horse-1"
        )
        let decryptedBackup = try AccountBackupFile.decryptedPayload(
            fileData: backupFileA,
            password: "correct-horse-1"
        )
        try expect(
            decryptedBackup == backupPayloadJSON,
            "backup file round-trips with the correct password"
        )
        try expect(
            backupFileA != backupPayloadJSON,
            "backup file is not plaintext"
        )
        try expect(
            backupFileA != backupFileB,
            "repeated exports differ by random salt and nonce"
        )

        do {
            _ = try AccountBackupFile.decryptedPayload(
                fileData: backupFileA,
                password: "wrong-password-1"
            )
            try expect(false, "wrong password must be rejected")
        } catch let error as AccountBackupFileError {
            try expect(
                error == .authenticationFailed,
                "wrong password maps to authenticationFailed"
            )
        }

        var tamperedFile = backupFileA
        tamperedFile[tamperedFile.count - 1] ^= 0xFF
        do {
            _ = try AccountBackupFile.decryptedPayload(
                fileData: tamperedFile,
                password: "correct-horse-1"
            )
            try expect(false, "tampered ciphertext must be rejected")
        } catch let error as AccountBackupFileError {
            try expect(
                error == .authenticationFailed,
                "tampered ciphertext maps to authenticationFailed"
            )
        }

        var upgradedFile = backupFileA
        upgradedFile[upgradedFile.startIndex + 8] = 2
        do {
            _ = try AccountBackupFile.decryptedPayload(
                fileData: upgradedFile,
                password: "correct-horse-1"
            )
            try expect(false, "unsupported version must be rejected")
        } catch let error as AccountBackupFileError {
            try expect(
                error == .unsupportedVersion,
                "unsupported version maps to unsupportedVersion"
            )
        }

        var brokenMagicFile = backupFileA
        brokenMagicFile[brokenMagicFile.startIndex] = 0x00
        do {
            _ = try AccountBackupFile.decryptedPayload(
                fileData: brokenMagicFile,
                password: "correct-horse-1"
            )
            try expect(false, "broken magic must be rejected")
        } catch let error as AccountBackupFileError {
            try expect(
                error == .notABackupFile,
                "broken magic maps to notABackupFile"
            )
        }

        for brokenInput: Data in [
            Data(),
            Data(backupFileA.prefix(backupFileA.count - 20)),
            Data(backupFileA.prefix(backupFileA.count - 17))
        ] {
            do {
                _ = try AccountBackupFile.decryptedPayload(
                    fileData: brokenInput,
                    password: "correct-horse-1"
                )
                try expect(false, "truncated input must be rejected")
            } catch let error as AccountBackupFileError {
                try expect(
                    (
                        error == .malformed
                            || error == .notABackupFile
                            || error == .authenticationFailed
                    ),
                    "truncated input must be rejected with a readable error"
                )
            }
        }

        // MARK: - 导入 / 导出账号备份：编排与仓库集成（Phase 3）

        // T-GT-01：导入计数与分类（纯核心）
        let invalidIdentityRecord = BackupAccountRecord(
            provider: .traeCN,
            metadata: backupMetadata("phantom-user"),
            credential: .trae(chinaSnapshot)
        )
        let countSummary = AccountBackupCore.importSummary(
            records: [
                BackupAccountRecord(
                    provider: .traeWork,
                    metadata: backupMetadata("t-user-2"),
                    credential: .trae(workSnapshot)
                ),
                BackupAccountRecord(
                    provider: .traeCN,
                    metadata: backupMetadata("t-user-1"),
                    credential: .trae(chinaSnapshot)
                ),
                invalidIdentityRecord
            ],
            vaultStatus: { record in
                record.metadata.accountID == "t-user-1"
            },
            applyRecord: { _ in .inserted }
        )
        try expect(
            countSummary.imported == 1
                && countSummary.skipped == 1
                && countSummary.failed == 1
                && countSummary.failures.count == 1,
            "import summary tallies imported/skipped/failed correctly"
        )

        // T-GT-02：无账号导出被拦截（纯核心）
        do {
            _ = try AccountBackupCore.exportEnvelope(
                workBuddyItems: [],
                traeItems: []
            )
            try expect(false, "empty export must be rejected")
        } catch AccountBackupServiceError.emptyExport {
        }

        // T-ST-01/02/03：Trae 仓库端到端（FixtureTraeVault + 临时索引）
        let backupTraeDirectory = directory.appendingPathComponent(
            "backup-trae-store",
            isDirectory: true
        )
        let backupChinaStorageURL = backupTraeDirectory
            .appendingPathComponent("china", isDirectory: true)
            .appendingPathComponent("storage.json")
        let backupWorkStorageURL = backupTraeDirectory
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("storage.json")
        let backupTraeIndexURL = backupTraeDirectory.appendingPathComponent(
            "trae-accounts.json"
        )
        let backupChinaAuth = try fixtureTraeAuth(
            userID: "backup-china-user",
            token: "backup-china-token",
            host: "api.trae.cn",
            displayName: "Backup China",
            keyByte: 77
        )
        let backupWorkAuth = try fixtureTraeAuth(
            userID: "backup-work-user",
            token: "backup-work-token",
            host: "grow-normal.trae.ai",
            displayName: "Backup Work",
            keyByte: 78
        )
        try TraeAtomicFile.write(
            try fixtureTraeStorage(
                authBlob: backupChinaAuth.blob,
                userTag: "backup-china-tag",
                deviceSuffix: "backup-china-device",
                marker: "keep-backup-china"
            ),
            to: backupChinaStorageURL
        )
        try TraeAtomicFile.write(
            try fixtureTraeStorage(
                authBlob: backupWorkAuth.blob,
                userTag: "backup-work-tag",
                deviceSuffix: "backup-work-device",
                marker: "keep-backup-work"
            ),
            to: backupWorkStorageURL
        )
        let backupSourceVault = FixtureTraeVault()
        let backupSourceStore = TraeAccountStore(
            indexURL: backupTraeIndexURL,
            vault: backupSourceVault,
            controller: FixtureTraeApplicationController(
                installedVariants: Set(TraeVariant.allCases),
                runningVariants: [],
                launchFailuresRemaining: 0
            ),
            storageURL: { variant in
                variant == .china ? backupChinaStorageURL : backupWorkStorageURL
            }
        )
        _ = try backupSourceStore.captureCurrent(.china)
        _ = try backupSourceStore.captureCurrent(.work)

        let sourceItems = backupSourceStore.backupExportItems()
        try expect(
            sourceItems.count == 2
                && sourceItems.allSatisfy { $0.snapshot != nil },
            "backup export enumerates all Trae snapshots with credentials"
        )
        let exportBefore = backupSourceStore.accounts
        let (exportEnvelope, exportSummary) = try AccountBackupCore.exportEnvelope(
            workBuddyItems: [],
            traeItems: sourceItems
        )
        try expect(
            exportEnvelope.accounts.count == 2
                && exportSummary.totalExported == 2
                && exportSummary.skippedWithoutSnapshot == 0,
            "Trae export produces a complete envelope"
        )
        try expect(
            backupSourceStore.accounts == exportBefore
                && backupSourceVault.savedAccounts.count == 2,
            "export leaves the source vault and index untouched"
        )

        let backupTargetVault = FixtureTraeVault()
        let backupTargetStore = TraeAccountStore(
            indexURL: backupTraeIndexURL.appendingPathExtension("target"),
            vault: backupTargetVault,
            controller: FixtureTraeApplicationController(
                installedVariants: Set(TraeVariant.allCases),
                runningVariants: [],
                launchFailuresRemaining: 0
            ),
            storageURL: { variant in
                variant == .china ? backupChinaStorageURL : backupWorkStorageURL
            }
        )
        let firstImport = AccountBackupCore.importSummary(
            records: exportEnvelope.accounts,
            vaultStatus: { record in
                try backupTargetStore.hasSnapshot(
                    variant: record.provider == .traeCN ? .china : .work,
                    userID: record.metadata.accountID
                )
            },
            applyRecord: { record in
                let variant: TraeVariant = record.provider == .traeCN ? .china : .work
                return try backupTargetStore.importSnapshot(
                    profile: record.metadata.traeProfile(variant: variant),
                    snapshot: try record.credential.traeSnapshot()
                )
            }
        )
        try expect(
            firstImport.imported == 2
                && firstImport.skipped == 0
                && firstImport.failed == 0
                && Set(backupTargetStore.accounts.map(\.id))
                    == Set(exportBefore.map(\.id)),
            "import restores accounts into a fresh store"
        )
        let secondImport = AccountBackupCore.importSummary(
            records: exportEnvelope.accounts,
            vaultStatus: { record in
                try backupTargetStore.hasSnapshot(
                    variant: record.provider == .traeCN ? .china : .work,
                    userID: record.metadata.accountID
                )
            },
            applyRecord: { _ -> BackupImportApplyResult in
                throw SelfTestFailure(
                    message: "import must not re-apply skipped accounts",
                    file: #filePath,
                    line: #line
                )
            }
        )
        try expect(
            secondImport.skipped == 2 && secondImport.imported == 0,
            "re-import skips already-restored accounts"
        )

        // T-ST-03：个别账号写入失败 → 计入失败，其余成功（fresh store 验证真实落盘状态）
        let partialStoreVault = FixtureTraeVault()
        let partialStore = TraeAccountStore(
            indexURL: backupTraeIndexURL.appendingPathExtension("partial"),
            vault: partialStoreVault,
            controller: FixtureTraeApplicationController(
                installedVariants: Set(TraeVariant.allCases),
                runningVariants: [],
                launchFailuresRemaining: 0
            ),
            storageURL: { variant in
                variant == .china ? backupChinaStorageURL : backupWorkStorageURL
            }
        )
        let partialImport = AccountBackupCore.importSummary(
            records: exportEnvelope.accounts,
            vaultStatus: { record in
                try partialStore.hasSnapshot(
                    variant: record.provider == .traeCN ? .china : .work,
                    userID: record.metadata.accountID
                )
            },
            applyRecord: { record in
                if record.metadata.accountID == "backup-work-user" {
                    throw OpenUsageError.keychain("fixture failure")
                }
                let variant: TraeVariant = record.provider == .traeCN ? .china : .work
                return try partialStore.importSnapshot(
                    profile: record.metadata.traeProfile(variant: variant),
                    snapshot: try record.credential.traeSnapshot()
                )
            }
        )
        try expect(
            partialImport.imported == 1
                && partialImport.failed == 1
                && partialStore.accounts.count == 1,
            "a single failing account is tallied without blocking the rest in a fresh store"
        )

        // T-PROBE-01：存在性探测失败（钥匙串故障）→ 计入失败，绝不写入
        var probeAttempts = 0
        let probeFailureSummary = AccountBackupCore.importSummary(
            records: [exportEnvelope.accounts[0]],
            vaultStatus: { _ in
                probeAttempts += 1
                throw OpenUsageError.keychain("locked")
            },
            applyRecord: { _ -> BackupImportApplyResult in
                try expect(false, "applyRecord must not run when the probe fails")
                return .inserted
            }
        )
        try expect(
            probeFailureSummary.failed == 1
                && probeFailureSummary.imported == 0
                && probeFailureSummary.skipped == 0
                && probeAttempts == 1,
            "a failing existence probe is tallied as failure and never applied"
        )

        // T-INPUT-01：输入规模上限
        do {
            try validateAccountBackupInput(
                byteCount: AccountBackupInputLimits.maxFileBytes + 1,
                accountCount: 1
            )
            try expect(false, "oversized file must be rejected")
        } catch AccountBackupInputError.fileTooLarge {
        }
        do {
            try validateAccountBackupInput(
                byteCount: 1,
                accountCount: AccountBackupInputLimits.maxAccounts + 1
            )
            try expect(false, "too many accounts must be rejected")
        } catch AccountBackupInputError.tooManyAccounts {
        }
        try validateAccountBackupInput(byteCount: 1024, accountCount: 10)

        // T-ORPHAN-01：索引保存失败 → 补偿回滚本次新建的钥匙串项，不留幽灵账号
        let blockedIndexDirectory = backupTraeDirectory.appendingPathComponent(
            "blocked-index-dir",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: blockedIndexDirectory,
            withIntermediateDirectories: false
        )
        let orphanStoreVault = FixtureTraeVault()
        let orphanStore = TraeAccountStore(
            indexURL: blockedIndexDirectory,
            vault: orphanStoreVault,
            controller: FixtureTraeApplicationController(
                installedVariants: Set(TraeVariant.allCases),
                runningVariants: [],
                launchFailuresRemaining: 0
            ),
            storageURL: { variant in
                variant == .china ? backupChinaStorageURL : backupWorkStorageURL
            }
        )
        guard let chinaBackupRecord = exportEnvelope.accounts.first(
            where: { $0.provider == .traeCN }
        ) else {
            throw SelfTestFailure(
                message: "backup envelope must contain a Trae CN record",
                file: #filePath,
                line: #line
            )
        }
        do {
            try orphanStore.importSnapshot(
                profile: chinaBackupRecord.metadata.traeProfile(variant: .china),
                snapshot: try chinaBackupRecord.credential.traeSnapshot()
            )
            try expect(false, "index-save failure must surface as an import error")
        } catch {
            try expect(
                orphanStoreVault.snapshots.isEmpty
                    && orphanStoreVault.savedAccounts.isEmpty
                    && orphanStore.accounts.isEmpty,
                "failed import compensates the inserted Keychain item"
            )
        }

        // T-GT-01 补充：校验失败文案存在（K 的次数）
        try expect(
            countSummary.failures.first?.contains("身份") == true,
            "failed records carry a readable reason"
        )

        // T-CF-04：apply 返回 alreadyExists（TOCTOU duplicate）→ 计入跳过而非导入
        let duplicateHandling = AccountBackupCore.importSummary(
            records: [
                BackupAccountRecord(
                    provider: .traeWork,
                    metadata: backupMetadata("t-user-2"),
                    credential: .trae(workSnapshot)
                )
            ],
            vaultStatus: { _ in false },
            applyRecord: { _ in .alreadyExists }
        )
        try expect(
            duplicateHandling.imported == 0
                && duplicateHandling.skipped == 1
                && duplicateHandling.failed == 0,
            "apply-time duplicate is tallied as skipped"
        )

        // T-KDF-01：头部迭代次数解析与边界 + canonical 210k 兼容
        let kdf210kFile = try AccountBackupFile.encryptedFile(
            payloadJSON: backupPayloadJSON,
            password: "correct-horse-1",
            iterations: 210_000
        )
        let kdf210kDecrypted = try AccountBackupFile.decryptedPayload(
            fileData: kdf210kFile,
            password: "correct-horse-1"
        )
        try expect(
            kdf210kDecrypted == backupPayloadJSON,
            "canonical-minimum 210k v1 file still decrypts"
        )
        func withHeaderIterations(_ value: UInt32, in data: Data) -> Data {
            var copy = data
            let encoded = withUnsafeBytes(of: value.bigEndian) { Data($0) }
            copy.replaceSubrange(10..<14, with: encoded)
            return copy
        }
        for value: UInt32 in [209_999, 2_000_001] {
            do {
                _ = try AccountBackupFile.decryptedPayload(
                    fileData: withHeaderIterations(value, in: backupFileA),
                    password: "correct-horse-1"
                )
                try expect(false, "out-of-range iterations must be rejected")
            } catch let error as AccountBackupFileError {
                try expect(
                    error == .malformed,
                    "out-of-range iterations map to malformed"
                )
            }
        }
        do {
            _ = try AccountBackupFile.decryptedPayload(
                fileData: withHeaderIterations(2_000_000, in: backupFileA),
                password: "correct-horse-1"
            )
            try expect(false, "tampered in-range iterations must fail auth")
        } catch let error as AccountBackupFileError {
            try expect(
                error == .authenticationFailed,
                "in-range iterations pass the range guard then fail auth"
            )
        }

        print("OpenUsage self-test passed: \(assertions) assertions")
    }
}

private struct SelfTestFailure: LocalizedError {
    let message: String
    let file: String
    let line: UInt

    var errorDescription: String? {
        "\(file):\(line): \(message)"
    }
}

private struct FixtureTraeHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let responseURL: URL?

    init(
        data: Data,
        statusCode: Int = 200,
        responseURL: URL? = nil
    ) {
        self.data = data
        self.statusCode = statusCode
        self.responseURL = responseURL
    }
}

private enum FixtureTraeHTTPError: Error {
    case missingResponse
    case invalidResponse
    case missingRequestBody
}

private actor FixtureTraeHTTPClient: TraeHTTPClient {
    private var responses: [FixtureTraeHTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [FixtureTraeHTTPResponse]) {
        self.responses = responses
    }

    func data(
        for request: URLRequest
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !responses.isEmpty else {
            throw FixtureTraeHTTPError.missingResponse
        }
        let fixture = responses.removeFirst()
        guard
            let responseURL = fixture.responseURL ?? request.url,
            let response = HTTPURLResponse(
                url: responseURL,
                statusCode: fixture.statusCode,
                httpVersion: nil,
                headerFields: nil
            )
        else {
            throw FixtureTraeHTTPError.invalidResponse
        }
        return (fixture.data, response)
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }

    func requestCount() -> Int {
        requests.count
    }
}

private func requestJSONBody(_ request: URLRequest) throws -> [String: Any] {
    guard
        let body = request.httpBody,
        let object = try JSONSerialization.jsonObject(with: body)
            as? [String: Any]
    else {
        throw FixtureTraeHTTPError.missingRequestBody
    }
    return object
}

private func fixtureTraeUsageResponse(
    total: Int?,
    rows: [[String: Any]]
) throws -> Data {
    var payload: [String: Any] = [
        "user_usage_group_by_sessions": rows
    ]
    if let total {
        payload["total_count"] = total
    }
    return try JSONSerialization.data(
        withJSONObject: ["data": payload],
        options: [.sortedKeys]
    )
}

private func fixtureTraeUsageRow(
    id: String,
    timestamp: Int64,
    input: Int = 10,
    output: Int = 5
) -> [String: Any] {
    [
        "session_id": id,
        "usage_time": timestamp,
        "model_name": "fixture-model",
        "mode": "Chat",
        "amount_float": 1,
        "extra_info": [
            "input_token": input,
            "output_token": output
        ]
    ]
}

private func fixtureTraeAuth(
    userID: String,
    token: String,
    host: String,
    displayName: String,
    keyByte: UInt8
) throws -> (data: Data, blob: String) {
    let object: [String: Any] = [
        "token": token,
        "refreshToken": "\(token)-refresh",
        "userId": userID,
        "host": host,
        "userRegion": "fixture",
        "account": [
            "name": displayName,
            "email": "\(userID)@fixture.invalid",
            "avatarUrl": "https://fixture.invalid/avatar.png"
        ]
    ]
    let data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    )
    let randomKey = Data(
        (0..<32).map { UInt8((Int(keyByte) + $0) % 256) }
    )
    return (
        data,
        try TraeByteCrypto.encodeForTesting(data, randomKey: randomKey)
    )
}

private func fixtureTraeStorage(
    authBlob: String,
    userTag: String,
    deviceSuffix: String,
    marker: String
) throws -> Data {
    let object: [String: Any] = [
        TraeStorageCodec.authKey: authBlob,
        TraeStorageCodec.userTagKey: userTag,
        TraeStorageCodec.serverDataKey: "server-\(marker)",
        "\(TraeStorageCodec.deviceAuthPrefix)\(deviceSuffix)":
            "device-\(marker)",
        "editor.fontSize": 15,
        "fixture.settings.marker": marker,
        "fixture.nested.settings": [
            "theme": "fixture-dark",
            "telemetry": false
        ]
    ]
    return try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys]
    )
}

private final class FixtureTraeVault: TraeCredentialVaulting, @unchecked Sendable {
    private(set) var snapshots: [String: TraeCredentialSnapshot] = [:]
    private(set) var savedAccounts = Set<String>()

    func save(_ snapshot: TraeCredentialSnapshot) throws {
        snapshots[snapshot.keychainAccount] = snapshot
        savedAccounts.insert(snapshot.keychainAccount)
    }

    func load(
        variant: TraeVariant,
        userID: String
    ) throws -> TraeCredentialSnapshot {
        guard let snapshot = snapshots["\(variant.rawValue):\(userID)"] else {
            throw TraeSupportError.accountSnapshotMissing
        }
        return snapshot
    }

    func probeExistence(variant: TraeVariant, userID: String) throws -> Bool {
        snapshots["\(variant.rawValue):\(userID)"] != nil
    }

    func insertIfAbsent(_ snapshot: TraeCredentialSnapshot) throws -> Bool {
        guard snapshots[snapshot.keychainAccount] == nil else { return false }
        snapshots[snapshot.keychainAccount] = snapshot
        savedAccounts.insert(snapshot.keychainAccount)
        return true
    }

    func delete(variant: TraeVariant, userID: String) throws {
        snapshots.removeValue(forKey: "\(variant.rawValue):\(userID)")
        savedAccounts.remove("\(variant.rawValue):\(userID)")
    }
}

private enum FixtureTraeError: Error {
    case launchFailure
}

@MainActor
private final class FixtureTraeApplicationController: TraeApplicationControlling {
    private let installedVariants: Set<TraeVariant>
    private var runningVariants: Set<TraeVariant>
    private var launchFailuresRemaining: Int
    private var firstStopAction: (@MainActor () throws -> Void)?
    private(set) var stopCalls: [TraeVariant] = []
    private(set) var launchCalls: [TraeVariant] = []

    init(
        installedVariants: Set<TraeVariant>,
        runningVariants: Set<TraeVariant>,
        launchFailuresRemaining: Int
    ) {
        self.installedVariants = installedVariants
        self.runningVariants = runningVariants
        self.launchFailuresRemaining = launchFailuresRemaining
    }

    func setFirstStopAction(
        _ action: @escaping @MainActor () throws -> Void
    ) {
        firstStopAction = action
    }

    func applicationURL(for variant: TraeVariant) -> URL? {
        guard installedVariants.contains(variant) else { return nil }
        return URL(fileURLWithPath: "/Applications/\(variant.displayName).app")
    }

    func isRunning(_ variant: TraeVariant) -> Bool {
        runningVariants.contains(variant)
    }

    func stop(_ variant: TraeVariant) async throws {
        stopCalls.append(variant)
        runningVariants.remove(variant)
        if let firstStopAction {
            self.firstStopAction = nil
            try firstStopAction()
        }
    }

    func launch(_ variant: TraeVariant) async throws {
        launchCalls.append(variant)
        if launchFailuresRemaining > 0 {
            launchFailuresRemaining -= 1
            throw FixtureTraeError.launchFailure
        }
        runningVariants.insert(variant)
    }
}
