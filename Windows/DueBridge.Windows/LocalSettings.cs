using System.IO;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using DueBridge.Outlook;
using Microsoft.Win32;

namespace DueBridge.Windows;

internal enum SourceKind { Blackboard, Mo, LearningInZju }

internal sealed record SourceBinding(
    string? AccountId = null, bool Enabled = false, DateTimeOffset? LastSuccess = null);

internal sealed record LocalSettings(
    SourceBinding Blackboard,
    SourceBinding Mo,
    SourceBinding LearningInZju,
    string? BlackboardAddress,
    Dictionary<string, string> BlackboardCourses,
    OutlookAccount? OutlookAccount,
    OutlookCalendarBinding? OutlookCalendar,
    bool Paused)
{
    internal static LocalSettings Empty => new(new(), new(), new(), null, new(StringComparer.Ordinal), null, null, false);

    internal SourceBinding Source(SourceKind kind) => kind switch
    {
        SourceKind.Blackboard => Blackboard,
        SourceKind.Mo => Mo,
        SourceKind.LearningInZju => LearningInZju,
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };

    internal LocalSettings WithSource(SourceKind kind, SourceBinding value) => kind switch
    {
        SourceKind.Blackboard => this with { Blackboard = value },
        SourceKind.Mo => this with { Mo = value },
        SourceKind.LearningInZju => this with { LearningInZju = value },
        _ => throw new ArgumentOutOfRangeException(nameof(kind))
    };

    internal LocalSettings ClearSyncConsent() => this with
    {
        Blackboard = Blackboard with { Enabled = false, LastSuccess = null },
        Mo = Mo with { Enabled = false, LastSuccess = null },
        LearningInZju = LearningInZju with { Enabled = false, LastSuccess = null }
    };
}

internal sealed class SettingsStore
{
    internal string DataDirectory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DueBridge");
    private string PathToFile => Path.Combine(DataDirectory, "settings.dpapi");

    internal LocalSettings Load()
    {
        byte[] encrypted;
        try { encrypted = File.ReadAllBytes(PathToFile); }
        catch (FileNotFoundException) { return LocalSettings.Empty; }
        catch (DirectoryNotFoundException) { return LocalSettings.Empty; }
        var plaintext = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
        try
        {
            var settings = JsonSerializer.Deserialize<LocalSettings>(plaintext);
            if (settings?.Blackboard is null || settings.Mo is null || settings.LearningInZju is null ||
                settings.BlackboardCourses is null ||
                (settings.OutlookCalendar is { } target &&
                    (target.Account is null || target.Account.HomeAccountId != settings.OutlookAccount?.HomeAccountId ||
                     string.IsNullOrWhiteSpace(target.CalendarId))))
                throw new JsonException("Invalid DueBridge settings.");
            return settings;
        }
        finally { CryptographicOperations.ZeroMemory(plaintext); }
    }

    internal void Save(LocalSettings settings)
    {
        Directory.CreateDirectory(DataDirectory);
        var temporary = PathToFile + ".tmp";
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(settings);
        try
        {
            var encrypted = ProtectedData.Protect(plaintext, null, DataProtectionScope.CurrentUser);
            using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None))
            {
                stream.Write(encrypted);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, PathToFile, overwrite: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
            if (File.Exists(temporary))
                File.Delete(temporary);
        }
    }

    internal static string OutlookClientId()
    {
#if DEBUG
        var development = Environment.GetEnvironmentVariable("DUEBRIDGE_OUTLOOK_CLIENT_ID");
        if (!string.IsNullOrWhiteSpace(development))
            return development;
#endif
        return typeof(SettingsStore).Assembly.GetCustomAttributes<AssemblyMetadataAttribute>()
            .FirstOrDefault(attribute => attribute.Key == "DueBridgeOutlookClientId")?.Value ?? "";
    }
}

internal static class StartAtLogin
{
    private const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "DueBridge.Windows";

    internal static bool IsEnabled()
    {
        using var run = Registry.CurrentUser.OpenSubKey(Key);
        return run?.GetValue(Name) is string;
    }

    internal static void Set(bool enabled)
    {
        using var run = Registry.CurrentUser.CreateSubKey(Key) ?? throw new IOException();
        if (!enabled)
        {
            run.DeleteValue(Name, throwOnMissingValue: false);
            return;
        }
        var executable = Environment.ProcessPath ?? throw new IOException();
        run.SetValue(Name, $"\"{executable}\" --start-at-login", RegistryValueKind.String);
    }
}
