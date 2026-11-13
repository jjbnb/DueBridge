using System.IO;
using System.Reflection;
using System.Runtime.Versioning;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Win32;

namespace DueBridge.Windows;

[SupportedOSPlatform("windows")]
internal sealed class SettingsStore(string? dataDirectory = null)
{
    internal string DataDirectory { get; } = dataDirectory ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DueBridge");
    private string PathToFile => Path.Combine(DataDirectory, "settings.dpapi");

    internal LocalSettings Load()
    {
        byte[] encrypted;
        try
        {
            if (new FileInfo(PathToFile).Length > 16 * 1024 * 1024)
                throw new JsonException("DueBridge settings are too large.");
            encrypted = File.ReadAllBytes(PathToFile);
        }
        catch (FileNotFoundException) { return LocalSettings.Empty; }
        catch (DirectoryNotFoundException) { return LocalSettings.Empty; }
        var plaintext = ProtectedData.Unprotect(encrypted, null, DataProtectionScope.CurrentUser);
        try
        {
            var settings = JsonSerializer.Deserialize<LocalSettings>(plaintext);
            if (settings is null) throw new JsonException("Invalid DueBridge settings.");
            settings.Validate();
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
            if (plaintext.Length > 16 * 1024 * 1024)
                throw new IOException("DueBridge settings are too large.");
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

[SupportedOSPlatform("windows")]
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
