namespace DueBridge.Core;

public sealed class SyncOperation
{
    private sealed class Run
    {
        public CancellationTokenSource Cancellation { get; } = new();
        public TaskCompletionSource Stopped { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public Task? CancellationCallbacks { get; set; }
    }

    private readonly object _gate = new();
    private Run? _current;

    public async Task<bool> TryRunAsync(Func<CancellationToken, Task> action)
    {
        Run run;
        lock (_gate)
        {
            if (_current is not null)
                return false;
            _current = run = new Run();
        }
        try { await action(run.Cancellation.Token); }
        catch (OperationCanceledException) when (run.Cancellation.IsCancellationRequested) { }
        finally
        {
            Task? callbacks;
            lock (_gate)
            {
                callbacks = run.CancellationCallbacks;
                _current = null;
                run.Stopped.SetResult();
            }
            try
            {
                if (callbacks is not null)
                    await callbacks;
            }
            catch (Exception) { /* CancelAndDrainAsync observes callback failures. */ }
            finally { run.Cancellation.Dispose(); }
        }
        return true;
    }

    public async Task CancelAndDrainAsync()
    {
        Task cancel;
        Task stopped;
        lock (_gate)
        {
            if (_current is not { } run)
                return;
            cancel = run.CancellationCallbacks ??= run.Cancellation.CancelAsync();
            stopped = run.Stopped.Task;
        }
        await Task.WhenAll(cancel, stopped);
    }
}
