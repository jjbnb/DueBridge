using System.Buffers;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.RegularExpressions;

namespace DueBridge.Core;

public sealed partial class BlackboardFeed(HttpClient http)
{
    private const string Host = "learn.intl.zju.edu.cn";
    private const string Prefix = "/webapps/calendar/calendarFeed/";
    private const int MaxBytes = 8 * 1024 * 1024;

    public static Uri SignInPage { get; } = new("https://" + Host + "/");

    [GeneratedRegex(@"\Ahttps://(?<authority>[^/?#]+)(?<path>/[^?#]*)(?:\?[^#]*)?\z", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex AbsoluteAddress();

    [GeneratedRegex(@"%(?![0-9A-Fa-f]{2})", RegexOptions.CultureInvariant)]
    private static partial Regex InvalidEscape();

    public static HttpClient CreateHttpClient() => new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        AutomaticDecompression = DecompressionMethods.All,
        ConnectTimeout = TimeSpan.FromSeconds(15),
        MaxConnectionsPerServer = 1,
        PooledConnectionLifetime = TimeSpan.FromMinutes(5)
    }) { Timeout = Timeout.InfiniteTimeSpan };

    public static Uri ValidateAddress(string address)
    {
        var raw = address.Trim();
        var match = AbsoluteAddress().Match(raw);
        string authority = match.Groups["authority"].Value;
        string path = match.Groups["path"].Value;
        if (match.Success && (authority.Equals(Host, StringComparison.OrdinalIgnoreCase) ||
            authority.Equals(Host + ":443", StringComparison.OrdinalIgnoreCase)) &&
            !raw.Any(character => char.IsControl(character) || character == '\\') && !InvalidEscape().IsMatch(raw))
        {
            var decoded = Uri.UnescapeDataString(path);
            if (decoded.StartsWith(Prefix, StringComparison.Ordinal) &&
                !decoded.Any(character => char.IsControl(character) || character == '\\') &&
                !decoded.Split('/').Any(segment => segment is "." or "..") &&
                Uri.TryCreate(raw, UriKind.Absolute, out var uri) && uri.IdnHost == Host)
                return uri;
        }
        throw new BlackboardException("请填写学校 HTTPS 私人日历订阅链接（calendarFeed 路径）。");
    }

    public async Task<SourcePreview> PreviewAsync(string address, CancellationToken cancellationToken)
    {
        var source = ValidateAddress(address);
        var next = source;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(45));
        try
        {
            for (int redirects = 0; ; redirects++)
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, next);
                request.Headers.Accept.ParseAdd("text/calendar, text/plain;q=0.8");
                request.Headers.CacheControl = new CacheControlHeaderValue { NoCache = true, NoStore = true };
                using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token)
                    .ConfigureAwait(false);

                if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
                {
                    next = Redirect(next, response.Headers.Location, redirects);
                    continue;
                }

                if (response.RequestMessage?.RequestUri is { } responseAddress)
                    ValidateAddress(responseAddress.OriginalString);
                if ((int)response.StatusCode is 408 or 429 or >= 500 and <= 599)
                    throw new BlackboardException("暂时无法读取 BB 日历，请稍后重试。", retryable: true);
                if (response.StatusCode != HttpStatusCode.OK)
                    throw new BlackboardException("BB 日历链接无法读取，请重新取得订阅链接。");
                var mime = response.Content.Headers.ContentType?.MediaType?.ToLowerInvariant();
                if (mime is not (null or "text/calendar" or "text/plain" or "application/ics" or
                    "application/octet-stream" or "application/calendar") ||
                    response.Content.Headers.ContentLength > MaxBytes)
                    throw new BlackboardException("服务器返回了登录页、错误页或过大的文件。");

                var bytes = await ReadBoundedAsync(response.Content, timeout.Token).ConfigureAwait(false);
                string body;
                try { body = new UTF8Encoding(false, true).GetString(bytes); }
                catch (DecoderFallbackException) { throw new BlackboardException("BB 日历不是有效的 UTF-8 文本。"); }
                var (entries, warnings) = BlackboardCalendar.ParseWithWarnings(body);
                timeout.Token.ThrowIfCancellationRequested();
                return new SourcePreview(BlackboardCalendar.Hash(source.AbsoluteUri), entries) { Warnings = warnings };
            }
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new BlackboardException("读取 BB 日历超时，请稍后重试。", retryable: true);
        }
        catch (Exception ex) when (ex is HttpRequestException or IOException)
        {
            cancellationToken.ThrowIfCancellationRequested();
            throw new BlackboardException("暂时无法读取 BB 日历，请稍后重试。", retryable: true);
        }
    }

    private static Uri Redirect(Uri previous, Uri? location, int redirects)
    {
        if (redirects >= 4 || location is null)
            throw new BlackboardException("BB 日历跳转无效或次数过多。");
        try
        {
            if (location.IsAbsoluteUri)
                return ValidateAddress(location.OriginalString);
            if (Uri.TryCreate(previous, location, out var resolved))
                return ValidateAddress(resolved.OriginalString);
        }
        catch (BlackboardException)
        {
            throw new BlackboardException("BB 日历跳转到了登录页或学校日历范围之外。");
        }
        throw new BlackboardException("BB 日历跳转无效。");
    }

    private static async Task<byte[]> ReadBoundedAsync(HttpContent content, CancellationToken cancellationToken)
    {
        await using var stream = await content.ReadAsStreamAsync(cancellationToken).ConfigureAwait(false);
        using var output = new MemoryStream();
        var buffer = ArrayPool<byte>.Shared.Rent(16 * 1024);
        try
        {
            int read;
            while ((read = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false)) > 0)
            {
                if (output.Length + read > MaxBytes)
                    throw new BlackboardException("BB 日历文件过大。");
                output.Write(buffer, 0, read);
            }
            return output.ToArray();
        }
        finally { ArrayPool<byte>.Shared.Return(buffer, clearArray: true); }
    }
}
