using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using DueBridge.Core;

namespace DueBridge.Outlook;

public sealed class OutlookCalendar(HttpClient httpClient,
    Func<OutlookAccount, CancellationToken, Task<string>> getAccessToken, TimeProvider? timeProvider = null)
{
    private const string CalendarProperty = "String {7ce84863-2e9c-4f3e-8de7-c4fa72916a44} Name DueBridgeCalendar";
    private const string EntryProperty = "String {7ce84863-2e9c-4f3e-8de7-c4fa72916a44} Name DueBridgeEntry";
    private const string CalendarMarker = "1";
    private const string CalendarPath = "me/calendars";
    private const string CalendarFields = "id,isDefaultCalendar,isSharedWithMe,canEdit";
    private const string EventFields = "id,subject,start,end,isAllDay,showAs,isReminderOn,attendees,isOnlineMeeting,transactionId";

    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly TimeProvider clock = timeProvider ?? TimeProvider.System;
    private readonly GraphTransport graph = new(httpClient, timeProvider ?? TimeProvider.System);

    public static HttpClient CreateHttpClient() => new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false
    })
    {
        Timeout = TimeSpan.FromSeconds(25),
        MaxResponseContentBufferSize = 8 * 1024 * 1024
    };

    public async Task<OutlookCalendarBinding> CreateCalendarAsync(OutlookAccount account,
        CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var token = await TokenAsync(account, cancellationToken).ConfigureAwait(false);
            var existing = await FindCalendarAsync(token, cancellationToken).ConfigureAwait(false);
            if (existing is not null)
                return new OutlookCalendarBinding(account, existing);

            var payload = new
            {
                name = "DueBridge",
                singleValueExtendedProperties = new[] { new { id = CalendarProperty, value = CalendarMarker } }
            };
            var endpoint = new Uri(GraphTransport.Root, CalendarPath);
            try
            {
                var created = await graph.SendAsync(HttpMethod.Post, endpoint, token, payload, cancellationToken)
                    .ConfigureAwait(false);
                return new OutlookCalendarBinding(account, Id(created));
            }
            catch (OutlookException error) when (IsAmbiguousWrite(error))
            {
                var recovered = await FindCalendarAsync(token, cancellationToken).ConfigureAwait(false);
                if (recovered is null) throw;
                return new OutlookCalendarBinding(account, recovered);
            }
        }
        finally { gate.Release(); }
    }

    public async Task<CalendarSyncResult> SyncAsync(OutlookCalendarBinding binding,
        IReadOnlyList<CalendarEntry> entries, CancellationToken cancellationToken = default)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var calendarPath = $"{CalendarPath}/{EscapeId(binding.CalendarId)}";
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var transactions = new Dictionary<Guid, string>();
            var snapshot = new List<(CalendarEntry Entry, string Marker, GraphEvent Desired, Guid Transaction)>(entries.Count);
            foreach (var entry in entries)
            {
                if (string.IsNullOrWhiteSpace(entry.Key))
                    throw new OutlookException(OutlookFailure.ConflictingEvents);
                var marker = Convert.ToHexString(Hash(entry.Key));
                if (!seen.Add(marker))
                    throw new OutlookException(OutlookFailure.ConflictingEvents);
                var transaction = new Guid(Hash($"{binding.CalendarId}\n{marker}").AsSpan(0, 16));
                if (!transactions.TryAdd(transaction, marker))
                    throw new OutlookException(OutlookFailure.ConflictingEvents);
                snapshot.Add((entry, marker, new GraphEvent(entry), transaction));
            }
            var token = await TokenAsync(binding.Account, cancellationToken).ConfigureAwait(false);
            var target = new Uri(GraphTransport.Root, $"{calendarPath}?{SelectAndExpand(CalendarFields, CalendarProperty)}");
            var calendar = await graph.SendAsync(HttpMethod.Get, target, token, null, cancellationToken).ConfigureAwait(false);
            if (Id(calendar) != binding.CalendarId || Marker(calendar, CalendarProperty) != CalendarMarker)
                throw new OutlookException(OutlookFailure.CalendarMissing);
            EnsureWritableDedicatedCalendar(calendar);
            cancellationToken.ThrowIfCancellationRequested();
            if (snapshot.Count == 0)
                return new CalendarSyncResult(0, 0, 0);

            var path = $"{calendarPath}/events";
            var endpoint = new Uri(GraphTransport.Root, path);
            var list = Collection(path, EventFields, EntryProperty);
            var existing = await FindEventsAsync(list, seen, transactions, token, cancellationToken).ConfigureAwait(false);
            var now = clock.GetUtcNow();
            int added = 0, updated = 0, unchanged = 0;
            foreach (var (entry, marker, desired, transaction) in snapshot)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!desired.HasDeadline && !entry.Cancelled)
                {
                    unchanged++;
                }
                else if (existing.TryGetValue(marker, out var current))
                {
                    if (await UpdateIfChangedAsync(endpoint, current, desired, token, cancellationToken).ConfigureAwait(false))
                        updated++;
                    else
                        unchanged++;
                }
                else if (!desired.HasDeadline || entry.Cancelled || DeadlinePresentation.IsBeforeToday(entry, now))
                {
                    unchanged++;
                }
                else
                {
                    var payload = desired.ManagedFields();
                    payload["attendees"] = Array.Empty<object>();
                    payload["isOnlineMeeting"] = false;
                    payload["body"] = new { contentType = "text", content = entry.Notes };
                    payload["singleValueExtendedProperties"] = new[] { new { id = EntryProperty, value = marker } };
                    payload["transactionId"] = transaction.ToString();
                    try
                    {
                        var created = await graph.SendAsync(HttpMethod.Post, endpoint, token, payload, cancellationToken)
                            .ConfigureAwait(false);
                        _ = Id(created);
                    }
                    catch (OutlookException error) when (IsAmbiguousWrite(error))
                    {
                        existing = await FindEventsAsync(list, seen, transactions, token, cancellationToken).ConfigureAwait(false);
                        if (!existing.TryGetValue(marker, out var recovered)) throw;
                        await UpdateIfChangedAsync(endpoint, recovered, desired, token, cancellationToken).ConfigureAwait(false);
                    }
                    added++;
                }
            }
            return new CalendarSyncResult(added, updated, unchanged);
        }
        finally { gate.Release(); }
    }

    private async Task<bool> UpdateIfChangedAsync(Uri endpoint, JsonElement existing, GraphEvent desired,
        string token, CancellationToken cancellationToken)
    {
        if (desired.Matches(existing))
            return false;
        // Editing a meeting can send attendee notifications even when the PATCH omits attendees.
        if (!GraphEvent.IsSafeToUpdate(existing))
            throw new OutlookException(OutlookFailure.ConflictingEvents);
        var item = new Uri(endpoint.AbsoluteUri + "/" + EscapeId(Id(existing)));
        await graph.SendAsync(HttpMethod.Patch, item, token, desired.ManagedFields(), cancellationToken).ConfigureAwait(false);
        return true;
    }

    private async Task<string?> FindCalendarAsync(string token, CancellationToken cancellationToken)
    {
        string? id = null;
        var endpoint = Collection(CalendarPath, CalendarFields, CalendarProperty);
        await foreach (var calendar in graph.ListAsync(endpoint, token, cancellationToken).ConfigureAwait(false))
        {
            if (Marker(calendar, CalendarProperty) != CalendarMarker)
                continue;
            var candidate = Id(calendar);
            EnsureWritableDedicatedCalendar(calendar);
            if (id is not null && id != candidate)
                throw new OutlookException(OutlookFailure.ConflictingEvents);
            id = candidate;
        }
        return id;
    }

    private static void EnsureWritableDedicatedCalendar(JsonElement calendar)
    {
        if (!GraphEvent.FlagIs(calendar, "isDefaultCalendar", false) ||
            !GraphEvent.FlagIs(calendar, "isSharedWithMe", false) || !GraphEvent.FlagIs(calendar, "canEdit", true))
            throw new OutlookException(OutlookFailure.PermissionDenied);
    }

    private async Task<Dictionary<string, JsonElement>> FindEventsAsync(Uri endpoint, HashSet<string> wanted,
        Dictionary<Guid, string> transactions, string token, CancellationToken cancellationToken)
    {
        var events = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        await foreach (var item in graph.ListAsync(endpoint, token, cancellationToken).ConfigureAwait(false))
        {
            var marker = Marker(item, EntryProperty);
            if (Guid.TryParse(GraphTransport.Text(item, "transactionId"), out var transaction) &&
                transactions.TryGetValue(transaction, out var expected) && marker != expected)
                throw new OutlookException(OutlookFailure.ConflictingEvents);
            if (marker is null || !wanted.Contains(marker))
                continue;
            var id = Id(item);
            if (!events.TryAdd(marker, item) && Id(events[marker]) != id)
                throw new OutlookException(OutlookFailure.ConflictingEvents);
        }
        return events;
    }

    private static string? Marker(JsonElement item, string expected)
    {
        if (!item.TryGetProperty("singleValueExtendedProperties", out var properties) || properties.ValueKind == JsonValueKind.Null)
            return null;
        if (properties.ValueKind != JsonValueKind.Array)
            throw GraphTransport.Unexpected();
        string? found = null;
        foreach (var property in properties.EnumerateArray())
        {
            if (property.ValueKind != JsonValueKind.Object)
                throw GraphTransport.Unexpected();
            if (!string.Equals(GraphTransport.Text(property, "id"), expected, StringComparison.OrdinalIgnoreCase))
                continue;
            if (found is not null)
                throw GraphTransport.Unexpected();
            found = GraphTransport.Text(property, "value") ?? throw GraphTransport.Unexpected();
        }
        return found;
    }

    private static Uri Collection(string path, string fields, string property)
        => new(GraphTransport.Root, $"{path}?$top=100&{SelectAndExpand(fields, property)}");

    private static string SelectAndExpand(string fields, string property)
        => $"$select={fields}&$expand=" + Uri.EscapeDataString($"singleValueExtendedProperties($filter=id eq '{property}')");

    private async Task<string> TokenAsync(OutlookAccount account, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrWhiteSpace(account.HomeAccountId))
            throw new OutlookException(OutlookFailure.SignInRequired);
        var token = await getAccessToken(account, cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrWhiteSpace(token))
            throw new OutlookException(OutlookFailure.SignInRequired);
        return token;
    }

    private static bool IsAmbiguousWrite(OutlookException error)
        => error.Failure is OutlookFailure.Unavailable or OutlookFailure.UnexpectedResponse or OutlookFailure.ConflictingEvents;

    private static byte[] Hash(string value) => SHA256.HashData(Encoding.UTF8.GetBytes(value));
    private static string Id(JsonElement item)
    {
        var id = GraphTransport.Text(item, "id");
        return string.IsNullOrWhiteSpace(id) || id is "." or ".." || id.Any(char.IsControl)
            ? throw GraphTransport.Unexpected()
            : id;
    }

    private static string EscapeId(string id)
        => string.IsNullOrWhiteSpace(id) || id is "." or ".." || id.Any(char.IsControl)
            ? throw GraphTransport.Unexpected()
            : Uri.EscapeDataString(id);
}
