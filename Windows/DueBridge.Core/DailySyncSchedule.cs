namespace DueBridge.Core;

public sealed class DailySyncSchedule
{
    private DateOnly? _attemptedDay;
    private bool _transientFailure;

    public bool CanAttempt(DateTimeOffset? lastSuccess, DateTimeOffset now) =>
        DeadlinePresentation.NeedsCatchUp(lastSuccess, now) && _attemptedDay != DeadlinePresentation.ShanghaiDate(now);

    public void MarkAttempt(DateTimeOffset now)
    {
        _attemptedDay = DeadlinePresentation.ShanghaiDate(now);
        _transientFailure = false;
    }

    public void MarkTransientFailure() => _transientFailure = true;

    public void RearmAfterRecovery()
    {
        if (_transientFailure)
            Reset();
    }

    public void Reset()
    {
        _attemptedDay = null;
        _transientFailure = false;
    }
}
