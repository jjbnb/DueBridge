using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;

namespace DueBridge.School;

public enum SchoolPlatform { Mo, LearningInZju }

public sealed class SchoolConnectionException(string message, bool retryable = false) : Exception(message)
{
    public bool Retryable { get; } = retryable;
}

internal sealed record SchoolRequest(string Path, string? Body = null);

internal sealed record SchoolPolicy(SchoolPlatform Platform, string Id, string Label, string Host, string Login)
{
    private const string CallbackPrefix = "http://mo.zju.edu.cn/";
    public string Origin => "https://" + Host;
    public string Background => Origin + "/robots.txt";

    public static SchoolPolicy For(SchoolPlatform platform) => platform switch
    {
        SchoolPlatform.Mo => new(platform, "mo", "智海 MO", "mo.zju.edu.cn",
            "https://zjuam.zju.edu.cn/cas/oauth2.0/authorize?response_type=code&client_id=mU53a5ysj5jfo8PUvP&redirect_uri=http://mo.zju.edu.cn/user/login"),
        SchoolPlatform.LearningInZju => new(platform, "learning-in-zju", "学在浙大", "courses.zju.edu.cn",
            "https://courses.zju.edu.cn/"),
        _ => throw new ArgumentOutOfRangeException(nameof(platform))
    };

    public bool AllowsNavigation(string url, bool interactive)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            uri.Port != 443 || uri.UserInfo.Length != 0) return false;
        return uri.IdnHost == Host || interactive && uri.IdnHost is "zjuam.zju.edu.cn" or "identity.zju.edu.cn";
    }

    public bool IsCallbackCandidate(string url)
    {
        if (Platform != SchoolPlatform.Mo || !url.StartsWith(CallbackPrefix, StringComparison.OrdinalIgnoreCase))
            return false;
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.AbsolutePath != "/user/login")
            return false;
        var suffix = url[CallbackPrefix.Length..];
        int parameter = suffix.IndexOfAny(['?', '#']);
        return (parameter < 0 ? suffix : suffix[..parameter]) == "user/login";
    }

    public Uri? TryUpgradeCallback(string url, string method, bool hasBody)
    {
        if (method != "GET" || hasBody || !IsCallbackCandidate(url)) return null;
        return new Uri("https://mo.zju.edu.cn/" + url[CallbackPrefix.Length..]);
    }

    public static bool ValidId(string? value) =>
        !string.IsNullOrWhiteSpace(value) && Encoding.UTF8.GetByteCount(value) <= 1024 && !value.Any(char.IsControl);

    public static string HashFields(params string[] fields)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        Span<byte> length = stackalloc byte[8];
        foreach (var field in fields)
        {
            byte[] bytes = Encoding.UTF8.GetBytes(field);
            BinaryPrimitives.WriteUInt64BigEndian(length, (ulong)bytes.Length);
            hash.AppendData(length);
            hash.AppendData(bytes);
        }
        return Convert.ToHexStringLower(hash.GetHashAndReset());
    }
}
