using Microsoft.Data.Sqlite;

namespace NetworkMonitor.Core;

public sealed class UsageStore
{
    private readonly string _connectionString;

    public UsageStore(string databasePath)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(databasePath)!);
        _connectionString = new SqliteConnectionStringBuilder { DataSource = databasePath, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = true }.ToString();
    }

    public async Task InitializeAsync(CancellationToken cancellationToken = default)
    {
        await using var connection = new SqliteConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            PRAGMA journal_mode=WAL;
            PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS SchemaMigrations (Version INTEGER PRIMARY KEY, AppliedUtc TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS Interfaces (
                InterfaceId TEXT PRIMARY KEY, Luid TEXT NOT NULL, Name TEXT NOT NULL,
                Description TEXT NOT NULL, Kind INTEGER NOT NULL, IsHardware INTEGER NOT NULL,
                FirstSeenUtc TEXT NOT NULL, LastSeenUtc TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS UsageBuckets (
                InterfaceId TEXT NOT NULL, LocalDay TEXT NOT NULL, TimeZoneId TEXT NOT NULL,
                BucketHourUtc TEXT NOT NULL, DownloadBytes INTEGER NOT NULL, UploadBytes INTEGER NOT NULL,
                Quality INTEGER NOT NULL,
                PRIMARY KEY (InterfaceId, LocalDay, TimeZoneId, BucketHourUtc),
                FOREIGN KEY (InterfaceId) REFERENCES Interfaces(InterfaceId)
            );
            CREATE INDEX IF NOT EXISTS IX_UsageBuckets_Day ON UsageBuckets(LocalDay, InterfaceId);
            INSERT OR IGNORE INTO SchemaMigrations(Version, AppliedUtc) VALUES (1, strftime('%Y-%m-%dT%H:%M:%fZ','now'));
            """;
        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    public async Task RecordBatchAsync(IReadOnlyList<(InterfaceSnapshot Snapshot, UsageDelta? Delta)> records, CancellationToken cancellationToken = default)
    {
        await using var connection = new SqliteConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);
        foreach (var (snapshot, delta) in records)
        {
            var now = snapshot.CapturedAtUtc;
            await using (var upsertInterface = connection.CreateCommand())
            {
                upsertInterface.Transaction = (SqliteTransaction)transaction;
                upsertInterface.CommandText = """
                INSERT INTO Interfaces(InterfaceId,Luid,Name,Description,Kind,IsHardware,FirstSeenUtc,LastSeenUtc)
                VALUES($id,$luid,$name,$description,$kind,$hardware,$now,$now)
                ON CONFLICT(InterfaceId) DO UPDATE SET Luid=excluded.Luid, Name=excluded.Name,
                  Description=excluded.Description, Kind=excluded.Kind, IsHardware=excluded.IsHardware, LastSeenUtc=excluded.LastSeenUtc;
                """;
                upsertInterface.Parameters.AddWithValue("$id", snapshot.Id.ToString("D"));
                upsertInterface.Parameters.AddWithValue("$luid", snapshot.Luid.ToString(System.Globalization.CultureInfo.InvariantCulture));
                upsertInterface.Parameters.AddWithValue("$name", snapshot.Name);
                upsertInterface.Parameters.AddWithValue("$description", snapshot.Description);
                upsertInterface.Parameters.AddWithValue("$kind", (int)snapshot.Kind);
                upsertInterface.Parameters.AddWithValue("$hardware", snapshot.IsHardware ? 1 : 0);
                upsertInterface.Parameters.AddWithValue("$now", now.ToUniversalTime().ToString("O"));
                await upsertInterface.ExecuteNonQueryAsync(cancellationToken);
            }

            if (delta is not null)
            {
                var localEnd = TimeZoneInfo.ConvertTime(delta.EndUtc, TimeZoneInfo.Local);
                var localStart = TimeZoneInfo.ConvertTime(delta.StartUtc, TimeZoneInfo.Local);
                var quality = delta.Quality;
                var startUtc = delta.StartUtc.ToUniversalTime();
                var endUtc = delta.EndUtc.ToUniversalTime();
                if (localStart.Date != localEnd.Date || startUtc.Hour != endUtc.Hour || startUtc.Day != endUtc.Day)
                    quality = (InterfaceQuality)Math.Max((int)quality, (int)InterfaceQuality.Reconciled);
                await using var usage = connection.CreateCommand();
                usage.Transaction = (SqliteTransaction)transaction;
                usage.CommandText = """
                INSERT INTO UsageBuckets(InterfaceId,LocalDay,TimeZoneId,BucketHourUtc,DownloadBytes,UploadBytes,Quality)
                VALUES($id,$day,$zone,$end,$download,$upload,$quality)
                ON CONFLICT(InterfaceId,LocalDay,TimeZoneId,BucketHourUtc) DO UPDATE SET
                  DownloadBytes=DownloadBytes+excluded.DownloadBytes,
                  UploadBytes=UploadBytes+excluded.UploadBytes,
                  Quality=MAX(Quality,excluded.Quality);
                """;
                usage.Parameters.AddWithValue("$id", delta.InterfaceId.ToString("D"));
                usage.Parameters.AddWithValue("$day", localEnd.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture));
                usage.Parameters.AddWithValue("$zone", TimeZoneInfo.Local.Id);
                var utc = delta.EndUtc.ToUniversalTime();
                var hour = new DateTimeOffset(utc.Year, utc.Month, utc.Day, utc.Hour, 0, 0, TimeSpan.Zero);
                usage.Parameters.AddWithValue("$end", hour.ToString("O"));
                usage.Parameters.AddWithValue("$download", checked((long)delta.DownloadBytes));
                usage.Parameters.AddWithValue("$upload", checked((long)delta.UploadBytes));
                usage.Parameters.AddWithValue("$quality", (int)quality);
                await usage.ExecuteNonQueryAsync(cancellationToken);
            }
        }
        await transaction.CommitAsync(cancellationToken);
    }

    public async Task<IReadOnlyDictionary<string, (long Download, long Upload)>> GetMonthByDayAsync(
        DateOnly month, CancellationToken cancellationToken = default)
    {
        var firstDay = new DateOnly(month.Year, month.Month, 1).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        var afterMonth = new DateOnly(month.Year, month.Month, 1).AddMonths(1).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        var result = new Dictionary<string, (long Download, long Upload)>();
        await using var connection = new SqliteConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT u.LocalDay, SUM(u.DownloadBytes), SUM(u.UploadBytes)
            FROM UsageBuckets u JOIN Interfaces i ON i.InterfaceId=u.InterfaceId
            WHERE u.LocalDay >= $first AND u.LocalDay < $after
              AND i.IsHardware=1 AND i.Kind IN ($wifi,$ethernet)
            GROUP BY u.LocalDay ORDER BY u.LocalDay
            """;
        command.Parameters.AddWithValue("$first", firstDay);
        command.Parameters.AddWithValue("$after", afterMonth);
        command.Parameters.AddWithValue("$wifi", (int)InterfaceKind.WiFi);
        command.Parameters.AddWithValue("$ethernet", (int)InterfaceKind.Ethernet);
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken)) result[reader.GetString(0)] = (reader.GetInt64(1), reader.GetInt64(2));
        return result;
    }

    public async Task<IReadOnlyDictionary<Guid, (long Download, long Upload)>> GetLifetimeByInterfaceAsync(
        CancellationToken cancellationToken = default)
    {
        var result = new Dictionary<Guid, (long Download, long Upload)>();
        await using var connection = new SqliteConnection(_connectionString);
        await connection.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT InterfaceId, SUM(DownloadBytes), SUM(UploadBytes) FROM UsageBuckets GROUP BY InterfaceId";
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            if (Guid.TryParse(reader.GetString(0), out var id))
                result[id] = (reader.GetInt64(1), reader.GetInt64(2));
        }
        return result;
    }
}
