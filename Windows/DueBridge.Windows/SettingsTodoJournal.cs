using DueBridge.Outlook;

namespace DueBridge.Windows;

// The UI supplies one atomic dispatcher update, so a journal write cannot overwrite a concurrent pin/settings change.
internal sealed class SettingsTodoJournal(Func<LocalSettings> current,
    Func<Func<LocalSettings, LocalSettings>, LocalSettings> update) : ITodoWriteJournal
{
    public bool IsPending(string operationKey) => current().TodoPending.ContainsKey(operationKey);

    public void Begin(string operationKey, string description) => update(settings =>
    {
        if (settings.TodoPending.ContainsKey(operationKey)) throw new TodoException(TodoFailure.PendingCreation);
        var pending = new Dictionary<string, string>(settings.TodoPending, StringComparer.Ordinal)
            { [operationKey] = description };
        return settings with { TodoPending = pending };
    });

    public void Complete(string operationKey)
    {
        if (!IsPending(operationKey)) return;
        update(settings =>
    {
        var pending = new Dictionary<string, string>(settings.TodoPending, StringComparer.Ordinal);
        pending.Remove(operationKey);
        return settings with { TodoPending = pending };
        });
    }
}
