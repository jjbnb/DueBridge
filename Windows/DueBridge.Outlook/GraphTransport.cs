using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Text.Json;

namespace DueBridge.Outlook;

internal sealed class GraphTransport(HttpClient http, TimeProvider clock)
{
    internal static readonly Uri Root = new("https://graph.microsoft.com/v1.0/");
    private static readonly TimeSpan MaximumRetryDelay = TimeSpan.FromSeconds(30);
    private const int MaximumPages = 200;
    private DateTimeOffset retryAfterUtc;

    internal async IAsyncEnumerable<JsonElement> ListAsync(Uri firstPage, string token,
        [EnumeratorCancellation] CancellationToken cancellationToken)
    {
        var visited = new HashSet<string>(StringComparer.Ordinal);
        Uri page = firstPage;
        while (visited.Count < MaximumPages && visited.Add(page.AbsoluteUri))
        {
            var document = await SendAsync(HttpMethod.Get, page, token, null, cancellationToken).ConfigureAwait(false);
            if (!document.TryGetProperty("value", out var collection) || collection.ValueKind != JsonValueKind.Array)
                throw Unexpected();
            foreach (var item in collection.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object)
                    throw Unexpected();
                yield return item;
            }

            if (!document.TryGetProperty("@odata.nextLink", out var next) || next.ValueKind == JsonValueKind.Null)
                yield break;
            if (next.ValueKind != JsonValueKind.String || !Uri.TryCreate(next.GetString(), UriKind.Absolute, out var link) ||
                !IsGraph(link) || !string.Equals(link.AbsolutePath, firstPage.AbsolutePath, StringComparison.Ordinal))
                throw Unexpected();
            page = link;
        }
        throw Unexpected();
    }

    internal async Task<JsonElement> SendAsync(HttpMethod method, Uri uri, string token, object? body,
        CancellationToken cancellationToken)
    {
        if (!IsGraph(uri))
            throw Unexpected();
        cancellationToken.ThrowIfCancellationRequested();
        if (clock.GetUtcNow() < retryAfterUtc)
            throw new OutlookException(OutlookFailure.Throttled);

        for (int retry = 0; ; retry++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var request = new HttpRequestMessage(method, uri);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.TryAddWithoutValidation("Prefer", "outlook.timezone=\"China Standard Time\"");
            request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
            if (body is not null)
                request.Content = JsonContent.Create(body);

            try
            {
                using var response = await http.SendAsync(request, cancellationToken).ConfigureAwait(false);
                if (response.StatusCode == HttpStatusCode.TooManyRequests)
                {
                    var header = response.Headers.RetryAfter;
                    var now = clock.GetUtcNow();
                    var delay = header?.Delta
                        ?? (header?.Date is { } date ? date - now : TimeSpan.FromSeconds(1 << retry));
                    retryAfterUtc = now + delay;
                    if (retry == 2 || delay > MaximumRetryDelay)
                        throw new OutlookException(OutlookFailure.Throttled);
                    response.Dispose();
                    if (delay > TimeSpan.Zero)
                        await Task.Delay(delay, clock, cancellationToken).ConfigureAwait(false);
                    continue;
                }

                if (!response.IsSuccessStatusCode)
                    throw new OutlookException(MapStatus(response.StatusCode));
                if (method == HttpMethod.Patch)
                    return default;

                await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
                using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellationToken)
                    .ConfigureAwait(false);
                return document.RootElement.ValueKind == JsonValueKind.Object
                    ? document.RootElement.Clone()
                    : throw Unexpected();
            }
            catch (Exception error) when (error is HttpRequestException or IOException ||
                error is OperationCanceledException && !cancellationToken.IsCancellationRequested)
            { throw new OutlookException(OutlookFailure.Unavailable); }
            catch (JsonException) { throw Unexpected(); }
        }
    }

    private static OutlookFailure MapStatus(HttpStatusCode code) => code switch
    {
        HttpStatusCode.Unauthorized => OutlookFailure.SignInRequired,
        HttpStatusCode.Forbidden => OutlookFailure.PermissionDenied,
        HttpStatusCode.NotFound or HttpStatusCode.Gone => OutlookFailure.CalendarMissing,
        HttpStatusCode.Conflict or HttpStatusCode.PreconditionFailed => OutlookFailure.ConflictingEvents,
        HttpStatusCode.RequestTimeout => OutlookFailure.Unavailable,
        _ when (int)code >= 500 => OutlookFailure.Unavailable,
        _ => OutlookFailure.UnexpectedResponse
    };

    private static bool IsGraph(Uri uri)
        => uri.IsAbsoluteUri && uri.Scheme == Uri.UriSchemeHttps && uri.Host == Root.Host &&
            uri.IsDefaultPort && uri.UserInfo.Length == 0 && uri.Fragment.Length == 0 &&
            uri.AbsolutePath.StartsWith(Root.AbsolutePath, StringComparison.Ordinal);

    internal static string? Text(JsonElement item, string key)
        => item.TryGetProperty(key, out var property) && property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : null;

    internal static OutlookException Unexpected() => new(OutlookFailure.UnexpectedResponse);
}
